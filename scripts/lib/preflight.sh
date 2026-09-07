#!/bin/bash
# Preflight checks (sourced; needs tools.sh, tfvars.sh, tfc_api.sh, sg_api.sh).
#
# Verifies, before the long terraform apply or a bulk import, that the tokens
# work and that everything terraform.tfvars refers to actually exists in TFC
# and StackGuardian. Prints one line per check (✓ ok, ! warning, ✗ failure) and
# fails the run when any check fails. Skipped with --skip-preflight.

PF_FAIL=0
PF_WARN=0
pf_ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
pf_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; PF_WARN=$((PF_WARN + 1)); }
pf_fail() { printf '  %s✗%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; PF_FAIL=$((PF_FAIL + 1)); }

# --- Terraform Cloud -----------------------------------------------------------
preflight_tfc() {
  local host token org body n names_json tags_json ignore_json jqb
  jqb="$(sg_resolve jq sg_ensure_jq)"
  host="$(tfc_hostname)"
  org="$(tfvars_get .tfOrg)"
  [ -n "$org" ] || { pf_fail "tfOrg is not set in $(sg_rel "$TFVARS")"; return 0; }
  token="$(tfc_token "$host")"
  if [ -z "$token" ]; then
    pf_fail "no TFC/TFE credentials for $host — set TFE_TOKEN (recommended) or run 'terraform login'"
    return 0
  fi
  if ! tfc_http "account/details" >/dev/null; then
    case "$TFC_HTTP_CODE" in
    401 | 403) pf_fail "TFC rejected $(tfc_token_source) for $host (HTTP $TFC_HTTP_CODE) — set TFE_TOKEN or re-run 'terraform login'" ;;
    000) pf_fail "cannot reach https://$host (network/proxy?)" ;;
    *) pf_warn "unexpected HTTP $TFC_HTTP_CODE from $host while verifying credentials" ;;
    esac
    return 0
  fi
  pf_ok "TFC credentials valid ($host, via $(tfc_token_source))"
  if tfc_http "organizations/$org" >/dev/null; then
    pf_ok "TFC organisation '$org' accessible"
  else
    case "$TFC_HTTP_CODE" in
    404 | 403) pf_fail "TFC organisation '$org' not found or not accessible with this token (HTTP $TFC_HTTP_CODE) — check tfOrg" ;;
    *) pf_warn "could not verify TFC organisation '$org' (HTTP $TFC_HTTP_CODE)" ;;
    esac
    return 0
  fi
  # Workspace selection: mirror the module's filters (names glob, include/exclude tags).
  if body="$(tfc_list_workspaces "$org" 2>/dev/null)"; then
    names_json="$(tfvars_get_json .workspacenames)"
    tags_json="$(tfvars_get_json .tfWorkspaceTags)"
    ignore_json="$(tfvars_get_json .tfWorkspaceIgnoreTags)"
    n="$(printf '%s' "$body" | "$jqb" --argjson names "${names_json:-null}" --argjson tags "${tags_json:-null}" --argjson ignore "${ignore_json:-null}" '
      def glob($p): ("^" + ($p | gsub("\\*"; ".*")) + "$");
      [ .[]
        | select(($names == null) or ($names == ["*"]) or ([.name] | inside([]) | not) and ([$names[] as $p | (.name | test(glob($p)))] | any))
        | select(($tags == null) or (($tags | length) == 0) or ([.tags[]?] | inside($tags) | not) or (([.tags[]?] | map(select(. as $t | $tags | index($t) != null)) | length) > 0))
        | select(($ignore == null) or (($ignore | length) == 0) or (([.tags[]?] | map(select(. as $t | $ignore | index($t) != null)) | length) == 0))
      ] | length')"
    if [ "$n" -gt 0 ]; then
      pf_ok "$n workspace(s) match the selection (of $(printf '%s' "$body" | "$jqb" 'length') in the org)"
    else
      pf_warn "no workspace matches workspacenames/tfWorkspaceTags/tfWorkspaceIgnoreTags — apply would export nothing"
    fi
    PF_TFC_WORKSPACES="$body"
  else
    pf_warn "could not list workspaces for '$org' (HTTP $TFC_HTTP_CODE)"
  fi
  return 0
}

# --- StackGuardian ------------------------------------------------------------
# preflight_sg <required:0|1>
preflight_sg() {
  local required="$1" ints names id n jqb rg
  jqb="$(sg_resolve jq sg_ensure_jq)"
  if [ -z "${SG_API_TOKEN:-}" ] || [ -z "$ORG" ]; then
    if [ "$required" -eq 1 ]; then
      [ -n "${SG_API_TOKEN:-}" ] || pf_fail "SG_API_TOKEN is not set"
      [ -n "$ORG" ] || pf_fail "StackGuardian org not set (use --org or SG_ORG)"
    else
      pf_warn "SG_API_TOKEN/SG_ORG not set — StackGuardian references are not verified (they will be at import)"
    fi
    return 0
  fi
  if ! ints="$(sg_list_integrations 2>/dev/null)"; then
    case "$SG_HTTP_CODE" in
    401 | 403) pf_fail "StackGuardian rejected SG_API_TOKEN for org '$ORG' (HTTP $SG_HTTP_CODE)" ;;
    404) pf_fail "StackGuardian org '$ORG' not found at $SG_BASE_URL (HTTP 404) — check --org / SG_ORG" ;;
    000) pf_fail "cannot reach $SG_BASE_URL (network/proxy? SG_BASE_URL?)" ;;
    *) pf_fail "could not list StackGuardian connectors (HTTP $SG_HTTP_CODE)" ;;
    esac
    return 0
  fi
  pf_ok "StackGuardian credentials valid (org '$ORG', $SG_BASE_URL)"

  # Every integration id referenced anywhere in tfvars must exist.
  names="$(printf '%s' "$ints" | "$jqb" -c '[.[].name]')"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
    *CHANGE_ME* | *INTEGRATION_ID*) pf_fail "placeholder connector id '$id' in $(sg_rel "$TFVARS") — run '$PROG init' or edit the file" ;;
    /integrations/*)
      if printf '%s' "$names" | "$jqb" -e --arg n "${id#/integrations/}" 'index($n) != null' >/dev/null; then
        pf_ok "connector $id exists"
      else
        pf_fail "connector $id not found in org '$ORG' (available: $(printf '%s' "$names" | "$jqb" -r 'join(", ")'))"
      fi
      ;;
    /secrets/*)
      if sg_secret_exists "${id#/secrets/}"; then pf_ok "secret $id exists"; else pf_fail "secret $id not found in org '$ORG'"; fi
      ;;
    *) pf_warn "unrecognised integration id '$id' (expected /integrations/<name> or /secrets/<name>)" ;;
    esac
  done < <(tfvars_json | "$jqb" -r '
      [ .SGDefaultVCSAuthIntegrationID,
        (.SGDefaultDeploymentPlatformConfig // [])[]?.config.integrationId,
        ((.workspaceOverrides // {}) | to_entries[]? | .value | (.vcsAuthIntegrationID, ((.DeploymentPlatformConfig // [])[]?.config.integrationId))) ]
      | map(select(. != null and . != "")) | unique | .[]')

  # Every private runner group must exist.
  while IFS= read -r rg; do
    [ -n "$rg" ] || continue
    if sg_runnergroup_exists "$rg"; then pf_ok "runner group '$rg' exists"; else pf_fail "runner group '$rg' not found in org '$ORG' — check SGDefaultRunnerConstraints / workspaceOverrides"; fi
  done < <(tfvars_json | "$jqb" -r '
      [ (.SGDefaultRunnerConstraints // {} | select(.type == "private") | .names[]?),
        ((.workspaceOverrides // {}) | to_entries[]? | .value.RunnerConstraints // {} | select(.type == "private") | .names[]?) ]
      | unique | .[]')
  n="$(tfvars_json | "$jqb" -r '(.SGDefaultRunnerConstraints // {}).type // "shared"')"
  if [ "$n" = "shared" ]; then pf_ok "runners: StackGuardian shared runners"; fi
  return 0
}

# --- static config --------------------------------------------------------------
preflight_config() {
  local v ceiling="1.5.7" export_path want jqb
  jqb="$(sg_resolve jq sg_ensure_jq)"
  v="$(tfvars_get .SGDefaultSourceConfigDestKind GIT_OTHER)"
  case "$v" in
  GITHUB_COM | GITHUB_APP_CUSTOM | GIT_OTHER | INLINE | BITBUCKET_ORG | GITLAB_COM | AZURE_DEVOPS) pf_ok "SGDefaultSourceConfigDestKind = $v" ;;
  *) pf_fail "SGDefaultSourceConfigDestKind '$v' is not one of GITHUB_COM, GITLAB_COM, BITBUCKET_ORG, AZURE_DEVOPS, GIT_OTHER" ;;
  esac
  v="$(tfvars_get .SGDefaultTerraformVersion TERRAFORM-1.5.7)"
  if [[ "$v" =~ ^TERRAFORM-([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    if [ "$(printf '%03d%03d%03d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")" -gt "001005007" ]; then
      pf_warn "SGDefaultTerraformVersion $v is above SG's managed ceiling ($ceiling); fallbacks would fail too unless a private runner ships that binary"
    else
      pf_ok "SGDefaultTerraformVersion = $v"
    fi
  else
    pf_fail "SGDefaultTerraformVersion '$v' must look like TERRAFORM-1.5.7"
  fi
  export_path="$(tfvars_get .exportPath export)"
  case "$export_path" in /*) want="$export_path" ;; *) want="$SG_REPO_ROOT/$export_path" ;; esac
  if [ "$(cd "$(dirname "$want")" 2>/dev/null && pwd)/$(basename "$want")" = "$(cd "$(dirname "$EXPORT_DIR")" 2>/dev/null && pwd)/$(basename "$EXPORT_DIR")" ]; then
    pf_ok "export directory: $(sg_rel "$EXPORT_DIR")"
  else
    pf_warn "exportPath in tfvars ($export_path) differs from the orchestrator's export dir ($(sg_rel "$EXPORT_DIR")) — payloads would be written where later phases don't look"
  fi
  if [ -n "${PF_TFC_WORKSPACES:-}" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      if printf '%s' "$PF_TFC_WORKSPACES" | "$jqb" -e --arg n "$v" '[.[].name] | index($n) != null' >/dev/null; then
        pf_ok "workspaceOverrides['$v'] matches a workspace"
      else
        pf_warn "workspaceOverrides['$v'] does not match any workspace in the org (typo?)"
      fi
    done < <(tfvars_json | "$jqb" -r '(.workspaceOverrides // {}) | keys[]')
  fi
  return 0
}

# --- import inputs --------------------------------------------------------------
preflight_import_inputs() {
  payload_files
  if [ "${#PF[@]}" -gt 0 ]; then
    pf_ok "${#PF[@]} payload file(s) in $(sg_rel "$EXPORT_DIR")"
  else
    pf_fail "no payload files in $(sg_rel "$EXPORT_DIR") — run '$PROG apply' first"
  fi
  if sg_resolve sg-cli sg_ensure_sgcli >/dev/null 2>&1; then pf_ok "sg-cli available"; else pf_fail "sg-cli not found and could not be downloaded"; fi
  return 0
}

# preflight_run <apply|import|all> — run the checks for a context; dies on
# failures. Runs at most once per process (PREFLIGHT_DONE).
preflight_run() {
  local ctx="$1"
  [ "${SKIP_PREFLIGHT:-0}" -eq 1 ] && { sg_warn "preflight skipped (--skip-preflight)"; return 0; }
  [ "${PREFLIGHT_DONE:-0}" -eq 1 ] && return 0
  sg_step "Preflight ($ctx)"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS"). Run: $PROG init"
  PF_FAIL=0
  PF_WARN=0
  PF_TFC_WORKSPACES=""
  local parse_err
  if ! parse_err="$(tfvars_valid)"; then
    pf_fail "$(sg_rel "$TFVARS") is not valid HCL: ${parse_err:-parse error}"
    die "fix the file (or re-run '$PROG init') and try again."
  fi
  case "$ctx" in
  apply)
    preflight_tfc
    preflight_sg 0
    preflight_config
    ;;
  import)
    preflight_sg 1
    preflight_config
    preflight_import_inputs
    ;;
  all)
    preflight_tfc
    preflight_sg 1
    preflight_config
    ;;
  *) die "preflight: unknown context '$ctx'" ;;
  esac
  PREFLIGHT_DONE=1
  if [ "$PF_FAIL" -gt 0 ]; then
    die "preflight found $PF_FAIL problem(s); fix them (or re-run '$PROG init') and try again. Use --skip-preflight to bypass."
  fi
  if [ "$PF_WARN" -gt 0 ]; then
    sg_warn "preflight passed with $PF_WARN warning(s)"
  else
    sg_success "preflight passed"
  fi
}

cmd_preflight() {
  PREFLIGHT_DONE=0
  preflight_run all
}
