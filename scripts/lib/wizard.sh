#!/bin/bash
# Interactive 'init' wizard (sourced; needs tools.sh, prompt.sh, tfvars.sh,
# tfc_api.sh, sg_api.sh). Discovers TFC orgs/workspaces and SG integrations /
# runner groups with the tokens already in the environment and writes
# terraform.tfvars. Every step degrades to free-text entry when a token is
# missing or an API call fails, so the wizard always completes.

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

# _w_repo_prefix_for <sourceConfigDestKind> — proposed repo URL prefix.
_w_repo_prefix_for() {
  case "$1" in
  GITHUB_COM) printf 'https://github.com' ;;
  GITLAB_COM) printf 'https://gitlab.com' ;;
  BITBUCKET_ORG) printf 'https://bitbucket.org' ;;
  AZURE_DEVOPS) printf 'https://dev.azure.com' ;;
  *) printf 'https://VCS_PROVIDER_DOMAIN' ;;
  esac
}

# --- step 1: Terraform Cloud ------------------------------------------------
wizard_tfc() {
  local host token orgs n ws projects wsn prn scope tags alltags
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
      # shellcheck disable=SC2046
      W_TFORG="$(SG_SELECT_OTHER=1 sg_select "Which TFC organisation do you want to migrate?" $(printf '%s' "$orgs" | "$jqb" -r '.[]'))" || return 1
    fi
  else
    W_TFORG="$(sg_ask "TFC organisation name" "$(_w_default .tfOrg '')")" || return 1
    [ -n "$W_TFORG" ] || W_TFORG="$(sg_ask_required "TFC organisation name")" || return 1
  fi

  W_WSNAMES_JSON='["*"]'
  W_TAGS_JSON=null
  W_IGNORE_TAGS_JSON=null
  if [ "$W_TFC_DISCOVERY" -eq 1 ] && ws="$(tfc_list_workspaces "$W_TFORG" 2>/dev/null)"; then
    wsn="$(printf '%s' "$ws" | "$jqb" 'length')"
    projects="$(tfc_list_projects "$W_TFORG" 2>/dev/null || echo '[]')"
    prn="$(printf '%s' "$projects" | "$jqb" 'length')"
    sg_log "found $wsn workspace(s) in $prn project(s); each project becomes SG workflow group tfc-<project>"
    W_WS_COUNT="$wsn"
    W_WS_ABOVE_CEILING="$(printf '%s' "$ws" | "$jqb" '[.[] | select((.terraform_version // "") | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | select(((.terraform_version | split(".") | map(tonumber)) as $v | ($v[0] > 1) or ($v[0] == 1 and $v[1] > 5) or ($v[0] == 1 and $v[1] == 5 and $v[2] > 7)))] | length')"
    alltags="$(printf '%s' "$ws" | "$jqb" -r '[.[].tags[]?] | unique | join(", ")')"
  else
    alltags=""
  fi
  scope="$(sg_select "Which workspaces should be migrated?" \
    "all|every workspace in the organisation" \
    "tags|only workspaces carrying certain tags" \
    "exclude|all workspaces except those carrying certain tags" \
    "names|specific workspace names")" || return 1
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
}

# --- step 2: StackGuardian ---------------------------------------------------
wizard_sg() {
  local ints vcs cloud pick kind name runner groups jqb
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

  # VCS connector -> integration id, source kind, repo prefix.
  vcs=""
  [ "$W_SG_DISCOVERY" -eq 1 ] && vcs="$(printf '%s' "$ints" | "$jqb" -r '.[] | select((.type // "") | test("^(GITHUB_COM|GITHUB_APP_CUSTOM|GITLAB_COM|BITBUCKET_ORG|AZURE_DEVOPS|GIT_OTHER)$")) | "\(.name)|\(.type)"')"
  if [ -n "$vcs" ]; then
    # shellcheck disable=SC2046
    pick="$(SG_SELECT_OTHER=1 sg_select "Which VCS connector should clone the repositories?" $(printf '%s\n' "$vcs" | tr '\n' ' '))" || return 1
    kind="$(printf '%s' "$ints" | "$jqb" -r --arg n "$pick" '.[] | select(.name == $n) | .type' | head -1)"
  else
    pick="$(sg_ask "VCS connector name (as in StackGuardian, e.g. github_com)" "$(_w_default .SGDefaultVCSAuthIntegrationID '' | sed 's#^/integrations/##')")" || return 1
    [ -n "$pick" ] || pick="$(sg_ask_required "VCS connector name")" || return 1
    kind=""
  fi
  W_VCS_INTEGRATION="/integrations/${pick#/integrations/}"
  case "$kind" in
  GITHUB_APP_CUSTOM) W_DEST_KIND=GITHUB_COM ;;
  GITHUB_COM | GITLAB_COM | BITBUCKET_ORG | AZURE_DEVOPS | GIT_OTHER) W_DEST_KIND="$kind" ;;
  *) W_DEST_KIND="$(sg_select "VCS provider kind" GITHUB_COM GITLAB_COM BITBUCKET_ORG AZURE_DEVOPS GIT_OTHER)" || return 1 ;;
  esac
  # Repo URL prefix follows the connector kind; editable in terraform.tfvars.
  W_REPO_PREFIX="$(_w_default .SGDefaultIACVCSRepoPrefix "$(_w_repo_prefix_for "$W_DEST_KIND")")"

  # Cloud connector -> DeploymentPlatformConfig.
  cloud=""
  [ "$W_SG_DISCOVERY" -eq 1 ] && cloud="$(printf '%s' "$ints" | "$jqb" -r '.[] | select((.type // "") | test("^(AWS|AZURE|GCP)_")) | "\(.name)|\(.type)"')"
  if [ -n "$cloud" ]; then
    # shellcheck disable=SC2046
    pick="$(SG_SELECT_OTHER=1 sg_select "Which cloud connector should the workflows deploy with?" $(printf '%s\n' "$cloud" | tr '\n' ' ') "skip|decide later (leaves a placeholder to edit)")" || return 1
    kind="$(printf '%s' "$ints" | "$jqb" -r --arg n "$pick" '.[] | select(.name == $n) | .type' | head -1)"
  else
    pick="$(sg_ask "Cloud connector name (as in StackGuardian; empty to decide later)" "$(_w_default .SGDefaultDeploymentPlatformConfig[0].config.integrationId '' | sed 's#^/integrations/##')")" || return 1
    kind=""
  fi
  if [ -z "$pick" ] || [ "$pick" = "skip" ]; then
    W_DPC_JSON='[{"kind":"AWS_RBAC","config":{"integrationId":"/integrations/CHANGE_ME"}}]'
    W_DPC_PLACEHOLDER=1
  else
    [ -n "$kind" ] || kind="$(sg_select "Connector kind" AWS_RBAC AWS_STATIC AWS_OIDC AZURE_STATIC AZURE_OIDC AZURE_MANAGED_ID_OIDC GCP_STATIC GCP_OIDC)" || return 1
    W_DPC_JSON="$("$jqb" -nc --arg k "$kind" --arg i "/integrations/${pick#/integrations/}" '[{kind:$k, config:{integrationId:$i}}]')"
    W_DPC_PLACEHOLDER=0
  fi

  # Runner constraints.
  runner="$(sg_select "Where should the workflows run?" \
    "shared|StackGuardian-hosted shared runners" \
    "private|a private runner group in your own network")" || return 1
  if [ "$runner" = "private" ]; then
    groups=""
    [ "$W_SG_DISCOVERY" -eq 1 ] && groups="$(sg_list_runnergroups 2>/dev/null | "$jqb" -r '.[]' 2>/dev/null || true)"
    if [ -n "$groups" ]; then
      # shellcheck disable=SC2046
      name="$(SG_SELECT_OTHER=1 sg_select "Which runner group?" $(printf '%s\n' "$groups" | tr '\n' ' '))" || return 1
    else
      name="$(sg_ask_required "Runner group name")" || return 1
    fi
    if [ "$W_SG_DISCOVERY" -eq 1 ] && ! sg_runnergroup_exists "$name"; then
      sg_warn "runner group '$name' was not found in org '$ORG' — preflight will fail until it exists"
    fi
    W_RUNNER_JSON="$("$jqb" -nc --arg n "$name" '{type:"private", names:[$n]}')"
  else
    W_RUNNER_JSON='{"type":"shared"}'
  fi
}

# --- step 3: policy ------------------------------------------------------------
wizard_policy() {
  sg_step "3/4 Workflow defaults"
  # Approvers, repo prefix and the fallback Terraform version are plain values
  # with sensible defaults — edit them in terraform.tfvars if needed.
  W_APPROVERS_JSON="$(tfvars_get_json .SGDefaultWfApprovers)"
  [ "$W_APPROVERS_JSON" = "null" ] && W_APPROVERS_JSON='[]'
  W_TF_VERSION="$(_w_default .SGDefaultTerraformVersion TERRAFORM-1.5.7)"
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
  sg_step "4/4 Review"
  row() { printf '  %s%-28s%s %s\n' "$C_BOLD" "$1" "$C_RESET" "$2" >&2; }
  row "TFC host / org" "$W_TFHOST / $W_TFORG"
  row "Workspaces" "$W_WSNAMES_JSON  tags=$W_TAGS_JSON  ignore=$W_IGNORE_TAGS_JSON${W_WS_COUNT:+  ($W_WS_COUNT found)}"
  row "SG org" "$ORG"
  row "VCS connector" "$W_VCS_INTEGRATION ($W_DEST_KIND, $W_REPO_PREFIX)"
  row "Cloud connector" "$W_DPC_JSON"
  row "Runners" "$W_RUNNER_JSON"
  row "State export / triggers" "$W_EXPORT_STATE / $W_TRIGGERS"
  row "Strip variables matching" "$W_IGNORE_PATTERNS_JSON"
  row "Fallback Terraform" "$W_TF_VERSION${W_WS_ABOVE_CEILING:+  ($W_WS_ABOVE_CEILING workspace(s) pinned above 1.5.7 (the last FOSS runtime SG bundles) will use it)}"
  [ "${W_DPC_PLACEHOLDER:-0}" -eq 1 ] && sg_warn "cloud connector left as a placeholder — edit SGDefaultDeploymentPlatformConfig in $(sg_rel "$TFVARS") before 'apply'"
  sg_dim "approvers, repo URL prefix and the fallback version can be edited in $(sg_rel "$TFVARS")"
  sg_confirm "Write $(sg_rel "$TFVARS")?" Y
}

# wizard_run — the whole flow; returns non-zero when aborted.
wizard_run() {
  wizard_tfc && wizard_sg && wizard_policy || { sg_err "init aborted"; return 1; }
  wizard_review || { sg_log "nothing written"; return 1; }
  if [ -f "$TFVARS" ]; then
    cp "$TFVARS" "$TFVARS.bak"
    sg_log "previous file kept as $(sg_rel "$TFVARS.bak")"
  fi
  tfvars_write "$TFVARS"
  if ! tfvars_valid; then
    sg_err "the generated $(sg_rel "$TFVARS") is not valid HCL — this is a bug in the wizard; the file was kept for inspection"
    return 1
  fi
  # Remember the SG org (and API host) for later phases, so users don't have to
  # export SG_ORG again in a new shell. Tokens are never stored.
  state_update '.config = ((.config // {}) + {sg_org: $o, sg_base_url: $u})' --arg o "$ORG" --arg u "$SG_BASE_URL"
  sg_success "wrote $(sg_rel "$TFVARS")"
}
