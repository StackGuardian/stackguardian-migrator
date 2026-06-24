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

variable "SGDefaultSourceConfigDestKind" {
  default     = "GIT_OTHER"
  description = "Choose from: GITHUB_COM, BITBUCKET_ORG, GITLAB_COM, AZURE_DEVOPS, GIT_OTHER"
  type        = string
}

variable "SGDefaultTerraformVersion" {
  default     = "TERRAFORM-1.5.7"
  description = "SG Terraform version used when a workspace's terraform_version is not a pinned semver (e.g. 'latest' or a version constraint), or the workspace runs an engine SG cannot map. Use the SG-formatted value, e.g. TERRAFORM-1.5.7."
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