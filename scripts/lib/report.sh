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
  # Per project: the SG workflow group the transformer assigned (projects.*.workflowGroup;
  # older summaries only have the counts, then the default tfc-<segment> is shown).
  "$jqb" -r 'if (.projects // null) != null then .projects | to_entries[] | "    \(.key) -> \(.value.workflowGroup): \(.value.workspaceCount) workflow(s)"
             else .projectWorkspaceCounts | to_entries[] | "    tfc-\(.key | ascii_downcase | gsub("[^a-z0-9-]+"; "-")): \(.value) workflow(s)" end' "$f" >&2
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
  local runners_preset=0
  [ "$("$jqb" -r '.runnerConstraintsSource // "config"' "$f")" = "preset" ] && runners_preset=1
  if [ "$src" = "preset" ] && [ "$runners_preset" -eq 1 ]; then
    sg_row "Version & runners" "left to the org's execution preset (applied at import)"
  else
    if [ "$src" = "preset" ]; then
      sg_row "Terraform version" "none sent; the org's execution preset applies at import"
    elif [ -z "$def" ]; then
      sg_row "Terraform version" "carried from TFC; unpinned or rejected pins go to the execution preset"
    else
      sg_row "Terraform version" "carried from TFC; fallback ${def#TERRAFORM-} for unpinned or rejected pins"
    fi
    [ "$runners_preset" -eq 1 ] && sg_row "Runners" "none sent; the org's execution preset applies at import"
  fi

  _summary_section "$f" '.skippedSensitiveVars' "Sensitive variables skipped" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "TFC never exposes their values; they become placeholder SG secrets after import"
  _summary_section "$f" '.strippedVars' "TFC-specific variables stripped" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "they only mean something inside Terraform Cloud (ignoreVarPatterns)"
  _summary_section "$f" '.strippedCloudAuthVars // {}' "Cloud credential variables stripped" \
    'to_entries[] | "\(.key): \(.value | join(", "))"' "the workflow's cloud connector provides them (stripCloudAuthVars)"
  _summary_section "$f" '.unknownProjectOverrides // []' "projectOverrides key(s) matching no TFC project" \
    '.[]' "typo? their settings apply to nothing"
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
  ws_jq_args
  for f in "$@"; do
    seg="$(seg_of "$f")"
    grp="$(group_for "$seg")"
    existing="$(sg_list_workflows "$grp")"
    printf '%s' "$existing" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || existing='[]'
    rows="$("$JQ_BIN" -r --argjson ex "$existing" --arg grp "$grp" "${WS_JQ_ARGS[@]}" \
      --argjson skip "${PLAN_SKIP_SEGS:-[]}" --arg seg "$seg" \
      --slurpfile sum "${summary:-/dev/null}" "$WS_SCOPE_JQ"'
      ($sum[0] // {}) as $S
      | .[]
      | select(.ResourceName | ws_selected)
      | ((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) as $wsName
      | .ResourceName as $n
      | [ $n, $grp,
          (if ($skip | index($seg)) != null then "skip" elif ($ex | index($n)) != null then "update" else "create" end),
          (.TerraformConfig.terraformVersion // "preset"),
          ((.RunnerConstraints // null) | if . == null then "preset" elif .type == "private" then "private" else "shared" end),
          (if (.VCSTriggers // null) != null then "yes" else "no" end),
          ((.VCSConfig.iacInputData.data // {}) | length),
          (($S.skippedSensitiveVars // {})[$wsName] // [] | length),
          $seg, $wsName, (($S.workspaceProjects // {})[$wsName] // "")
        ] | @tsv' "$f")"
    [ -n "$rows" ] && all_rows="$all_rows${all_rows:+$'\n'}$rows"
    names+=("$grp")
  done
  # Kept for the run result: name, group, action, version, runner, triggers,
  # vars, secrets, segment, workspace, project (tab-separated).
  PLAN_ROWS_TSV="$all_rows"
  while IFS=$'\t' read -r name grp _; do [ -n "$name" ] && names+=("$name"); done <<<"$all_rows"
  wn="$(sg_maxlen 8 ${names[@]+"${names[@]}"})"
  while IFS=$'\t' read -r _ grp _; do [ -n "$grp" ] && groups+=("$grp"); done <<<"$all_rows"
  gn="$(sg_maxlen 5 ${groups[@]+"${groups[@]}"})"
  # The RUNNER column only grows when a row defers to the preset ("preset (private:rg)").
  rw=8
  case "$all_rows" in *$'\t'preset$'\t'*) rw="$(sg_maxlen 8 "preset (${SG_PRESET_RUNNER_SHORT:-})")" ;; esac
  printf "\n  %s%-${wn}s  %-${gn}s  %-7s %-28s %-${rw}s %-8s %-5s %s%s\n" "$C_BOLD" "WORKFLOW" "GROUP" "ACTION" "TERRAFORM" "RUNNER" "TRIGGERS" "VARS" "SECRETS" "$C_RESET" >&2
  # The legend below only explains what the table actually shows.
  local has_create=0 has_update=0 has_skip=0 has_fallback=0 has_preset=0 has_secrets=0 legend=""
  while IFS=$'\t' read -r name grp action tfv runner trig vars secrets _; do
    [ -n "$name" ] || continue
    if [ "$tfv" = "preset" ]; then tfv="preset${SG_PRESET_TFV:+ ($SG_PRESET_TFV)}"; has_preset=1
    elif tf_version_above_ceiling "$tfv"; then tfv="${tfv#TERRAFORM-} -> ${SG_TF_FALLBACK_SHORT:-${SG_DEFAULT_TF_VERSION#TERRAFORM-}} (fallback)"; has_fallback=1
    else tfv="${tfv#TERRAFORM-}"; fi
    [ "$runner" = "preset" ] && { runner="preset${SG_PRESET_RUNNER_SHORT:+ ($SG_PRESET_RUNNER_SHORT)}"; has_preset=1; }
    if [ "$secrets" = "0" ]; then secrets="-"; else has_secrets=1; fi
    case "$action" in
    create) action="${C_GREEN}create ${C_RESET}"; has_create=1 ;;
    update) action="${C_YELLOW}update ${C_RESET}"; has_update=1 ;;
    skip) action="${C_DIM}skip   ${C_RESET}"; has_skip=1 ;;
    esac
    printf "  %-${wn}s  %-${gn}s  %s %-28s %-${rw}s %-8s %-5s %s\n" "$name" "$grp" "$action" "$tfv" "$runner" "$trig" "$vars" "$secrets" >&2
  done <<<"$all_rows"
  echo >&2
  if [ "$has_update" -eq 1 ] || [ "$has_skip" -eq 1 ]; then
    [ "$has_create" -eq 1 ] && legend="create = new workflow"
    [ "$has_update" -eq 1 ] && legend="$legend${legend:+; }update = exists in the group, PATCHed with the current payload"
    [ "$has_skip" -eq 1 ] && legend="$legend${legend:+; }skip = file already imported with identical content (--fresh re-imports)"
    sg_dim "ACTION $legend"
  fi
  legend=""
  [ "$has_fallback" -eq 1 ] && legend="TERRAFORM '-> fallback' = pinned above SG's managed ceiling (1.5.7, last FOSS release)"
  [ "$has_preset" -eq 1 ] && legend="$legend${legend:+; }'preset' = left to the org's execution preset at import"
  [ "$has_secrets" -eq 1 ] && legend="$legend${legend:+; }SECRETS = sensitive vars recreated as placeholder secrets"
  [ -n "$legend" ] && sg_dim "$legend"
  return 0
}

# write_run_result <outcome> — export/run-result.json and run-summary.md: what
# this run planned or did, per workflow, for CI jobs (the markdown is made for
# `cat export/run-summary.md >> "$GITHUB_STEP_SUMMARY"`). Outcome: planned (dry
# run), blocked (plan problems), success, failed. Reads PLAN_ROWS_TSV
# (show_import_plan), PLAN_GROUP_ROWS (plan_groups), PLAN_PROBLEMS, the merged
# run state and CHECKLIST_OPEN. Needs JQ_BIN.
write_run_result() {
  local outcome="$1" json="$EXPORT_DIR/run-result.json" md="$EXPORT_DIR/run-summary.md" rows problems scope
  rows="$(printf '%s\n' "${PLAN_ROWS_TSV:-}" | "$JQ_BIN" -Rc 'select(length > 0) | split("\t")
    | {name: .[0], group: .[1], plan: .[2], terraformVersion: (.[3] | ltrimstr("TERRAFORM-")), runner: .[4], triggers: .[5],
       vars: (.[6] | tonumber? // 0), secrets: (.[7] | tonumber? // 0), segment: .[8], workspace: .[9], project: .[10]}' | "$JQ_BIN" -sc .)"
  problems="$(printf '%s\n' ${PLAN_PROBLEMS[@]+"${PLAN_PROBLEMS[@]}"} | "$JQ_BIN" -Rc 'select(length > 0)' | "$JQ_BIN" -sc .)"
  scope="$("$JQ_BIN" -nc --argjson p "$([ "${#PROJECT_FILTER[@]}" -gt 0 ] && names_json "${PROJECT_FILTER[@]}" || echo '[]')" \
    --argjson w "$([ "${#WS_FILTER[@]}" -gt 0 ] && names_json "${WS_FILTER[@]}" || echo '[]')" \
    --argjson x "$([ "${#WS_EXCLUDE[@]}" -gt 0 ] && names_json "${WS_EXCLUDE[@]}" || echo '[]')" \
    --argjson t "$([ "${#TAG_FILTER[@]}" -gt 0 ] && names_json "${TAG_FILTER[@]}" || echo '[]')" \
    --argjson xt "$([ "${#TAG_EXCLUDE[@]}" -gt 0 ] && names_json "${TAG_EXCLUDE[@]}" || echo '[]')" \
    '{projects: $p, workspaces: $w, excludeWorkspaces: $x, tags: $t, excludeTags: $xt}')"
  state_read | "$JQ_BIN" --arg cmd "$PROG ${SG_RUN_ARGS:-}" --arg at "$(state_now)" --argjson took "$((SECONDS - RUN_T0))" \
    --arg org "$ORG" --arg url "$SG_BASE_URL" --arg region "${SG_REGION:-}" --arg ui "${SG_UI_URL:-}" --argjson dry "$([ "${DRY_RUN:-0}" -eq 1 ] && echo true || echo false)" \
    --arg outcome "$outcome" --argjson scope "$scope" --argjson groups "${PLAN_GROUP_ROWS:-[]}" \
    --argjson overlay "${TFVARS_OVERLAY_JSON:-null}" --arg overlay_desc "$(declare -F overlay_describe >/dev/null && overlay_describe || true)" \
    --argjson problems "$problems" --argjson rows "$rows" --argjson open "${CHECKLIST_OPEN:-0}" '
    . as $st
    | {
      command: $cmd, at: $at, tookSeconds: $took, org: $org, region: $region, apiUrl: $url, uiUrl: $ui, dryRun: $dry, outcome: $outcome,
      scope: $scope, configuration: {description: $overlay_desc, overlay: ($overlay // {})}, groups: $groups, problems: $problems,
      workflows: [ $rows[] | . as $r
        | ($st.import[$r.segment] // {}) as $imp | ($st.triggers[$r.segment] // {}) as $tr
        | . + {
          result: (if $outcome == "planned" or $outcome == "blocked" then "planned"
                   elif $r.plan == "skip" then "skipped"
                   elif (($imp.failed // []) | index($r.name)) != null then "failed"
                   # planned as create but PATCHed: the probe workflow, imported once alone and once with its file
                   elif (($imp.updated // []) | index($r.name)) != null and $r.plan != "create" then "updated"
                   elif (($imp.imported // []) | index($r.name)) != null then "created"
                   else "not-imported" end),
          tfFallback: ((($imp.tf_fallback // []) | index($r.name)) != null),
          state: (if (($imp.state_uploaded // []) | index($r.name)) != null then "uploaded"
                  elif (($imp.state_failed // []) | index($r.name)) != null then "failed"
                  elif (($imp.imported // []) | index($r.name)) != null then "none" else null end),
          triggers: (if $r.triggers == "no" then "none"
                     elif (($tr.failed // []) | index($r.name)) != null then "failed"
                     elif (($tr.missing // []) | index($r.name)) != null then "missing"
                     elif (($tr.unchanged // []) | index($r.name)) != null then "unchanged"
                     elif (($tr.set // []) | index($r.name)) != null then "set" else null end)
        } ],
      checklistOpen: $open, checklist: "post-import-checklist.md"
    }' >"$json"
  "$JQ_BIN" -r '
    "# StackGuardian migration: \(.outcome)", "",
    "- Org: `\(.org)` (\(.apiUrl))", "- Command: `\(.command)`", "- Finished: \(.at) after \(.tookSeconds)s",
    (if .dryRun then "- Dry run: nothing was created or changed in StackGuardian" else empty end),
    (if (.scope | [.[]] | add | length) > 0 then "- Scope: \(.scope | to_entries | map(select(.value | length > 0) | "\(.key) \(.value | join(", "))") | join("; "))" else empty end),
    (if (.configuration.description // "") != "" then "- Run configuration: \(.configuration.description)" else empty end),
    "",
    "| Workflow | Group | Plan | Result | Terraform | State | Triggers |", "|---|---|---|---|---|---|---|",
    (.workflows[] | "| \(.name) | \(.group) | \(.plan) | \(.result) | \(.terraformVersion)\(if .tfFallback then " (fallback)" else "" end) | \(.state // "-") | \(.triggers // "-") |"),
    "",
    (if (.problems | length) > 0 then "## Problems", (.problems[] | "- \(.)"), "" else empty end),
    (if .outcome == "planned" or .outcome == "blocked" then empty
     elif .checklistOpen > 0 then "\(.checklistOpen) item(s) still need a human: see post-import-checklist.md"
     else "Nothing left to do by hand." end)' "$json" >"$md"
}
