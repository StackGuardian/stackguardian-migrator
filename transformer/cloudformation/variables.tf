variable "exportPath" {
  default     = "export"
  description = "name of the folder to export the payload, state files to. ./export is the default"
  type        = string
}
variable "s3_path" {
  description = "Base path for CloudFormation templates in S3"
  default     = "stackguardian/cloudformation_templates" # Adjust to your desired base path
}
variable "default_region" {
  description = "default aws region"
  default     = "eu-central-1" # Change to your desired AWS region, where Cloudformation stacks are maintained.
}
variable "s3Bucket" {
  default     = ""
  description = "name of the s3Bucket to export the cf templates"
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