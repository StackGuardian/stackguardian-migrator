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

# tfc_list_workspaces <org> — [{name, id, project, tags, terraform_version,
# execution_mode, vcs_provider, vcs_url, vcs_identifier}, ...]. The vcs_* fields
# are empty for CLI-driven workspaces (no VCS connection).
tfc_list_workspaces() {
  tfc_get_all "organizations/$1/workspaces" | "$(sg_resolve jq sg_ensure_jq)" -c \
    '[.[] | {name: .attributes.name, id: .id, project: (.relationships.project.data.id // ""), tags: (.attributes."tag-names" // []), terraform_version: .attributes."terraform-version", execution_mode: .attributes."execution-mode",
             vcs_provider: (.attributes."vcs-repo"."service-provider" // ""), vcs_url: (.attributes."vcs-repo"."repository-http-url" // ""), vcs_identifier: (.attributes."vcs-repo".identifier // "")}]'
}

# tfc_select_workspaces <workspaces-json> <names-json> <tags-json> <ignore-json>
# — the subset the transformer exports, mirroring tfe_workspace_ids: name globs
# (["*"] = all), include tags (a workspace must carry all of them), exclude
# tags (any of them drops the workspace). null/[] disables a filter.
tfc_select_workspaces() {
  printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" -c --argjson names "${2:-null}" --argjson tags "${3:-null}" --argjson ignore "${4:-null}" '
    def glob($p): ("^" + ($p | gsub("\\*"; ".*")) + "$");
    [ .[]
      | select(($names == null) or ($names == ["*"]) or ([$names[] as $p | (.name | test(glob($p)))] | any))
      | select(($tags == null) or (($tags | length) == 0) or ([$tags[] as $t | ([.tags[]?] | index($t) != null)] | all))
      | select(($ignore == null) or (($ignore | length) == 0) or (([.tags[]?] | map(select(. as $t | $ignore | index($t) != null)) | length) == 0))
    ]'
}

# tfc_vcs_kind_for <tfc-service-provider> — the SG sourceConfigDestKind that
# matches a TFC VCS provider (github, github_app, gitlab_hosted, ado_services,
# ...); empty when unknown.
tfc_vcs_kind_for() {
  case "$1" in
  github | github_app | github_enterprise) printf 'GITHUB_COM' ;;
  gitlab_hosted | gitlab_community_edition | gitlab_enterprise_edition) printf 'GITLAB_COM' ;;
  bitbucket_hosted | bitbucket_server | bitbucket_data_center) printf 'BITBUCKET_ORG' ;;
  ado_services | ado_server) printf 'AZURE_DEVOPS' ;;
  *) printf '' ;;
  esac
}

# tfc_vcs_label_for <tfc-service-provider> — human name (GitHub, GitLab, ...).
tfc_vcs_label_for() {
  case "$1" in
  github*) printf 'GitHub' ;;
  gitlab*) printf 'GitLab' ;;
  bitbucket*) printf 'Bitbucket' ;;
  ado*) printf 'Azure DevOps' ;;
  *) printf '%s' "$1" ;;
  esac
}

# tfc_vcs_summary <workspaces-json> — one line per provider in use:
# "<provider>\t<count>\t<repo-url-prefix or ->", most common first. The prefix
# is repository-http-url with the repo identifier stripped (https://github.com,
# https://gitlab.example.com, https://dev.azure.com, ...); "-" when the
# workspaces of that provider disagree.
tfc_vcs_summary() {
  printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" -r '
    [ .[] | select(.vcs_provider != "") | . as $o
      | { provider: .vcs_provider,
          prefix: (if ($o.vcs_url | length) > 0 and ($o.vcs_identifier | length) > 0 and ($o.vcs_url | endswith("/" + $o.vcs_identifier))
                   then ($o.vcs_url | rtrimstr("/" + $o.vcs_identifier))
                   else (($o.vcs_url | capture("^(?<h>https?://[^/]+)").h) // "") end) } ]
    | group_by(.provider) | sort_by(-length)
    | .[] | "\(.[0].provider)\t\(length)\t\(([.[].prefix] | unique | map(select(. != ""))) as $p | if ($p | length) == 1 then $p[0] else "-" end)"'
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
