variable "tfOrg" {
  description = "TFC/TFE organization name"
  type        = string
}

variable "workspacenames" {
  default     = ["*"]
  description = "List of TFC/TFE workspace names to export. Wildcards are supported (e.g., [\"*\"], [\"*-example\"], [\"example-*\"])."
  type        = list(string)
}

variable "exportStateFiles" {
  default     = true
  description = "Also Export Terraform state to files?"
  type        = bool
}

variable "tfHostname" {
  default     = "app.terraform.io"
  description = "TFC/TFE hostname used for the state-export API and the `terraform login` credential lookup."
  type        = string
}

variable "tfWorkspaceTags" {
  default     = null
  description = "List of TFC/TFE workspace tags to include when exporting. Excluded tags take precedence over included ones. Wildcards are not supported."
  type        = list(string)
}

variable "tfWorkspaceIgnoreTags" {
  default     = null
  description = "List of TFC/TFE workspace tags to exclude when exporting. Excluded tags take precedence over included ones. Wildcards are not supported."
  type        = list(string)
}

variable "tfProjects" {
  default     = []
  description = "TFC/TFE projects to export, by name (as shown in TFC) or by slug (the payload file segment, e.g. my-first-project); [] = every project. Applied after the workspace filters. Entries matching no project are listed in migration-summary.md (unknownProjects). The orchestrator's --project sets this for one run."
  type        = list(string)
}

variable "tfWorkspaceIgnoreNames" {
  default     = []
  description = "Workspace names (globs, * and ? supported) to leave out of the export, applied after workspacenames and the tag filters. Excluded workspaces are listed in migration-summary.md. The orchestrator's --exclude-workspace adds to this list for one run."
  type        = list(string)
}

variable "exportPath" {
  default     = "export"
  description = "name of the folder to export the payload, state files to. ./export is the default"
  type        = string
}

variable "ignoreVarPatterns" {
  default     = ["^TFC_", "^TFE_"]
  description = "Regexes (matched against the variable name) for TFC/TFE-specific variables that have no meaning outside Terraform Cloud and are not migrated, e.g. TFC_WORKSPACE_NAME or the TFC_AWS_* dynamic-credential settings. Applies to terraform and env variables, including variable-set variables. Set to [] to keep everything; stripped variables are listed in migration-summary.md."
  type        = list(string)
}

variable "stripCloudAuthVars" {
  default     = true
  description = "Strip the cloud credential env variables (AWS_ACCESS_KEY_ID, ARM_CLIENT_SECRET, GOOGLE_CREDENTIALS, ...) that the workflow's StackGuardian cloud connector replaces. Which family is stripped follows each workflow's effective DeploymentPlatformConfig[0].kind (AWS_* -> AWS, AZURE_* -> AZURE, GCP_* -> GCP). Env variables only; terraform input variables are never touched. Stripped variables are listed in migration-summary.md (strippedCloudAuthVars) and a sensitive one is stripped as well, so no placeholder secret is created for it."
  type        = bool
}

variable "cloudAuthVarPatterns" {
  description = "Regexes (per cloud family AWS/AZURE/GCP, matched against the env variable name) stripped by stripCloudAuthVars. Setting this replaces the whole map, so keep the families you do not change. Also read by scripts/enrich_variable_sets.sh for variable-set variables."
  type        = map(list(string))
  default = {
    AWS = [
      "^AWS_ACCESS_KEY_ID$", "^AWS_SECRET_ACCESS_KEY$", "^AWS_SESSION_TOKEN$",
      "^AWS_PROFILE$", "^AWS_ROLE_ARN$", "^AWS_WEB_IDENTITY_TOKEN_FILE$",
      "^AWS_SHARED_CREDENTIALS_FILE$", "^AWS_CONFIG_FILE$",
    ]
    AZURE = [
      "^ARM_CLIENT_ID$", "^ARM_CLIENT_SECRET$", "^ARM_TENANT_ID$", "^ARM_SUBSCRIPTION_ID$",
      "^ARM_USE_OIDC$", "^ARM_OIDC_", "^ARM_CLIENT_CERTIFICATE", "^ARM_USE_MSI$", "^ARM_MSI_ENDPOINT$",
    ]
    GCP = [
      "^GOOGLE_CREDENTIALS$", "^GOOGLE_APPLICATION_CREDENTIALS$", "^GOOGLE_OAUTH_ACCESS_TOKEN$",
      "^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT$", "^CLOUDSDK_AUTH_",
    ]
  }
  validation {
    condition     = alltrue([for k in keys(var.cloudAuthVarPatterns) : contains(["AWS", "AZURE", "GCP"], k)])
    error_message = "cloudAuthVarPatterns keys must be AWS, AZURE or GCP (the prefix of the DeploymentPlatformConfig kind)."
  }
}

variable "SGDefaultWfApprovers" {
  default     = []
  description = "Add emails of the users who should approve the terraform plan, since approvalPreApply is set to true"
  type        = list(string)
}

variable "SGDefaultIACVCSRepoPrefix" {
  default     = "https://VCS_PROVIDER_DOMAIN"
  description = "Prefix for your repo URL"
  type        = string
}

variable "SGDefaultVCSAuthIntegrationID" {
  default     = "INTEGRATION_ID"
  description = "Provide an integration id like /integrations/aws-dev-account or /secrets/my-git-token"
  type        = string
}

variable "SGDefaultDeploymentPlatformConfig" {
  default = [
    {
      "kind" : "AWS_RBAC",
      "config" : {
        "integrationId" : "INTEGRATION_ID",
        "profileName" : "default"
      }
    }
  ]
  description = "Integration to use to authenticate against your cloud provider"
  type        = list(any)
}

variable "SGDefaultRunnerConstraints" {
  default     = { type = "shared" }
  nullable    = true
  description = "Runner constraints applied to every workflow. Use { type = \"shared\" } for SG-hosted runners, { type = \"private\", names = [\"<runner-group>\"] } to put every workflow behind a private runner group, or null to send no runner constraints at all so StackGuardian applies the org's execution preset (Settings -> Runner groups -> Execution presets; platform default: shared runners). Override per workspace via workspaceOverrides[name].RunnerConstraints."
  type = object({
    type  = string
    names = optional(list(string))
  })
  validation {
    condition     = var.SGDefaultRunnerConstraints == null || contains(["shared", "private"], try(var.SGDefaultRunnerConstraints.type, ""))
    error_message = "SGDefaultRunnerConstraints.type must be \"shared\" or \"private\" (or the whole variable null to defer to the execution preset)."
  }
  validation {
    condition     = var.SGDefaultRunnerConstraints == null || try(var.SGDefaultRunnerConstraints.type, "") != "private" || length(coalesce(try(var.SGDefaultRunnerConstraints.names, null), [])) > 0
    error_message = "SGDefaultRunnerConstraints.names must list at least one runner group when type is \"private\"."
  }
}

variable "SGDefaultSourceConfigDestKind" {
  default     = "GIT_OTHER"
  description = "Choose from: GITHUB_COM, BITBUCKET_ORG, GITLAB_COM, AZURE_DEVOPS, GIT_OTHER"
  type        = string
}

variable "SGTerraformVersionSource" {
  default     = "carry"
  description = "Where the migrated workflows get their Terraform version from. \"carry\": keep each workspace's pinned TFC version; workspaces without a pinned semver (e.g. 'latest') use SGDefaultTerraformVersion, and so does the importer when the SG API rejects a pinned version as above its managed ceiling (1.5.7). \"preset\": send no version at all, so StackGuardian fills it from the org's execution preset (Settings -> Runner groups -> Execution presets), or its platform default when none is configured; SGDefaultTerraformVersion is then ignored. A workspaceOverrides[name].terraformVersion is always sent as-is."
  type        = string
  validation {
    condition     = contains(["carry", "preset"], var.SGTerraformVersionSource)
    error_message = "SGTerraformVersionSource must be \"carry\" or \"preset\"."
  }
}

variable "SGDefaultTerraformVersion" {
  default     = "TERRAFORM-1.5.7"
  nullable    = true
  description = "Fallback SG Terraform version when SGTerraformVersionSource is \"carry\": used for workspaces whose terraform_version is not a pinned semver (e.g. 'latest' or a version constraint), and by the importer when the SG API rejects a pinned version as above the managed ceiling (1.5.7, the last MPL/FOSS release; newer versions are BSL and not bundled). Use the SG-formatted value, e.g. TERRAFORM-1.5.7, or null to leave those workflows to the org's execution preset instead."
  type        = string
}

variable "SGDefaultEnableVCSTriggers" {
  default     = true
  description = "Pre-configure VCS triggers on each VCS-backed workflow, remapped from the workspace's own TFC settings (tracked branch, push, PR speculative plans, file triggers). Set false to import workflows without any triggers. Per-workspace overrides via workspaceOverrides[name].VCSTriggers."
  type        = bool
}

variable "forceStateRefresh" {
  default     = false
  description = "Re-pull Terraform state for every workspace on each apply. When false (default), state export is idempotent and only runs for workspaces it has not exported before."
  type        = bool
}

# The override maps are typed "any" on purpose: with map(object({ ... =
# optional(any) })) Terraform requires every entry to resolve each attribute to
# one common type, so one workspace setting RunnerConstraints while another
# omits it fails with "attribute types must all match for conversion to map".
# The validations below check the field names instead; the values are shaped
# like the SGDefault* variables they override.
locals {
  overrideFieldNames = [
    "DeploymentPlatformConfig",  # list, like SGDefaultDeploymentPlatformConfig
    "RunnerConstraints",         # object { type, names }, like SGDefaultRunnerConstraints
    "Approvers",                 # list(string)
    "vcsAuthIntegrationID",      # string
    "vcsRepoPrefix",             # string
    "sourceConfigDestKind",      # string
    "terraformVersion",          # string, sent as-is (e.g. TERRAFORM-1.7.5)
    "extraEnvironmentVariables", # list of SG EnvironmentVariables entries
    "VCSTriggers",               # object, replaces the derived triggers entirely
  ]
}

variable "workspaceOverrides" {
  default     = {}
  description = "Per-workspace overrides keyed by TFC/TFE workspace name. Any field set here wins over the matching projectOverrides and SGDefault* values for that workspace only. Fields: DeploymentPlatformConfig, RunnerConstraints, Approvers, vcsAuthIntegrationID, vcsRepoPrefix, sourceConfigDestKind, terraformVersion, extraEnvironmentVariables, VCSTriggers (see terraform.tfvars.example)."
  type        = any
  validation {
    condition     = can([for name, o in var.workspaceOverrides : keys(o)]) && alltrue([for name, o in var.workspaceOverrides : length(setsubtract(keys(o), ["DeploymentPlatformConfig", "RunnerConstraints", "Approvers", "vcsAuthIntegrationID", "vcsRepoPrefix", "sourceConfigDestKind", "terraformVersion", "extraEnvironmentVariables", "VCSTriggers"])) == 0])
    error_message = "workspaceOverrides must map workspace names to objects with only these fields: DeploymentPlatformConfig, RunnerConstraints, Approvers, vcsAuthIntegrationID, vcsRepoPrefix, sourceConfigDestKind, terraformVersion, extraEnvironmentVariables, VCSTriggers."
  }
}

variable "projectOverrides" {
  default     = {}
  description = "Per-project overrides keyed by the TFC/TFE project name (as shown in TFC, case-sensitive). Applied to every workspace of that project: workspaceOverrides win over these, these win over the SGDefault* values. Same fields as workspaceOverrides plus workflowGroup, which replaces the default StackGuardian workflow group tfc-<project> for the whole project (the payload file keeps its sg-payload.<project>.json name). Keys that match no project are listed in migration-summary.md (unknownProjectOverrides)."
  type        = any
  validation {
    condition     = can([for name, o in var.projectOverrides : keys(o)]) && alltrue([for name, o in var.projectOverrides : length(setsubtract(keys(o), ["DeploymentPlatformConfig", "RunnerConstraints", "Approvers", "vcsAuthIntegrationID", "vcsRepoPrefix", "sourceConfigDestKind", "terraformVersion", "extraEnvironmentVariables", "VCSTriggers", "workflowGroup"])) == 0])
    error_message = "projectOverrides must map TFC project names to objects with only these fields: DeploymentPlatformConfig, RunnerConstraints, Approvers, vcsAuthIntegrationID, vcsRepoPrefix, sourceConfigDestKind, terraformVersion, extraEnvironmentVariables, VCSTriggers, workflowGroup."
  }
}
