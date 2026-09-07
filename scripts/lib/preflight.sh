#!/bin/bash
# Preflight checks (sourced; needs tools.sh, tfvars.sh, tfc_api.sh, sg_api.sh).
#
# Verifies, before the long terraform apply or a bulk import, that the tokens
# work and that everything terraform.tfvars refers to actually exists in TFC
# and StackGuardian — and that the pieces agree with each other (VCS connector
# kind vs. sourceConfigDestKind, repo URL prefix vs. where the TFC repositories
# live). Prints one line per check (✓ ok, ! warning, ✗ failure) and fails the
# run when any check fails. Skipped with --skip-preflight.

PF_OK=0
PF_FAIL=0
PF_WARN=0
pf_ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; PF_OK=$((PF_OK + 1)); }
pf_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; PF_WARN=$((PF_WARN + 1)); }
pf_fail() { printf '  %s✗%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; PF_FAIL=$((PF_FAIL + 1)); }

# --- Terraform Cloud -----------------------------------------------------------
preflight_tfc() {
  local host token org body n sel jqb
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
    sel="$(tfc_select_workspaces "$body" "$(tfvars_get_json .workspacenames)" "$(tfvars_get_json .tfWorkspaceTags)" "$(tfvars_get_json .tfWorkspaceIgnoreTags)")"
    n="$(printf '%s' "$sel" | "$jqb" 'length')"
    if [ "$n" -gt 0 ]; then
      pf_ok "$n workspace(s) match the selection (of $(printf '%s' "$body" | "$jqb" 'length') in the org)"
    else
      pf_warn "no workspace matches workspacenames/tfWorkspaceTags/tfWorkspaceIgnoreTags — apply would export nothing"
    fi
    PF_TFC_WORKSPACES="$body"
    PF_TFC_SELECTED="$sel"
  else
    pf_warn "could not list workspaces for '$org' (HTTP $TFC_HTTP_CODE)"
  fi
  return 0
}

# --- StackGuardian ------------------------------------------------------------
# preflight_sg <required:0|1>
preflight_sg() {
  local required="$1" ints names label id kind n jqb rg
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
  PF_SG_INTS="$ints"
  # The execution preset (org workflow defaults) decides whatever tfvars leaves
  # to it; preflight_config reports it next to the version/runner settings.
  if PF_PRESET="$(sg_execution_preset)"; then PF_PRESET_READ=1; else PF_PRESET_READ=0; fi

  # Every integration id referenced anywhere in tfvars must exist. Each line is
  # "<role>\t<id>" so the report can say what the connector is for.
  names="$(printf '%s' "$ints" | "$jqb" -c '[.[].name]')"
  while IFS=$'\t' read -r label id; do
    [ -n "$id" ] || continue
    case "$id" in
    *CHANGE_ME* | *INTEGRATION_ID*) pf_fail "placeholder $label connector id '$id' in $(sg_rel "$TFVARS") — run '$PROG init' or edit the file" ;;
    /integrations/*)
      if printf '%s' "$names" | "$jqb" -e --arg n "${id#/integrations/}" 'index($n) != null' >/dev/null; then
        kind="$(sg_integration_type "$ints" "$id")"
        pf_ok "$label connector ${id#/integrations/} exists${kind:+ ($kind)}"
      else
        pf_fail "$label connector $id not found in org '$ORG' (available: $(printf '%s' "$names" | "$jqb" -r 'join(", ")'))"
      fi
      ;;
    /secrets/*)
      if sg_secret_exists "${id#/secrets/}"; then pf_ok "secret $id exists"; else pf_fail "secret $id not found in org '$ORG'"; fi
      ;;
    *) pf_warn "unrecognised $label integration id '$id' (expected /integrations/<name> or /secrets/<name>)" ;;
    esac
  done < <(tfvars_json | "$jqb" -r '
      [ (.SGDefaultVCSAuthIntegrationID | select(. != null and . != "") | ["VCS", .]),
        ((.SGDefaultDeploymentPlatformConfig // [])[]?.config.integrationId | select(. != null and . != "") | ["cloud", .]),
        ((.workspaceOverrides // {}) | to_entries[]? | .value
          | ((.vcsAuthIntegrationID | select(. != null and . != "") | ["override VCS", .]),
             ((.DeploymentPlatformConfig // [])[]?.config.integrationId | select(. != null and . != "") | ["override cloud", .]))) ]
      | unique_by(.[1]) | .[] | @tsv')

  # Every private runner group must exist.
  while IFS= read -r rg; do
    [ -n "$rg" ] || continue
    if sg_runnergroup_exists "$rg"; then pf_ok "runner group '$rg' exists"; else pf_fail "runner group '$rg' not found in org '$ORG' — check SGDefaultRunnerConstraints / workspaceOverrides"; fi
  done < <(tfvars_json | "$jqb" -r '
      [ (.SGDefaultRunnerConstraints // {} | select(.type == "private") | .names[]?),
        ((.workspaceOverrides // {}) | to_entries[]? | .value.RunnerConstraints // {} | select(.type == "private") | .names[]?) ]
      | unique | .[]')
  if tfvars_is_null SGDefaultRunnerConstraints; then
    if [ "${PF_PRESET_READ:-0}" -eq 1 ]; then
      pf_ok "runners: from the org's execution preset — $(sg_preset_runner_desc "$PF_PRESET")"
    else
      pf_ok "runners: from the org's execution preset (platform default: shared runners)"
    fi
  else
    n="$(tfvars_json | "$jqb" -r '(.SGDefaultRunnerConstraints // {}).type // "shared"')"
    if [ "$n" = "shared" ]; then pf_ok "runners: StackGuardian shared runners"; fi
  fi
  return 0
}

# --- static config + consistency ---------------------------------------------------
# _pf_host <url> — host part of a URL.
_pf_host() { local h="${1#*://}"; printf '%s' "${h%%/*}"; }

# _pf_kind_of_host <host> — the provider kind a well-known VCS host implies.
_pf_kind_of_host() {
  case "$1" in
  github.com | www.github.com) printf 'GITHUB_COM' ;;
  gitlab.com | www.gitlab.com) printf 'GITLAB_COM' ;;
  bitbucket.org | www.bitbucket.org) printf 'BITBUCKET_ORG' ;;
  dev.azure.com | *.visualstudio.com) printf 'AZURE_DEVOPS' ;;
  *) printf '' ;;
  esac
}

preflight_config() {
  local v kind ceiling="1.5.7" export_path want jqb prefix host conn conn_kind line prov tfc_prefix tfc_kind
  jqb="$(sg_resolve jq sg_ensure_jq)"

  # VCS kind, and does it agree with the connector / the repositories?
  v="$(tfvars_get .SGDefaultSourceConfigDestKind GIT_OTHER)"
  case "$v" in
  GITHUB_COM | GITHUB_APP_CUSTOM | GIT_OTHER | INLINE | BITBUCKET_ORG | GITLAB_COM | AZURE_DEVOPS) ;;
  *) pf_fail "SGDefaultSourceConfigDestKind '$v' is not one of GITHUB_COM, GITLAB_COM, BITBUCKET_ORG, AZURE_DEVOPS, GIT_OTHER" ;;
  esac
  conn="$(tfvars_get .SGDefaultVCSAuthIntegrationID)"
  conn_kind=""
  [ -n "${PF_SG_INTS:-}" ] && [ -n "$conn" ] && conn_kind="$(sg_vcs_kind_of "$(sg_integration_type "$PF_SG_INTS" "$conn")")"
  if [ -n "$conn_kind" ] && [ "$conn_kind" != "$v" ]; then
    pf_fail "VCS kind $v does not match connector ${conn#/integrations/}, which is a $conn_kind connector — set SGDefaultSourceConfigDestKind = \"$conn_kind\" (or pick another connector)"
  elif [ -n "$conn_kind" ]; then
    pf_ok "VCS kind $v matches connector ${conn#/integrations/}"
  else
    pf_ok "VCS kind $v"
  fi

  # Repo URL prefix: compare with where the TFC workspaces' repositories live
  # (the transformer emits <prefix>/<tfc repo identifier>); otherwise with the
  # kind's well-known host.
  prefix="$(tfvars_get .SGDefaultIACVCSRepoPrefix)"
  host="$(_pf_host "$prefix")"
  tfc_prefix=""
  tfc_kind=""
  if [ -n "${PF_TFC_SELECTED:-}" ]; then
    while IFS=$'\t' read -r prov _ line; do
      [ -n "$prov" ] || continue
      tfc_kind="$(tfc_vcs_kind_for "$prov")"
      [ "$line" != "-" ] && tfc_prefix="$line"
      break # most common provider only
    done <<<"$(tfc_vcs_summary "$PF_TFC_SELECTED")"
  fi
  if [ -z "$prefix" ] || [ "$prefix" = "https://VCS_PROVIDER_DOMAIN" ]; then
    pf_fail "SGDefaultIACVCSRepoPrefix is not set — the repositories' base URL, e.g. https://github.com"
  elif [ -n "$tfc_prefix" ]; then
    case "$host" in
    *"$(_pf_host "$tfc_prefix")") pf_ok "repo URL prefix $prefix matches the TFC repositories" ;;
    *) pf_warn "repo URL prefix $prefix does not match where the TFC repositories live ($tfc_prefix) — every workflow would clone from the wrong place unless the repositories moved; check SGDefaultIACVCSRepoPrefix" ;;
    esac
  else
    kind="$(_pf_kind_of_host "$host")"
    if [ -n "$kind" ] && [ "$kind" != "$v" ] && [ "$v" != "GIT_OTHER" ]; then
      pf_warn "repo URL prefix $prefix looks like $kind but the VCS kind is $v — check SGDefaultIACVCSRepoPrefix / SGDefaultSourceConfigDestKind"
    else
      pf_ok "repo URL prefix $prefix"
    fi
  fi
  if [ -n "$tfc_kind" ] && [ "$tfc_kind" != "$v" ] && [ "$v" != "GIT_OTHER" ]; then
    pf_warn "the TFC workspaces are connected to $(tfc_vcs_label_for "$prov") but the VCS kind is $v"
  fi

  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
    AWS_STATIC | AWS_RBAC | AWS_OIDC | AZURE_STATIC | AZURE_OIDC | AZURE_MANAGED_ID_OIDC | GCP_STATIC | GCP_OIDC) pf_ok "cloud connector kind $v" ;;
    *) pf_fail "cloud connector kind '$v' (DeploymentPlatformConfig) is not one of AWS_STATIC, AWS_RBAC, AWS_OIDC, AZURE_STATIC, AZURE_OIDC, AZURE_MANAGED_ID_OIDC, GCP_STATIC, GCP_OIDC — a VCS connector was picked as the cloud connector?" ;;
    esac
  done < <(tfvars_json | "$jqb" -r '[ (.SGDefaultDeploymentPlatformConfig // [])[]?.kind, ((.workspaceOverrides // {}) | to_entries[]? | .value.DeploymentPlatformConfig // [] | .[]?.kind) ] | map(select(. != null)) | unique | .[]')

  # Terraform version policy, and what the execution preset would supply where
  # tfvars leaves the decision to it.
  local src preset_note=""
  src="$(tfvars_get .SGTerraformVersionSource carry)"
  case "$src" in
  carry | preset) ;;
  *)
    pf_fail "SGTerraformVersionSource '$src' must be \"carry\" or \"preset\""
    src="carry"
    ;;
  esac
  [ "${PF_PRESET_READ:-0}" -eq 1 ] && preset_note="$(sg_preset_desc "$PF_PRESET")"
  if tfvars_is_null SGDefaultTerraformVersion; then v=""; else v="$(tfvars_get .SGDefaultTerraformVersion TERRAFORM-1.5.7)"; fi
  if [ "$src" = "preset" ]; then
    if [ -n "$preset_note" ]; then
      pf_ok "Terraform version: from the org's execution preset — $preset_note"
    else
      pf_warn "Terraform version: from the org's execution preset, which could not be read here (platform default if none is configured: managed Terraform 1.5.7 on shared runners)"
    fi
  else
    if [ -z "$v" ]; then
      pf_ok "Terraform version: pinned TFC versions are carried over; unpinned or rejected pins go to the execution preset${preset_note:+ — $preset_note}"
    elif [[ "$v" =~ ^TERRAFORM-([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      if [ "$(printf '%03d%03d%03d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")" -gt "001005007" ]; then
        pf_warn "fallback Terraform ${v#TERRAFORM-} (SGDefaultTerraformVersion) is above SG's managed ceiling ($ceiling); fallbacks would fail too unless a private runner ships that binary"
      else
        pf_ok "Terraform version: pinned TFC versions are carried over; fallback ${v#TERRAFORM-} is within SG's managed ceiling ($ceiling)"
      fi
    else
      pf_fail "SGDefaultTerraformVersion '$v' must look like TERRAFORM-1.5.7 (or be null to defer to the execution preset)"
    fi
    if [ "${PF_PRESET_READ:-0}" -eq 1 ] && sg_preset_runner_provided "$PF_PRESET"; then
      pf_warn "the execution preset mounts a runner-provided Terraform binary; with SGTerraformVersionSource = \"carry\" the carried pins and that binary would be sent together — consider \"preset\""
    fi
  fi

  export_path="$(tfvars_get .exportPath export)"
  case "$export_path" in /*) want="$export_path" ;; *) want="$SG_REPO_ROOT/$export_path" ;; esac
  if [ "$(cd "$(dirname "$want")" 2>/dev/null && pwd)/$(basename "$want")" = "$(cd "$(dirname "$EXPORT_DIR")" 2>/dev/null && pwd)/$(basename "$EXPORT_DIR")" ]; then
    pf_ok "export directory $(sg_rel "$EXPORT_DIR")/"
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
    pf_ok "${#PF[@]} payload file(s) in $(sg_rel "$EXPORT_DIR")/"
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
  sg_step "Preflight"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS"). Run: $PROG init"
  PF_OK=0
  PF_FAIL=0
  PF_WARN=0
  PF_TFC_WORKSPACES=""
  PF_TFC_SELECTED=""
  PF_SG_INTS=""
  PF_PRESET="{}"
  PF_PRESET_READ=0
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
    sg_warn "preflight passed with $PF_WARN warning(s) — read them before continuing"
  else
    sg_success "preflight passed ($PF_OK checks)"
  fi
}

cmd_preflight() {
  PREFLIGHT_DONE=0
  preflight_run all
}
