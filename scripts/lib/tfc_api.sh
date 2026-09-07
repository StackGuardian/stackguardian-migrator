#!/bin/bash
# Terraform Cloud/Enterprise API access (sourced; needs tools.sh + tfvars.sh).
#
# Token resolution mirrors the tfe provider: TFE_TOKEN, then TF_TOKEN_<host>,
# then the `terraform login` credentials file. All helpers print JSON on stdout
# and log on stderr.

# tfc_hostname — TFC/TFE host from terraform.tfvars (tfHostname), default app.terraform.io.
tfc_hostname() {
  local h
  h="$(tfvars_get '.tfHostname')"
  printf '%s' "${h:-app.terraform.io}"
}

# tfc_token <host> — the token the tfe provider will use, or nothing.
tfc_token() {
  local host="$1" var creds
  if [ -n "${TFE_TOKEN:-}" ]; then printf '%s' "$TFE_TOKEN"; return; fi
  var="TF_TOKEN_$(echo "$host" | sed 's/-/__/g; s/\./_/g')"
  if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; return; fi
  creds="$HOME/.terraform.d/credentials.tfrc.json"
  [ -f "$creds" ] && "$(sg_resolve jq sg_ensure_jq)" -r --arg h "$host" '.credentials[$h].token // empty' "$creds" 2>/dev/null || true
}

# tfc_token_source — human description of where the token came from.
tfc_token_source() {
  if [ -n "${TFE_TOKEN:-}" ]; then printf 'TFE_TOKEN'
  elif env | grep -q '^TF_TOKEN_'; then printf 'the TF_TOKEN_* variable'
  else printf "the 'terraform login' session"; fi
}

# tfc_http <path> [curl-args...] — GET https://<host>/api/v2/<path>, body on
# stdout. Exit 0 on 2xx, 22 on 4xx, 1 on 5xx/network. Sets TFC_HTTP_CODE.
tfc_http() {
  local path="$1" host token tmp code
  shift
  host="${TFC_HOST:-$(tfc_hostname)}"
  token="$(tfc_token "$host")"
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" \
    -H "Content-Type: application/vnd.api+json" "$@" "https://$host/api/v2/$path" 2>/dev/null)" || true
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  # shellcheck disable=SC2034  # read by callers
  TFC_HTTP_CODE="$code"
  case "$code" in
  2*) cat "$tmp"; rm -f "$tmp"; return 0 ;;
  4*) rm -f "$tmp"; return 22 ;;
  *) rm -f "$tmp"; return 1 ;;
  esac
}

# tfc_get_all <path> — GET a paginated JSON:API collection; prints the merged
# .data array. Fails (non-zero) if any page fails.
tfc_get_all() {
  local path="$1" page=1 next acc sep body jqb
  jqb="$(sg_resolve jq sg_ensure_jq)"
  acc="$(mktemp)"
  : >"$acc"
  case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
  while :; do
    if ! body="$(tfc_http "${path}${sep}page%5Bsize%5D=100&page%5Bnumber%5D=$page")"; then
      sg_err "TFC API request failed (HTTP ${TFC_HTTP_CODE:-000}): $path"
      rm -f "$acc"
      return 1
    fi
    printf '%s' "$body" | "$jqb" -c '.data[]?' >>"$acc"
    next="$(printf '%s' "$body" | "$jqb" -r '.meta.pagination."next-page" // empty' 2>/dev/null || true)"
    [ -z "$next" ] && break
    page="$next"
  done
  "$jqb" -s '.' "$acc"
  rm -f "$acc"
}

# tfc_list_orgs — ["org-name", ...] the token can see.
tfc_list_orgs() { tfc_get_all "organizations" | "$(sg_resolve jq sg_ensure_jq)" -c '[.[].id]'; }

# tfc_list_projects <org> — [{id, name}, ...]
tfc_list_projects() { tfc_get_all "organizations/$1/projects" | "$(sg_resolve jq sg_ensure_jq)" -c '[.[] | {id: .id, name: .attributes.name}]'; }

# tfc_list_workspaces <org> — [{name, id, project, tags, terraform_version, execution_mode}, ...]
tfc_list_workspaces() {
  tfc_get_all "organizations/$1/workspaces" | "$(sg_resolve jq sg_ensure_jq)" -c \
    '[.[] | {name: .attributes.name, id: .id, project: (.relationships.project.data.id // ""), tags: (.attributes."tag-names" // []), terraform_version: .attributes."terraform-version", execution_mode: .attributes."execution-mode"}]'
}

# require_tfc_auth — fail fast when the tfe provider would not be able to
# authenticate: no credential at all, or one that TFC/TFE rejects (e.g. an
# expired `terraform login` session). Verified with GET /account/details.
require_tfc_auth() {
  local host token
  host="$(tfc_hostname)"
  token="$(tfc_token "$host")"
  [ -n "$token" ] || die "no Terraform Cloud/Enterprise credentials found for $host. Set TFE_TOKEN=<long-lived API token> (recommended) or run 'terraform login' before '$PROG apply'."
  command -v curl >/dev/null 2>&1 || return 0
  if tfc_http "account/details" >/dev/null; then
    sg_log "TFC/TFE credentials verified ($host)"
    return 0
  fi
  case "$TFC_HTTP_CODE" in
  401 | 403) die "Terraform Cloud/Enterprise rejected $(tfc_token_source) for $host (HTTP $TFC_HTTP_CODE). Set TFE_TOKEN=<long-lived API token> or re-run 'terraform login'." ;;
  000) die "could not reach https://$host to verify TFC/TFE credentials (network/proxy?)" ;;
  *) sg_warn "unexpected HTTP $TFC_HTTP_CODE verifying TFC/TFE credentials at $host; continuing" ;;
  esac
}
