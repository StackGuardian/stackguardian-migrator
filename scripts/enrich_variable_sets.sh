#!/bin/bash
# Enrich generated payloads with TFC/TFE Variable Set variables.
#
# The tfe provider can't enumerate variable sets, so we use the TFC API (same
# token as state export). For each workspace we compute the variable sets that
# apply (global / project-scoped / workspace-scoped), resolve set-vs-set
# precedence (priority + scope), and merge the result into the matching workflow
# payload. A workspace's own variable is only overridden by a *priority* set;
# otherwise set vars only fill keys the workspace doesn't define. Sensitive set
# vars can't be read from the API and are skipped + reported.
#
# Usage: enrich_variable_sets.sh <org> <payload.json> [more.json ...]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"

ORG="${1:-}"
shift || true
if [ -z "$ORG" ] || [ "$#" -eq 0 ]; then
  echo "Usage: $0 <org> <payload.json> [more.json ...]" >&2
  exit 1
fi

HOST="${SG_TFC_HOSTNAME:-app.terraform.io}"
API="https://$HOST/api/v2"
command -v curl >/dev/null 2>&1 || { sg_err "curl is required for variable-set enrichment"; exit 1; }
JQ_BIN="$(sg_resolve jq sg_ensure_jq)"

# TFC token (same sources as state export): credentials file or TFE_TOKEN.
creds="$HOME/.terraform.d/credentials.tfrc.json"
token=""
[ -f "$creds" ] && token="$("$JQ_BIN" -r --arg h "$HOST" '.credentials[$h].token // empty' "$creds" 2>/dev/null || true)"
[ -z "$token" ] && token="${TFE_TOKEN:-}"
if [ -z "$token" ]; then
  sg_warn "no TFC token (terraform login / TFE_TOKEN); skipping variable-set enrichment"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AUTH=(-H "Authorization: Bearer $token")

# fetch_all <path> — GET a paginated JSON:API collection, print the merged .data array.
fetch_all() {
  local path="$1" page=1 next
  : >"$WORK/acc.ndjson"
  while :; do
    if ! curl -fsS "${AUTH[@]}" "$API/$path?page%5Bsize%5D=100&page%5Bnumber%5D=$page" >"$WORK/page.json"; then
      sg_err "TFC API request failed: $path"; return 1
    fi
    "$JQ_BIN" -c '.data[]?' "$WORK/page.json" >>"$WORK/acc.ndjson"
    next="$("$JQ_BIN" -r '.meta.pagination."next-page" // empty' "$WORK/page.json" 2>/dev/null || true)"
    [ -z "$next" ] && break
    page="$next"
  done
  "$JQ_BIN" -s '.' "$WORK/acc.ndjson"
}

sg_log "fetching workspaces and variable sets from $HOST (org: $ORG)..."

# name -> {id, project}
fetch_all "organizations/$ORG/workspaces" \
  | "$JQ_BIN" '[.[] | {name: .attributes.name, id: .id, project: (.relationships.project.data.id // "")}]' \
  >"$WORK/workspaces.json" || exit 1

# Each set with its scope + variables.
: >"$WORK/sets.ndjson"
sets_raw="$(fetch_all "organizations/$ORG/varsets")" || exit 1
echo "$sets_raw" | "$JQ_BIN" -c '.[]' | while IFS= read -r s; do
  sid="$(echo "$s" | "$JQ_BIN" -r '.id')"
  vars="$(curl -fsS "${AUTH[@]}" "$API/varsets/$sid/relationships/vars" 2>/dev/null \
    | "$JQ_BIN" -c '[.data[]? | {key: .attributes.key, value: (.attributes.value // ""), category: .attributes.category, sensitive: (.attributes.sensitive // false), hcl: (.attributes.hcl // false)}]' 2>/dev/null || echo '[]')"
  echo "$s" | "$JQ_BIN" -c --argjson vars "$vars" '{
    name: .attributes.name,
    global: (.attributes.global // false),
    priority: (.attributes.priority // false),
    wsids: [.relationships.workspaces.data[]?.id],
    projids: [.relationships.projects.data[]?.id],
    vars: $vars
  }' >>"$WORK/sets.ndjson"
done
"$JQ_BIN" -s '.' "$WORK/sets.ndjson" >"$WORK/sets.json"

set_count="$("$JQ_BIN" 'length' "$WORK/sets.json")"
if [ "$set_count" -eq 0 ]; then
  sg_log "no variable sets found; nothing to enrich"
  exit 0
fi
sg_log "resolving $set_count variable set(s) across workspaces..."

# Per workspace -> list of winning vars (set-vs-set precedence resolved; tagged
# with priority + sensitive + conflict). rank: non-priority global/proj/ws = 1/2/3,
# priority = 5/6/7; workspace's own vars sit at 4 and are applied during merge.
"$JQ_BIN" -n --slurpfile ws "$WORK/workspaces.json" --slurpfile sets "$WORK/sets.json" '
  ($ws[0]) as $workspaces | ($sets[0]) as $sets
  | reduce $workspaces[] as $w ({};
      . + { ($w.name): (
        [ $sets[]
          | . as $s
          | (($s.global == true)
             or (($s.wsids // []) | index($w.id) != null)
             or (($w.project != "") and (($s.projids // []) | index($w.project) != null))) as $applies
          | select($applies)
          | (if (($s.wsids // []) | index($w.id) != null) then 3
             elif (($w.project != "") and (($s.projids // []) | index($w.project) != null)) then 2
             else 1 end) as $scope
          | ($scope + (if $s.priority then 4 else 0 end)) as $rank
          | ($s.vars[]? | {key, value, category, hcl, sensitive, rank: $rank, set: $s.name, priority: ($rank >= 5)})
        ]
        | group_by(.key)
        | map( (max_by(.rank)) as $win
               | $win + { conflict: (([ .[] | select(.rank == $win.rank) ] | length) > 1) } )
      )}
    )
' >"$WORK/effective.json"

# Merge the effective set vars into each payload, then report counts.
for f in "$@"; do
  before_tf="$("$JQ_BIN" '[.[].VCSConfig.iacInputData.data | length] | add // 0' "$f")"
  out="$WORK/merged.json"
  "$JQ_BIN" --slurpfile eff "$WORK/effective.json" '
    ($eff[0]) as $E
    | map(
        ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) as $wsName
        | ($E[$wsName] // []) as $all
        | ($all | map(select(.sensitive != true and .category == "terraform"))) as $tf
        | ($all | map(select(.sensitive != true and .category == "env"))) as $env
        | .VCSConfig.iacInputData.data = (
            reduce $tf[] as $v ((.VCSConfig.iacInputData.data // {});
              ($v.value | (fromjson? // $v.value)) as $val
              | if (has($v.key) | not) then . + {($v.key): $val}
                elif $v.priority then . + {($v.key): $val}
                else . end))
        | .EnvironmentVariables = (
            reduce $env[] as $v ((.EnvironmentVariables // []);
              (map(.config.varName) | index($v.key)) as $idx
              | if ($idx == null) then . + [{config: {textValue: $v.value, varName: $v.key}, kind: "PLAIN_TEXT"}]
                elif $v.priority then (.[$idx].config.textValue = $v.value)
                else . end))
      )
  ' "$f" >"$out" && mv "$out" "$f"
  after_tf="$("$JQ_BIN" '[.[].VCSConfig.iacInputData.data | length] | add // 0' "$f")"
  sg_log "$(basename "$f"): +$((after_tf - before_tf)) terraform var(s) from variable sets"
done

# Report sensitive set vars (cannot be migrated) and key conflicts.
"$JQ_BIN" -r '
  to_entries[] | .key as $ws | .value[]
  | select(.sensitive == true) | "  - \($ws): \(.category):\(.key) (set \(.set))"
' "$WORK/effective.json" | sort -u >"$WORK/sensitive.txt"
if [ -s "$WORK/sensitive.txt" ]; then
  sg_warn "sensitive variable-set vars skipped (recreate as SG secrets):"
  cat "$WORK/sensitive.txt" >&2
fi
"$JQ_BIN" -r '
  to_entries[] | .key as $ws | .value[]
  | select(.conflict == true) | "  - \($ws): \(.category):\(.key)"
' "$WORK/effective.json" | sort -u >"$WORK/conflicts.txt"
if [ -s "$WORK/conflicts.txt" ]; then
  sg_warn "variable-set key conflicts (same key in multiple equal-precedence sets; picked one):"
  cat "$WORK/conflicts.txt" >&2
fi

sg_success "variable-set enrichment complete"
