#!/bin/bash
# Interactive 'init' wizard (sourced; needs tools.sh, prompt.sh, tfvars.sh,
# tfc_api.sh, sg_api.sh, state.sh). Discovers TFC orgs/workspaces and SG
# integrations / runner groups with the tokens already in the environment and
# writes terraform.tfvars. Every step degrades to free-text entry when a token is
# missing or an API call fails, so the wizard always completes.
#
# What TFC knows about the workspaces steers the StackGuardian step: the VCS
# provider each workspace is connected to ranks the matching connectors first,
# and the repositories' URL gives the repo URL prefix (so a rerun that switches
# connector never keeps a prefix from the previous provider).
#
# shellcheck disable=SC2034  # the W_* results are consumed by tfvars_write (lib/tfvars.sh)

# _w_default <jq-expr> <fallback> — current tfvars value (re-run) or fallback.
_w_default() { local v; v="$(tfvars_get "$1")"; printf '%s' "${v:-$2}"; }

# _w_csv_json <csv> — "a, b" -> ["a","b"]; empty -> [].
_w_csv_json() {
  local jqb out
  jqb="$(sg_resolve jq sg_ensure_jq)"
  # (grep -v exits 1 on empty input; never let that trigger the fallback twice)
  out="$(printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | { grep -v '^$' || true; } | "$jqb" -R . | "$jqb" -sc . 2>/dev/null)"
  printf '%s' "${out:-[]}"
}

# _w_csv <json-array> — ["a","b"] -> "a, b" (for the review).
_w_csv() { printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" -r 'if type == "array" then join(", ") else tostring end' 2>/dev/null; }

# _w_repo_prefix_for <sourceConfigDestKind> — the provider's well-known host,
# used only when TFC does not tell us where the repositories live.
_w_repo_prefix_for() {
  case "$1" in
  GITHUB_COM) printf 'https://github.com' ;;
  GITLAB_COM) printf 'https://gitlab.com' ;;
  BITBUCKET_ORG) printf 'https://bitbucket.org' ;;
  AZURE_DEVOPS) printf 'https://dev.azure.com' ;;
  *) printf 'https://VCS_PROVIDER_DOMAIN' ;;
  esac
}

# _w_host <url> — "https://www.github.com/x" -> "www.github.com".
_w_host() { local h="${1#*://}"; printf '%s' "${h%%/*}"; }

# _w_select_lines <question> <lines> [extra-items...] — sg_select (with an
# "Other" entry) over newline-separated "value|desc" items; names may contain
# spaces or glob characters, so no word splitting.
_w_select_lines() {
  local q="$1" lines="$2" line
  shift 2
  local -a items=()
  while IFS= read -r line; do [ -n "$line" ] && items+=("$line"); done <<<"$lines"
  SG_SELECT_OTHER=1 sg_select "$q" "${items[@]}" "$@"
}

# _w_project_counts <workspaces-json> <projects-json> <groups:0|1> —
# "Default Project (2), Team A (1)" or, as SG groups, "tfc-default-project (2), ...".
_w_project_counts() {
  printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" -r --argjson pr "$2" --argjson g "$3" '
    ($pr | map({key: .id, value: .name}) | from_entries) as $names
    | group_by(.project) | sort_by(-length)
    | map((($names[.[0].project] // .[0].project) as $n
           | if $g == 1 then "tfc-" + ($n | ascii_downcase | gsub("[^a-z0-9-]+"; "-")) else $n end) + " (\(length))")
    | join(", ")' 2>/dev/null
}

# _w_tfc_kind_matches <sg-kind> — exit 0 when the TFC workspaces use that provider.
_w_tfc_kind_matches() {
  [ -n "$1" ] || return 1
  case " ${W_TFC_VCS_KINDS:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# --- step 1: Terraform Cloud ------------------------------------------------
wizard_tfc() {
  local host token orgs n ws projects wsn prn scope tags alltags sel prov cnt prefix kind
  local jqb
  jqb="$(sg_resolve jq sg_ensure_jq)"
  sg_step "1/4 Terraform Cloud / Enterprise"
  host="$(sg_ask "TFC/TFE hostname" "$(_w_default .tfHostname app.terraform.io)")" || return 1
  W_TFHOST="$host"
  # shellcheck disable=SC2034  # consumed by tfc_http (lib/tfc_api.sh)
  TFC_HOST="$host"
  token="$(tfc_token "$host")"
  W_TFC_DISCOVERY=0
  if [ -z "$token" ]; then
    sg_warn "no TFC credentials found for $host (TFE_TOKEN or 'terraform login'); organisations and workspaces cannot be listed"
  elif ! tfc_http "account/details" >/dev/null; then
    sg_warn "TFC rejected $(tfc_token_source) for $host (HTTP $TFC_HTTP_CODE); continuing without discovery"
  else
    W_TFC_DISCOVERY=1
  fi

  if [ "$W_TFC_DISCOVERY" -eq 1 ] && orgs="$(tfc_list_orgs 2>/dev/null)" && [ "$(printf '%s' "$orgs" | "$jqb" 'length')" -gt 0 ]; then
    n="$(printf '%s' "$orgs" | "$jqb" 'length')"
    if [ "$n" -eq 1 ]; then
      W_TFORG="$(printf '%s' "$orgs" | "$jqb" -r '.[0]')"
      sg_log "organisation: $W_TFORG (the only one this token can see)"
    else
      W_TFORG="$(_w_select_lines "Which TFC organisation do you want to migrate?" "$(printf '%s' "$orgs" | "$jqb" -r '.[]')")" || return 1
    fi
  else
    W_TFORG="$(sg_ask "TFC organisation name" "$(_w_default .tfOrg '')")" || return 1
    [ -n "$W_TFORG" ] || W_TFORG="$(sg_ask_required "TFC organisation name")" || return 1
  fi

  W_WSNAMES_JSON='["*"]'
  W_TAGS_JSON=null
  W_IGNORE_TAGS_JSON=null
  W_TFC_WS_JSON=""
  W_WS_COUNT=""
  W_WS_TOTAL=""
  W_WS_ABOVE_CEILING=""
  W_GROUPS=""
  W_TFC_VCS=""
  W_TFC_VCS_KINDS=""
  W_TFC_REPO_PREFIX=""
  W_TFC_VCS_OTHER=0
  projects='[]'
  if [ "$W_TFC_DISCOVERY" -eq 1 ] && ws="$(tfc_list_workspaces "$W_TFORG" 2>/dev/null)"; then
    W_TFC_WS_JSON="$ws"
    wsn="$(printf '%s' "$ws" | "$jqb" 'length')"
    projects="$(tfc_list_projects "$W_TFORG" 2>/dev/null || echo '[]')"
    prn="$(printf '%s' "$projects" | "$jqb" 'length')"
    sg_log "found $wsn workspace(s) in $prn project(s); each project becomes SG workflow group tfc-<project>"
    [ "$prn" -le 8 ] && [ "$wsn" -gt 0 ] && sg_dim "$(_w_project_counts "$ws" "$projects" 0)"
    alltags="$(printf '%s' "$ws" | "$jqb" -r '[.[].tags[]?] | unique | join(", ")')"
  else
    alltags=""
  fi
  scope="$(sg_select "Which workspaces should be migrated?" \
    "all|every workspace in the organisation" \
    "tags|only workspaces carrying certain tags" \
    "exclude|all workspaces except those carrying certain tags" \
    "names|specific workspace names")" || return 1
  W_SCOPE="$scope"
  case "$scope" in
  tags)
    [ -n "$alltags" ] && sg_dim "tags in use: $alltags"
    tags="$(sg_ask_required "Tags to include (comma-separated)")" || return 1
    W_TAGS_JSON="$(_w_csv_json "$tags")"
    ;;
  exclude)
    [ -n "$alltags" ] && sg_dim "tags in use: $alltags"
    tags="$(sg_ask_required "Tags to exclude (comma-separated)")" || return 1
    W_IGNORE_TAGS_JSON="$(_w_csv_json "$tags")"
    ;;
  names)
    tags="$(sg_ask_required "Workspace names (comma-separated, * wildcards allowed)")" || return 1
    W_WSNAMES_JSON="$(_w_csv_json "$tags")"
    ;;
  esac

  # What the selection looks like (drives the review and the SG step's hints).
  if [ -n "$W_TFC_WS_JSON" ]; then
    sel="$(tfc_select_workspaces "$W_TFC_WS_JSON" "$W_WSNAMES_JSON" "$W_TAGS_JSON" "$W_IGNORE_TAGS_JSON")"
    W_WS_TOTAL="$wsn"
    W_WS_COUNT="$(printf '%s' "$sel" | "$jqb" 'length')"
    W_WS_ABOVE_CEILING="$(printf '%s' "$sel" | "$jqb" '[.[] | select((.terraform_version // "") | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | select(((.terraform_version | split(".") | map(tonumber)) as $v | ($v[0] > 1) or ($v[0] == 1 and $v[1] > 5) or ($v[0] == 1 and $v[1] == 5 and $v[2] > 7)))] | length')"
    W_GROUPS="$(_w_project_counts "$sel" "$projects" 1)"
    if [ "$scope" != "all" ]; then
      if [ "$W_WS_COUNT" -eq 0 ]; then
        sg_warn "no workspace matches that selection — 'apply' would export nothing"
      else
        sg_log "$W_WS_COUNT of $wsn workspace(s) match"
      fi
    fi
    # VCS providers in use, most common first; the first one's repo URL prefix
    # becomes the default for every workflow (others need workspaceOverrides).
    W_TFC_VCS="$(tfc_vcs_summary "$sel")"
    while IFS=$'\t' read -r prov cnt prefix; do
      [ -n "$prov" ] || continue
      kind="$(tfc_vcs_kind_for "$prov")"
      [ -n "$kind" ] && W_TFC_VCS_KINDS="$W_TFC_VCS_KINDS $kind"
      if [ -z "$W_TFC_REPO_PREFIX" ]; then
        [ "$prefix" != "-" ] && W_TFC_REPO_PREFIX="$prefix"
      else
        W_TFC_VCS_OTHER=$((W_TFC_VCS_OTHER + cnt))
      fi
    done <<<"$W_TFC_VCS"
  fi
  return 0
}

# --- step 2: StackGuardian ---------------------------------------------------
wizard_sg() {
  local ints vcs cloud pick kind name runner groups jqb hint prov cnt prefix prev_kind prev_prefix line k
  jqb="$(sg_resolve jq sg_ensure_jq)"
  sg_step "2/4 StackGuardian"
  if [ -z "$ORG" ]; then
    ORG="$(sg_ask_required "StackGuardian organisation")" || return 1
  else
    sg_log "organisation: $ORG (from --org / SG_ORG)"
  fi
  W_SG_DISCOVERY=0
  if [ -z "${SG_API_TOKEN:-}" ]; then
    sg_warn "SG_API_TOKEN is not set; connectors and runner groups cannot be listed (export it and re-run 'init' to pick from a list)"
  elif ! ints="$(sg_list_integrations)"; then
    case "$SG_HTTP_CODE" in
    401 | 403) sg_warn "StackGuardian rejected SG_API_TOKEN for org '$ORG' (HTTP $SG_HTTP_CODE); continuing without discovery" ;;
    404) sg_warn "StackGuardian org '$ORG' not found at $SG_BASE_URL (HTTP 404); continuing without discovery" ;;
    *) sg_warn "could not list connectors (HTTP $SG_HTTP_CODE); continuing without discovery" ;;
    esac
  else
    W_SG_DISCOVERY=1
  fi

  # VCS connector -> integration id, source kind, repo prefix. Connectors of the
  # provider the TFC workspaces are connected to come first (and are the default).
  if [ -n "${W_TFC_VCS:-}" ]; then
    hint=""
    while IFS=$'\t' read -r prov cnt prefix; do
      [ -n "$prov" ] || continue
      hint="$hint${hint:+, }$(tfc_vcs_label_for "$prov") ($cnt)"
    done <<<"$W_TFC_VCS"
    sg_dim "the selected TFC workspaces are connected to: $hint — matching connectors are listed first"
  elif [ -n "${W_TFC_WS_JSON:-}" ] && [ "${W_WS_COUNT:-0}" -gt 0 ]; then
    sg_dim "none of the selected TFC workspaces is VCS-connected (CLI-driven); pick the connector for the repositories anyway"
  fi
  vcs=""
  if [ "$W_SG_DISCOVERY" -eq 1 ]; then
    local -a first=() rest=()
    while IFS='|' read -r name kind; do
      [ -n "$name" ] || continue
      if _w_tfc_kind_matches "$(sg_vcs_kind_of "$kind")"; then first+=("$name|$kind"); else rest+=("$name|$kind"); fi
    done <<<"$(printf '%s' "$ints" | "$jqb" -r '[.[] | select((.type // "") | IN("GITHUB_COM","GITHUB_APP_CUSTOM","GITLAB_COM","GITLAB_OAUTH_SSH","BITBUCKET_ORG","AZURE_DEVOPS","AZURE_DEVOPS_SP","GIT_OTHER"))] | sort_by(.name) | .[] | "\(.name)|\(.type)"')"
    vcs="$(printf '%s\n' ${first[@]+"${first[@]}"} ${rest[@]+"${rest[@]}"})"
  fi
  if [ -n "$vcs" ]; then
    pick="$(_w_select_lines "Which VCS connector should clone the repositories?" "$vcs")" || return 1
    kind="$(sg_integration_type "$ints" "$pick")"
  else
    pick="$(sg_ask "VCS connector name (as in StackGuardian, e.g. github_com)" "$(_w_default .SGDefaultVCSAuthIntegrationID '' | sed 's#^/integrations/##')")" || return 1
    [ -n "$pick" ] || pick="$(sg_ask_required "VCS connector name")" || return 1
    kind=""
  fi
  W_VCS_INTEGRATION="/integrations/${pick#/integrations/}"
  W_DEST_KIND="$(sg_vcs_kind_of "$kind")"
  if [ -z "$W_DEST_KIND" ]; then
    # Unknown connector type (or no discovery): ask, defaulting to what TFC uses.
    local -a kinds=(GITHUB_COM GITLAB_COM BITBUCKET_ORG AZURE_DEVOPS GIT_OTHER)
    for k in ${W_TFC_VCS_KINDS:-}; do kinds=("$k" "${kinds[@]}"); break; done
    W_DEST_KIND="$(sg_select "VCS provider kind" "${kinds[@]}")" || return 1
  fi
  if [ -n "${W_TFC_VCS_KINDS:-}" ] && ! _w_tfc_kind_matches "$W_DEST_KIND"; then
    sg_warn "the TFC workspaces are connected to $(tfc_vcs_label_for "${W_TFC_VCS%%	*}") but '$pick' is a $W_DEST_KIND connector — the workflows will not be able to clone unless the repositories moved"
  fi
  # Repo URL prefix: where TFC says the repositories live; otherwise the previous
  # value (only if the provider kind did not change — this is what used to leave
  # a stale prefix behind); otherwise the provider's well-known host.
  prev_kind="$(tfvars_get .SGDefaultSourceConfigDestKind)"
  prev_prefix="$(tfvars_get .SGDefaultIACVCSRepoPrefix)"
  [ "$prev_kind" = "$W_DEST_KIND" ] || prev_prefix=""
  if [ -n "${W_TFC_REPO_PREFIX:-}" ]; then
    # Keep a hand-tuned variant of the same host (e.g. www.github.com).
    case "$(_w_host "$prev_prefix")" in
    *"$(_w_host "$W_TFC_REPO_PREFIX")") [ -n "$prev_prefix" ] && W_REPO_PREFIX="$prev_prefix" || W_REPO_PREFIX="$W_TFC_REPO_PREFIX" ;;
    *) W_REPO_PREFIX="$W_TFC_REPO_PREFIX" ;;
    esac
  elif [ -n "$prev_prefix" ]; then
    W_REPO_PREFIX="$prev_prefix"
  else
    W_REPO_PREFIX="$(_w_repo_prefix_for "$W_DEST_KIND")"
  fi

  # Cloud connector -> DeploymentPlatformConfig.
  cloud=""
  # Only kinds DeploymentPlatformConfig accepts (AZURE_DEVOPS* are VCS connectors).
  [ "$W_SG_DISCOVERY" -eq 1 ] && cloud="$(printf '%s' "$ints" | "$jqb" -r '[.[] | select((.type // "") | IN("AWS_STATIC","AWS_RBAC","AWS_OIDC","AZURE_STATIC","AZURE_OIDC","AZURE_MANAGED_ID_OIDC","GCP_STATIC","GCP_OIDC"))] | sort_by(.type, .name) | .[] | "\(.name)|\(.type)"')"
  if [ -n "$cloud" ]; then
    pick="$(_w_select_lines "Which cloud connector should the workflows deploy with?" "$cloud" "skip|decide later (leaves a placeholder to edit)")" || return 1
    kind="$(sg_integration_type "$ints" "$pick")"
  else
    pick="$(sg_ask "Cloud connector name (as in StackGuardian; empty to decide later)" "$(_w_default .SGDefaultDeploymentPlatformConfig[0].config.integrationId '' | sed 's#^/integrations/##')")" || return 1
    kind=""
  fi
  if [ -z "$pick" ] || [ "$pick" = "skip" ]; then
    W_DPC_JSON='[{"kind":"AWS_RBAC","config":{"integrationId":"/integrations/CHANGE_ME"}}]'
    W_DPC_PLACEHOLDER=1
    W_CLOUD_DESC="none yet — a placeholder is written; edit it before 'apply'"
  else
    [ -n "$kind" ] || kind="$(sg_select "Connector kind" AWS_RBAC AWS_STATIC AWS_OIDC AZURE_STATIC AZURE_OIDC AZURE_MANAGED_ID_OIDC GCP_STATIC GCP_OIDC)" || return 1
    W_DPC_JSON="$("$jqb" -nc --arg k "$kind" --arg i "/integrations/${pick#/integrations/}" '[{kind:$k, config:{integrationId:$i}}]')"
    W_DPC_PLACEHOLDER=0
    W_CLOUD_DESC="${pick#/integrations/} ($kind)"
  fi

  # The org's execution preset (Settings -> Runner groups -> Execution presets):
  # what StackGuardian fills in for runners / Terraform version when the payload
  # carries none. Read once here; steps 2 and 3 offer it as a choice.
  W_PRESET_JSON='{}'
  W_PRESET_READ=0
  W_PRESET_RUNNER=""
  W_PRESET_TFVER=""
  if [ "$W_SG_DISCOVERY" -eq 1 ]; then
    if W_PRESET_JSON="$(sg_execution_preset)"; then
      W_PRESET_READ=1
      W_PRESET_RUNNER="$(sg_preset_runner_desc "$W_PRESET_JSON")"
      W_PRESET_TFVER="$(sg_preset_version_desc "$W_PRESET_JSON")"
      if [ "$W_PRESET_JSON" = "{}" ]; then
        sg_dim "execution preset: none configured in $ORG — StackGuardian's platform defaults apply ($W_PRESET_TFVER on $W_PRESET_RUNNER)"
      else
        sg_dim "execution preset of $ORG: $W_PRESET_TFVER on $W_PRESET_RUNNER"
      fi
    fi
  fi

  # Runner constraints: the org's execution preset (first when we could read it
  # and nothing explicit was configured before), SG shared runners, or a private
  # runner group.
  local -a runner_items=("shared|StackGuardian-hosted shared runners" "private|a private runner group in your own network")
  local preset_item="preset|whatever the org's execution preset says${W_PRESET_RUNNER:+ (now: $W_PRESET_RUNNER)}"
  if tfvars_is_null SGDefaultRunnerConstraints || { [ "$W_PRESET_READ" -eq 1 ] && ! tfvars_has SGDefaultRunnerConstraints; }; then
    runner_items=("$preset_item" "${runner_items[@]}")
  else
    runner_items+=("$preset_item")
  fi
  runner="$(sg_select "Where should the workflows run?" "${runner_items[@]}")" || return 1
  if [ "$runner" = "preset" ]; then
    W_RUNNER_JSON="null"
    W_RUNNER_DESC="from the org's execution preset${W_PRESET_RUNNER:+ (now: $W_PRESET_RUNNER)}"
  elif [ "$runner" = "private" ]; then
    groups=""
    [ "$W_SG_DISCOVERY" -eq 1 ] && groups="$(sg_list_runnergroups 2>/dev/null | "$jqb" -r 'sort | .[]' 2>/dev/null || true)"
    if [ -n "$groups" ]; then
      name="$(_w_select_lines "Which runner group?" "$groups")" || return 1
    else
      name="$(sg_ask_required "Runner group name")" || return 1
    fi
    if [ "$W_SG_DISCOVERY" -eq 1 ] && ! sg_runnergroup_exists "$name"; then
      sg_warn "runner group '$name' was not found in org '$ORG' — preflight will fail until it exists"
    fi
    W_RUNNER_JSON="$("$jqb" -nc --arg n "$name" '{type:"private", names:[$n]}')"
    W_RUNNER_DESC="private runner group '$name'"
  else
    W_RUNNER_JSON='{"type":"shared"}'
    W_RUNNER_DESC="StackGuardian shared runners"
  fi
}

# --- step 3: policy ------------------------------------------------------------
wizard_policy() {
  sg_step "3/4 Workflow defaults"
  # Approvers, repo prefix and the fallback Terraform version are plain values
  # with sensible defaults — edit them in terraform.tfvars if needed.
  W_APPROVERS_JSON="$(tfvars_get_json .SGDefaultWfApprovers)"
  [ "$W_APPROVERS_JSON" = "null" ] && W_APPROVERS_JSON='[]'

  # Terraform version: carry the TFC pins (plus a fallback for the rest) or send
  # none and let the org's execution preset decide. Previous choices come first.
  local src fb prev_src prev_fb fixed above_hint=""
  local -a src_items fb_items
  [ "${W_WS_ABOVE_CEILING:-0}" -gt 0 ] && above_hint=" ($W_WS_ABOVE_CEILING pinned above SG's 1.5.7 ceiling would use the fallback)"
  src_items=("carry|keep each workspace's pinned TFC version$above_hint"
    "preset|no version at all: the org's execution preset applies${W_PRESET_TFVER:+ (now: $W_PRESET_TFVER)}")
  prev_src="$(_w_default .SGTerraformVersionSource carry)"
  [ "$prev_src" = "preset" ] && src_items=("${src_items[1]}" "${src_items[0]}")
  src="$(sg_select "Which Terraform version should the migrated workflows run?" "${src_items[@]}")" || return 1
  W_TF_SOURCE="$src"
  if [ "$src" = "preset" ]; then
    W_TF_VERSION="null"
  else
    if tfvars_is_null SGDefaultTerraformVersion; then prev_fb="null"; else prev_fb="$(_w_default .SGDefaultTerraformVersion TERRAFORM-1.5.7)"; fi
    [ "$prev_fb" = "null" ] && fixed="TERRAFORM-1.5.7" || fixed="TERRAFORM-${prev_fb#TERRAFORM-}"
    fb_items=("${fixed#TERRAFORM-}|a fixed version ($fixed; StackGuardian bundles Terraform up to 1.5.7)"
      "preset|the org's execution preset${W_PRESET_TFVER:+ (now: $W_PRESET_TFVER)}")
    [ "$prev_fb" = "null" ] && fb_items=("${fb_items[1]}" "${fb_items[0]}")
    fb="$(sg_select "Fallback for workspaces without a pinned version, and for pins StackGuardian rejects (above 1.5.7)?" "${fb_items[@]}")" || return 1
    case "$fb" in
    preset) W_TF_VERSION="null" ;;
    *) W_TF_VERSION="TERRAFORM-${fb#TERRAFORM-}" ;;
    esac
  fi
  if sg_confirm "Export Terraform state for each workspace?" "$([ "$(_w_default .exportStateFiles true)" = "false" ] && echo N || echo Y)"; then W_EXPORT_STATE=true; else W_EXPORT_STATE=false; fi
  if sg_confirm "Pre-configure VCS triggers (push / pull-request runs) from the TFC settings?" "$([ "$(_w_default .SGDefaultEnableVCSTriggers true)" = "false" ] && echo N || echo Y)"; then W_TRIGGERS=true; else W_TRIGGERS=false; fi
  sg_dim "TFC_* / TFE_* variables (e.g. TFC_WORKSPACE_NAME, TFC_AWS_RUN_ROLE_ARN) only mean something inside Terraform Cloud."
  if sg_confirm "Strip TFC-specific variables (TFC_*, TFE_*) from the migrated workflows?" "$([ "$(tfvars_get_json .ignoreVarPatterns)" = "[]" ] && echo N || echo Y)"; then
    W_IGNORE_PATTERNS_JSON='["^TFC_","^TFE_"]'
  else
    W_IGNORE_PATTERNS_JSON='[]'
  fi
}

# --- step 4: review + write ----------------------------------------------------
wizard_review() {
  local scope tf yn_state yn_trig strip
  sg_step "4/4 Review"
  sg_row "TFC" "$W_TFHOST / $W_TFORG"
  case "${W_SCOPE:-all}" in
  tags) scope="workspaces tagged $(_w_csv "$W_TAGS_JSON")" ;;
  exclude) scope="all workspaces except those tagged $(_w_csv "$W_IGNORE_TAGS_JSON")" ;;
  names) scope="workspaces named $(_w_csv "$W_WSNAMES_JSON")" ;;
  *) scope="all workspaces" ;;
  esac
  if [ -n "${W_WS_COUNT:-}" ]; then
    if [ "${W_SCOPE:-all}" = "all" ]; then scope="$scope ($W_WS_COUNT)"; else scope="$scope — $W_WS_COUNT of $W_WS_TOTAL match"; fi
  fi
  sg_row "Workspaces" "$scope"
  [ -n "${W_GROUPS:-}" ] && sg_row "Workflow groups" "$W_GROUPS"
  sg_row "StackGuardian org" "$ORG"
  sg_row "VCS connector" "${W_VCS_INTEGRATION#/integrations/} ($W_DEST_KIND) — repositories under $W_REPO_PREFIX"
  sg_row "Cloud connector" "$W_CLOUD_DESC"
  sg_row "Runners" "$W_RUNNER_DESC"
  [ "$W_EXPORT_STATE" = "true" ] && yn_state=yes || yn_state=no
  [ "$W_TRIGGERS" = "true" ] && yn_trig="yes, from each workspace's TFC settings" || yn_trig=no
  sg_row "State export" "$yn_state"
  sg_row "VCS triggers" "$yn_trig"
  [ "$W_IGNORE_PATTERNS_JSON" = "[]" ] && strip="none" || strip="TFC_*, TFE_*"
  sg_row "Strip variables" "$strip"
  if [ "${W_TF_SOURCE:-carry}" = "preset" ]; then
    tf="from the org's execution preset${W_PRESET_TFVER:+ (now: $W_PRESET_TFVER)}"
  else
    if [ "${W_TF_VERSION:-null}" = "null" ]; then
      tf="carried from TFC; unpinned workspaces and pins above 1.5.7 go to the execution preset${W_PRESET_TFVER:+ (now: $W_PRESET_TFVER)}"
    else
      tf="carried from TFC; fallback ${W_TF_VERSION#TERRAFORM-} for unpinned workspaces and pins above 1.5.7"
    fi
    [ "${W_WS_ABOVE_CEILING:-0}" -gt 0 ] && tf="$tf — $W_WS_ABOVE_CEILING workspace(s) affected"
  fi
  sg_row "Terraform version" "$tf"
  [ "${W_DPC_PLACEHOLDER:-0}" -eq 1 ] && sg_warn "cloud connector left as a placeholder — edit SGDefaultDeploymentPlatformConfig in $(sg_rel "$TFVARS") before 'apply'"
  [ "${W_TFC_VCS_OTHER:-0}" -gt 0 ] && sg_warn "$W_TFC_VCS_OTHER workspace(s) use a different VCS provider than the default above — give them their own connector/prefix via workspaceOverrides in $(sg_rel "$TFVARS")"
  sg_dim "approvers and the repo URL prefix can be edited in $(sg_rel "$TFVARS")"
  sg_confirm "Write $(sg_rel "$TFVARS")?" Y
}

# wizard_run — the whole flow; returns non-zero when aborted.
wizard_run() {
  local kept=""
  wizard_tfc && wizard_sg && wizard_policy || { sg_err "init aborted"; return 1; }
  wizard_review || { sg_log "nothing written"; return 1; }
  if [ -f "$TFVARS" ]; then
    cp "$TFVARS" "$TFVARS.bak"
    kept=" (previous version kept as $(basename "$TFVARS").bak)"
  fi
  tfvars_write "$TFVARS"
  if ! tfvars_valid; then
    sg_err "the generated $(sg_rel "$TFVARS") is not valid HCL — this is a bug in the wizard; the file was kept for inspection"
    return 1
  fi
  # Remember the SG org (and API host) for later phases, so users don't have to
  # export SG_ORG again in a new shell. Tokens are never stored.
  state_update '.config = ((.config // {}) + {sg_org: $o, sg_base_url: $u})' --arg o "$ORG" --arg u "$SG_BASE_URL"
  sg_success "wrote $(sg_rel "$TFVARS")$kept"
}
