#!/bin/bash
# Friendly explanations for StackGuardian API errors (sourced; needs tools.sh).
#
# explain_api_error <response-body-or-message> prints, at most once per
# distinct hint per run, what the error usually means and which
# terraform.tfvars field to change. Unknown messages print nothing (the raw
# response is already shown by the caller). Patterns are case-insensitive
# extended regexes matched against the message text.

_SG_HINTS_SHOWN=" "

# Table: "<regex> => <hint>" — keep hints to one line each.
SG_API_HINTS=(
  'above the highest managed version => Terraform version above SG'"'"'s managed ceiling (1.5.7, last MPL/FOSS release). The importer retries with SGDefaultTerraformVersion automatically; to keep the newer version use a private runner binary path or a custom runtime template (workspaceOverrides[<ws>].terraformVersion).'
  'integration.*(not found|does not exist|invalid)|(not found|does not exist|invalid).*integration => Connector/integration id not found in this org. Check SGDefaultVCSAuthIntegrationID and SGDefaultDeploymentPlatformConfig[].config.integrationId (or the workspaceOverrides equivalents); '"'"'preflight'"'"' lists the ids that exist.'
  'runner ?group.*(not found|does not exist|invalid)|(not found|does not exist|invalid).*runner => Runner group not found. Check SGDefaultRunnerConstraints.names / workspaceOverrides[<ws>].RunnerConstraints against the runner groups in the SG org.'
  '(repo|repository).*(not found|access|permission|denied|unable|could not|cannot)|(clone|checkout).*(fail|denied|unable) => The VCS connector cannot reach the repository. Check SGDefaultIACVCSRepoPrefix + the workspace repo path, and that the connector (SGDefaultVCSAuthIntegrationID) has access to that repository.'
  'approver => Approvers must be e-mail addresses of existing SG users. Check SGDefaultWfApprovers / workspaceOverrides[<ws>].Approvers.'
  'already exists => A resource with that name already exists. Re-running the import updates workflows in place; for workflow groups this is harmless.'
  'ResourceName => Invalid workflow name: 1-100 chars, letters/digits/-/_ only. The transformer sanitizes names (see renamedWorkspaces in migration-summary.md); adjust local.resourceNames if a rule is missing.'
  'sourceConfigDestKind => Invalid VCS kind. SGDefaultSourceConfigDestKind must be one of GITHUB_COM, GITLAB_COM, BITBUCKET_ORG, AZURE_DEVOPS, GIT_OTHER.'
  '(unauthori[sz]ed|forbidden|invalid token|authentication) => SG_API_TOKEN was rejected or lacks permission for this org. Regenerate it under Org settings -> API keys and re-export SG_API_TOKEN.'
)

explain_api_error() {
  local msg="$1" entry re hint
  # Prefer the API's "msg" field when the body is JSON.
  if printf '%s' "$msg" | grep -q '^{'; then
    msg="$(printf '%s' "$msg" | "$(sg_resolve jq sg_ensure_jq)" -r '.msg // .message // .error // .' 2>/dev/null || printf '%s' "$msg")"
  fi
  for entry in "${SG_API_HINTS[@]}"; do
    re="${entry%% => *}"
    hint="${entry#* => }"
    if printf '%s' "$msg" | grep -Eiq -- "$re"; then
      case "$_SG_HINTS_SHOWN" in *" $re "*) return 0 ;; esac
      _SG_HINTS_SHOWN="$_SG_HINTS_SHOWN$re "
      printf '  %s→ %s%s\n' "$C_YELLOW" "$hint" "$C_RESET" >&2
      return 0
    fi
  done
  return 0
}
