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
- `DeploymentPlatformConfig` - (Used to authenticate against a cloud provider using a StackGuardian Integration)
- `VCSConfig` - Provide full path to the repo like as well the relevant sourceConfigDestKind from the following "GITHUB_COM", "BITBUCKET_ORG", "GITLAB_COM", "AZURE_DEVOPS".

### Bulk import workflows to StackGuardian Platform

- Fetch sg-cli (https://github.com/StackGuardian/sg-cli.git) and set up sg-cli locally (documentation present in repo)
- Run the following commands and pass the `sg-payload.json` as payload (represented below)

```shell
cd ../../out

Get your SG API Key here: https://app.stackguardian.io/orchestrator/orgs/<org-id>/settings?tab=api_key

export SG_API_TOKEN=<YOUR_SG_API_TOKEN>
wget -q "$(wget -qO- "https://api.github.com/repos/stackguardian/sg-cli/releases/latest" | jq -r '.tarball_url')" -O sg-cli.tar.gz && tar -xf sg-cli.tar.gz && rm -f sg-cli.tar.gz && /bin/cp -rf StackGuardian-sg-cli*/shell/sg-cli . && rm -rfd StackGuardian-sg-cli* && ./sg-cli workflow create --bulk --org "stackguardian" --workflow-group "test-tfc-exporter" -- sg-payload.json
```