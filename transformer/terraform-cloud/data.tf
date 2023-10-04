data "tfe_workspace_ids" "data" {
  names        = var.workspacenames
  organization = var.tfOrg
  tag_names    = var.tfWorkspaceTags
  exclude_tags = var.tfWorkspaceIgnoreTags
}

data "tfe_workspace" "data" {
  for_each = toset(local.workflowNames)

  name         = each.key
  organization = var.tfOrg
}

data "tfe_variables" "data" {
  for_each = toset(local.workflowIds)

  workspace_id = each.key
}