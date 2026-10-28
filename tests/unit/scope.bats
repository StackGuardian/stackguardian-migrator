#!/usr/bin/env bats
# Run scope: the bash globs (ws_selected) and the jq globs (WS_SCOPE_JQ) must
# pick the same workspaces, on every platform.

load helpers

setup() {
  load_libs
  write_tfvars 'tfWorkspaceIgnoreNames = ["sandbox-*"]'
}

NAMES=(app-prod app-dev team-a-prod sandbox-1 'odd.name' 'x?y' infra)

# both_select — the names each implementation selects, one line each "bash|jq".
both_select() {
  local n b j
  ws_jq_args
  for n in "${NAMES[@]}"; do
    if ws_selected "$n"; then b=1; else b=0; fi
    j="$("$JQ_BIN" -rn --arg n "$n" "${WS_JQ_ARGS[@]}" "$WS_SCOPE_JQ"' $n | if ws_selected then 1 else 0 end')"
    printf '%s %s|%s\n' "$n" "$b" "$j"
  done
}

@test "ws_selected: tfvars excludes apply without flags" {
  ! ws_selected sandbox-1
  ws_selected app-prod
}

@test "ws_selected: --workspace globs, excludes win" {
  WS_FILTER=('app-*' 'sandbox-*')
  ws_selected app-dev
  ! ws_selected infra
  ! ws_selected sandbox-1
}

@test "ws_selected: '*' alone is not a narrowing" {
  WS_FILTER=('*')
  ! ws_narrowed
  ws_selected infra
}

@test "ws_selected: ? and literal dots" {
  WS_FILTER=('odd.name' 'x?y')
  ws_selected odd.name
  ! ws_selected oddxname
  ws_selected 'x?y'
  ws_selected xzy
}

@test "bash and jq globs agree: no flags" {
  run both_select
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E ' (0\|1|1\|0)$'
}

@test "bash and jq globs agree: --workspace + --exclude-workspace" {
  WS_FILTER=('*-prod' 'x?y' 'odd.name')
  WS_EXCLUDE=('team-*')
  run both_select
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E ' (0\|1|1\|0)$'
  printf '%s\n' "$output" | grep -qx 'app-prod 1|1'
  printf '%s\n' "$output" | grep -qx 'team-a-prod 0|0'
}

@test "project_selected: by name or slug, split files belong to their project" {
  PROJECT_FILTER=('Data Tech')
  project_selected data-tech
  project_selected data-tech.wfgrp-data-tech-dev
  ! project_selected other
  PROJECT_FILTER=(other)
  ! project_selected data-tech.wfgrp-data-tech-dev
}

@test "names_json keeps spaces and globs" {
  [ "$(names_json 'a b' '*' 'c"d')" = '["a b","*","c\"d"]' ]
}

@test "ws_exclude_json: tfvars and flags, unique" {
  WS_EXCLUDE=('sandbox-*' 'tmp-*')
  [ "$(ws_exclude_json)" = '["sandbox-*","tmp-*"]' ]
}
