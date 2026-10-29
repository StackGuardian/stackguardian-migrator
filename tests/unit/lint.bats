#!/usr/bin/env bats
# The portability lint itself, and the scripts' syntax under the bash that
# runs them (/bin/bash: 3.2 on macOS).

load helpers

@test "portability lint: the repo is clean" {
  run "$REPO/tests/lint-portability.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "portability lint: flags every known-bad line of the fixture" {
  run "$REPO/tests/lint-portability.sh" "$BATS_TEST_DIRNAME/fixtures/lint-bad.sh"
  [ "$status" -eq 1 ]
  # Lines 5, 7 and 27 are the portable forms (-i.bak, a later read -r, a quoted brace default).
  local n flagged
  flagged=" $(printf '%s\n' "$output" | sed -nE 's/^[^ ]*lint-bad\.sh:([0-9]+):.*/\1/p' | sort -n | uniq | tr '\n' ' ')"
  for n in 1 2 3 4 6 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 28 29; do
    case "$flagged" in *" $n "*) ;; *) echo "line $n not flagged (got:$flagged)"; return 1 ;; esac
  done
  for n in 5 7 27; do
    case "$flagged" in *" $n "*) echo "line $n flagged but is portable"; return 1 ;; esac
  done
}

@test "every script parses with /bin/bash" {
  local f bad=""
  for f in "$REPO"/sg-migrate.sh "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh "$REPO"/tests/*.sh; do
    /bin/bash -n "$f" 2>&1 || bad="$bad $f"
  done
  [ -z "$bad" ] || { echo "syntax errors in:$bad"; return 1; }
}

@test "shellcheck (skipped when not installed)" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  cd "$REPO"
  # The libraries are checked through migrate.sh (-x follows its sources).
  # SC2034 is off: the parser sets globals the sourced libraries read, which
  # shellcheck cannot see across files in that direction.
  run shellcheck -x -S warning -e SC2034 sg-migrate.sh scripts/*.sh tests/*.sh
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
