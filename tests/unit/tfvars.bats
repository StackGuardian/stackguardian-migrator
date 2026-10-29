#!/usr/bin/env bats
# terraform.tfvars reading, writing and upgrading (hcl2json, jq, awk, sed).

load helpers

setup() { load_libs; }

@test "tfvars_get: false is a value, missing takes the default" {
  write_tfvars 'stripCloudAuthVars = false
tfOrg = "acme"'
  [ "$(tfvars_get .stripCloudAuthVars true)" = "false" ]
  [ "$(tfvars_get .tfOrg)" = "acme" ]
  [ "$(tfvars_get .nope dflt)" = "dflt" ]
}

@test "tfvars_has / tfvars_is_null: explicit null vs missing" {
  write_tfvars 'SGDefaultTerraformVersion = null'
  tfvars_has SGDefaultTerraformVersion
  tfvars_is_null SGDefaultTerraformVersion
  ! tfvars_has SGDefaultRunnerConstraints
  ! tfvars_is_null SGDefaultRunnerConstraints
}

@test "tfvars_json: the run overlay merges deeply over the file" {
  write_tfvars 'projectOverrides = { "A" = { workflowGroup = "g-a" }, "B" = { workflowGroup = "g-b" } }'
  TFVARS_OVERLAY_JSON='{"projectOverrides":{"A":{"vcsAuthIntegrationID":"/integrations/x"}}}'
  [ "$(tfvars_get '.projectOverrides.A.workflowGroup')" = "g-a" ]
  [ "$(tfvars_get '.projectOverrides.A.vcsAuthIntegrationID')" = "/integrations/x" ]
  [ "$(tfvars_get '.projectOverrides.B.workflowGroup')" = "g-b" ]
}

@test "_tfvars_str round-trips quotes and backslashes" {
  local v='a "b" \c d\\e'
  write_tfvars "x = $(_tfvars_str "$v")"
  [ "$(tfvars_get .x)" = "$v" ]
}

@test "_tfvars_str escapes template sequences for HCL" {
  # tofu reads "$${d}" as ${d}; hcl2json leaves the escape as it is, so the
  # file text is what is checked here.
  [ "$(_tfvars_str 'a ${d} %{e}')" = '"a $${d} %%{e}"' ]
  write_tfvars "x = $(_tfvars_str 'a ${d} %{e}')"
  tfvars_valid
}

@test "_tfvars_map round-trips through hcl2json" {
  local m='{"Data Tech":{"workflowGroup":"g \"q\"","DeploymentPlatformConfig":[{"kind":"AWS_RBAC","config":{"integrationId":"/integrations/aws"}}]}}'
  write_tfvars "projectOverrides = $(_tfvars_map "$m")"
  tfvars_valid
  # hcl2json sorts object keys.
  [ "$(tfvars_get_json .projectOverrides | "$JQ_BIN" -Sc .)" = "$("$JQ_BIN" -Sc . <<<"$m")" ]
}

@test "_tfvars_map_commented: every line commented, no braces" {
  run _tfvars_map_commented '{"P":{"workflowGroup":"g"}}'
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -v '^# '
  [ "${lines[0]}" = '#   "P" = {' ]
}

@test "tfvars_upgrade: appends missing settings, keeps the file, parses" {
  write_tfvars '# my comment
tfOrg = "acme"
workspacenames = ["*"]'
  cp "$TFVARS" "$BATS_TEST_TMPDIR/before"
  run tfvars_upgrade
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -qx SGDefaultEnableVCSTriggers
  # The original lines are untouched and first; the .bak is the old file.
  # (No cmp: minimal RHEL images have no diffutils.)
  [ "$(head -3 "$TFVARS")" = "$(cat "$BATS_TEST_TMPDIR/before")" ]
  [ "$(cat "$TFVARS.bak")" = "$(cat "$BATS_TEST_TMPDIR/before")" ]
  tfvars_valid
  [ "$(tfvars_get .tfOrg)" = "acme" ]
  # Nothing left to add.
  [ -z "$(tfvars_missing_keys)" ]
  run tfvars_upgrade
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tfvars_missing_keys: a complete example file has none" {
  cp "$REPO/transformer/terraform-cloud/terraform.tfvars.example" "$TFVARS"
  tfvars_invalidate
  run tfvars_missing_keys
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "missing: $output"; return 1; }
}

@test "tfvars_write: a wizard file parses and carries unasked keys" {
  W_TFORG=acme W_WSNAMES_JSON='["*"]' W_EXPORT_STATE=true W_TAGS_JSON=null W_IGNORE_TAGS_JSON=null
  W_APPROVERS_JSON='[]' W_REPO_PREFIX='https://github.com/acme/' W_VCS_INTEGRATION=/integrations/gh
  W_DPC_JSON='[{"kind":"AWS_RBAC","config":{"integrationId":"/integrations/aws"}}]' W_RUNNER_JSON=null
  W_DEST_KIND=GITHUB_COM W_TF_VERSION=null W_TRIGGERS=true W_IGNORE_PATTERNS_JSON='[]'
  W_PREV_JSON='{"myExtra":{"a":1}}'
  tfvars_write "$TFVARS"
  tfvars_valid
  [ "$(tfvars_get .SGDefaultIACVCSRepoPrefix)" = "https://github.com/acme/" ]
  tfvars_is_null SGDefaultTerraformVersion
  [ "$(tfvars_get_json .myExtra)" = '{"a":1}' ]
}
