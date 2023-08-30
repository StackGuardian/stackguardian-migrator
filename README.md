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

- Choose the transformer and locate the example of `exporter.tfvars`.
- Edit that file ( exporter.tfvars)  to match your context.
- Run the following commands:

```shell
cd transformer/<tfc>
terraform init
terraform apply -auto-approve -var-file=exporter.tfvars
```

A new `out` folder should have been created. The `data.json` files contains the mapping of your resources equivalent to StackGuardian, and the `state-files` folder contains the files for the Terraform state of your workspace, if the state export was enabled.
