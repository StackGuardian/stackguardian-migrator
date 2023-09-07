variable "stateExport" {
  default     = true
  description = "Export Terraform state to files?"
  type        = bool
}

variable "tfOrg" {
  description = "TFC/TFE organization name"
  type        = string
}

variable "workspaceIds" {
  default     = ["*"]
  description = "List of TFC/TFE workspace names to export. Wildcards are supported (e.g., [\"*\"], [\"*-example\"], [\"example-*\"])."
  type        = list(string)
}

variable "tfWorkspaceIgnoreTags" {
  default     = null
  description = "List of TFC/TFE workspace tags to exclude when exporting. Excluded tags take precedence over included ones. Wildcards are not supported."
  type        = list(string)
}

variable "tfWorkspaceTags" {
  default     = null
  description = "List of TFC/TFE workspace tags to include when exporting. Excluded tags take precedence over included ones. Wildcards are not supported."
  type        = list(string)
}

variable "exportPath" {
  default     = "export"
  description = "name of the folder to export the payload, state files to . /export is the Default "
  type        = string
}