locals {
  workflowIds   = [for i, v in data.tfe_workspace_ids.data.ids : v]
  workflowNames = [for i, v in data.tfe_workspace_ids.data.ids : i]
  workflows = [for i, v in data.tfe_workspace_ids.data.ids : {
    CLIConfiguration = {
      "WorkflowGroup" : {
        "name" : data.tfe_workspace.data[i].project_id
      },
      "TfStateFilePath" : "${abspath(path.root)}/../../${var.exportPath}/states/${data.tfe_workspace.data[i].name}.tfstate"
    }
    ResourceName = data.tfe_workspace.data[i].name
    Description  = ""
    Tags         = data.tfe_workspace.data[i].tag_names
    EnvironmentVariables = [for i, v in data.tfe_variables.data[v].variables :
      { "config" : {
        "textValue" : v.value,
        "varName" : v.name
        },
    "kind" : "PLAIN_TEXT" } if v.category == "env" && v.sensitive == false]

    DeploymentPlatformConfig = var.SGDefaultDeploymentPlatformConfig
    RunnerConstraints        = { "type" : "shared" }
    VCSConfig = {
      "iacVCSConfig" : {
        "useMarketplaceTemplate" : false,
        "customSource" : {
          "sourceConfigDestKind" : var.SGDefaultSourceConfigDestKind
          "config" : {
            "includeSubModule" : false,
            "ref" : length(data.tfe_workspace.data[i].vcs_repo) > 0 ? data.tfe_workspace.data[i].vcs_repo[0].branch != "" ? data.tfe_workspace.data[i].vcs_repo[0].branch : "" : "",
            "isPrivate" : length(data.tfe_workspace.data[i].vcs_repo) > 0 ? length(data.tfe_workspace.data[i].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[i].vcs_repo[0].github_app_installation_id) > 0 ? true : false : false,
            "auth" : length(data.tfe_workspace.data[i].vcs_repo) > 0 ? length(data.tfe_workspace.data[i].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[i].vcs_repo[0].github_app_installation_id) > 0 ? var.SGDefaultVCSAuthIntegrationID : "" : "",
            "workingDir" : data.tfe_workspace.data[i].working_directory,
            "repo" : length(data.tfe_workspace.data[i].vcs_repo) > 0 ? format("%s/%s", var.SGDefaultIACVCSRepoPrefix, data.tfe_workspace.data[i].vcs_repo[0].identifier) : ""
          }
        }
      },
      "iacInputData" : {
        "schemaType" : "RAW_JSON",
        "data" : { for i, v in data.tfe_variables.data[v].variables : v.name => try(jsondecode(v.value), v.value) if v.category == "terraform" }
      }
    }

    MiniSteps = {
      "wfChaining" : {
        "ERRORED" : [],
        "COMPLETED" : []
      },
      "notifications" : {
        "email" : {
          "ERRORED" : [],
          "COMPLETED" : [],
          "APPROVAL_REQUIRED" : [],
          "CANCELLED" : []
        }
      }
    }

    Approvers = data.tfe_workspace.data[i].auto_apply == true ? [] : var.SGDefaultWfApprovers

    TerraformConfig = {
      "managedTerraformState" : true,
      "terraformVersion" : data.tfe_workspace.data[i].terraform_version,
      "approvalPreApply" : !data.tfe_workspace.data[i].auto_apply
    }

    WfType        = "TERRAFORM"
    UserSchedules = []
  }]
  data = jsonencode(
    local.workflows
  )
}
