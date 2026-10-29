#!/usr/bin/env bats
# Naming and formatting helpers whose output ends up in SG resource names,
# file names and the terminal.

load helpers

setup() { load_libs; }

@test "secret_name_for: anything but [A-Za-z0-9_-] becomes -" {
  [ "$(secret_name_for wf-data-tech-adp-dev DB_PASSWORD)" = "tfc-wf-data-tech-adp-dev-DB_PASSWORD" ]
  [ "$(secret_name_for 'wf.data tech/x' 'MY_VAR-1')" = "tfc-wf-data-tech-x-MY_VAR-1" ]
  [ "$(secret_name_for 'a:b' 'c@d')" = "tfc-a-b-c-d" ]
}

@test "secret_name_for: cut at 100 characters" {
  local long
  long="$(printf 'w%.0s' $(seq 1 120))"
  run secret_name_for "$long" VAR
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 100 ]
}

@test "slug_of: the transformer's project slug rule" {
  [ "$(slug_of 'Data Tech')" = "data-tech" ]
  [ "$(slug_of 'data-tech')" = "data-tech" ]
  [ "$(slug_of 'A__B.c')" = "a-b-c" ]
  [ "$(slug_of 'Team (EU) / prod')" = "team-eu-prod" ]
}

@test "tf_version_above_ceiling: 1.5.7 is the managed ceiling" {
  tf_version_above_ceiling TERRAFORM-1.5.8
  tf_version_above_ceiling TERRAFORM-1.10.0
  tf_version_above_ceiling TERRAFORM-2.0.0
  ! tf_version_above_ceiling TERRAFORM-1.5.7
  ! tf_version_above_ceiling TERRAFORM-1.4.99
  ! tf_version_above_ceiling 1.9.0
  ! tf_version_above_ceiling TERRAFORM-latest
}

@test "sg_fmt_secs" {
  [ "$(sg_fmt_secs 0)" = "0s" ]
  [ "$(sg_fmt_secs 59)" = "59s" ]
  [ "$(sg_fmt_secs 72)" = "1m 12s" ]
  [ "$(sg_fmt_secs 3725)" = "1h 02m" ]
}

@test "sg_maxlen" {
  [ "$(sg_maxlen 3 a bb)" = "3" ]
  [ "$(sg_maxlen 3 a 'bb cc')" = "5" ]
}

@test "sg_rel: paths under the repo are shown relative" {
  [ "$(sg_rel "$SG_REPO_ROOT/export/a.json")" = "export/a.json" ]
  [ "$(sg_rel "$SG_REPO_ROOT")" = "." ]
  [ "$(sg_rel /elsewhere/x)" = "/elsewhere/x" ]
}

@test "sg_vcs_kind_of: connector type to sourceConfigDestKind" {
  [ "$(sg_vcs_kind_of GITHUB_APP_CUSTOM)" = "GITHUB_COM" ]
  [ "$(sg_vcs_kind_of GITLAB_OAUTH_SSH)" = "GITLAB_COM" ]
  [ "$(sg_vcs_kind_of AZURE_DEVOPS_SP)" = "AZURE_DEVOPS" ]
  [ -z "$(sg_vcs_kind_of AWS_RBAC)" ]
}

@test "wf_ui_url / wfgrp_ui_url" {
  SG_UI_URL=https://app.stackguardian.io ORG=acme
  [ "$(wf_ui_url g w)" = "https://app.stackguardian.io/orchestrator/orgs/acme/wfgrps/g/wfs/w" ]
  [ "$(wfgrp_ui_url g)" = "https://app.stackguardian.io/orchestrator/orgs/acme/wfgrps/g" ]
}
