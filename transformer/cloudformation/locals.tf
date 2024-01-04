locals {
  stack_names = jsondecode(file("stack_names.json"))
}
locals {
  workflows = [
    for stack_name, stack_data in data.aws_cloudformation_stack.resource : {
      CLIConfiguration = {
        WorkflowGroup = {
          name = stack_name
        }
      }
      ResourceName          = stack_name
      Description           = stack_data.description
      Tags                  = stack_data.tags
      EnvironmentVariables = [
        {
          "config": {
            "textValue": "eu-west-1",
            "varName": "AWS_REGION"
          },
          "kind": "PLAIN_TEXT"
        }
      ]
      VCSConfig               = {}
      TerraformConfig         = {}
      DeploymentPlatformConfig = var.SGDefaultDeploymentPlatformConfig
      WfStepsConfig = [
        {
          name         = "CreateChangeset"
          mountPoints  = []
          wfStepTemplateId = "/demo-org/cloudformation:51"
          wfStepInputData = {
            schemaType = "FORM_JSONSCHEMA"
            data = {
              cfCapabilities   = stack_data.capabilities
              cfStackName       = stack_name
              cfS3TemplateURL  = "${var.s3_path}/${stack_name}.yaml"
              cfAction          = "create-changeset"
            }
          }
          approval = false
        },
        {
          name         = "ApplyChangeset"
          mountPoints  = []
          wfStepTemplateId = "/demo-org/cloudformation:51"
          wfStepInputData = {
            schemaType = "FORM_JSONSCHEMA"
            data = {
              cfStackName        = stack_name
              RetainExceptOnCreate = false
              cfAction           = "apply-changeset"
              DisableRollback    = stack_data.disable_rollback
            }
          }
          approval = true
        }
      ]
      RunnerConstraints = { type = "shared" }
      Approvers         = var.SGDefaultWfApprovers
      WfType            = "CUSTOM"
      UserSchedules     = []
      MiniSteps = {
        webhooks = {
          COMPLETED = [],
          ERRORED   = []
        }
        notifications = {
          email = {
            APPROVAL_REQUIRED = [],
            CANCELLED         = [],
            COMPLETED         = [],
            ERRORED           = []
          }
        }
        wfChaining = {
          COMPLETED = [],
          ERRORED   = []
        }
      }
      GitHubComSync = {
        pull_request_opened = {
          createWfRun = {
            enabled = false
          }
        }
      }
    }
  ]

  data = jsonencode(local.workflows)
}