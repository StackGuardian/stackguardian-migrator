#!/bin/bash
# Reporting helpers (sourced; needs tools.sh, sg_api.sh): the migration
# summary shown after apply, and the per-workflow import plan shown before the
# confirmation prompt (and by 'import --dry-run').

# show_migration_summary — condensed view of export/migration-summary.json plus
# the state export result, so nobody has to know to open the files.
show_migration_summary() {
  local f="$EXPORT_DIR/migration-summary.json" jqb n fails=0 states
  [ -f "$f" ] || return 0
  jqb="$(sg_resolve jq sg_ensure_jq)"
  sg_step "Migration summary"
  sg_row "TFC organisation" "$("$jqb" -r '.organization' "$f")"
  sg_row "Workspaces exported" "$("$jqb" -r '.workspaceCount' "$f")"
  "$jqb" -r '.projectWorkspaceCounts | to_entries[] | "    tfc-\(.key | ascii_downcase | gsub("[^a-z0-9-]+"; "-")): \(.value) workflow(s)"' "$f" >&2
  if [ "$(tfvars_get .exportStateFiles true)" != "false" ]; then
    states=0
    for n in "$EXPORT_DIR"/states/*.tfstate; do [ -f "$n" ] && states=$((states + 1)); done
    [ -s "$EXPORT_DIR/state-export-failures.log" ] && fails="$(wc -l <"$EXPORT_DIR/state-export-failures.log" | tr -d ' ')"
    if [ "$fails" -gt 0 ]; then
      sg_row "State files" "$states exported, ${C_YELLOW}$fails failed${C_RESET} (see below)"
    else
      sg_row "State files" "$states exported to $(sg_rel "$EXPORT_DIR")/states/"
    fi
  fi

  # Version / runner policy (what the transformer sent, or left to the preset).
  local src def
  src="$("$jqb" -r '.terraformVersionSource // "carry"' "$f")"
  def="$("$jqb" -r '.terraformVersionDefault // empty' "$f")"
  if [ "$src" = "preset" ]; then
    sg_row "Terraform version" "none sent; the org's execution preset applies at import"
  elif [ -z "$def" ]; then
    sg_row "Terraform version" "carried from TFC; unpinned or rejected pins go to the execution preset"
  else
    sg_row "Terraform version" "carried from TFC; fallback ${def#TERRAFORM-} for unpinned or rejected pins"
  fi
  [ "$("$jqb" -r '.runnerConstraintsSource // "config"' "$f")" = "preset" ] && sg_row "Runners" "none sent; the org's execution preset applies at import"

  _summary_section "$f" '.skippedSensitiveVars' "Sensitive variables skipped" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "TFC never exposes their values; they become placeholder SG secrets after import"
  _summary_section "$f" '.strippedVars' "TFC-specific variables stripped" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "they only mean something inside Terraform Cloud (ignoreVarPatterns)"
  _summary_section "$f" '.terraformVersionFallbacks' "Terraform version not pinned" \
    'to_entries[] | "\(.key): \"\(.value)\""' "$([ -z "$def" ] && echo "left to the execution preset" || echo "the fallback ${def#TERRAFORM-} is used")"
  _summary_section "$f" '.nonRemoteExecutionModes' "Non-remote execution mode" \
    'to_entries[] | "\(.key): \(.value)"' "their state may not live in TFC"
  _summary_section "$f" '.renamedWorkspaces' "Renamed to a valid SG workflow name" \
    'to_entries[] | "\(.key) -> \(.value)"' ""
  if [ "$fails" -gt 0 ]; then
    printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "state could not be exported for $fails workspace(s):" >&2
    sed 's/^/      /' "$EXPORT_DIR/state-export-failures.log" | head -10 >&2
    [ "$fails" -gt 10 ] && sg_dim "  ... see $(sg_rel "$EXPORT_DIR")/state-export-failures.log"
  fi
  sg_dim "full report: $(sg_rel "$EXPORT_DIR")/migration-summary.md"
}

# _summary_section <file> <jq-path> <title> <jq-line-filter> <hint> — prints
# "! <title> in <n> workspace(s) — <hint>" plus up to 10 detail lines.
_summary_section() {
  local f="$1" path="$2" title="$3" lines="$4" hint="$5" jqb n
  jqb="$(sg_resolve jq sg_ensure_jq)"
  n="$("$jqb" -r "$path | length" "$f")"
  [ "$n" -gt 0 ] || return 0
  printf '  %s!%s %s in %s workspace(s)%s\n' "$C_YELLOW" "$C_RESET" "$title" "$n" "${hint:+ — $hint}" >&2
  "$jqb" -r "$path | $lines" "$f" | head -10 | sed 's/^/      /' >&2
  [ "$n" -gt 10 ] && sg_dim "  ... $((n - 10)) more in migration-summary.md"
  return 0
}

# tf_version_above_ceiling <TERRAFORM-x.y.z> — exit 0 when above 1.5.7.
tf_version_above_ceiling() {
  [[ "$1" =~ ^TERRAFORM-([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  [ "$(printf '%03d%03d%03d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")" -gt "001005007" ]
}

# preset_labels — short labels for the plan and the fallback messages, from
# SG_PRESET_JSON (the org's execution preset, "" when it could not be read) and
# SG_DEFAULT_TF_VERSION ("" = drop the version so the preset decides):
#   SG_PRESET_TFV            "1.5.7" / "bin:/opt/tf" / "platform default"
#   SG_PRESET_RUNNER_SHORT   "shared" / "private:rg"
#   SG_TF_FALLBACK_SHORT     "1.5.7" / "preset"
#   SG_TF_FALLBACK_LABEL     "TERRAFORM-1.5.7" / "no pinned version (the org's execution preset decides: ...)"
# shellcheck disable=SC2034  # consumed by migrate.sh (do_import, tf_fallback_notice) and checklist.sh
preset_labels() {
  SG_PRESET_TFV=""
  SG_PRESET_RUNNER_SHORT=""
  if [ -n "${SG_PRESET_JSON:-}" ]; then
    SG_PRESET_TFV="$(printf '%s' "$SG_PRESET_JSON" | "$JQ_BIN" -r '
      ((.terraformDefaults // {}).TerraformConfig // {}) as $c
      | if (($c.terraformBinPath // []) | length) > 0 then "bin:\($c.terraformBinPath[0].source // "")"
        elif ($c.terraformVersion // "") == "" then "platform default"
        else ($c.terraformVersion | ltrimstr("TERRAFORM-")) end')"
    SG_PRESET_RUNNER_SHORT="$(printf '%s' "$SG_PRESET_JSON" | "$JQ_BIN" -r '(.RunnerConstraints // {}) | if (.type // "shared") == "private" then "private:\((.names // []) | join(","))" else "shared" end')"
  fi
  if [ -n "${SG_DEFAULT_TF_VERSION:-}" ]; then
    SG_TF_FALLBACK_SHORT="${SG_DEFAULT_TF_VERSION#TERRAFORM-}"
    SG_TF_FALLBACK_LABEL="$SG_DEFAULT_TF_VERSION"
  else
    SG_TF_FALLBACK_SHORT="preset"
    SG_TF_FALLBACK_LABEL="the version from the org's execution preset ($(sg_preset_desc "${SG_PRESET_JSON:-}"))"
  fi
}

# show_import_plan <payload>... — per-workflow table: what will be created or
# updated, with the Terraform version (and fallback), runner, triggers and the
# number of variables / skipped secrets. "preset" marks a value the payload
# leaves to the org's execution preset. Columns are sized to their content.
# Needs JQ_BIN, ORG, SG_API_TOKEN, preset_labels.
show_import_plan() {
  local f seg grp existing summary rows all_rows="" name action tfv runner trig vars secrets wn gn rw
  local -a names=() groups=()
  summary="$EXPORT_DIR/migration-summary.json"
  [ -f "$summary" ] || summary=""
  for f in "$@"; do
    seg="$(seg_of "$f")"
    grp="$(group_for "$seg")"
    existing="$(sg_list_workflows "$grp")"
    printf '%s' "$existing" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || existing='[]'
    rows="$("$JQ_BIN" -r --argjson ex "$existing" --arg grp "$grp" --argjson ws "$(ws_filter_json)" \
      --slurpfile sum "${summary:-/dev/null}" '
      ($sum[0] // {}) as $S
      | .[]
      | select(($ws | length) == 0 or (.ResourceName as $n | $ws | index($n) != null))
      | ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) as $wsName
      | .ResourceName as $n
      | [ $n, $grp,
          (if ($ex | index($n)) != null then "update" else "create" end),
          (.TerraformConfig.terraformVersion // "preset"),
          ((.RunnerConstraints // null) | if . == null then "preset" elif .type == "private" then "private" else "shared" end),
          (if (.VCSTriggers // null) != null then "yes" else "no" end),
          ((.VCSConfig.iacInputData.data // {}) | length),
          (($S.skippedSensitiveVars // {})[$wsName] // [] | length)
        ] | @tsv' "$f")"
    [ -n "$rows" ] && all_rows="$all_rows${all_rows:+$'\n'}$rows"
    names+=("$grp")
  done
  while IFS=$'\t' read -r name grp _; do [ -n "$name" ] && names+=("$name"); done <<<"$all_rows"
  wn="$(sg_maxlen 8 ${names[@]+"${names[@]}"})"
  while IFS=$'\t' read -r _ grp _; do [ -n "$grp" ] && groups+=("$grp"); done <<<"$all_rows"
  gn="$(sg_maxlen 5 ${groups[@]+"${groups[@]}"})"
  # The RUNNER column only grows when a row defers to the preset ("preset (private:rg)").
  rw=8
  case "$all_rows" in *$'\t'preset$'\t'*) rw="$(sg_maxlen 8 "preset (${SG_PRESET_RUNNER_SHORT:-})")" ;; esac
  printf "\n  %s%-${wn}s  %-${gn}s  %-7s %-28s %-${rw}s %-8s %-5s %s%s\n" "$C_BOLD" "WORKFLOW" "GROUP" "ACTION" "TERRAFORM" "RUNNER" "TRIGGERS" "VARS" "SECRETS" "$C_RESET" >&2
  while IFS=$'\t' read -r name grp action tfv runner trig vars secrets; do
    [ -n "$name" ] || continue
    if [ "$tfv" = "preset" ]; then tfv="preset${SG_PRESET_TFV:+ ($SG_PRESET_TFV)}"
    elif tf_version_above_ceiling "$tfv"; then tfv="${tfv#TERRAFORM-} -> ${SG_TF_FALLBACK_SHORT:-${SG_DEFAULT_TF_VERSION#TERRAFORM-}} (fallback)"
    else tfv="${tfv#TERRAFORM-}"; fi
    [ "$runner" = "preset" ] && runner="preset${SG_PRESET_RUNNER_SHORT:+ ($SG_PRESET_RUNNER_SHORT)}"
    [ "$secrets" = "0" ] && secrets="-"
    case "$action" in create) action="${C_GREEN}create ${C_RESET}" ;; update) action="${C_YELLOW}update ${C_RESET}" ;; esac
    printf "  %-${wn}s  %-${gn}s  %s %-28s %-${rw}s %-8s %-5s %s\n" "$name" "$grp" "$action" "$tfv" "$runner" "$trig" "$vars" "$secrets" >&2
  done <<<"$all_rows"
  echo >&2
  sg_dim "TERRAFORM '-> fallback' = pinned above SG's managed ceiling (1.5.7, last FOSS release); 'preset' = left to the org's execution preset at import; SECRETS = sensitive vars recreated as placeholder secrets"
}
