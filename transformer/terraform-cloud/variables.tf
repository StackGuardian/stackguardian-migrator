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

variable "workspaceOverrides" {
  default     = {}
  description = "Per-workspace overrides keyed by TFC/TFE workspace name. Any field set here takes precedence over the matching SGDefault* value for that workspace only."
  type = map(object({
    DeploymentPlatformConfig  = optional(list(any))
    RunnerConstraints         = optional(any)
    Approvers                 = optional(list(string))
    vcsAuthIntegrationID      = optional(string)
    vcsRepoPrefix             = optional(string)
    sourceConfigDestKind      = optional(string)
    terraformVersion          = optional(string)
    extraEnvironmentVariables = optional(list(any), [])
    VCSTriggers               = optional(any)
  }))
}
