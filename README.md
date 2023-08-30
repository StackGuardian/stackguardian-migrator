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
