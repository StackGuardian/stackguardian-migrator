#!/usr/bin/env bats
# Run state (.sg/state.json) and the tool helpers in tools.sh.

load helpers

setup() { load_libs; }

@test "sg_sha: same value with shasum or sha256sum" {
  # sha256("abc") = ba7816bf8f01cfea...
  [ "$(sg_sha abc)" = "ba7816bf8f01cfea" ]
  printf 'abc' >"$BATS_TEST_TMPDIR/f"
  [ "$(sg_sha_files "$BATS_TEST_TMPDIR/f" "$BATS_TEST_TMPDIR/missing")" = "ba7816bf8f01cfea" ]
}

@test "state: phase done only with the same inputs" {
  state_mark_phase apply sha1
  state_phase_done apply sha1
  ! state_phase_done apply sha2
  ! state_phase_done convert sha1
  [ -f "$SG_STATE_FILE" ]
}

@test "state_now: ISO 8601 UTC" {
  [[ "$(state_now)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "state_import_done: failures and missing state re-run the file" {
  state_record_import p '{"group":"g","payload_sha":"s1","imported":["w"],"failed":[],"state_failed":[],"workspaces":{"ws":{"workflow":"w","group":"g"}}}'
  state_import_done p s1
  ! state_import_done p s2
  state_record_import p '{"group":"g","payload_sha":"s1","imported":[],"failed":[],"state_failed":["w"],"workspaces":{}}'
  ! state_import_done p s1
}

@test "state_record_import: a workspace landing elsewhere is recorded as replaced" {
  state_record_import p '{"group":"g","payload_sha":"s","imported":["w"],"workspaces":{"ws":{"workflow":"w","group":"g"}}}'
  state_record_import p.g2 '{"group":"g2","payload_sha":"s","imported":["w2"],"workspaces":{"ws":{"workflow":"w2","group":"g2"}}}'
  [ "$(state_read | "$JQ_BIN" -c '.replaced_workflows')" = '[{"workspace":"ws","workflow":"w","group":"g"}]' ]
  # Moved out of the old file's map.
  [ "$(state_read | "$JQ_BIN" -c '.import.p.workspaces')" = '{}' ]
}

@test "sg_retry: retries, then returns the last code" {
  local n="$BATS_TEST_TMPDIR/n"
  echo 0 >"$n"
  failing() { echo $(($(cat "$n") + 1)) >"$n"; return 3; }
  run sg_retry 3 0 -- failing
  [ "$status" -eq 3 ]
  [ "$(cat "$n")" = "3" ]
}

@test "sg_retry: SG_NO_RETRY_RC returns at once" {
  local n="$BATS_TEST_TMPDIR/n"
  echo 0 >"$n"
  definitive() { echo $(($(cat "$n") + 1)) >"$n"; return 22; }
  SG_NO_RETRY_RC=22 run sg_retry 4 0 -- definitive
  [ "$status" -eq 22 ]
  [ "$(cat "$n")" = "1" ]
}

# fake_bins <name>... — a PATH dir holding only these (no-op) executables.
fake_bins() {
  local d="$BATS_TEST_TMPDIR/bin-$*" b
  d="${d// /-}"
  mkdir -p "$d"
  for b in "$@"; do printf '#!/bin/sh\n' >"$d/$b" && chmod +x "$d/$b"; done
  printf '%s' "$d"
}

@test "sg_tf_bin: tofu first, terraform as fallback, SG_TF_BIN wins" {
  local both only_tf none
  both="$(fake_bins tofu terraform)"
  only_tf="$(fake_bins terraform)"
  none="$(fake_bins nothing)"
  [ "$(PATH="$both" sg_tf_bin)" = "$both/tofu" ]
  [ "$(PATH="$only_tf" sg_tf_bin)" = "$only_tf/terraform" ]
  [ "$(PATH="$both" SG_TF_BIN=terraform sg_tf_bin)" = "$both/terraform" ]
  ! PATH="$none" sg_tf_bin
  ! PATH="$only_tf" SG_TF_BIN=tofu sg_tf_bin
}
