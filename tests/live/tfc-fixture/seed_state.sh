#!/bin/bash
# seed_state.sh <prefix> — give every fixture workspace without a state a small
# one (lock, POST state-version, unlock), so the export and the SG state upload
# have something to carry. The tfe provider has no resource for this.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../scripts/tools.sh
source "$here/../../../scripts/tools.sh"
# shellcheck source=../../../scripts/lib/tfc_api.sh
source "$here/../../../scripts/lib/tfc_api.sh"
export TFC_HOST="${TFC_HOST:-app.terraform.io}"
JQ="$(sg_resolve jq sg_ensure_jq)"
prefix="${1:-mig-test}"

ids="$(cd "$here" && tofu output -json workspace_ids)"
for ws in $("$JQ" -r 'keys[]' <<<"$ids"); do
  [[ "$ws" == "$prefix"* ]] || continue
  id="$("$JQ" -r --arg w "$ws" '.[$w]' <<<"$ids")"
  if tfc_http "workspaces/$id/current-state-version" >/dev/null 2>&1; then
    echo "  $ws: has a state"
    continue
  fi
  lineage="$(uuidgen | tr 'A-Z' 'a-z')"
  state="$("$JQ" -nc --arg l "$lineage" --arg w "$ws" '{version:4, terraform_version:"1.5.7", serial:1, lineage:$l,
    outputs:{workspace:{value:$w, type:"string"}}, resources:[], check_results:null}')"
  md5="$(printf '%s' "$state" | { md5sum 2>/dev/null || md5 -q; } | cut -d' ' -f1)"
  b64="$(printf '%s' "$state" | base64 | tr -d '\n')"
  body="$("$JQ" -nc --arg m "$md5" --arg l "$lineage" --arg s "$b64" \
    '{data:{type:"state-versions", attributes:{serial:1, md5:$m, lineage:$l, state:$s}}}')"
  tfc_http "workspaces/$id/actions/lock" -X POST --data '{"reason":"seed state"}' >/dev/null
  if tfc_http "workspaces/$id/state-versions" -X POST --data "$body" >/dev/null; then
    echo "  $ws: state seeded"
  else
    echo "  $ws: state upload failed (HTTP $TFC_HTTP_CODE)" >&2
  fi
  tfc_http "workspaces/$id/actions/unlock" -X POST >/dev/null
done
