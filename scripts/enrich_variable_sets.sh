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
# Output: one line naming the sets and one per payload that gained variables;
# SG_VERBOSE=1 adds the fetch step and each set's scope and size.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"
# shellcheck source=lib/tfvars.sh
source "$SCRIPT_DIR/lib/tfvars.sh"
# shellcheck source=lib/tfc_api.sh
source "$SCRIPT_DIR/lib/tfc_api.sh"
TFVARS="${TFVARS:-$SG_REPO_ROOT/transformer/terraform-cloud/terraform.tfvars}"
VERBOSE="${SG_VERBOSE:-0}"

ORG="${1:-}"
shift || true
if [ -z "$ORG" ] || [ "$#" -eq 0 ]; then
  echo "Usage: $0 <org> <payload.json> [more.json ...]" >&2
  exit 1
fi

TFC_HOST="${SG_TFC_HOSTNAME:-$(tfc_hostname)}"
HOST="$TFC_HOST"
command -v curl >/dev/null 2>&1 || {
  sg_err "curl is required for variable-set enrichment"
  exit 1
}
JQ_BIN="$(sg_resolve jq sg_ensure_jq)"

# TFC token: same resolution as the tfe provider / state export (lib/tfc_api.sh).
if [ -z "$(tfc_token "$HOST")" ]; then
  sg_warn "no TFC token (terraform login / TFE_TOKEN); skipping variable-set enrichment"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fetch_all <path> — paginated GET, merged .data array (lib/tfc_api.sh).
fetch_all() { tfc_get_all "$1"; }

[ "$VERBOSE" -eq 1 ] && sg_log "fetching workspaces and variable sets from $HOST (org: $ORG)..."

# name -> {id, project}
fetch_all "organizations/$ORG/workspaces" |
  "$JQ_BIN" '[.[] | {name: .attributes.name, id: .id, project: (.relationships.project.data.id // "")}]' \
    >"$WORK/workspaces.json" || exit 1

# Each set with its scope + variables.
: >"$WORK/sets.ndjson"
sets_raw="$(fetch_all "organizations/$ORG/varsets")" || exit 1
echo "$sets_raw" | "$JQ_BIN" -c '.[]' | while IFS= read -r s; do
  sid="$(echo "$s" | "$JQ_BIN" -r '.id')"
  vars="$(tfc_http "varsets/$sid/relationships/vars" 2>/dev/null |
    "$JQ_BIN" -c '[.data[]? | {key: .attributes.key, value: (.attributes.value // ""), category: .attributes.category, sensitive: (.attributes.sensitive // false), hcl: (.attributes.hcl // false)}]' 2>/dev/null || echo '[]')"
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
# The sets by name; with -v one line per set (scope, size) so it is clear
# where merged vars come from.
set_names="$("$JQ_BIN" -r '[.[].name] | if length > 6 then (.[:6] | join(", ")) + ", ... \(length - 6) more" else join(", ") end' "$WORK/sets.json")"
[ "$VERBOSE" -eq 1 ] && sg_log "resolving $set_count variable set(s) across workspaces:"
[ "$VERBOSE" -eq 1 ] && "$JQ_BIN" -r '.[] | "  - \(.name): \(if .global then "global" else ([(if (.projids | length) > 0 then "\(.projids | length) project(s)" else empty end), (if (.wsids | length) > 0 then "\(.wsids | length) workspace(s)" else empty end)] | if length == 0 then "unassigned" else join(", ") end) end), \(.vars | length) var(s)\(if .priority then ", priority" else "" end)"' "$WORK/sets.json" >&2

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

# TFC-specific variables are stripped here too (same patterns as the transformer).
IGNORE_JSON="$(tfvars_get_json .ignoreVarPatterns)"
[ "$IGNORE_JSON" = "null" ] && IGNORE_JSON='["^TFC_","^TFE_"]'

# Cloud credential env vars are stripped per workflow like the transformer does:
# the payload's DeploymentPlatformConfig[0].kind gives the family (AWS/AZURE/GCP),
# the patterns come from terraform.tfvars. Keep the defaults in sync with
# variables.tf (cloudAuthVarPatterns). jq (Oniguruma) and Terraform (RE2) agree
# on the anchored/prefix patterns used here.
CLOUD_AUTH_DEFAULTS='{"AWS":["^AWS_ACCESS_KEY_ID$","^AWS_SECRET_ACCESS_KEY$","^AWS_SESSION_TOKEN$","^AWS_PROFILE$","^AWS_ROLE_ARN$","^AWS_WEB_IDENTITY_TOKEN_FILE$","^AWS_SHARED_CREDENTIALS_FILE$","^AWS_CONFIG_FILE$"],"AZURE":["^ARM_CLIENT_ID$","^ARM_CLIENT_SECRET$","^ARM_TENANT_ID$","^ARM_SUBSCRIPTION_ID$","^ARM_USE_OIDC$","^ARM_OIDC_","^ARM_CLIENT_CERTIFICATE","^ARM_USE_MSI$","^ARM_MSI_ENDPOINT$"],"GCP":["^GOOGLE_CREDENTIALS$","^GOOGLE_APPLICATION_CREDENTIALS$","^GOOGLE_OAUTH_ACCESS_TOKEN$","^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT$","^CLOUDSDK_AUTH_"]}'
CLOUD_JSON="$(tfvars_get_json .cloudAuthVarPatterns)"
[ "$CLOUD_JSON" = "null" ] && CLOUD_JSON="$CLOUD_AUTH_DEFAULTS"
[ "$(tfvars_get .stripCloudAuthVars true)" != "false" ] || CLOUD_JSON='{}'

# workspace name -> cloud family, from the payloads (for the reports below).
"$JQ_BIN" -s '[.[][] | {key: ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")),
                         value: ((.DeploymentPlatformConfig[0].kind // "") | split("_")[0])}] | from_entries' "$@" >"$WORK/cloud.json"

# Merge the effective set vars into each payload, then report counts: the
# files that gained variables get a line each, the rest are only counted.
unchanged=0
changed_lines=()
for f in "$@"; do
  before_tf="$("$JQ_BIN" '[.[].VCSConfig.iacInputData.data | length] | add // 0' "$f")"
  before_env="$("$JQ_BIN" '[.[].EnvironmentVariables | length] | add // 0' "$f")"
  out="$WORK/merged.json"
  "$JQ_BIN" --slurpfile eff "$WORK/effective.json" --argjson ignore "$IGNORE_JSON" --argjson cloud_patterns "$CLOUD_JSON" '
    ($eff[0]) as $E
    | map(
        ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) as $wsName
        | ($E[$wsName] // [] | map(select(.key as $k | [$ignore[] | . as $p | select($k | test($p))] | length == 0))) as $all
        | ((.DeploymentPlatformConfig[0].kind // "") | split("_")[0]) as $cloud
        | ($cloud_patterns[$cloud] // []) as $cpats
        | ($all | map(select(.sensitive != true and .category == "terraform"))) as $tf
        | ($all | map(select(.sensitive != true and .category == "env"
              and ((.key as $k | [$cpats[] | . as $p | select($k | test($p))] | length) == 0)))) as $env
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
  after_env="$("$JQ_BIN" '[.[].EnvironmentVariables | length] | add // 0' "$f")"
  if [ "$((after_tf - before_tf + after_env - before_env))" -eq 0 ]; then
    unchanged=$((unchanged + 1))
  else
    changed_lines+=("$(basename "$f"): +$((after_tf - before_tf)) terraform, +$((after_env - before_env)) env var(s) from variable sets")
  fi
done
if [ "$unchanged" -eq 0 ]; then
  sg_log "$set_count variable set(s) resolved ($set_names)"
elif [ "$unchanged" -eq "$#" ]; then
  sg_log "$set_count variable set(s) resolved ($set_names); no new variables for the exported workspaces (the sets only override or add nothing here)"
else
  sg_log "$set_count variable set(s) resolved ($set_names); $unchanged payload file(s) gained nothing"
fi
for line in ${changed_lines[@]+"${changed_lines[@]}"}; do sg_log "$line"; done

# Report cloud credential set vars stripped (the connector provides them),
# then sensitive set vars (cannot be migrated; stripped ones excluded) and key
# conflicts.
"$JQ_BIN" -r --slurpfile cloud "$WORK/cloud.json" --argjson pats "$CLOUD_JSON" '
  ($cloud[0]) as $C
  | to_entries[] | .key as $ws | ($pats[$C[$ws] // ""] // []) as $cpats
  | .value[] | select(.category == "env")
  | select(.key as $k | ([$cpats[] | . as $p | select($k | test($p))] | length) > 0)
  | "  - \($ws): env:\(.key) (set \(.set))"
' "$WORK/effective.json" | sort -u >"$WORK/cloudauth.txt"
if [ -s "$WORK/cloudauth.txt" ]; then
  sg_log "cloud credential variable-set vars stripped (the workflow's cloud connector provides them):"
  cat "$WORK/cloudauth.txt" >&2
fi
"$JQ_BIN" -r --slurpfile cloud "$WORK/cloud.json" --argjson pats "$CLOUD_JSON" '
  ($cloud[0]) as $C
  | to_entries[] | .key as $ws | ($pats[$C[$ws] // ""] // []) as $cpats
  | .value[] | select(.sensitive == true)
  | select(.category != "env" or ((.key as $k | [$cpats[] | . as $p | select($k | test($p))] | length) == 0))
  | "  - \($ws): \(.category):\(.key) (set \(.set))"
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
