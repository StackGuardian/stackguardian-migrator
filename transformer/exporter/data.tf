data "tfe_workspace_ids" "ids" {
  names        = var.workspaceIds
  organization = var.tfOrg
  tag_names    = var.tfWorkspaceTags
  exclude_tags = var.tfWorkspaceIgnoreTags
}

data "tfe_workspace" "ids" {
  for_each = toset(local.workflowNames)

  name         = each.key
  organization = var.tfOrg
}

data "tfe_variables" "ids" {
  for_each = toset(local.workflowIds)

  workspace_id = each.key
}