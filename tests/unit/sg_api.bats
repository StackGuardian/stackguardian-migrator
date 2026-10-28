#!/usr/bin/env bats
# Pure parts of the SG API layer: variable merge, preset fill, descriptions.

load helpers

setup() { load_libs; }

LIVE='{"EnvironmentVariables":[{"kind":"PLAIN_TEXT","config":{"varName":"A","textValue":"live-a"}},{"kind":"PLAIN_TEXT","config":{"varName":"SG_ONLY","textValue":"x"}}],"VCSConfig":{"iacInputData":{"data":{"a":"live","sg_only":1}}}}'
BODY='{"EnvironmentVariables":[{"kind":"PLAIN_TEXT","config":{"varName":"A","textValue":"tfc-a"}},{"kind":"PLAIN_TEXT","config":{"varName":"NEW","textValue":"n"}}],"VCSConfig":{"iacInputData":{"data":{"a":"tfc","b":2}}}}'

@test "_sg_wf_vars_merge merge: payload wins, SG-only kept, new appended" {
  run _sg_wf_vars_merge merge "$LIVE" "$BODY"
  [ "$status" -eq 0 ]
  [ "$("$JQ_BIN" -c '[.EnvironmentVariables[] | "\(.config.varName)=\(.config.textValue)"]' <<<"$output")" = '["A=tfc-a","SG_ONLY=x","NEW=n"]' ]
  [ "$("$JQ_BIN" -c '.VCSConfig.iacInputData.data' <<<"$output")" = '{"a":"tfc","sg_only":1,"b":2}' ]
}

@test "_sg_wf_vars_merge add: the workflow's values win" {
  run _sg_wf_vars_merge add "$LIVE" "$BODY"
  [ "$status" -eq 0 ]
  [ "$("$JQ_BIN" -c '[.EnvironmentVariables[] | "\(.config.varName)=\(.config.textValue)"]' <<<"$output")" = '["A=live-a","SG_ONLY=x","NEW=n"]' ]
  [ "$("$JQ_BIN" -c '.VCSConfig.iacInputData.data' <<<"$output")" = '{"a":"live","b":2,"sg_only":1}' ]
}

@test "_sg_wf_vars_merge: keys the body leaves out stay out" {
  run _sg_wf_vars_merge merge "$LIVE" '{"Description":"d"}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"Description":"d"}' ]
}

PRESET='{"terraformDefaults":{"TerraformConfig":{"terraformVersion":"/opt/tf","terraformBinPath":[{"source":"/usr/bin/terraform","target":"/opt/tf"}]}},"RunnerConstraints":{"type":"private","names":["rg"]}}'

@test "_sg_wf_preset_fill: fills what the body leaves out" {
  SG_PRESET_JSON="$PRESET"
  run _sg_wf_preset_fill '{"WfType":"TERRAFORM","TerraformConfig":{"approvalPreApply":true}}'
  [ "$status" -eq 0 ]
  [ "$("$JQ_BIN" -r '.TerraformConfig.terraformVersion' <<<"$output")" = "/opt/tf" ]
  [ "$("$JQ_BIN" -r '.TerraformConfig.terraformBinPath[0].target' <<<"$output")" = "/opt/tf" ]
  [ "$("$JQ_BIN" -c '.RunnerConstraints' <<<"$output")" = '{"type":"private","names":["rg"]}' ]
}

@test "_sg_wf_preset_fill: an explicit version and runner are kept" {
  SG_PRESET_JSON="$PRESET"
  run _sg_wf_preset_fill '{"WfType":"TERRAFORM","TerraformConfig":{"terraformVersion":"TERRAFORM-1.5.7"},"RunnerConstraints":{"type":"shared"}}'
  [ "$("$JQ_BIN" -r '.TerraformConfig.terraformVersion' <<<"$output")" = "TERRAFORM-1.5.7" ]
  [ "$("$JQ_BIN" -r '.RunnerConstraints.type' <<<"$output")" = "shared" ]
}

@test "_sg_wf_preset_fill: no preset, body unchanged" {
  SG_PRESET_JSON=""
  [ "$(_sg_wf_preset_fill '{"WfType":"TERRAFORM"}')" = '{"WfType":"TERRAFORM"}' ]
}

@test "sg_preset_desc" {
  [ "$(sg_preset_desc '{}')" = "platform default: managed Terraform 1.5.7 on shared runners" ]
  [ "$(sg_preset_desc "$PRESET")" = "runner-provided binary /opt/tf on private runner group rg" ]
  [ "$(sg_preset_desc '{"terraformDefaults":{"TerraformConfig":{"terraformVersion":"TERRAFORM-1.5.7"}}}')" = "Terraform 1.5.7 on shared runners" ]
  sg_preset_runner_provided "$PRESET"
  ! sg_preset_runner_provided '{}'
}

@test "preset_labels" {
  SG_PRESET_JSON="$PRESET" SG_DEFAULT_TF_VERSION=""
  preset_labels
  [ "$SG_PRESET_TFV" = "bin:/opt/tf" ]
  [ "$SG_PRESET_RUNNER_SHORT" = "private:rg" ]
  [ "$SG_TF_FALLBACK_SHORT" = "preset" ]
  SG_DEFAULT_TF_VERSION=TERRAFORM-1.5.7
  preset_labels
  [ "$SG_TF_FALLBACK_SHORT" = "1.5.7" ]
}

@test "sg_integration_type: by name or /integrations/<name>" {
  local ints='[{"name":"gh","type":"GITHUB_APP_CUSTOM"},{"name":"aws","type":"AWS_RBAC"}]'
  [ "$(sg_integration_type "$ints" /integrations/gh)" = "GITHUB_APP_CUSTOM" ]
  [ "$(sg_integration_type "$ints" aws)" = "AWS_RBAC" ]
  [ -z "$(sg_integration_type "$ints" nope)" ]
}

@test "_sg_wf_body drops the CLI-only keys" {
  [ "$(_sg_wf_body '{"ResourceName":"w","CLIConfiguration":{"a":1},"VCSTriggers":{}}')" = '{"ResourceName":"w"}' ]
}

@test "explain_api_error: JSON msg, one hint per run, unknown is silent" {
  run explain_api_error '{"msg":"Workflow ID not unique"}'
  printf '%s\n' "$output" | grep -q 'already exists'
  _SG_HINTS_SHOWN=" "
  explain_api_error 'Workflow ID not unique' 2>"$BATS_TEST_TMPDIR/1"
  explain_api_error 'Workflow ID not unique' 2>"$BATS_TEST_TMPDIR/2"
  [ -s "$BATS_TEST_TMPDIR/1" ]
  [ ! -s "$BATS_TEST_TMPDIR/2" ]
  run explain_api_error 'something else entirely'
  [ -z "$output" ]
}
