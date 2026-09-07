#!/bin/bash
# Reporting helpers (sourced; needs tools.sh, sg_api.sh): the migration
# summary shown after apply, and the per-workflow import plan shown before the
# confirmation prompt (and by 'import --dry-run').

# show_migration_summary — condensed view of export/migration-summary.json plus
# state-export-failures.log, so nobody has to know to open the files.
show_migration_summary() {
  local f="$EXPORT_DIR/migration-summary.json" jqb n
  [ -f "$f" ] || return 0
  jqb="$(sg_resolve jq sg_ensure_jq)"
  sg_step "Migration summary"
  printf '  %s%-30s%s %s\n' "$C_BOLD" "TFC organisation" "$C_RESET" "$("$jqb" -r '.organization' "$f")" >&2
  printf '  %s%-30s%s %s\n' "$C_BOLD" "Workspaces exported" "$C_RESET" "$("$jqb" -r '.workspaceCount' "$f")" >&2
  "$jqb" -r '.projectWorkspaceCounts | to_entries[] | "    tfc-\(.key | ascii_downcase | gsub("[^a-z0-9-]+"; "-")): \(.value) workflow(s)"' "$f" >&2

  _summary_section "$f" '.skippedSensitiveVars' "Sensitive variables skipped (TFC never exposes them)" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "recreated as SG secrets after import"
  _summary_section "$f" '.strippedVars' "TFC-specific variables stripped (ignoreVarPatterns)" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' ""
  _summary_section "$f" '.terraformVersionFallbacks' "Terraform version not pinned (SGDefaultTerraformVersion used)" \
    'to_entries[] | "\(.key): \"\(.value)\""' ""
  _summary_section "$f" '.nonRemoteExecutionModes' "Non-remote execution mode (state may not be in TFC)" \
    'to_entries[] | "\(.key): \(.value)"' ""
  _summary_section "$f" '.renamedWorkspaces' "Renamed to a valid SG workflow name" \
    'to_entries[] | "\(.key) -> \(.value)"' ""
  if [ -s "$EXPORT_DIR/state-export-failures.log" ]; then
    n="$(wc -l <"$EXPORT_DIR/state-export-failures.log" | tr -d ' ')"
    printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "state could not be exported for $n workspace(s):" >&2
    sed 's/^/      /' "$EXPORT_DIR/state-export-failures.log" | head -10 >&2
    [ "$n" -gt 10 ] && sg_dim "  ... see $(sg_rel "$EXPORT_DIR")/state-export-failures.log"
  fi
  sg_dim "full report: $(sg_rel "$EXPORT_DIR")/migration-summary.md"
}

# _summary_section <file> <jq-path> <title> <jq-line-filter> <hint>
_summary_section() {
  local f="$1" path="$2" title="$3" lines="$4" hint="$5" jqb n
  jqb="$(sg_resolve jq sg_ensure_jq)"
  n="$("$jqb" -r "$path | length" "$f")"
  [ "$n" -gt 0 ] || return 0
  printf '  %s!%s %s (%s)%s\n' "$C_YELLOW" "$C_RESET" "$title" "$n" "${hint:+ — $hint}" >&2
  "$jqb" -r "$path | $lines" "$f" | head -10 | sed 's/^/      /' >&2
  [ "$n" -gt 10 ] && sg_dim "  ... $((n - 10)) more in migration-summary.md"
  return 0
}

# tf_version_above_ceiling <TERRAFORM-x.y.z> — exit 0 when above 1.5.7.
tf_version_above_ceiling() {
  [[ "$1" =~ ^TERRAFORM-([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  [ "$(printf '%03d%03d%03d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")" -gt "001005007" ]
}

# show_import_plan <payload>... — per-workflow table: what will be created or
# updated, with the Terraform version (and fallback), runner, triggers and the
# number of variables / skipped secrets. Needs JQ_BIN, ORG, SG_API_TOKEN.
show_import_plan() {
  local f seg grp existing summary rows
  summary="$EXPORT_DIR/migration-summary.json"
  [ -f "$summary" ] || summary=""
  printf '\n  %s%-28s %-24s %-7s %-28s %-8s %-8s %-5s %s%s\n' "$C_BOLD" "WORKFLOW" "GROUP" "ACTION" "TERRAFORM" "RUNNER" "TRIGGERS" "VARS" "SECRETS" "$C_RESET" >&2
  for f in "$@"; do
    seg="$(seg_of "$f")"
    grp="$(group_for "$seg")"
    existing="$(sg_list_workflows "$grp")"
    printf '%s' "$existing" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || existing='[]'
    rows="$("$JQ_BIN" -r --argjson ex "$existing" --arg def "$SG_DEFAULT_TF_VERSION" --argjson ws "$(ws_filter_json)" \
      --slurpfile sum "${summary:-/dev/null}" '
      ($sum[0] // {}) as $S
      | .[]
      | select(($ws | length) == 0 or (.ResourceName as $n | $ws | index($n) != null))
      | ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) as $wsName
      | .ResourceName as $n
      | [ $n,
          (if ($ex | index($n)) != null then "update" else "create" end),
          (.TerraformConfig.terraformVersion // "-"),
          ((.RunnerConstraints // {}) | if .type == "private" then "private" else "shared" end),
          (if (.VCSTriggers // null) != null then "yes" else "no" end),
          ((.VCSConfig.iacInputData.data // {}) | length),
          (($S.skippedSensitiveVars // {})[$wsName] // [] | length)
        ] | @tsv' "$f")"
    while IFS=$'\t' read -r name action tfv runner trig vars secrets; do
      [ -n "$name" ] || continue
      if tf_version_above_ceiling "$tfv"; then tfv="${tfv#TERRAFORM-} -> ${SG_DEFAULT_TF_VERSION#TERRAFORM-} (fallback)"; else tfv="${tfv#TERRAFORM-}"; fi
      [ "$secrets" = "0" ] && secrets="-"
      case "$action" in create) action="${C_GREEN}create ${C_RESET}" ;; update) action="${C_YELLOW}update ${C_RESET}" ;; esac
      printf '  %-28s %-24s %s %-28s %-8s %-8s %-5s %s\n' "$name" "$grp" "$action" "$tfv" "$runner" "$trig" "$vars" "$secrets" >&2
    done <<<"$rows"
  done
  echo >&2
  sg_dim "TERRAFORM '-> fallback' = pinned above SG's managed ceiling (1.5.7, last FOSS release); SECRETS = sensitive vars to recreate"
}
