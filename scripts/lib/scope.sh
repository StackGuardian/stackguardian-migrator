#!/bin/bash
# Run scope for the migrator (sourced; needs tools.sh, lib/tfvars.sh, jq).
#
# terraform.tfvars holds the widest scope (workspacenames, tfWorkspaceIgnoreNames,
# the tag filters) and the CLI narrows one run:
#   --workspace GLOB          replaces workspacenames for the run ("*" = all)
#   --exclude-workspace GLOB  adds to tfWorkspaceIgnoreNames for the run
# Every phase applies the same selection: apply hands the lists to terraform,
# the later phases match them against the payload entries (ResourceName), so
# 'import --workspace "team-*"' picks the workflows 'apply --workspace "team-*"'
# exported. Globs support * and ?.

PROJECT_FILTER=()
WS_FILTER=()
WS_EXCLUDE=()

# names_json <name>... — the arguments as a JSON array of strings.
names_json() { printf '%s\n' "$@" | "$JQ_BIN" -R . | "$JQ_BIN" -s .; }

_scope_jq() { JQ_BIN="${JQ_BIN:-$(sg_resolve jq sg_ensure_jq)}"; }

# ws_narrowed — exit 0 when a CLI flag restricts the run ("*" alone does not,
# so a CI run over everything keeps the unchanged-file skip).
ws_narrowed() {
  local p
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && return 0
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do [ "$p" = "*" ] || return 0; done
  return 1
}

# ws_filter_json — the --workspace globs as a JSON array ([] = no filter).
ws_filter_json() {
  local p
  _scope_jq
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do
    [ "$p" = "*" ] || { names_json "${WS_FILTER[@]}"; return; }
  done
  echo '[]'
}

# ws_exclude_json — tfWorkspaceIgnoreNames from terraform.tfvars plus the
# --exclude-workspace globs, as a JSON array (memoized per process).
ws_exclude_json() {
  local tf
  if [ -z "${_WS_EXCLUDE_JSON:-}" ]; then
    _scope_jq
    tf="$(tfvars_get_json .tfWorkspaceIgnoreNames)"
    [ "$tf" = "null" ] && tf='[]'
    if [ "${#WS_EXCLUDE[@]}" -eq 0 ]; then
      _WS_EXCLUDE_JSON="$("$JQ_BIN" -c . <<<"$tf")"
    else
      _WS_EXCLUDE_JSON="$("$JQ_BIN" -nc --argjson a "$tf" --argjson b "$(names_json "${WS_EXCLUDE[@]}")" '$a + $b | unique')"
    fi
  fi
  printf '%s' "$_WS_EXCLUDE_JSON"
}

# ws_selected <name> — exit 0 when <name> is in the run's scope: not excluded,
# and matched by a --workspace glob when one is set.
ws_selected() {
  local p
  if [ -z "${_WS_EXCLUDE_LIST+x}" ]; then
    _WS_EXCLUDE_LIST=()
    while IFS= read -r p; do [ -n "$p" ] && _WS_EXCLUDE_LIST+=("$p"); done < <(ws_exclude_json | "$JQ_BIN" -r '.[]')
  fi
  for p in ${_WS_EXCLUDE_LIST[@]+"${_WS_EXCLUDE_LIST[@]}"}; do
    # shellcheck disable=SC2254  # unquoted on purpose: $p is a glob
    case "$1" in $p) return 1 ;; esac
  done
  ws_narrowed || return 0
  for p in ${WS_FILTER[@]+"${WS_FILTER[@]}"}; do
    [ "$p" = "*" ] && return 0
    # shellcheck disable=SC2254
    case "$1" in $p) return 0 ;; esac
  done
  [ "${#WS_FILTER[@]}" -eq 0 ]
}

# WS_SCOPE_JQ — the same test for jq programs over payload entries. Prepend it
# to the program and pass "${WS_JQ_ARGS[@]}" (after ws_jq_args), then use
# 'select(.ResourceName | ws_selected)'.
WS_SCOPE_JQ='
  def ws_glob($p): "^" + ($p | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
  def ws_selected: . as $n
    | (($inc | length) == 0 or any($inc[]; . as $p | $n | test(ws_glob($p))))
    and (($exc | length) == 0 or (any($exc[]; . as $p | $n | test(ws_glob($p))) | not));
'
WS_JQ_ARGS=()
# ws_jq_args — fill WS_JQ_ARGS with the --argjson pairs WS_SCOPE_JQ expects.
ws_jq_args() { WS_JQ_ARGS=(--argjson inc "$(ws_filter_json)" --argjson exc "$(ws_exclude_json)"); }

# scope_tfvar_args — fill SCOPE_TFVAR_ARGS with the -var flags that hand the
# CLI scope to terraform apply (nothing when no flag is set).
SCOPE_TFVAR_ARGS=()
scope_tfvar_args() {
  SCOPE_TFVAR_ARGS=()
  _scope_jq
  [ "${#WS_FILTER[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "workspacenames=$(names_json "${WS_FILTER[@]}")")
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && SCOPE_TFVAR_ARGS+=(-var "tfWorkspaceIgnoreNames=$(ws_exclude_json)")
  return 0
}

# scope_describe — one line for the log: what the CLI flags select.
scope_describe() {
  local out=""
  [ "${#WS_FILTER[@]}" -gt 0 ] && out="workspaces ${WS_FILTER[*]}"
  [ "${#WS_EXCLUDE[@]}" -gt 0 ] && out="${out:+$out, }excluding ${WS_EXCLUDE[*]}"
  printf '%s' "$out"
}

# scope_sha_input — the CLI scope as a string for the apply phase hash, so a
# run with a different selection re-runs the export.
scope_sha_input() { printf '%s|%s' "$(ws_filter_json)" "$(ws_exclude_json)"; }
