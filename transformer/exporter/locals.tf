locals {
  workflowIds   = [for i, v in data.tfe_workspace_ids.ids.ids : v]
  workflowNames = [for i, v in data.tfe_workspace_ids.ids.ids : i]
  workflows = [for i, v in data.tfe_workspace_ids.ids.ids : {
    CLIConfiguration = {
      "WorkflowGroup" : {
        "name" : data.tfe_workspace.ids[i].project_id
      },
      "TfStateFilePath" : "${abspath(path.root)}/../../export/states/${data.tfe_workspace.ids[i].name}.tfstate"
    }
    ResourceName = data.tfe_workspace.ids[i].name
    Description  = ""
    Tags         = data.tfe_workspace.ids[i].tag_names
    EnvironmentVariables = [for i, v in data.tfe_variables.ids[v].variables :
      { "config" : {
        "textValue" : v.value,
        "varName" : v.name
        },
    "kind" : "PLAIN_TEXT" } if v.category == "env" && v.sensitive == false]

    DeploymentPlatformConfig = []
    RunnerConstraints        = { "type" : "shared" }
    VCSConfig = {
      "iacVCSConfig" : {
        "useMarketplaceTemplate" : false,
        "customSource" : {
          "sourceConfigDestKind" : "Choose from: GITHUB_COM, BITBUCKET_ORG, GITLAB_COM, AZURE_DEVOPS",
          "config" : {
            "includeSubModule" : false,
            "ref" : length(data.tfe_workspace.ids[i].vcs_repo) > 0 ? data.tfe_workspace.ids[i].vcs_repo[0].branch != "" ? data.tfe_workspace.ids[i].vcs_repo[0].branch : "" : "",
            "isPrivate" : length(data.tfe_workspace.ids[i].vcs_repo) > 0 ? length(data.tfe_workspace.ids[i].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.ids[i].vcs_repo[0].github_app_installation_id) > 0 ? true : false : false,
            "auth" : length(data.tfe_workspace.ids[i].vcs_repo) > 0 ? length(data.tfe_workspace.ids[i].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.ids[i].vcs_repo[0].github_app_installation_id) > 0 ? "Provide an integration id like /integrations/aws-dev-account or /secrets/my-git-token" : "" : "",
            "workingDir" : data.tfe_workspace.ids[i].working_directory,
            "repo" : length(data.tfe_workspace.ids[i].vcs_repo) > 0 ? data.tfe_workspace.ids[i].vcs_repo[0].identifier : ""
          }
        }
      },
      "iacInputData" : {
        "schemaType" : "RAW_JSON",
        "data" : { for i, v in data.tfe_variables.ids[v].variables : v.name => v.value if v.category == "terraform" }
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

    Approvers = data.tfe_workspace.ids[i].auto_apply == true ? [] : ["Add emails of the users who should approve the terraform plan, since approvalPreApply is set to true"]

    TerraformConfig = {
      "managedTerraformState" : var.stateExport,
      "terraformVersion" : data.tfe_workspace.ids[i].terraform_version,
      "approvalPreApply" : !data.tfe_workspace.ids[i].auto_apply
    }

    WfType        = "TERRAFORM"
    UserSchedules = []
  }]
  data = jsonencode(
    local.workflows
  )
}