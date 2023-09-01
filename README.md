# StackGuardian Migrator

Migrate workloads from other platforms to [StackGuardian Platform](https://app.stackguardian.io).

## Supported platforms for migration

- Terraform Cloud

## Overview

- Extract and transform the workloads from the target platform to StackGuardian Workflows.
- Review the bulk workflow creation payload.
- Run sg-cli with the bulk workflow creation payload.

## Prerequisites

- Terraform
  - terraform login to ensure that Terraform can interact with your Terraform Cloud/Enterprise account.
- [sg-cli](https://github.com/StackGuardian/sg-cli/tree/main/shell)

### Perform terraform login
`terraform login`

### Export the resource definitions and Terraform state

- Choose the transformer and locate the example of `terraform.tfvars`.
- Edit that file ( terraform.tfvars) to match your context.
- Run the following commands:

```shell
cd transformer/tfc
terraform init
terraform apply -auto-approve -var-file=terraform.tfvars
```

A new `out` folder should have been created. The `sg-payload.json` file contains the definition for each workflow that will be created for each Terraform Workspace, and the `state-files` folder contains the files for the Terraform state for each of your workspaces, if the state export was enabled.

After completing the export , edit the `sg-payload.json` file to provide tune each workflow configuration with the following:
## Use the example.json file to refrence and edit the schema of the `sg-payload.json`
- `DeploymentPlatformConfig` - (Used to authenticate against a cloud provider using a StackGuardian Integration), Create the relevant integration in StackGuardian platform and update `DeploymentPlatformConfig.kind` from the following "AZURE_STATIC", "AWS_STATIC","GCP_STATIC", "AWS_RBAC". Update `DeploymentPlatformConfig.config.integrationId` with "/integrations/INTEGRATION_NAME" and `DeploymentPlatformConfig.config.profileName` with the name of the integration used upon creation.
```DeploymentPlatformConfig: {
      "kind": "AWS_RBAC",
      "config": {
        "integrationId": "/integrations/aws-rbac",
        "profileName": "default"
      }
    }```
- `VCSConfig` - Provide full path to the `repo` like as well the relevant `sourceConfigDestKind` from the following "GITHUB_COM", "BITBUCKET_ORG", "GITLAB_COM", "AZURE_DEVOPS".
    - `config.auth` 
    - `config.isPrivate`
     
- `ResourceName` // workspace name 
- `wfgrpName` // this corresponds to the labelling of workflow group name in the StackGuardian platform
- `Description` // description for the workflows created in the StackGuardian platform
- `Tags` // list of tags for the workflows created in the StackGuardian platform 
- `EnvironmentVariables` // environment variables for the workflows created in the StackGuardian platform
- `RunnerConstraints` // Runner description for the workflows in the StackGuardian platform
- `DeploymentPlatformConfig`
- `Approvers` // Aprrovers for the workflow to run it successfully
- `TerraformConfig` // Terraform configuration for the workflows created in the StackGuardian platform
- `WfType` // this corresponds to the workflow type of  the workflow created in the StackGuardian platform
- `UserSchedules` // Scheduled workflow run configuration for the workflow in the StackGuardian platform
- `MiniSteps` // Ministeps for the workflow to direct the process if the workflow returns an error/success/approval required and workflow chaining .

### Bulk import workflows to StackGuardian Platform

- Fetch sg-cli (https://github.com/StackGuardian/sg-cli.git) and set up sg-cli locally (documentation present in repo)
- Run the following commands and pass the `sg-payload.json` as payload (represented below)

```shell
cd ../../out

Get your SG API Key here: https://app.stackguardian.io/orchestrator/orgs/<org-id>/settings?tab=api_key

export SG_API_TOKEN=<YOUR_SG_API_TOKEN>
wget -q "$(wget -qO- "https://api.github.com/repos/stackguardian/sg-cli/releases/latest" | jq -r '.tarball_url')" -O sg-cli.tar.gz && tar -xf sg-cli.tar.gz && rm -f sg-cli.tar.gz && /bin/cp -rf StackGuardian-sg-cli*/shell/sg-cli . && rm -rfd StackGuardian-sg-cli*

./sg-cli workflow create --bulk --org "<ORG NAME>" -- sg-payload.json
```

if you want to update a workflow with different details, please re-run the sg-cli command with the modified sg-payload.json and your workflow will be updated with the new details, as long as the ResourceName (Workflow name) remains the same.
```shell
./sg-cli workflow create --bulk --org "<ORG NAME>" -- sg-payload.json
```