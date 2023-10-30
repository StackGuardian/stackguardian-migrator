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