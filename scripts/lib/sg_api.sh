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

# sg_api_raw <method> <url> [json-body] — the request itself, no logging: the
# response body goes to stdout whatever the status, SG_HTTP_CODE is set, exit
# code per the contract above. Callers that need the error body use this.
sg_api_raw() {
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
  cat "$tmp"
  rm -f "$tmp"
  case "$code" in 2*) return 0 ;; 4*) return 22 ;; *) return 1 ;; esac
}

# _sg_api <method> <url> [json-body] — sg_api_raw plus logging; body on stdout
# only on 2xx (4xx/5xx are reported on stderr).
_sg_api() {
  local url="$2" tmp rc=0
  tmp="$(mktemp)"
  # Not a $(...) capture: SG_HTTP_CODE must survive into this shell.
  sg_api_raw "$@" >"$tmp" || rc=$?
  case "$rc" in
  0) cat "$tmp" ;;
  22)
    sg_err "  HTTP $SG_HTTP_CODE from ${url#"$SG_BASE_URL"}: $(head -c 400 "$tmp")"
    if declare -F explain_api_error >/dev/null; then explain_api_error "$(head -c 2000 "$tmp")"; fi
    ;;
  *) sg_warn "  HTTP $SG_HTTP_CODE from ${url#"$SG_BASE_URL"}" ;;
  esac
  rm -f "$tmp"
  return "$rc"
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

# sg_set_vcs_triggers <group> <wf> <json> — POST the VCS triggers. The endpoint
# is an upsert: a second call answers 200 ("VCS triggers updated" / "Webhook
# already exists ..."), so re-runs are safe. Defensively also 0 on a 4xx whose
# body says the webhook exists (older builds); 22 on any other 4xx, 1 otherwise.
sg_set_vcs_triggers() {
  local tmp rc=0
  tmp="$(mktemp)"
  # Not a $(...) capture: SG_HTTP_CODE must survive into this shell.
  sg_api_raw POST "$(wf_triggers_endpoint "$1" "$2")" "$3" >"$tmp" || rc=$?
  if [ "$rc" -eq 22 ] && grep -Eiq 'already (exists|registered)|duplicate' "$tmp"; then
    rc=0
  elif [ "$rc" -ne 0 ]; then
    sg_err "  HTTP $SG_HTTP_CODE from vcs_triggers ($1/$2): $(head -c 300 "$tmp")"
    if [ "$rc" -eq 22 ] && declare -F explain_api_error >/dev/null; then explain_api_error "$(head -c 2000 "$tmp")"; fi
  fi
  rm -f "$tmp"
  return "$rc"
}

# sg_workflow_exists <group> <wf> — exit 0 when the workflow exists.
sg_workflow_exists() { [ "$(sg_http_code GET "$(wf_url "$1" "$2")")" = "200" ]; }

# _sg_listall <path-under-org> <jq-item-expr> — every item of a paginated
# listall endpoint (the API pages at 50 by default; lastevaluatedkey is the
# cursor) mapped through <jq-item-expr>, as a JSON array; [] on any error.
# Tolerates the response shapes seen so far (msg / data / data.Workflows /
# bare array). The expression is spliced into the jq program.
_sg_listall() {
  local path="$1" expr="$2" key="" body page acc='[]' jqb
  jqb="$(sg_resolve jq sg_ensure_jq)"
  while :; do
    body="$(sg_api_get "$(sg_org_url)/${path}?limit=100${key:+&lastevaluatedkey=$key}" 2>/dev/null)" || break
    page="$(printf '%s' "$body" | "$jqb" -c '[(if (.msg | type) == "array" then .msg elif (.data | type) == "array" then .data elif (.data.Workflows? | type) == "array" then .data.Workflows elif type == "array" then . else [] end)[] | '"$expr"' | select(. != null and . != "")]' 2>/dev/null)" || page='[]'
    acc="$("$jqb" -nc --argjson a "$acc" --argjson b "$page" '$a + $b')"
    key="$(printf '%s' "$body" | "$jqb" -r '.lastevaluatedkey // empty' 2>/dev/null | "$jqb" -sRr @uri)"
    [ -n "$key" ] || break
  done
  printf '%s' "$acc"
}

# sg_list_workflows <group> — ["wf-name", ...] in the group ([] on 404).
sg_list_workflows() { _sg_listall "wfgrps/$1/wfs/listall/" '(.ResourceName // .Id)'; }

# sg_list_wfgrps — ["group-name", ...] of the org.
sg_list_wfgrps() { _sg_listall "wfgrps/listall/" '(.ResourceName // .Id)'; }

# sg_patch_workflow <group> <wf> <json> — PATCH a workflow.
sg_patch_workflow() { sg_api_patch "$(wf_url "$1" "$2")" "$3"; }

# --- direct workflow create (sg-cli workaround) -----------------------------
# sg-cli (<= v2.2.1, on sg-sdk-go v1.1.0) round-trips every payload entry through
# the SDK's Workflow struct, whose iacInputData.data map is tagged omitempty: a
# workspace with no Terraform variables ("data": {}) reaches the API without the
# key and is rejected with "VCSConfig.iacInputData.data: This field is required."
# Such entries are created straight from the payload JSON instead.
# TODO(sg-cli): workaround — the fix belongs in sg-cli: bump sg-sdk-go to
# >= v1.5.7 (IacInputData.Data became a pointer so "data": {} is sent) or POST
# the raw entry. Drop this block and import_bulk's split once a release has it.

# _sg_wf_body <entry-json> — a payload entry as the workflow API takes it:
# CLIConfiguration is sg-cli's own block; VCSTriggers is applied in the
# trigger pass (the create API does not take it).
_sg_wf_body() { "$(sg_resolve jq sg_ensure_jq)" -c 'del(.CLIConfiguration, .VCSTriggers)' <<<"$1"; }

# _sg_wf_call <method> <url> <body> — request; silent on success, on failure
# prints "<http-code>: <body>" (one line) so the caller can log a sg-cli-style
# line. 0/22/1.
_sg_wf_call() {
  local tmp rc=0
  tmp="$(mktemp)"
  # Response into a file, not $(...): SG_HTTP_CODE must survive into this shell.
  sg_api_raw "$1" "$2" "$3" >"$tmp" || rc=$?
  [ "$rc" -eq 0 ] || printf '%s: %s\n' "$SG_HTTP_CODE" "$(tr -d '\n' <"$tmp")"
  rm -f "$tmp"
  return "$rc"
}

# sg_update_workflow <group> <entry-json> — PATCH an existing workflow with the
# payload entry. Output/exit as _sg_wf_call.
# TODO(sg-cli): sg-cli only switches to its update path on the message
# "Workflow name not unique", but the API answers 409 "Workflow ID not unique",
# so re-importing an existing workflow fails inside sg-cli; import_bulk
# catches that 409 and updates through here. Remove once sg-cli handles it.
sg_update_workflow() {
  local name
  name="$("$(sg_resolve jq sg_ensure_jq)" -r '.ResourceName' <<<"$2")"
  _sg_wf_call PATCH "$(wf_url "$1" "$name")" "$(_sg_wf_body "$2")"
}

# sg_create_workflow <group> <entry-json> — POST one payload entry; when the
# workflow already exists (409 / "not unique") it is updated instead, as
# sg-cli intends to, and "updated" is printed. Otherwise output/exit as
# _sg_wf_call (callers run this in a subshell, so results travel via stdout).
sg_create_workflow() {
  local grp="$1" entry="$2" err rc=0
  err="$(_sg_wf_call POST "$(sg_org_url)/wfgrps/$grp/wfs/" "$(_sg_wf_body "$entry")")" || rc=$?
  if [ "$rc" -eq 22 ] && { [ "$SG_HTTP_CODE" = "409" ] || [[ "$err" == *"not unique"* ]]; }; then
    sg_update_workflow "$grp" "$entry" && echo updated
    return
  fi
  [ "$rc" -eq 0 ] || printf '%s\n' "$err"
  return "$rc"
}

# sg_upload_tfstate <group> <wf> <file> — upload a workflow's Terraform state:
# fetch the presigned URL, PUT the file. 0 on a 2xx from the store; otherwise
# prints a one-line reason (for the log) and returns 1. The store behind the
# URL differs per environment: Azure Blob requires x-ms-blob-type on every PUT
# (S3/GCS ignore it) and answers 201, not 200.
# TODO(sg-cli): sg-cli's own upload (uploadTfState) sends no x-ms-blob-type and
# only accepts a literal "HTTP/1.1 200 OK", so the migrator re-uploads whatever
# sg-cli reports as failed (import_bulk) — drop that once sg-cli is fixed.
sg_upload_tfstate() {
  local url code body
  body="$(sg_api_get "$(wf_url "$1" "$2")tfstate_upload_url" 2>/dev/null)" || {
    printf 'no upload URL (HTTP %s)' "$SG_HTTP_CODE"
    return 1
  }
  url="$(printf '%s' "$body" | "$(sg_resolve jq sg_ensure_jq)" -r '.msg // empty' 2>/dev/null)"
  [ -n "$url" ] || {
    printf 'no upload URL in the API response'
    return 1
  }
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    -H "Content-Type: application/json" -H "x-ms-blob-type: BlockBlob" \
    -T "$3" "$url" 2>/dev/null)" || true
  code="$(sg_norm_code "$code")"
  case "$code" in 2*) return 0 ;; esac
  printf 'store answered HTTP %s' "$code"
  return 1
}

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
