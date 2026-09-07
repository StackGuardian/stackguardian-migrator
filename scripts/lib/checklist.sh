#!/bin/bash
# Post-import checklist and secret stubs (sourced; needs tools.sh, sg_api.sh,
# state.sh). Turns everything the migration could not do automatically into
# export/post-import-checklist.md, and creates placeholder SG secrets for the
# sensitive variables TFC never exposes so the workflows are wired up and the
# user only has to fill in values.

SG_UI_URL="${SG_UI_URL:-https://app.stackguardian.io}"
wf_ui_url() { printf '%s/orchestrator/orgs/%s/wfgrps/%s/wfs/%s' "$SG_UI_URL" "$ORG" "$1" "$2"; }
secrets_ui_url() { printf '%s/orchestrator/orgs/%s/settings?tab=secrets' "$SG_UI_URL" "$ORG"; }

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

# write_checklist — render export/post-import-checklist.md and print it.
write_checklist() {
  local out="$EXPORT_DIR/post-import-checklist.md" summary="$EXPORT_DIR/migration-summary.json" st items
  st="$(state_read)"
  {
    printf '# Post-import checklist — StackGuardian org %s\n\n' "$ORG"
    printf 'Generated %s by stackguardian-migrator. Tick items as you complete them.\n\n' "$(state_now)"

    # 1. secrets
    printf '## 1. Set the real values of the placeholder secrets\n\n'
    printf 'TFC never exposes sensitive variable values, so each one was recreated as an SG secret with the value `CHANGE_ME` and referenced from its workflow as `${secret::<name>}`. Set the real values under [Org settings → Secrets](%s).\n\n' "$(secrets_ui_url)"
    items="$(printf '%s' "$st" | "$JQ_BIN" -r --arg ui "$SG_UI_URL" --arg org "$ORG" '.secrets // {} | to_entries[] | "- [ ] `\(.key)` — \(.value.category) var `\(.value.var)` of [\(.value.group)/\(.value.workflow)](\($ui)/orchestrator/orgs/\($org)/wfgrps/\(.value.group)/wfs/\(.value.workflow))"')"
    if [ -n "$items" ]; then printf '%s\n\n' "$items"; else printf -- '- None.\n\n'; fi
    if [ -f "$summary" ]; then
      items="$("$JQ_BIN" -r --argjson stubbed "$(printf '%s' "$st" | "$JQ_BIN" -c '[.secrets // {} | .[] | "\(.workspace)|\(.category):\(.var)"]')" \
        '.skippedSensitiveVars | to_entries[] | .key as $ws | .value[] | select(($ws + "|" + .) as $k | $stubbed | index($k) == null) | "- [ ] `\(.)` of workspace `\($ws)` — no stub created (workflow missing or --no-secret-stubs); create the secret and reference it by hand"' "$summary")"
      [ -n "$items" ] && printf '%s\n\n' "$items"
    fi

    # 2. failed imports
    printf '## 2. Workflows that failed to import\n\n'
    items="$(printf '%s' "$st" | "$JQ_BIN" -r '.import // {} | to_entries[] | .value.group as $g | .value.failed[]? | "- [ ] `\($g)/\(.)` — see the import output for the API error; fix terraform.tfvars (or workspaceOverrides) and re-run `./sg-migrate.sh import`"')"
    if [ -n "$items" ]; then printf '%s\n\n' "$items"; else printf -- '- None.\n\n'; fi

    # 3. terraform version fallbacks
    printf '## 3. Verify workflows moved to a different Terraform version\n\n'
    printf 'StackGuardian bundles managed Terraform only up to 1.5.7 (the last MPL/FOSS release). These workflows were pinned higher in TFC and now run the fallback version; run a plan and check for incompatibilities. To keep the newer version, point `workspaceOverrides[<ws>].terraformVersion` at a binary on a private runner and re-import.\n\n'
    items=""
    [ -s "$EXPORT_DIR/terraform-version-fallbacks.log" ] && items="$(sed 's/^/- [ ] /' "$EXPORT_DIR/terraform-version-fallbacks.log")"
    if [ -f "$summary" ]; then
      items="$items$(printf '%s' "$items" | grep -q . && echo)$("$JQ_BIN" -r '.terraformVersionFallbacks | to_entries[] | "- [ ] `\(.key)` was not pinned in TFC (\"\(.value)\"); SGDefaultTerraformVersion was used — confirm it is compatible"' "$summary")"
    fi
    if [ -n "$items" ]; then printf '%s\n\n' "$items"; else printf -- '- None.\n\n'; fi

    # 4. VCS triggers
    printf '## 4. VCS triggers\n\n'
    items="$(printf '%s' "$st" | "$JQ_BIN" -r '.triggers // {} | to_entries[] | .value.group as $g | (.value.failed[]? | "- [ ] `\($g)/\(.)` — trigger registration failed; check the connector has admin/webhook rights on the repository, then re-run `./sg-migrate.sh triggers`"), (.value.missing[]? | "- [ ] `\($g)/\(.)` — workflow was not imported, so no trigger was registered")')"
    if [ -n "$items" ]; then printf '%s\n\n' "$items"; else printf -- '- None failed. Push to a tracked branch or open a pull request to confirm the webhooks fire.\n\n'; fi

    # 5. state
    printf '## 5. Terraform state\n\n'
    if [ -s "$EXPORT_DIR/state-export-failures.log" ]; then
      printf 'State could not be pulled from TFC for these workspaces; upload it manually (Workflow → Settings → State) or run an import in the new workflow.\n\n'
      sed 's/^/- [ ] /' "$EXPORT_DIR/state-export-failures.log"; echo
    else
      printf -- '- All selected workspaces had their state exported.\n\n'
    fi
    if [ -f "$summary" ]; then
      items="$("$JQ_BIN" -r '.nonRemoteExecutionModes | to_entries[] | "- [ ] `\(.key)` used `\(.value)` execution in TFC — its state may live outside TFC; verify the exported state is current"' "$summary")"
      [ -n "$items" ] && printf '%s\n\n' "$items"
    fi

    # 6. renames
    if [ -f "$summary" ] && [ "$("$JQ_BIN" '.renamedWorkspaces | length' "$summary")" -gt 0 ]; then
      printf '## 6. Renamed workflows\n\nThese TFC workspace names were not valid StackGuardian workflow names and were adjusted:\n\n'
      "$JQ_BIN" -r '.renamedWorkspaces | to_entries[] | "- `\(.key)` → `\(.value)`"' "$summary"; echo
    fi

    printf '## Finally\n\n- [ ] Run a plan on one workflow per project and compare with the last TFC run.\n- [ ] Disable auto-apply / triggers on the TFC workspaces once StackGuardian owns the deployments.\n'
  } >"$out"
  sg_step "Post-import checklist"
  sed 's/^/  /' "$out" >&2
  sg_dim "saved to $(sg_rel "$out")"
}

cmd_checklist() {
  sg_step "Phase: checklist"
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  export SG_API_TOKEN SG_BASE_URL
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."
  [ "$SECRET_STUBS" -eq 1 ] && create_secret_stubs
  write_checklist
}
