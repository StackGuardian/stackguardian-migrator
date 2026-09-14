#!/bin/bash
# Run scope for the migrator (sourced; needs tools.sh, lib/tfvars.sh, jq).
#
# terraform.tfvars holds the widest scope (workspacenames, tfWorkspaceIgnoreNames,
# tfProjects, the tag filters) and the CLI narrows one run:
#   --project NAME|SLUG       replaces tfProjects for the run
#   --workspace GLOB          replaces workspacenames for the run ("*" = all)
#   --exclude-workspace GLOB  adds to tfWorkspaceIgnoreNames for the run
#   --tag NAME                replaces tfWorkspaceTags for the run
#   --exclude-tag NAME        adds to tfWorkspaceIgnoreTags for the run
# Every phase applies the same selection: apply hands the lists to terraform,
# the later phases match them against the payload files (project slug) and
# entries (ResourceName), so 'import --workspace "team-*"' picks the workflows
# 'apply --workspace "team-*"' exported. Tags are not in the payload, so the
# tag flags only shape the export. Globs support * and ?.

PROJECT_FILTER=()
WS_FILTER=()
WS_EXCLUDE=()
TAG_FILTER=()
TAG_EXCLUDE=()

# scope_tags_json / scope_ignore_tags_json — the effective tag filters:
# --tag replaces tfWorkspaceTags, --exclude-tag adds to tfWorkspaceIgnoreTags
# (null = no filter, as in the module).
scope_tags_json() {
  local tf
  if [ "${#TAG_FILTER[@]}" -gt 0 ]; then names_json "${TAG_FILTER[@]}"; return; fi
  tf="$(tfvars_get_json .tfWorkspaceTags)"
  printf '%s' "${tf:-null}"
}
scope_ignore_tags_json() {
  local tf
  _scope_jq
  tf="$(tfvars_get_json .tfWorkspaceIgnoreTags)"
  [ "$tf" = "null" ] || [ -z "$tf" ] && tf='[]'
  if [ "${#TAG_EXCLUDE[@]}" -eq 0 ]; then printf '%s' "$tf"; return; fi
  "$JQ_BIN" -nc --argjson a "$tf" --argjson b "$(names_json "${TAG_EXCLUDE[@]}")" '$a + $b | unique'
}

# names_json <name>... — the arguments as a JSON array of strings.
names_json() { _scope_jq; printf '%s\n' "$@" | "$JQ_BIN" -R . | "$JQ_BIN" -sc .; }

_scope_jq() { JQ_BIN="${JQ_BIN:-$(sg_resolve jq sg_ensure_jq)}"; }

# slug_of <project name> — the payload file segment of a TFC project: the same
# rule as the transformer's projectSlugs (lowercase, runs of anything but
# [a-z0-9-] become "-"), so --project accepts the name or the slug.
slug_of() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g'; }

# project_selected <segment> — exit 0 when no --project is set or one of them
# names this payload segment.
project_selected() {
  local p
  [ "${#PROJECT_FILTER[@]}" -eq 0 ] && return 0
  for p in "${PROJECT_FILTER[@]}"; do [ "$(slug_of "$p")" = "$1" ] && return 0; done
  return 1
}

# ws_narrowed — exit 0 when a CLI flag restricts the run ("*" alone does not,
# so a CI run over everything keeps the unchanged-file skip).
ws_narrowed() {
  local p
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && return 0
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do [ "$p" = "*" ] || return 0; done
  return 1
}

# ws_filter_json — the --workspace globs as a JSON array ([] = no filter).
ws_filter_json() {
  local p
  _scope_jq
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do
    [ "$p" = "*" ] || { names_json "${WS_FILTER[@]}"; return; }
  done
  echo '[]'
}

# ws_exclude_json — tfWorkspaceIgnoreNames from terraform.tfvars plus the
# --exclude-workspace globs, as a JSON array (memoized per process).
ws_exclude_json() {
  local tf
  if [ -z "${_WS_EXCLUDE_JSON:-}" ]; then
    _scope_jq
    tf="$(tfvars_get_json .tfWorkspaceIgnoreNames)"
    [ "$tf" = "null" ] && tf='[]'
    if [ "${#WS_EXCLUDE[@]}" -eq 0 ]; then
      _WS_EXCLUDE_JSON="$("$JQ_BIN" -c . <<<"$tf")"
    else
      _WS_EXCLUDE_JSON="$("$JQ_BIN" -nc --argjson a "$tf" --argjson b "$(names_json "${WS_EXCLUDE[@]}")" '$a + $b | unique')"
    fi
  fi
  printf '%s' "$_WS_EXCLUDE_JSON"
}

# ws_selected <name> — exit 0 when <name> is in the run's scope: not excluded,
# and matched by a --workspace glob when one is set.
ws_selected() {
  local p
  if [ -z "${_WS_EXCLUDE_LIST+x}" ]; then
    _WS_EXCLUDE_LIST=()
    while IFS= read -r p; do [ -n "$p" ] && _WS_EXCLUDE_LIST+=("$p"); done < <(ws_exclude_json | "$JQ_BIN" -r '.[]')
  fi
  for p in ${_WS_EXCLUDE_LIST[@]+"${_WS_EXCLUDE_LIST[@]}"}; do
    # shellcheck disable=SC2254  # unquoted on purpose: $p is a glob
    case "$1" in $p) return 1 ;; esac
  done
  ws_narrowed || return 0
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do
    [ "$p" = "*" ] && return 0
    # shellcheck disable=SC2254
    case "$1" in $p) return 0 ;; esac
  done
  [ "${#WS_FILTER[@]}" -eq 0 ]
}

# WS_SCOPE_JQ — the same test for jq programs over payload entries. Prepend it
# to the program and pass "${WS_JQ_ARGS[@]}" (after ws_jq_args), then use
# 'select(.ResourceName | ws_selected)'.
WS_SCOPE_JQ='
  def ws_glob($p): "^" + ($p | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
  def ws_selected: . as $n
    | (($inc | length) == 0 or any($inc[]; . as $p | $n | test(ws_glob($p))))
    and (($exc | length) == 0 or (any($exc[]; . as $p | $n | test(ws_glob($p))) | not));
'
WS_JQ_ARGS=()
# ws_jq_args — fill WS_JQ_ARGS with the --argjson pairs WS_SCOPE_JQ expects.
ws_jq_args() { WS_JQ_ARGS=(--argjson inc "$(ws_filter_json)" --argjson exc "$(ws_exclude_json)"); }

# scope_tfvar_args — fill SCOPE_TFVAR_ARGS with the -var flags that hand the
# CLI scope to terraform apply (nothing when no flag is set).
SCOPE_TFVAR_ARGS=()
scope_tfvar_args() {
  local k
  SCOPE_TFVAR_ARGS=()
  _scope_jq
  # The configuration overlay first (merged values, see overlay_build); a
  # scope flag on the same variable wins because terraform takes the last -var.
  while IFS= read -r k; do
    [ -n "$k" ] && SCOPE_TFVAR_ARGS+=(-var "$k=$(tfvars_get_json ".$k")")
  done < <(printf '%s' "${TFVARS_OVERLAY_JSON:-{\}}" | "$JQ_BIN" -r 'keys[]')
  [ "${#PROJECT_FILTER[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "tfProjects=$(names_json "${PROJECT_FILTER[@]}")")
  [ "${#WS_FILTER[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "workspacenames=$(names_json "${WS_FILTER[@]}")")
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "tfWorkspaceIgnoreNames=$(ws_exclude_json)")
  [ "${#TAG_FILTER[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "tfWorkspaceTags=$(scope_tags_json)")
  [ "${#TAG_EXCLUDE[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "tfWorkspaceIgnoreTags=$(scope_ignore_tags_json)")
  return 0
}

# scope_describe — one line for the log: what the CLI flags select.
scope_describe() {
  local out=""
  [ "${#PROJECT_FILTER[@]}" -gt 0 ] && out="project(s) ${PROJECT_FILTER[*]}"
  [ "${#WS_FILTER[@]}" -gt 0 ] && out="${out:+$out, }workspaces ${WS_FILTER[*]}"
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && out="${out:+$out, }excluding ${WS_EXCLUDE[*]}"
  [ "${#TAG_FILTER[@]}" -gt 0 ] && out="${out:+$out, }tagged ${TAG_FILTER[*]}"
  [ "${#TAG_EXCLUDE[@]}" -gt 0 ] && out="${out:+$out, }not tagged ${TAG_EXCLUDE[*]}"
  printf '%s' "$out"
}

# scope_sha_input — the CLI scope as a string for the apply phase hash, so a
# run with a different selection re-runs the export.
scope_sha_input() { printf '%s|%s|%s|%s|%s|%s' "${PROJECT_FILTER[*]-}" "$(ws_filter_json)" "$(ws_exclude_json)" "$(scope_tags_json)" "$(scope_ignore_tags_json)" "${TFVARS_OVERLAY_JSON:-}"; }

# --- run configuration overlay ------------------------------------------------
# Connector and setting flags apply to one run on top of terraform.tfvars:
#   --set KEY=VALUE             any transformer variable (HCL/JSON value; bare text = string)
#   --cloud-connector ID        DeploymentPlatformConfig; the kind is looked up in SG
#   --vcs-connector ID          vcsAuthIntegrationID + sourceConfigDestKind (looked up) + repo prefix
#   --runner-group NAME|shared  RunnerConstraints
#   --workflow-group NAME       the project's workflow group (needs --project)
# With --project the connector flags become that project's projectOverrides
# entry, so every workspace of the project inherits them; without it they set
# the SGDefault* values. tfvars_json returns the file merged with
# TFVARS_OVERLAY_JSON, so preflight, the plan, enrich and the import see the
# same values, and apply receives them as -var. Nothing is written to the
# tfvars: a later run without the flags PATCHes the workflows back to it.
SET_VARS=()
CLOUD_CONNECTOR=""
VCS_CONNECTOR=""
RUNNER_GROUP=""
WORKFLOW_GROUP=""
TFVARS_OVERLAY_JSON='{}'

overlay_requested() { [ "${#SET_VARS[@]}" -gt 0 ] || [ -n "$CLOUD_CONNECTOR$VCS_CONNECTOR$RUNNER_GROUP$WORKFLOW_GROUP" ]; }

# _overlay_value <text> — a --set value as JSON. Literals ([..], {..}, "..",
# true/false/null, numbers) go through hcl2json; anything else is a string, so
# /integrations/x or aws-prod never turn into HCL expressions.
_overlay_value() {
  case "$1" in
  \[* | \{* | \"* | true | false | null)
    printf 'x = %s\n' "$1" | "$(sg_resolve hcl2json sg_ensure_hcl2json)" 2>/dev/null | "$JQ_BIN" -c '.x'
    return
    ;;
  esac
  case "$1" in
  '' | *[!0-9.-]*) "$JQ_BIN" -cn --arg v "$1" '$v' ;;
  *) printf '%s' "$1" ;;
  esac
}

# _overlay_project_name <value> — the raw TFC project name for a --project
# value (name or slug), via the TFC API: projectOverrides is keyed by the
# name. A value matching no project is fatal; when TFC cannot be reached the
# value is used as given, with a warning (fine when it is the exact name).
_overlay_project_name() {
  local slug hit
  _scope_jq
  slug="$(slug_of "$1")"
  if [ -z "${_OVERLAY_PROJECTS+x}" ]; then
    _OVERLAY_PROJECTS="$(tfc_list_projects "$(tfvars_get .tfOrg)" 2>/dev/null)" || _OVERLAY_PROJECTS=""
  fi
  if [ -z "$_OVERLAY_PROJECTS" ]; then
    sg_warn "could not list the TFC projects to resolve --project '$1' — using it as the project name"
    printf '%s' "$1"
    return
  fi
  hit="$(printf '%s' "$_OVERLAY_PROJECTS" | "$JQ_BIN" -r --arg s "$slug" '[.[] | select((.name | ascii_downcase | gsub("[^a-z0-9-]+"; "-")) == $s) | .name] | first // empty')"
  [ -n "$hit" ] || die "--project '$1' matches no TFC project in '$(tfvars_get .tfOrg)' (projects: $(printf '%s' "$_OVERLAY_PROJECTS" | "$JQ_BIN" -r '[.[].name] | join(", ")'))"
  printf '%s' "$hit"
}

# overlay_build — turn the flags into TFVARS_OVERLAY_JSON (dies on a bad flag).
# Needs ORG/SG_API_TOKEN for the connector lookups and TFC auth to resolve a
# project slug (falls back to the value as given).
overlay_build() {
  overlay_requested || return 0
  _scope_jq
  local o='{}' kv k v ints ctype kind fields='{}' p name rc
  for kv in ${SET_VARS[@]+"${SET_VARS[@]}"}; do
    k="${kv%%=*}"
    v="${kv#*=}"
    { [ "$k" != "$kv" ] && [ -n "$k" ]; } || die "--set expects KEY=VALUE, got '$kv'"
    tfvars_variable_names | grep -qx -- "$k" || die "--set: '$k' is not a setting of the transformer (see transformer/terraform-cloud/variables.tf)"
    v="$(_overlay_value "$v")"
    [ -n "$v" ] || die "--set $k: the value is not valid HCL/JSON"
    o="$("$JQ_BIN" -c --arg k "$k" --argjson v "$v" '.[$k] = $v' <<<"$o")"
  done
  if [ -n "$CLOUD_CONNECTOR$VCS_CONNECTOR" ]; then
    { [ -n "${SG_API_TOKEN:-}" ] && [ -n "${ORG:-}" ]; } || die "--cloud-connector / --vcs-connector need SG_API_TOKEN and SG_ORG (the connector kind is looked up in the org)"
    ints="$(sg_list_integrations)" || die "could not list the connectors of org '$ORG' (HTTP ${SG_HTTP_CODE:-?}) — check SG_API_TOKEN"
  fi
  if [ -n "$CLOUD_CONNECTOR" ]; then
    ctype="$(sg_integration_type "$ints" "$CLOUD_CONNECTOR")"
    [ -n "$ctype" ] || die "cloud connector '$CLOUD_CONNECTOR' not found in org '$ORG' (available: $(printf '%s' "$ints" | "$JQ_BIN" -r '[.[] | select(.type | test("^(AWS|AZURE|GCP)_")) | .name] | join(", ")'))"
    case "$ctype" in AWS_* | AZURE_* | GCP_*) ;; *) die "'$CLOUD_CONNECTOR' is a $ctype connector, not a cloud connector" ;; esac
    fields="$("$JQ_BIN" -c --arg k "$ctype" --arg i "/integrations/${CLOUD_CONNECTOR#/integrations/}" '.DeploymentPlatformConfig = [{kind: $k, config: {integrationId: $i}}]' <<<"$fields")"
    OVERLAY_CLOUD_KIND="$ctype"
  fi
  if [ -n "$VCS_CONNECTOR" ]; then
    ctype="$(sg_integration_type "$ints" "$VCS_CONNECTOR")"
    [ -n "$ctype" ] || die "VCS connector '$VCS_CONNECTOR' not found in org '$ORG' (available: $(printf '%s' "$ints" | "$JQ_BIN" -r '[.[] | select(.type | test("^(AWS|AZURE|GCP)_") | not) | .name] | join(", ")'))"
    kind="$(sg_vcs_kind_of "$ctype")"
    [ -n "$kind" ] || die "'$VCS_CONNECTOR' is a $ctype connector; the migrator cannot map that to a VCS kind — pass --set SGDefaultSourceConfigDestKind=<GITHUB_COM|GITLAB_COM|BITBUCKET_ORG|AZURE_DEVOPS|GIT_OTHER> as well"
    fields="$("$JQ_BIN" -c --arg i "/integrations/${VCS_CONNECTOR#/integrations/}" --arg k "$kind" '.vcsAuthIntegrationID = $i | .sourceConfigDestKind = $k' <<<"$fields")"
    # A different provider than the tfvars default needs its own repo prefix.
    if [ "$kind" != "$(tfvars_get .SGDefaultSourceConfigDestKind)" ]; then
      fields="$("$JQ_BIN" -c --arg p "$(_w_repo_prefix_for "$kind")" '.vcsRepoPrefix = $p' <<<"$fields")"
    fi
    OVERLAY_VCS_KIND="$kind"
  fi
  if [ -n "$RUNNER_GROUP" ]; then
    if [ "$RUNNER_GROUP" = "shared" ]; then rc='{"type":"shared"}'; else rc="$("$JQ_BIN" -cn --arg n "$RUNNER_GROUP" '{type: "private", names: [$n]}')"; fi
    fields="$("$JQ_BIN" -c --argjson r "$rc" '.RunnerConstraints = $r' <<<"$fields")"
  fi
  if [ -n "$WORKFLOW_GROUP" ]; then
    [ "${#PROJECT_FILTER[@]}" -gt 0 ] || die "--workflow-group needs --project: a workflow group belongs to a TFC project"
    fields="$("$JQ_BIN" -c --arg g "$WORKFLOW_GROUP" '.workflowGroup = $g' <<<"$fields")"
  fi
  if [ "$fields" != "{}" ]; then
    if [ "${#PROJECT_FILTER[@]}" -gt 0 ]; then
      for p in "${PROJECT_FILTER[@]}"; do
        name="$(_overlay_project_name "$p")"
        o="$("$JQ_BIN" -c --arg n "$name" --argjson f "$fields" '.projectOverrides[$n] = ((.projectOverrides[$n] // {}) + $f)' <<<"$o")"
      done
    else
      o="$("$JQ_BIN" -c --argjson f "$fields" '. + ($f | with_entries(.key |= ({
        DeploymentPlatformConfig: "SGDefaultDeploymentPlatformConfig", vcsAuthIntegrationID: "SGDefaultVCSAuthIntegrationID",
        sourceConfigDestKind: "SGDefaultSourceConfigDestKind", vcsRepoPrefix: "SGDefaultIACVCSRepoPrefix",
        RunnerConstraints: "SGDefaultRunnerConstraints"}[.])))' <<<"$o")"
    fi
  fi
  TFVARS_OVERLAY_JSON="$o"
  tfvars_invalidate
  sg_log "run configuration: $(overlay_describe)"
}

# overlay_describe — one line for the log and the run result.
overlay_describe() {
  local out="" kv
  [ -n "$CLOUD_CONNECTOR" ] && out="cloud connector ${CLOUD_CONNECTOR#/integrations/} (${OVERLAY_CLOUD_KIND:-?})"
  [ -n "$VCS_CONNECTOR" ] && out="${out:+$out, }VCS connector ${VCS_CONNECTOR#/integrations/} (${OVERLAY_VCS_KIND:-?})"
  [ -n "$RUNNER_GROUP" ] && out="${out:+$out, }runners $RUNNER_GROUP"
  [ -n "$WORKFLOW_GROUP" ] && out="${out:+$out, }workflow group $WORKFLOW_GROUP"
  if [ -n "$out" ]; then
    if [ "${#PROJECT_FILTER[@]}" -gt 0 ]; then out="$out for project(s) ${PROJECT_FILTER[*]}"; else out="$out as the defaults"; fi
  fi
  for kv in ${SET_VARS[@]+"${SET_VARS[@]}"}; do out="${out:+$out, }$kv"; done
  printf '%s' "$out"
}
