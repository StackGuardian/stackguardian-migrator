# StackGuardian Migrator

Migrate workloads from other platforms to [StackGuardian Platform](https://app.stackguardian.io).

## Supported platforms for migration

- Terraform Cloud

## Overview

- Extract and transform the workloads from the target platform to StackGuardian Workflows.
- Review the bulk workflow creation payload.
- Run sg-cli with the bulk workflow creation payload.

## Quick start (orchestrated)

`./sg-migrate.sh` runs the whole flow — `terraform apply` → HCL→JSON conversion → schema validation → bulk import — with all tooling (Terraform, `jq`, `hcl2json`, `yajsv`, `sg-cli`) isolated in a Docker image, so it behaves identically on Linux, macOS, and Windows. Docker is required for this path; without it the script automatically falls back to running natively (downloading pinned tools into `.sg/cached/`).

```shell
export TFE_TOKEN=<TFC/TFE token>     # long-lived API token (User/Team/Org token from the TFC UI)
export SG_API_TOKEN=<your SG token>
export SG_ORG=<your SG org>

./sg-migrate.sh init                 # scaffolds terraform.tfvars
# edit transformer/terraform-cloud/terraform.tfvars  (org, integrations, workspaceOverrides)

./sg-migrate.sh all                  # apply -> enrich -> convert -> validate -> import (prompts before importing)
```

That's it — no workflow-group mapping to fill in. Each TFC project is imported into an SG workflow group named `tfc-<project>`, **created automatically via the API** if it doesn't exist. The import prompt shows each group as `exists` or `create` before anything is written.

- Single phase: `./sg-migrate.sh apply|enrich|convert|validate|import|triggers`. Running `./sg-migrate.sh` with no command prints the help menu.
- TFC **Variable Set** variables are merged into the payloads automatically (the `enrich` phase, via the TFC API); skip it with `--no-variable-sets`.
- `./sg-migrate.sh clean` removes local working artifacts (`export/`, Terraform state, tool cache) for a fresh start; add `--all` to also remove config. `clean` always runs locally.
- **Override** a project's target group (to reuse an existing group) in `.sg/workflow-groups.json`: `{"<project-segment>": "<existing-group>"}`. Override groups must already exist (they're not auto-created).
- Output is concise by default (terraform's plan/init noise is hidden; shown on error). Add `-v`/`--verbose` for full output.
- Flags: `-y` skip the import prompt (CI), `--concurrency N` parallel jobs, `--org NAME`, `--no-create-groups` require groups to pre-exist, `--build` rebuild the image, `--native`/`--local` force a local run even when Docker is available.
- Tuning via env: `SG_RETRIES`, `SG_TF_PARALLELISM`, `SG_NATIVE=1`.
- Tab completion for the current shell session: `source <(./sg-migrate.sh completion zsh)` (or `bash`). `init` prints this line for your shell.
- TFC auth: set `TFE_TOKEN` (recommended — a long-lived token avoids re-running `terraform login`); otherwise the `terraform login` credentials file is mounted read-only into the container. SG/TFC tokens are passed as env vars.

The manual, step-by-step flow below remains supported for fine-grained control and is what each phase runs under the hood (the helper scripts live in `scripts/`).

## Prerequisites

- An organization on [StackGuardian Platform](https://app.stackguardian.io)
- Optionally, pre-configure VCS, cloud integrations or private runners to use when importing into StackGuardian Platform. To run every workflow on a private runner group, set `SGDefaultRunnerConstraints = { type = "private", names = ["<runner-group>"] }` in `terraform.tfvars` (per-workspace exceptions via `workspaceOverrides[<name>].RunnerConstraints`).
- Terraform
- [sg-cli](https://github.com/StackGuardian/sg-cli)

### Authenticate to Terraform Cloud/Enterprise

Set `TFE_TOKEN` to a long-lived API token (create one under **User Settings → Tokens**, or use a Team/Organization token) — this is the recommended path and avoids session expiry. Alternatively run `terraform login`, which writes `~/.terraform.d/credentials.tfrc.json`. The `tfe` provider, the API state export, and variable-set enrichment all use whichever is present.

### Export the resource definitions and Terraform state

- Choose the transformer and copy `terraform.tfvars.example` to `terraform.tfvars`.
- Edit terraform.tfvars with appropriate variables.
- Run the following commands:

```shell
cd transformer/terraform-cloud
terraform init
terraform apply -auto-approve -var-file=terraform.tfvars
```

A new `export` folder should have been created, containing:

- One payload file **per TFC project**, named `sg-payload.<project>.json`. Each contains the workflow definitions for the workspaces in that project, and is imported into its own StackGuardian workflow group.
- `migration-summary.md` (and `migration-summary.json`) — a report of what was migrated and what needs manual attention: skipped sensitive variables, Terraform-version fallbacks, renamed workspaces, and workspaces whose state could not be exported. **Read this before importing.**
- `terraform-version-fallbacks.log` (written by the `import` phase) — workflows that were created with `SGDefaultTerraformVersion` because their pinned version is above StackGuardian's managed ceiling; see _Notes and limitations_.
- The `states` folder with the Terraform state for each workspace, if state export was enabled.
- `state-export-failures.log`, if any workspace's state could not be pulled.

After completing the export, tune each `sg-payload.<project>.json` file with the fields below. For values that differ per workspace (cloud integration, VCS auth, approvers, Terraform version), prefer setting `workspaceOverrides` in `terraform.tfvars` and re-running `terraform apply` instead of editing the JSON by hand — see `terraform.tfvars.example`.

### Use the example_payload.jsonc file as a reference and edit the schema of the `sg-payload.json`

- `DeploymentPlatformConfig` - This is used to authenticate against a cloud provider using a StackGuardian Integration. Create the relevant integration in StackGuardian platform and update `DeploymentPlatformConfig.kind` to one of the following "AZURE_STATIC", "AWS_STATIC","GCP_STATIC", "AWS_RBAC". Update `DeploymentPlatformConfig.config.integrationId` with "/integrations/INTEGRATION_NAME" and `DeploymentPlatformConfig.config.profileName` with the name of the integration used upon creation.

```
  DeploymentPlatformConfig: [
    {
      "kind": "AWS_RBAC",
      "config": {
        "integrationId": "/integrations/aws-rbac",
        "profileName": "default"
      }
    }
  ]
```

- `VCSConfig` - Provide the full path to the `repo`, as well as the relevant `sourceConfigDestKind` from the following "GITHUB_COM", "BITBUCKET_ORG", "GITLAB_COM", "AZURE_DEVOPS"
  - `config.auth`
  - `config.isPrivate`
- `ResourceName` - name of your StackGuardian Workflow
- `wfgrpName` - this corresponds to the labelling of workflow group name in the StackGuardian platform
- `Description` - description for the workflows created in the StackGuardian platform
- `Tags` - list of tags for the workflows created in the StackGuardian platform
- `EnvironmentVariables` - environment variables for the workflows created in the StackGuardian platform
- `RunnerConstraints` - Runner description for the workflows in the StackGuardian platform
  - Private runners - ` 
"RunnerConstraints": {
  "type": "private",
  "names": [
      "sg-runner"
  ] 
}`
  - Shared runners - `
"RunnerConstraints": {
  "type": "shared"
}`
- `Approvers` - Approvers for the workflow to run it successfully
- `TerraformConfig` - Terraform configuration for the workflows created in the StackGuardian platform
- `UserSchedules` - Scheduled workflow run configuration for the workflow in the StackGuardian platform
- `MiniSteps` - Ministeps for the workflow to direct the process if the workflow returns an error/success/approval required and workflow chaining

### Convert HCL variables to JSON

HCL variables from Terraform Cloud appear as strings in the payload files and need to be converted to JSON before importing.

Run the script from the repo root, once per payload file. It rewrites the file in place — converting the HCL-string variable values under `VCSConfig.iacInputData.data` into JSON — so none of the following steps need any change. The script downloads `jq` and `hcl2json` at runtime.

```shell
for f in export/sg-payload.*.json; do ./scripts/convert_hcl_to_json.sh "$f"; done
```

### Validate the payloads (recommended)

Validate each payload against the StackGuardian workflow schema before importing, to catch malformed payloads before a bulk API run. The schema (`schema/sg-payload.schema.json`) is derived from the SG OpenAPI spec; the script downloads `yajsv` at runtime.

```shell
./scripts/validate_payload.sh export/sg-payload.*.json
```

### Bulk import workflows to StackGuardian Platform

> The orchestrated flow above creates the `tfc-<project>` groups for you. If you run sg-cli by hand, the target workflow group must already exist — create it in the SG UI/API first, or just use `./sg-migrate.sh import`.

- Fetch the [sg-cli](https://github.com/StackGuardian/sg-cli) Go binary for your platform (assets: `sg-cli_<OS>_<ARCH>.tar.gz`).
- Import **one payload file at a time**, each into its own workflow group. There is one file per TFC project (`sg-payload.<project>.json`), and the payload's group name is `tfc-<project>`.
- `--workflow-group` takes the group name (e.g. `tfc-networking`); the group must exist.
- Get your SG API Key here:
  - Login to Stackguardian.
  - Go to profile at the bottom left. Click on the email or the username.
  - Click API key and click on view.

```shell
cd ../../export

export SG_API_TOKEN=<YOUR_SG_API_TOKEN>
OS=$(uname -s); ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) ARCH=x86_64;; arm64|aarch64) ARCH=arm64;; esac
curl -fsSL "https://github.com/StackGuardian/sg-cli/releases/latest/download/sg-cli_${OS}_${ARCH}.tar.gz" | tar -xz sg-cli

# Run once per project file (group tfc-<project> must already exist):
./sg-cli workflow create --bulk --workflow-group "tfc-<project>" --org "<ORG NAME>" sg-payload.<project>.json
```

To update workflows with different details, re-run the sg-cli command with the modified payload file; workflows are updated as long as the `ResourceName` (workflow name) stays the same. Add `--dry-run` to preview a payload without applying.

## Notes and limitations

- **Workflow groups.** Each TFC project imports into an SG workflow group `tfc-<project>`, created via the API if missing (disable with `--no-create-groups`). Override the target group per project in `.sg/workflow-groups.json`; override groups must already exist.
- **Variable Sets are migrated** (the `enrich` phase) — global, project-, and workspace-scoped sets are resolved per workspace with TFC precedence (priority sets override workspace vars; otherwise workspace vars win). **Sensitive** set variables can't be read from the API, so they're skipped and reported — recreate them as StackGuardian secrets.
- **Sensitive variables are skipped.** TFC never returns sensitive values via the API, so they are omitted from the payload and listed in `migration-summary.md`. Recreate them as StackGuardian secrets.
- **Terraform version fallback (FOSS ceiling).** Workspaces set to `latest` or a version constraint use `SGDefaultTerraformVersion` at export time. Pinned versions are carried over as-is and tried first at import, so a custom runtime image or private runner that ships that binary keeps working. StackGuardian's _managed_ runtimes only go up to **1.5.7**, the last MPL-licensed (FOSS) Terraform release; newer versions are BSL-licensed and are not bundled. When the API rejects a workflow for that reason, the importer **automatically re-imports it with `SGDefaultTerraformVersion`**, patches the payload file to match, prints a notice, and records each case in `export/terraform-version-fallbacks.log`. Those workflows run a different Terraform than they did in TFC, so check compatibility before the first run. To keep a newer version, set `workspaceOverrides[<name>].terraformVersion` to a binary path mounted from a private runner (or use a custom runtime container template) and re-import.
- **State export is idempotent.** Re-running `terraform apply` only pulls state for workspaces not yet exported. Set `forceStateRefresh = true` to re-pull everything. Workspaces not using `remote` execution may export incomplete state — see the summary.
- **Workflow naming.** `ResourceName` currently mirrors the TFC workspace name. Confirm it satisfies StackGuardian's naming rules before import.
