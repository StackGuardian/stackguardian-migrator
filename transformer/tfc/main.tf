# TODO: update all versions

terraform {
  required_version = "~> 1.2"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.1"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.45.0"
    }
  }
}

locals {
  workflow_ids   = [for i, v in data.tfe_workspace_ids.all.ids : v]
  workflow_names = [for i, v in data.tfe_workspace_ids.all.ids : i]
  workflows = [for i, v in data.tfe_workspace_ids.all.ids : {
    CLIConfiguration = {
      "WorkflowGroup":{
        "name": "",
        "description": "",
        "tags": []
      },
      "TfStateFilePath" : "${abspath(path.root)}/../../out/state-files/${data.tfe_workspace.all[i].name}.tfstate"
    }
    ResourceName = data.tfe_workspace.all[i].name
    wfgrpName    = ""
    Description  = ""
    Tags         = data.tfe_workspace.all[i].tag_names
    EnvironmentVariables = [for i, v in data.tfe_variables.all[v].variables :
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
          "sourceConfigDestKind" : "PLEASE PROVIDE A VALUE",
          "config" : {
            "includeSubModule" : false,
            "ref" : length(data.tfe_workspace.all[i].vcs_repo) > 0 ? data.tfe_workspace.all[i].vcs_repo[0].branch != "" ? data.tfe_workspace.all[i].vcs_repo[0].branch : "" : "",
            "isPrivate" : true,
            "auth" : "PLEASE PROVIDE A VALUE",
            "workingDir" : "",
            "repo" : length(data.tfe_workspace.all[i].vcs_repo) > 0 ? split("/", data.tfe_workspace.all[i].vcs_repo[0].identifier)[1] : ""
          }
        }
      },
      "iacInputData" : {
        "schemaType" : "RAW_JSON",
        "data" : { for i, v in data.tfe_variables.all[v].variables : v.name => v.value if v.category == "terraform" }
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

    Approvers = []

    TerraformConfig = {
      "managedTerraformState" : var.export_state,
      "terraformVersion" : data.tfe_workspace.all[i].terraform_version
    }

    WfType        = "TERRAFORM"
    UserSchedules = []
  }]
  data = jsonencode(
    local.workflows
  )
}

data "tfe_workspace_ids" "all" {
  names        = var.tfc_workspace_names
  organization = var.tfc_organization
  tag_names    = var.tfc_workspace_include_tags
  exclude_tags = var.tfc_workspace_exclude_tags
}

data "tfe_workspace" "all" {
  for_each = toset(local.workflow_names)

  name         = each.key
  organization = var.tfc_organization
}

data "tfe_variables" "all" {
  for_each = toset(local.workflow_ids)

  workspace_id = each.key
}

resource "local_file" "data" {
  content  = local.data
  filename = "${path.module}/../../out/sg-payload.json"
}

resource "local_file" "generate_temp_tf_files" {
  for_each = var.export_state ? toset(local.workflow_names) : []

  content  = templatefile("${path.module}/workspace.tmpl", { tfc_organization = var.tfc_organization, workspace = each.key })
  filename = "${path.module}/../../out/tf-files/${each.key}/main.tf"
}

resource "null_resource" "export_state_files" {
  depends_on = [local_file.generate_temp_tf_files]
  for_each   = var.export_state ? toset(local.workflow_names) : []

  provisioner "local-exec" {
    command     = "mkdir -p ../../state-files && rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup && terraform init -input=false && terraform state pull > ../../state-files/'${each.key}.tfstate'"
    working_dir = "${path.module}/../../out/tf-files/${each.key}"
  }
}

resource "null_resource" "delete_temp_tf_files" {
  count      = var.export_state ? 1 : 0
  depends_on = [null_resource.export_state_files]

  provisioner "local-exec" {
    command     = "rm -rf tf-files"
    working_dir = "${path.module}/../../out/"
  }
}