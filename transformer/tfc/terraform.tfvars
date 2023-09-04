# Terraform Cloud/Enterprise organization name
tfc_organization = "test-123433"

# List of TFC/TFE workspace names to export. Wildcards are supported (e.g., ["*"], ["*-example"], ["example-*"]).
tfc_workspace_names = ["*"]

# List of TFC/TFE workspace tags to include when exporting. Excluded tags take precedence over included ones. Wildcards are not supported.
# tfc_workspace_include_tags = ["example"]

# List of TFC/TFE workspace tags to exclude when exporting. Excluded tags take precedence over included ones. Wildcards are not supported.
# tfc_workspace_exclude_tags = ["ignore"]

# Export Terraform state to files?
export_state = true
