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
git clone https://github.com/StackGuardian/stackguardian-migrator.git
cd stackguardian-migrator

export TFE_TOKEN=<TFC/TFE token>     # long-lived API token (User/Team/Org token from the TFC UI)
export SG_API_TOKEN=<your SG token>
export SG_ORG=<your SG org>

./sg-migrate.sh init                 # guided setup: TFC org/workspaces, SG connectors, runners, per-project settings -> terraform.tfvars
./sg-migrate.sh all                  # preflight -> apply -> enrich -> convert -> validate -> import (shows a plan, asks before importing)
```

That's it — no IDs to look up and no workflow-group mapping to fill in. `init` lists what the tokens can see (TFC organisations, projects and workspaces, SG VCS/cloud connectors and runner groups, the org's execution preset), asks which TFC projects to migrate (all, or some by name — `tfProjects`, `[]` = all) and then which of their workspaces, and writes `terraform.tfvars` from your picks — it also reads which VCS provider your TFC workspaces are connected to, lists the matching connectors first and takes the repository URL prefix from TFC. With more than one TFC project it asks whether the same connectors and groups apply to every project, or lets you pick a cloud connector, a VCS connector and the workflow group per project (see *Per-project settings* below). `all` verifies every reference **before** running terraform (preflight — including that the VCS connector, the VCS kind and the repo URL prefix agree with each other and with the TFC repositories), prints a migration summary after the export, shows a per-workflow import plan (create/update, Terraform version, runner, triggers, secrets), and ends with a **post-import checklist** of what still needs a human. Phases are numbered, long steps show a live progress line, and every phase reports how long it took. Each TFC project is imported into the SG workflow group assigned to it — `tfc-<project>` by default, or the group you picked for that project — **reusing the group when it exists and creating it otherwise**. Workflows are never moved between groups: when a project's workflows already live in another group, the plan stops and says so.

- **Region.** StackGuardian runs in the EU (`api.app.stackguardian.io` / `app.stackguardian.io`, the default) and the US (`api.us.stackguardian.io` / `us.stackguardian.io`). Pass `--region us` (or set `SG_REGION=us`) on `init` and it is remembered for every later run; the import plan and `export/run-result.json` show which API the run used. `SG_BASE_URL` / `SG_UI_URL` override the region's hosts for private or test environments.
- **Updating.** Clone the repo (don't fork it or download the release zip) and run `./sg-migrate.sh update` to pull the latest version; it fast-forwards the checkout and rebuilds the Docker image only if the `Dockerfile` changed. Your `terraform.tfvars`, `export/` and `.sg/` are never tracked, so they survive every update. To stay on a fixed release instead, `git checkout v1.2.2` (then `git checkout master` to follow the latest again).
- Single phase: `./sg-migrate.sh preflight|apply|enrich|convert|validate|import|triggers|checklist`. Running `./sg-migrate.sh` with no command prints the help menu.
- **Resume.** `all` remembers what it completed (`.sg/state.json`) and skips phases whose inputs have not changed, so after a failure you just re-run it; files already imported in full are skipped and files with failures are retried. `--fresh` redoes everything.
- **Scope.** `terraform.tfvars` holds the widest selection (`workspacenames`, `tfWorkspaceTags`/`tfWorkspaceIgnoreTags`, `tfWorkspaceIgnoreNames`, `tfProjects`); flags narrow one run and every phase applies the same selection: `--project <name or slug>` (a TFC project, exported and imported on its own), `--workspace <glob>` (`team-*`, `*` = all; replaces `workspacenames`), `--exclude-workspace <glob>` (adds to `tfWorkspaceIgnoreNames`), `--tag <name>` / `--exclude-tag <name>` (export only). All repeatable — migrate one team first, then the rest, or drive the selection from a CI trigger.
- **Inline connectors and settings.** For a run driven from a pipeline, the connectors can be passed instead of edited into the tfvars: `--cloud-connector <id>`, `--vcs-connector <id>`, `--runner-group <name>|shared`, `--workflow-group <name>` and the generic `--set KEY=VALUE` (any transformer variable, HCL or JSON value). Only the connector id is typed; its kind (`AWS_RBAC`, `AZURE_OIDC`, `GITHUB_COM`, ...) is looked up in the org, and the VCS kind and repo URL prefix follow the connector. With `--project` they become that project's `projectOverrides` entry for the run, so every workspace of the project inherits them; without it they set the `SGDefault*` values. They are applied on top of `terraform.tfvars` for that run only and reach the workflows through the export (`all`, or `apply` then `import`); a later run without them PATCHes the workflows back to the tfvars values. `./sg-migrate.sh -y all --project Payments --workspace '*' --workflow-group payments-prod --cloud-connector aws-payments --vcs-connector github_payments` migrates one project into one group with one set of connectors.
- **Dry run.** `./sg-migrate.sh import --dry-run` (or `all --dry-run`, which still runs the local export) prints the per-workflow plan and stops; nothing is created or changed in StackGuardian. The plan is also written to `export/run-result.json` and `export/run-summary.md`.
- **Sensitive variables** (which TFC never exposes) are recreated as SG secrets with the value `CHANGE_ME` and referenced from the workflows as `${secret::<name>}`; the checklist lists each one to fill in. Opt out with `--no-secret-stubs`.
- TFC **Variable Set** variables are merged into the payloads automatically (the `enrich` phase, via the TFC API); skip it with `--no-variable-sets`.
- `./sg-migrate.sh clean` removes local working artifacts (`export/`, Terraform state, run state, tool cache) for a fresh start; add `--all` to also remove config. `clean` (like `update` and `completion`) always runs locally.
- **Per-project settings.** `projectOverrides` in `terraform.tfvars` (keyed by the TFC project name, written by `init` or by hand) sets the cloud connector, VCS connector, runners, approvers, Terraform version and the target workflow group (`workflowGroup`) for every workspace of a project; precedence is `workspaceOverrides` > `projectOverrides` > `SGDefault*`. Re-running `init` keeps hand-written `projectOverrides`/`workspaceOverrides` blocks (comments inside them are not preserved) and carries over every setting it does not ask about. The older `.sg/workflow-groups.json` mapping still works but is deprecated.
- **Keeping `terraform.tfvars` current.** After `./sg-migrate.sh update`, `./sg-migrate.sh init --upgrade` appends the settings a new version introduced to your existing file, each with its default and comment, and touches nothing else (no prompts, so it works in CI too; the previous file is kept as `.bak`). A default is the same as leaving the setting out, so this is optional — preflight lists the settings your file predates until you run it.
- Output is concise by default (terraform's plan/init noise is hidden; shown on error). Add `-v`/`--verbose` for full output. Known API errors come with a hint naming the `terraform.tfvars` field to fix.
- Flags: `-y` skip the import prompt (required without a terminal, e.g. in CI), `--tfvars FILE` use a tfvars file kept elsewhere, `--concurrency N` parallel jobs, `--org NAME`, `--no-create-groups` require groups to pre-exist, `--skip-preflight`, `--build` rebuild the image, `--native`/`--local` force a local run even when Docker is available, `--mapping FILE` (deprecated group override map, see *Per-project settings*).
- Tuning via env: `SG_RETRIES`, `SG_TF_PARALLELISM`, `SG_NATIVE=1`, `SG_TFVARS` (same as `--tfvars`), `SG_UI_URL` (base URL for the checklist's links, default `https://app.stackguardian.io`).
- **Running in CI.** Without a terminal every prompt takes its default: `init` cannot run the wizard (it only copies the example file), so generate `terraform.tfvars` once with `init` on a workstation, keep it next to the pipeline (it is gitignored here) and pass it with `--tfvars`; `import`/`all` need `-y`. Pick the scope per trigger with the flags above and the connectors with `--cloud-connector`/`--vcs-connector`/`--workflow-group` when they are trigger inputs too, run `all --dry-run` on a pull request and `-y all` on merge, and publish `export/run-summary.md` (e.g. `cat export/run-summary.md >> "$GITHUB_STEP_SUMMARY"`); `export/run-result.json` has the same data for scripts. Cache `.sg/` and `export/` between runs to keep the resume logic; without them every run re-exports and updates every workflow, which is correct but slower. `export/states/` holds real Terraform state — do not publish it as an artifact.
- Tab completion for the current shell session: `source <(./sg-migrate.sh completion)` (bash/zsh detected; or pass `bash`/`zsh`). `init` prints this line.
- TFC auth: set `TFE_TOKEN` (recommended — a long-lived token avoids re-running `terraform login`); otherwise the `terraform login` credentials file is mounted read-only into the container. Tokens are only ever read from the environment; `init` never writes them to disk.

The manual, step-by-step flow below remains supported for fine-grained control and is what each phase runs under the hood (the helper scripts live in `scripts/`).

## Prerequisites

- An organization on [StackGuardian Platform](https://app.stackguardian.io)
- Optionally, pre-configure VCS, cloud integrations or private runners to use when importing into StackGuardian Platform. To run every workflow on a private runner group, set `SGDefaultRunnerConstraints = { type = "private", names = ["<runner-group>"] }` in `terraform.tfvars` (per-project exceptions via `projectOverrides[<project>].RunnerConstraints`, per-workspace via `workspaceOverrides[<name>].RunnerConstraints`).
- Terraform
- [sg-cli](https://github.com/StackGuardian/sg-cli)

With the orchestrated flow the last two come from the Docker image; only `git` and Docker are needed on the host.

### Windows (WSL 2)

Run the migrator from a WSL 2 distribution (Ubuntu from the Microsoft Store is fine); nothing is needed on the Windows side.

- Install [Docker Desktop](https://docs.docker.com/desktop/features/wsl/) with the WSL 2 backend and enable *WSL integration* for your distro (Settings → Resources → WSL integration). `docker` is then on the PATH inside WSL and `./sg-migrate.sh` works unchanged.
- Clone inside the Linux filesystem (e.g. `~/stackguardian-migrator`), not under `/mnt/c/...`: bind mounts from the Windows drive are slow, and a Git-for-Windows checkout may convert the scripts to CRLF line endings.
- Set `TFE_TOKEN` (or run `terraform login`) **inside WSL**. The wrapper mounts `~/.terraform.d/credentials.tfrc.json` from the WSL home; a `terraform login` done on the Windows side is not seen.

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

- **Workflow groups.** Each TFC project imports into the workflow group the transformer assigned to it: `projectOverrides[<project>].workflowGroup`, or `tfc-<project>`. The import plan shows `reuse` for a group that exists and `create` for one that will be created (`--no-create-groups` requires every group to exist). StackGuardian cannot move workflows between groups and the migrator never updates a group: when a project's workflows already live in another group (the one recorded in `.sg/state.json`, or the default `tfc-<project>` group) the plan shows `moved!` and stops — keep the old group or delete the workflows there first. Two projects may share a group only when their workflow names do not overlap; the plan refuses a collision. `.sg/workflow-groups.json` is still honoured as a deprecated override.
- **Per-project settings.** `projectOverrides` (keyed by the TFC project name) carries the same fields as `workspaceOverrides` plus `workflowGroup`, for every workspace of that project; precedence `workspaceOverrides` > `projectOverrides` > `SGDefault*`. `init` fills it in when you answer no to "use these connectors and the tfc-<project> groups for all projects", preflight checks every connector, runner group and kind in it and warns about keys that match no TFC project, and the migration summary lists which group each project maps to.
- **Variable Sets are migrated** (the `enrich` phase) — global, project-, and workspace-scoped sets are resolved per workspace with TFC precedence (priority sets override workspace vars; otherwise workspace vars win). **Sensitive** set variables can't be read from the API, so they're skipped and reported — recreate them as StackGuardian secrets.
- **TFC-specific variables are stripped.** Variables whose name matches `ignoreVarPatterns` (default `^TFC_`, `^TFE_`, e.g. `TFC_WORKSPACE_NAME` or the `TFC_AWS_*` dynamic-credential settings) only mean something inside Terraform Cloud and are not migrated, from workspaces or variable sets. They are listed in the migration summary; set `ignoreVarPatterns = []` to keep them.
- **Cloud credential variables are stripped.** A workflow's StackGuardian cloud connector provides the credentials, so the env variables the TFC workspace used for them (`ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`/`ARM_USE_OIDC`..., `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`/`AWS_PROFILE`/`AWS_ROLE_ARN`..., `GOOGLE_CREDENTIALS`/`GOOGLE_APPLICATION_CREDENTIALS`/`CLOUDSDK_AUTH_*`) are not migrated. Which family is stripped follows each workflow's effective connector kind (`AWS_*`, `AZURE_*`, `GCP_*`), from workspaces and variable sets alike; a sensitive one is stripped too, so no placeholder secret is created for it. They are listed in the migration summary; `stripCloudAuthVars = false` keeps them, `cloudAuthVarPatterns` changes the regexes per family. Terraform input variables are never touched.
- **Sensitive variables become placeholder secrets.** TFC never returns sensitive values via the API. The export omits them (listed in `migration-summary.md`); after import the orchestrator creates an SG secret `tfc-<workflow>-<VAR>` with the value `CHANGE_ME` for each, references it from the workflow (`${secret::<name>}`, as an environment variable or IaC input) and lists it in `export/post-import-checklist.md`. Set the real values in the SG UI. `--no-secret-stubs` leaves SG secrets untouched.
- **Terraform version fallback (FOSS ceiling).** With `SGTerraformVersionSource = "carry"` (the default) pinned versions are carried over as-is and tried first at import, so a custom runtime image or private runner that ships that binary keeps working; workspaces set to `latest` or a version constraint use `SGDefaultTerraformVersion` at export time. StackGuardian's _managed_ runtimes only go up to **1.5.7**, the last MPL-licensed (FOSS) Terraform release; newer versions are BSL-licensed and are not bundled. When the API rejects a workflow for that reason, the importer **automatically re-imports it with `SGDefaultTerraformVersion`** (or, when that is `null`, without any version so the execution preset decides — see the next bullet), patches the payload file to match, prints a notice, and records each case in `export/terraform-version-fallbacks.log`. Those workflows run a different Terraform than they did in TFC, so check compatibility before the first run. To keep a newer version, set `workspaceOverrides[<name>].terraformVersion` to a binary path mounted from a private runner (or use a custom runtime container template) and re-import.
- **Execution presets.** StackGuardian org admins can define an execution preset (Settings → Runner groups → Execution presets): default runner constraints plus a Terraform and an OpenTofu configuration that the API applies to any new workflow whose payload does not carry those fields. To lean on it, set `SGTerraformVersionSource = "preset"` (no version is sent at all) and/or `SGDefaultRunnerConstraints = null` (no runner constraints are sent); `SGDefaultTerraformVersion = null` keeps carrying TFC pins but hands the unpinned and rejected ones to the preset. `init` offers these choices with the org's current preset shown inline, preflight prints what the preset would supply, and the import plan marks such cells as `preset (…)`. The preset's custom runtime image or runner-provided binary is inherited in every mode, since the migrator never sets those keys.
- **Workspaces without variables are imported directly.** sg-cli (up to v2.2.1) drops an empty `iacInputData.data` from the request, and the API then rejects the workflow with `VCSConfig.iacInputData.data: This field is required.` The importer therefore creates workflows that have no Terraform variables straight through the API (same create, same state upload) and uses sg-cli for the rest. This is a workaround until sg-cli picks up sg-sdk-go v1.5.7, which fixes the dropped key.
- **Terraform state is uploaded by the migrator, and checked.** sg-cli's own upload sends a PUT that Azure-backed StackGuardian environments reject (missing `x-ms-blob-type`) and it reports success only on a literal `HTTP/1.1 200 OK`, so the importer re-uploads every state file sg-cli reports as failed and records per workflow whether the store accepted it. A workflow without its state counts as a failed import: it is listed in the checklist (`state: N workflow(s) are in SG without their state`) and the file is retried on the next `import`.
- **Re-runs update existing workflows.** Workflows that already exist in the target group (the plan's `update` rows) are PATCHed directly and their state re-uploaded; only new ones go through the create path. Should a create still meet `409 Workflow ID not unique` (sg-cli's own update path waits for a message the API no longer sends), the importer updates that workflow itself. A change in `terraform.tfvars` (connector, runner, approvers, version) reaches existing workflows through `apply` + `import`: the regenerated payload differs, the plan shows `update`, and the workflow is PATCHed; an unchanged file shows `skip`. VCS triggers are re-registered only when their configuration changed (the API upserts them). Secrets that already exist are never overwritten. Re-running `import` (or `import --fresh`) is therefore safe and idempotent.
- **Fail fast.** When more than one workflow is to be imported, the importer first imports a single one (the first selected workflow of the first payload file) and requires both the create and its state upload to succeed before the rest is imported in parallel. An environment problem then costs one workflow, not all of them; the probe workflow is simply updated again with its file.
- **State export is idempotent.** Re-running `terraform apply` only pulls state for workspaces not yet exported. Set `forceStateRefresh = true` to re-pull everything. Workspaces not using `remote` execution may export incomplete state — see the summary.
- **Workflow naming.** `ResourceName` mirrors the TFC workspace name, sanitized to StackGuardian's rules (1-100 chars, `[-a-zA-Z0-9_]`); any rename is listed in the summary and the checklist.
- **Preflight.** `apply`, `import` and `all` first verify the TFC and SG tokens, the TFC org and workspace selection, and that every connector, secret and runner group referenced in `terraform.tfvars` (globally, per project and per workspace) exists and agrees with the VCS kinds; `projectOverrides`/`workspaceOverrides` keys are checked against the TFC projects and workspaces. Fix what it reports (or re-run `init`); `--skip-preflight` bypasses it.
- **Post-import checklist.** `export/post-import-checklist.md` collects the secrets to fill in, failed imports, Terraform version fallbacks, failed VCS triggers, missing state exports and renames, with links into the SG UI. The terminal lists the sections that still need a human, one line each, folds the clean ones into a single ✓ line and links the imported workflow groups; the file has the details.
