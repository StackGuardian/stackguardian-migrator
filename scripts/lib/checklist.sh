#!/bin/bash
# Post-import checklist and secret stubs (sourced; needs tools.sh, sg_api.sh,
# state.sh). Turns everything the migration could not do automatically into
# export/post-import-checklist.md, and creates placeholder SG secrets for the
# sensitive variables TFC never exposes so the workflows are wired up and the
# user only has to fill in values.

SG_UI_URL="${SG_UI_URL:-https://app.stackguardian.io}"
wf_ui_url() { printf '%s/orchestrator/orgs/%s/wfgrps/%s/wfs/%s' "$SG_UI_URL" "$ORG" "$1" "$2"; }
wfgrp_ui_url() { printf '%s/orchestrator/orgs/%s/wfgrps/%s' "$SG_UI_URL" "$ORG" "$1"; }
secrets_ui_url() { printf '%s/orchestrator/orgs/%s?tab=secrets' "$SG_UI_URL" "$ORG"; }
# Set by write_checklist: how many checklist items still need a human (read by
# finish_line in migrate.sh).
# shellcheck disable=SC2034
CHECKLIST_OPEN=0

# secret_name_for <workflow> <var> — SG secret name for a stubbed variable.
secret_name_for() { printf 'tfc-%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_-\n' '-' | cut -c1-100; }

# workflow_for_workspace <tfc-workspace-name> — "<seg>\t<group>\t<ResourceName>"
# for the payload entry whose TfStateFilePath basename is the workspace.
workflow_for_workspace() {
  local f seg wf
  for f in "${PF[@]}"; do
    wf="$("$JQ_BIN" -r --arg ws "$1" '.[] | select(((.CLIConfiguration.TfStateFilePath // "") | sub(".*/"; "") | sub("\\.tfstate$"; "")) == $ws) | .ResourceName' "$f" | head -1)"
    if [ -n "$wf" ]; then
      seg="$(seg_of "$f")"
      printf '%s\t%s\t%s\n' "$seg" "$(group_for "$seg")" "$wf"
      return 0
    fi
  done
  return 1
}

# create_secret_stubs — for every skipped sensitive variable: create the SG
# secret (placeholder value) if missing, reference it from the workflow (env
# var or IaC input), patch the payload file to match, and record it in state.
create_secret_stubs() {
  local summary="$EXPORT_DIR/migration-summary.json" ws entry cat var f seg grp wf name ref created=0 reused=0 patched=0 skipped=0 body imported
  [ -f "$summary" ] || return 0
  [ "$("$JQ_BIN" '.skippedSensitiveVars | length' "$summary")" -gt 0 ] || return 0
  sg_log "creating placeholder secrets for sensitive variables (value: CHANGE_ME)..."
  while IFS=$'\t' read -r ws entry; do
    [ -n "$ws" ] || continue
    cat="${entry%%:*}"
    var="${entry#*:}"
    if ! IFS=$'\t' read -r seg grp wf < <(workflow_for_workspace "$ws"); then
      sg_warn "  $ws: no payload entry found for $entry — listed in the checklist only"
      skipped=$((skipped + 1))
      continue
    fi
    ws_selected "$wf" || continue
    imported="$(state_read | "$JQ_BIN" -r --arg s "$seg" --arg w "$wf" '.import[$s].imported // [] | index($w) != null')"
    if [ "$imported" != "true" ] || ! sg_workflow_exists "$grp" "$wf"; then
      sg_warn "  $grp/$wf is not in StackGuardian (import failed?) — $entry listed in the checklist only"
      skipped=$((skipped + 1))
      continue
    fi
    name="$(secret_name_for "$wf" "$var")"
    ref="\${secret::$name}"
    if sg_secret_exists "$name"; then
      reused=$((reused + 1))
    elif sg_create_secret "$name" "CHANGE_ME" "Placeholder for TFC sensitive variable $entry of workspace $ws — set the real value"; then
      created=$((created + 1))
    else
      sg_warn "  could not create secret $name — $entry listed in the checklist only"
      skipped=$((skipped + 1))
      continue
    fi
    # Reference the secret from the workflow: env var or IaC input value.
    f="$EXPORT_DIR/sg-payload.$seg.json"
    if [ "$cat" = "env" ]; then
      "$JQ_BIN" --arg w "$wf" --arg v "$var" --arg r "$ref" 'map(if .ResourceName == $w then
          .EnvironmentVariables = ((.EnvironmentVariables // []) | map(select(.config.varName != $v)) + [{kind:"PLAIN_TEXT", config:{varName:$v, textValue:$r}}]) else . end)' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
      body="$("$JQ_BIN" -c --arg w "$wf" '.[] | select(.ResourceName == $w) | {EnvironmentVariables}' "$f")"
    else
      "$JQ_BIN" --arg w "$wf" --arg v "$var" --arg r "$ref" 'map(if .ResourceName == $w then .VCSConfig.iacInputData.data[$v] = $r else . end)' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
      body="$("$JQ_BIN" -c --arg w "$wf" '.[] | select(.ResourceName == $w) | {VCSConfig}' "$f")"
    fi
    if SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_patch_workflow "$grp" "$wf" "$body"; then
      patched=$((patched + 1))
    else
      sg_warn "  secret $name created but $grp/$wf could not be updated to reference it"
    fi
    state_update '.secrets[$n] = {workflow: $w, group: $g, var: $v, category: $c, workspace: $ws, at: $at}' \
      --arg n "$name" --arg w "$wf" --arg g "$grp" --arg v "$var" --arg c "$cat" --arg ws "$ws" --arg at "$(state_now)"
  done < <("$JQ_BIN" -r '.skippedSensitiveVars | to_entries[] | .key as $ws | .value[] | "\($ws)\t\(.)"' "$summary")
  sg_log "secret stubs: $created created, $reused already existed, $patched workflow(s) now reference them, $skipped skipped"
  return 0
}

# _cl_count <text> — number of non-empty lines in a block of items.
_cl_count() {
  if [ -z "$1" ]; then printf '0'; else printf '%s\n' "$1" | grep -c . || true; fi
}

# _cl_status <count> <ok-text> <attention-text> — one terminal line per section.
_cl_status() {
  if [ "${1:-0}" -gt 0 ]; then printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$3" >&2
  else printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$2" >&2; fi
}

# _cl_block <items> — the markdown list for a section, or "- None."
_cl_block() { if [ -n "$1" ]; then printf '%s\n\n' "$1"; else printf -- '- None.\n\n'; fi; }

# write_checklist — render export/post-import-checklist.md, then show what
# landed and which sections still need a human (the file has the details and
# links; the terminal gets one status line per section). Sets CHECKLIST_OPEN.
write_checklist() {
  local out="$EXPORT_DIR/post-import-checklist.md" summary="$EXPORT_DIR/migration-summary.json" st
  local i_secrets i_unstubbed="" i_failed i_fallback="" i_unpinned="" i_preset="" i_trig i_state="" i_nonremote="" i_renamed=""
  local n_secrets n_unstubbed n_failed n_fallback n_unpinned n_preset n_trig n_state n_nonremote n_renamed
  local f seg grp n total=0 gw preset_desc=""
  local -a glines=()
  st="$(state_read)"
  [ -n "${SG_PRESET_JSON:-}" ] && preset_desc="$(sg_preset_desc "$SG_PRESET_JSON")"

  # --- collect the items once (markdown lines) --------------------------------
  i_secrets="$(printf '%s' "$st" | "$JQ_BIN" -r --arg ui "$SG_UI_URL" --arg org "$ORG" '.secrets // {} | to_entries[] | "- [ ] `\(.key)` — \(.value.category) var `\(.value.var)` of [\(.value.group)/\(.value.workflow)](\($ui)/orchestrator/orgs/\($org)/wfgrps/\(.value.group)/wfs/\(.value.workflow))"')"
  if [ -f "$summary" ]; then
    i_unstubbed="$("$JQ_BIN" -r --argjson stubbed "$(printf '%s' "$st" | "$JQ_BIN" -c '[.secrets // {} | .[] | "\(.workspace)|\(.category):\(.var)"]')" \
      '.skippedSensitiveVars | to_entries[] | .key as $ws | .value[] | select(($ws + "|" + .) as $k | $stubbed | index($k) == null) | "- [ ] `\(.)` of workspace `\($ws)` — no stub created (workflow missing or --no-secret-stubs); create the secret and reference it by hand"' "$summary")"
    i_unpinned="$("$JQ_BIN" -r --arg fb "${SG_TF_FALLBACK_LABEL:-the fallback version}" '.terraformVersionFallbacks | to_entries[] | "- [ ] `\(.key)` was not pinned in TFC (\"\(.value)\"); it runs \($fb) — confirm it is compatible"' "$summary")"
    # Preset mode: no version was sent for anyone, so every workflow may run
    # something other than its TFC version — list them all with what TFC had.
    if [ "$("$JQ_BIN" -r '.terraformVersionSource // "carry"' "$summary")" = "preset" ]; then
      i_preset="$("$JQ_BIN" -r --arg p "${preset_desc:-the execution preset of the org}" '.tfcTerraformVersions // {} | to_entries[] | "- [ ] `\(.key)` ran Terraform \(.value) in TFC; now \($p) applies — run a plan before relying on it"' "$summary")"
    fi
    i_nonremote="$("$JQ_BIN" -r '.nonRemoteExecutionModes | to_entries[] | "- [ ] `\(.key)` used `\(.value)` execution in TFC — its state may live outside TFC; verify the exported state is current"' "$summary")"
    i_renamed="$("$JQ_BIN" -r '.renamedWorkspaces | to_entries[] | "- `\(.key)` → `\(.value)`"' "$summary")"
  fi
  i_failed="$(printf '%s' "$st" | "$JQ_BIN" -r '.import // {} | to_entries[] | .value.group as $g | .value.failed[]? | "- [ ] `\($g)/\(.)` — see the import output for the API error; fix terraform.tfvars (or workspaceOverrides) and re-run `./sg-migrate.sh import`"')"
  [ -s "$EXPORT_DIR/terraform-version-fallbacks.log" ] && i_fallback="$(sed 's/^/- [ ] /' "$EXPORT_DIR/terraform-version-fallbacks.log")"
  i_trig="$(printf '%s' "$st" | "$JQ_BIN" -r '.triggers // {} | to_entries[] | .value.group as $g | (.value.failed[]? | "- [ ] `\($g)/\(.)` — trigger registration failed; check the connector has admin/webhook rights on the repository, then re-run `./sg-migrate.sh triggers`"), (.value.missing[]? | "- [ ] `\($g)/\(.)` — workflow was not imported, so no trigger was registered")')"
  [ -s "$EXPORT_DIR/state-export-failures.log" ] && i_state="$(sed 's/^/- [ ] /' "$EXPORT_DIR/state-export-failures.log")"
  n_secrets="$(_cl_count "$i_secrets")"; n_unstubbed="$(_cl_count "$i_unstubbed")"; n_failed="$(_cl_count "$i_failed")"
  n_fallback="$(_cl_count "$i_fallback")"; n_unpinned="$(_cl_count "$i_unpinned")"; n_preset="$(_cl_count "$i_preset")"; n_trig="$(_cl_count "$i_trig")"
  n_state="$(_cl_count "$i_state")"; n_nonremote="$(_cl_count "$i_nonremote")"; n_renamed="$(_cl_count "$i_renamed")"

  # --- the file -----------------------------------------------------------------
  {
    printf '# Post-import checklist — StackGuardian org %s\n\n' "$ORG"
    printf 'Generated %s by stackguardian-migrator. Tick items as you complete them.\n\n' "$(state_now)"
    printf '## 1. Set the real values of the placeholder secrets\n\n'
    printf 'TFC never exposes sensitive variable values, so each one was recreated as an SG secret with the value `CHANGE_ME` and referenced from its workflow as `${secret::<name>}`. Set the real values under [Org settings → Secrets](%s).\n\n' "$(secrets_ui_url)"
    _cl_block "$i_secrets"
    [ -n "$i_unstubbed" ] && printf '%s\n\n' "$i_unstubbed"
    printf '## 2. Workflows that failed to import\n\n'
    _cl_block "$i_failed"
    printf '## 3. Verify workflows moved to a different Terraform version\n\n'
    printf 'StackGuardian bundles managed Terraform only up to 1.5.7 (the last MPL/FOSS release). Workflows listed here run a different version than they did in TFC: the fallback `SGDefaultTerraformVersion`, or the version from the execution preset of the org (Settings → Runner groups → Execution presets) when no version was sent. Run a plan and check for incompatibilities. To keep a newer version, point `workspaceOverrides[<ws>].terraformVersion` at a binary on a private runner, or give the execution preset a custom runtime image that ships it, and re-import.\n\n'
    _cl_block "$(printf '%s\n%s\n%s' "$i_fallback" "$i_unpinned" "$i_preset" | grep . || true)"
    printf '## 4. VCS triggers\n\n'
    if [ -n "$i_trig" ]; then printf '%s\n\n' "$i_trig"; else printf -- '- None failed. Push to a tracked branch or open a pull request to confirm the webhooks fire.\n\n'; fi
    printf '## 5. Terraform state\n\n'
    if [ -n "$i_state" ]; then
      printf 'State could not be pulled from TFC for these workspaces; upload it manually (Workflow → Settings → State) or run an import in the new workflow.\n\n%s\n\n' "$i_state"
    else
      printf -- '- All selected workspaces had their state exported.\n\n'
    fi
    [ -n "$i_nonremote" ] && printf '%s\n\n' "$i_nonremote"
    if [ -n "$i_renamed" ]; then
      printf '## 6. Renamed workflows\n\nThese TFC workspace names were not valid StackGuardian workflow names and were adjusted:\n\n%s\n\n' "$i_renamed"
    fi
    printf '## Finally\n\n- [ ] Run a plan on one workflow per project and compare with the last TFC run.\n- [ ] Disable auto-apply / triggers on the TFC workspaces once StackGuardian owns the deployments.\n'
  } >"$out"

  # --- the terminal view --------------------------------------------------------
  sg_step "Post-import checklist"
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    grp="$(group_for "$seg")"
    n="$(printf '%s' "$st" | "$JQ_BIN" -r --arg s "$seg" '.import[$s].imported // [] | length')"
    total=$((total + n))
    glines+=("$grp ($n)|$(wfgrp_ui_url "$grp")")
  done
  if [ "$total" -gt 0 ]; then
    printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$total workflow(s) are in StackGuardian org $ORG:" >&2
    gw="$(sg_maxlen 10 "${glines[@]%%|*}")"
    for n in "${glines[@]}"; do printf "      %-${gw}s  %s%s%s\n" "${n%%|*}" "$C_DIM" "${n#*|}" "$C_RESET" >&2; done
  fi
  _cl_status "$((n_secrets + n_unstubbed))" "secrets: none to fill in" \
    "secrets: set the real value of $n_secrets placeholder secret(s) (value CHANGE_ME)${i_unstubbed:+; $n_unstubbed sensitive var(s) have no stub}"
  _cl_status "$n_failed" "imports: none failed" "imports: $n_failed workflow(s) failed — fix and re-run '$PROG import'"
  if [ "$n_preset" -gt 0 ]; then
    _cl_status "$n_preset" "" "Terraform version: all $n_preset workflow(s) take the execution preset's version (${preset_desc:-see the SG org settings}) instead of their TFC version — run a plan before relying on them"
  else
    _cl_status "$((n_fallback + n_unpinned))" "Terraform version: every workflow keeps its TFC version" \
      "Terraform version: $((n_fallback + n_unpinned)) workflow(s) run ${SG_TF_FALLBACK_LABEL:-the fallback version} instead of what TFC used — run a plan before relying on them"
  fi
  _cl_status "$n_trig" "VCS triggers: registered for every workflow that had them" "VCS triggers: $n_trig workflow(s) without triggers — see the checklist, then '$PROG triggers'"
  _cl_status "$((n_state + n_nonremote))" "state: exported for every selected workspace" \
    "state: $n_state workspace(s) without exported state${i_nonremote:+, $n_nonremote with non-remote execution} — upload by hand"
  [ "$n_renamed" -gt 0 ] && _cl_status "$n_renamed" "" "names: $n_renamed workflow(s) were renamed to valid SG names"
  # shellcheck disable=SC2034
  CHECKLIST_OPEN=$((n_secrets + n_unstubbed + n_failed + n_fallback + n_unpinned + n_preset + n_trig + n_state + n_nonremote))
  sg_dim "full checklist with links: $(sg_rel "$out")"
}

cmd_checklist() {
  phase_begin "checklist"
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  export SG_API_TOKEN SG_BASE_URL
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."
  [ "$SECRET_STUBS" -eq 1 ] && create_secret_stubs
  write_checklist
}
