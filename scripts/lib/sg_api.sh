#!/bin/bash
# StackGuardian API access (sourced; needs tools.sh). Expects SG_API_TOKEN,
# SG_BASE_URL and ORG to be set by the caller. Bodies go to stdout, logs to
# stderr. Return-code contract shared by every call: 0 on 2xx, 22 on a
# definitive 4xx (not retryable — pair with SG_NO_RETRY_RC=22), 1 on 5xx or a
# network error (retryable). SG_HTTP_CODE holds the last status.

sg_org_url() { printf '%s/api/v1/orgs/%s' "$SG_BASE_URL" "$ORG"; }

# sg_http_code <method> <url> — prints the HTTP status only (000 on network error).
sg_http_code() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: apikey $SG_API_TOKEN" "$2" 2>/dev/null)" || true
  sg_norm_code "$code"
}

# sg_norm_code <str> — curl prints "000" and exits non-zero on connection
# errors, so never append a fallback to its output; normalize instead.
sg_norm_code() { case "$1" in [0-9][0-9][0-9]) printf '%s' "$1" ;; *) printf '000' ;; esac; }

# _sg_api <method> <url> [json-body] — shared request; body on stdout.
_sg_api() {
  local method="$1" url="$2" body="${3-}" tmp code
  tmp="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: apikey $SG_API_TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$url" 2>/dev/null)" || true
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: apikey $SG_API_TOKEN" "$url" 2>/dev/null)" || true
  fi
  code="$(sg_norm_code "$code")"
  # shellcheck disable=SC2034  # read by callers
  SG_HTTP_CODE="$code"
  case "$code" in
  2*)
    cat "$tmp"
    rm -f "$tmp"
    return 0
    ;;
  4*)
    sg_err "  HTTP $code from ${url#"$SG_BASE_URL"}: $(head -c 400 "$tmp")"
    if declare -F explain_api_error >/dev/null; then explain_api_error "$(head -c 2000 "$tmp")"; fi
    rm -f "$tmp"
    return 22
    ;;
  *)
    sg_warn "  HTTP $code from ${url#"$SG_BASE_URL"}"
    rm -f "$tmp"
    return 1
    ;;
  esac
}

sg_api_get() { _sg_api GET "$1"; }
sg_api_post() { _sg_api POST "$1" "$2" >/dev/null; }
sg_api_patch() { _sg_api PATCH "$1" "$2" >/dev/null; }

# --- workflow groups -------------------------------------------------------

# wfgroup_http_code <group> -> HTTP status of GET (200 exists, 404 missing).
wfgroup_http_code() { sg_http_code GET "$(sg_org_url)/wfgrps/$1/"; }

# wfgroup_create <group> — create a workflow group (idempotent at call sites).
wfgroup_create() {
  local body
  body="$("$(sg_resolve jq sg_ensure_jq)" -nc --arg n "$1" '{ResourceName:$n, Description:"Created by stackguardian-migrator (Terraform Cloud import)"}')"
  SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_api_post "$(sg_org_url)/wfgrps/" "$body"
}

# --- workflows -------------------------------------------------------------

wf_url() { printf '%s/wfgrps/%s/wfs/%s/' "$(sg_org_url)" "$1" "$2"; }
wf_triggers_endpoint() { printf '%swebhooks/vcs_triggers/' "$(wf_url "$1" "$2")"; }

# sg_workflow_exists <group> <wf> — exit 0 when the workflow exists.
sg_workflow_exists() { [ "$(sg_http_code GET "$(wf_url "$1" "$2")")" = "200" ]; }

# sg_list_workflows <group> — ["wf-name", ...] in the group ([] on 404).
sg_list_workflows() {
  local body out
  if body="$(sg_api_get "$(sg_org_url)/wfgrps/$1/wfs/listall/" 2>/dev/null)"; then
    out="$(printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -c '[(if (.msg | type) == "array" then .msg elif (.data | type) == "array" then .data elif (.data.Workflows? | type) == "array" then .data.Workflows elif type == "array" then . else [] end)[] | (.ResourceName // .Id // empty)]' 2>/dev/null)"
  fi
  printf '%s' "${out:-[]}"
}

# sg_patch_workflow <group> <wf> <json> — PATCH a workflow.
sg_patch_workflow() { sg_api_patch "$(wf_url "$1" "$2")" "$3"; }

# --- execution preset (org workflow defaults) ------------------------------
# Settings -> Runner groups -> Execution presets is stored as the org's
# Settings.workflowDefaults: RunnerConstraints plus a TerraformConfig each for
# TERRAFORM and OPENTOFU workflows (terraformVersion, optional terraformBinPath /
# wfStepTemplateRevisionId). At workflow creation the API fills those keys from
# it when the payload does not carry them.

# sg_execution_preset — the preset as compact JSON; "{}" when the org has none.
# Exit 1 when the org could not be read (the caller decides how loud to be).
sg_execution_preset() {
  local body out
  body="$(sg_api_get "$(sg_org_url)/" 2>/dev/null)" || { printf '{}'; return 1; }
  out="$(printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -c '(.msg // .data // {}) | (.Settings // {}).workflowDefaults // {}' 2>/dev/null)"
  [ -n "$out" ] || out='{}'
  printf '%s' "$out"
}

# sg_preset_runner_desc <preset-json> — "shared runners" / "private runner group X".
sg_preset_runner_desc() {
  local p="${1:-}"
  [ -n "$p" ] || p='{}'
  printf '%s' "$p" | "$(sg_resolve jq sg_ensure_jq)" -r '
    (.RunnerConstraints // {}) as $r
    | if ($r.type // "shared") == "private" then "private runner group \(($r.names // []) | join(", "))" else "shared runners" end' 2>/dev/null
}

# sg_preset_version_desc <preset-json> [TERRAFORM|OPENTOFU] — e.g. "Terraform 1.5.7",
# "Terraform 1.5.7 with runtime image /org/img:3", "runner-provided binary /usr/bin/terraform",
# or "managed Terraform 1.5.7 (platform default)" when the preset has no version.
sg_preset_version_desc() {
  local p="${1:-}"
  [ -n "$p" ] || p='{}'
  printf '%s' "$p" | "$(sg_resolve jq sg_ensure_jq)" -r --arg t "${2:-TERRAFORM}" '
    (if $t == "OPENTOFU" then "OpenTofu" else "Terraform" end) as $tool
    | ((if $t == "OPENTOFU" then .openTofuDefaults else .terraformDefaults end // {}).TerraformConfig // {}) as $c
    | (if (($c.terraformBinPath // []) | length) > 0 then "runner-provided binary \($c.terraformBinPath[0].source // "")"
       elif ($c.terraformVersion // "") == "" then (if $t == "OPENTOFU" then "managed OpenTofu (platform default)" else "managed Terraform 1.5.7 (platform default)" end)
       else "\($tool) \($c.terraformVersion | ltrimstr("TERRAFORM-") | ltrimstr("OPENTOFU-"))" end)
      + (if ($c.wfStepTemplateRevisionId // "") != "" then " with runtime image \($c.wfStepTemplateRevisionId)" else "" end)' 2>/dev/null
}

# sg_preset_desc <preset-json> — one line: "Terraform 1.5.7 on shared runners";
# "none configured (platform defaults: managed Terraform 1.5.7 on shared runners)" for {}.
sg_preset_desc() {
  if [ -z "$1" ] || [ "$1" = "{}" ] || [ "$1" = "null" ]; then
    printf 'none configured (platform defaults: managed Terraform 1.5.7 on shared runners)'
  else
    printf '%s on %s' "$(sg_preset_version_desc "$1")" "$(sg_preset_runner_desc "$1")"
  fi
}

# sg_preset_runner_provided <preset-json> — exit 0 when the Terraform defaults
# mount a runner-provided binary (terraformBinPath).
sg_preset_runner_provided() {
  local p="${1:-}"
  [ -n "$p" ] || p='{}'
  printf '%s' "$p" | "$(sg_resolve jq sg_ensure_jq)" -e '((.terraformDefaults // {}).TerraformConfig.terraformBinPath // []) | length > 0' >/dev/null 2>&1
}

# --- integrations (connectors) --------------------------------------------

# sg_list_integrations — [{name, type}, ...] for the org (fails on error).
# The connector kind (GITHUB_COM, AWS_RBAC, ...) is Settings.kind in the API.
sg_list_integrations() {
  local body
  body="$(sg_api_get "$(sg_org_url)/integrations/listall/")" || return $?
  printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -c '[(if (.msg | type) == "array" then .msg elif (.data | type) == "array" then .data elif type == "array" then . else [] end)[] | {name: (.ResourceName // .Id // ""), type: (.Settings.kind // .kind // .ResourceType // "")}] | map(select(.name != ""))'
}

# sg_vcs_kind_of <connector-type> — the sourceConfigDestKind a VCS connector
# type implies (GITHUB_APP_CUSTOM -> GITHUB_COM, AZURE_DEVOPS_SP -> AZURE_DEVOPS,
# ...); empty for cloud connectors and unknown types.
sg_vcs_kind_of() {
  case "$1" in
  GITHUB_COM | GITHUB_APP_CUSTOM) printf 'GITHUB_COM' ;;
  GITLAB_COM | GITLAB_OAUTH_SSH) printf 'GITLAB_COM' ;;
  BITBUCKET_ORG) printf 'BITBUCKET_ORG' ;;
  AZURE_DEVOPS | AZURE_DEVOPS_SP) printf 'AZURE_DEVOPS' ;;
  GIT_OTHER) printf 'GIT_OTHER' ;;
  *) printf '' ;;
  esac
}

# sg_integration_type <integrations-json> <name> — the connector's kind, or empty.
sg_integration_type() {
  printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" -r --arg n "${2#/integrations/}" '[.[] | select(.name == $n) | .type][0] // empty'
}

# sg_integration_exists <name-or-/integrations/name> — exit 0 when it exists.
sg_integration_exists() {
  local n="${1#/integrations/}"
  [ "$(sg_http_code GET "$(sg_org_url)/integrations/$n/")" = "200" ]
}

# --- runner groups ---------------------------------------------------------

# sg_runnergroup_exists <name> — exit 0 when the runner group exists.
sg_runnergroup_exists() { [ "$(sg_http_code GET "$(sg_org_url)/runnergroups/$1/")" = "200" ]; }

# sg_list_runnergroups — ["name", ...]; empty output (exit 1) when the API has
# no list endpoint, so callers fall back to free text.
sg_list_runnergroups() {
  local body
  body="$(sg_api_get "$(sg_org_url)/runnergroups/listall/" 2>/dev/null)" || return 1
  printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -c '[(if (.msg | type) == "array" then .msg elif (.data | type) == "array" then .data elif type == "array" then . else [] end)[] | .ResourceName] | map(select(. != null))'
}

# --- secrets ---------------------------------------------------------------

# sg_secret_exists <name> — exit 0 when a secret with that name exists.
sg_secret_exists() {
  local body
  body="$(sg_api_get "$(sg_org_url)/secrets/listall/" 2>/dev/null)" || return 1
  printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -e --arg n "$1" '[(if (.msg | type) == "array" then .msg elif (.data | type) == "array" then .data elif type == "array" then . else [] end)[] | .ResourceName] | index($n) != null' >/dev/null
}

# sg_create_secret <name> <value> [description]
sg_create_secret() {
  local body
  body="$("$(sg_resolve jq sg_ensure_jq)" -nc --arg n "$1" --arg v "$2" --arg d "${3:-Created by stackguardian-migrator (placeholder — set the real value)}" \
    '{ResourceName:$n, ResourceType:"SECRET", Description:$d, Value:$v}')"
  SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_api_post "$(sg_org_url)/secrets/" "$body"
}
