#!/bin/bash
# Live tests: run the migrator against a real TFC org (the tfc-fixture) and a
# sandbox StackGuardian org, then check what landed there. See README.md.
#
#   op run --env-file <env file> -- tests/live/run.sh [scenario...]
#
# The scenarios share one sandbox checkout and run in order (later ones build
# on the import of "all"); the default is all of them. The StackGuardian side
# is cleaned first; the sandbox stays for inspection ($SG_LIVE_DIR).
set -uo pipefail
# shellcheck disable=SC2016  # jq programs in single quotes
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

A="$SG_LIVE_ROOT_GROUP/tfc-$SG_LIVE_PREFIX-a"
B="$SG_LIVE_ROOT_GROUP/tfc-$SG_LIVE_PREFIX-b"
P="$SG_LIVE_PREFIX"

result() { "$JQ" -c "$1" "$SANDBOX/export/run-result.json" 2>/dev/null; }
# shellcheck disable=SC2016  # jq programs
env_of() { "$JQ" -r --arg n "$2" '.EnvironmentVariables[]? | select(.config.varName == $n) | .config.textValue' <<<"$1"; }

scn_dryrun() {
  check "all --dry-run exits 0" migrate all --dry-run -y
  check "run-result outcome is planned" jqt "$(result .)" '.outcome == "planned"'
  check "nothing created under $SG_LIVE_ROOT_GROUP" test -z "$(sg_names "wfgrps/$SG_LIVE_ROOT_GROUP/wfgrps/listall/")"
}

scn_all() {
  local wf
  check "all -y exits 0" migrate all -y
  check "run-result outcome is success" jqt "$(result .)" '.outcome == "success"'
  check "groups $A and $B exist" test "$(sg_names "wfgrps/$SG_LIVE_ROOT_GROUP/wfgrps/listall/" | sort | tr '\n' ' ')" = "tfc-$P-a tfc-$P-b "
  check "group a holds its 3 workflows" test "$(sg_names "wfgrps/$A/wfs/listall/" | sort | tr '\n' ' ')" = "$(printf '%s\n' "$P-basic" "$P-dup" "${P}_Under" | sort | tr '\n' ' ')"
  check "group b holds its 2 workflows" test "$(sg_names "wfgrps/$B/wfs/listall/" | sort | tr '\n' ' ')" = "$P-b-one $P-b-two "
  check "every workflow created" jqt "$(result .)" '[.workflows[].result] | unique == ["created"]'
  check "every state uploaded" jqt "$(result .)" '[.workflows[].state] | unique == ["uploaded"]'

  wf="$(sg_wf "$A" "$P-basic")"
  check "basic: own region wins over the project set" jqt "$wf" '.VCSConfig.iacInputData.data.region == "eu-central-1"'
  check "basic: HCL list is a JSON array" jqt "$wf" '.VCSConfig.iacInputData.data.subnets == ["a","b"]'
  check "basic: HCL map is a JSON object" jqt "$wf" '.VCSConfig.iacInputData.data.tags_map == {"env":"dev","team":"a"}'
  check "basic: template sequences kept literally" jqt "$wf" '.VCSConfig.iacInputData.data.greeting == "hello ${name} and %{if true}x%{endif}"'
  check "basic: env var LOG_LEVEL" test "$(env_of "$wf" LOG_LEVEL)" = debug
  check "basic: project set env var SHARED_ENV" test "$(env_of "$wf" SHARED_ENV)" = from-project-set
  check "basic: env CROSS from the workspace set" test "$(env_of "$wf" CROSS)" = env-val
  known "basic: terraform CROSS from the project set (group_by key ignores category)" jqt "$wf" '.VCSConfig.iacInputData.data.CROSS == "tf-val"'
  check "basic: VCS triggers set" jqt "$(result .)" '.workflows[] | select(.name == "'"$P-basic"'") | .triggers == "set"'

  wf="$(sg_wf "$A" "$P-dup")"
  check "dup: 1.9.8 falls back to TERRAFORM-1.5.7" jqt "$wf" '.TerraformConfig.terraformVersion == "TERRAFORM-1.5.7"'
  check "dup: priority set wins over the workspace var" jqt "$wf" '.VCSConfig.iacInputData.data.instance_type == "t3.large"'
  check "dup: env TOKEN references a secret" jqt "$wf" '[.EnvironmentVariables[] | select(.config.varName == "TOKEN") | .config.textValue | test("secret::")] == [true]'
  known "dup: env TOKEN and terraform TOKEN get different secrets" jqt "$wf" '([.EnvironmentVariables[] | select(.config.varName == "TOKEN") | .config.textValue][0]) as $e | .VCSConfig.iacInputData.data.TOKEN as $t
    | ($e | tostring | test("secret::")) and ($t | tostring | test("secret::")) and $e != $t'

  check "secret stubs created" jqt "$(sg_call GET secrets/listall/)" '[.msg[].ResourceName | select(startswith("tfc-'"$P"'-dup-"))] | length >= 3'
}

scn_rerun() {
  check "a second all -y exits 0" migrate all -y
  check "export phases skipped" log_has 'unchanged since .* skipped'
  known "nothing created or updated (payload patches change the import hash)" jqt "$(result .)" '[.workflows[].result] | unique == ["skipped"]'
}

scn_fresh() {
  check "all --fresh -y exits 0" migrate all --fresh -y
  check "every workflow updated, none duplicated" jqt "$(result .)" '[.workflows[].result] | unique == ["updated"]'
  check "group a still holds 3 workflows" test "$(sg_names "wfgrps/$A/wfs/listall/" | wc -l | tr -d ' ')" = 3
  check "the ceiling fallback also covers the update" jqt "$(result .)" '.workflows[] | select(.name == "'"$P-dup"'") | .result == "updated" and .tfFallback'
}

scn_vars() {
  local wf body
  wf="$(sg_wf "$B" "$P-b-one")"
  body="$("$JQ" -c '{EnvironmentVariables: (.EnvironmentVariables + [{kind:"PLAIN_TEXT", config:{varName:"SG_ONLY", textValue:"kept"}}])}' <<<"$wf")"
  sg_call PATCH "wfgrps/$B/wfs/$P-b-one/" "$body" >/dev/null
  check "SG-only variable added through the API" test "$SG_CODE" = 200
  check "import --fresh --merge-vars exits 0" migrate import --fresh --merge-vars -y
  check "merge keeps the SG-only variable" test "$(env_of "$(sg_wf "$B" "$P-b-one")" SG_ONLY)" = kept
  check "import --fresh --replace-vars exits 0" migrate import --fresh --replace-vars -y
  check "replace drops the SG-only variable" test -z "$(env_of "$(sg_wf "$B" "$P-b-one")" SG_ONLY)"
}

scn_scoped() {
  check "import --project $P-b --fresh exits 0" migrate import --project "$P-b" --fresh -y
  known "a scoped run stubs only its own workflows' secrets" test -z "$(grep 'no payload entry found' "$SANDBOX/last.log")"
  check "only project b in the result" jqt "$(result .)" '[.workflows[].group] | unique == ["'"$B"'"]'
  check "group a untouched (3 workflows)" test "$(sg_names "wfgrps/$A/wfs/listall/" | wc -l | tr -d ' ')" = 3
}

# A workspace without a VCS repository: the API requires a repo. Its own
# scenario (and last), since the export is redone without the exclusion.
scn_novcs() {
  known "import of a workspace without VCS succeeds" migrate all -y --workspace "$P-novcs" --set 'tfWorkspaceIgnoreNames=[]'
}

# A workspace with a 25-var set: the set is read unpaged (20 vars arrive), and
# SG's update API refuses more than 20 env vars (create accepts them).
scn_big() {
  local wf
  migrate all -y --workspace "$P-big" --set 'tfWorkspaceIgnoreNames=[]'
  wf="$(sg_wf "$B" "$P-big")"
  known "big: all 25 set vars arrive (set vars read unpaged)" jqt "$wf" '[.EnvironmentVariables[] | select(.config.varName | startswith("BIG_"))] | length == 25'
  known "big: a re-import of a workflow with >20 env vars succeeds" migrate import --fresh -y --workspace "$P-big" --set 'tfWorkspaceIgnoreNames=[]'
}

ALL_SCENARIOS="dryrun all rerun fresh vars scoped big novcs"

main() {
  local s t0
  live_guard
  if [ "${1:-}" = clean ]; then
    live_clean
    printf '✓ cleaned %s/%s\n' "$SG_ORG" "$SG_LIVE_ROOT_GROUP"
    return
  fi
  printf 'live tests: SG org %s at %s, TFC org %s, root group %s\n' "$SG_ORG" "$SG_BASE_URL" "$TFC_ORG" "$SG_LIVE_ROOT_GROUP"
  printf 'sandbox: %s\n' "$SANDBOX"
  live_clean
  live_sandbox
  # shellcheck disable=SC2048,SC2086  # scenario names are plain words
  for s in ${*:-$ALL_SCENARIOS}; do
    declare -F "scn_$s" >/dev/null || live_die "unknown scenario '$s' (have: $ALL_SCENARIOS)"
    LIVE_SCENARIO="$s" LIVE_STEP=0
    t0=$SECONDS
    printf '\n── %s ──\n' "$s"
    "scn_$s"
    printf '  (%ss)\n' "$((SECONDS - t0))"
  done
  printf '\n%s passed, %s failed, %s known bugs\n' "$LIVE_PASS" "$LIVE_FAIL" "$LIVE_KNOWN"
  [ "$LIVE_FAIL" -eq 0 ] || {
    printf '  ✗ %s\n' "${LIVE_FAILED[@]}"
    printf 'logs: %s/log.<scenario>.<step>\n' "$SANDBOX"
    exit 1
  }
}

main "$@"
