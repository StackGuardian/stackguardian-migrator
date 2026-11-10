# StackGuardian Migrator reference

The detailed behavior behind [README.md](README.md). `./sg-migrate.sh --help` lists every command, flag and environment variable; [`terraform.tfvars.example`](transformer/terraform-cloud/terraform.tfvars.example) documents every setting with a comment.

## How a run works

`./sg-migrate.sh all` runs these phases in order. Each one can also be run on its own (`./sg-migrate.sh <phase>`).

| Phase | What it does | Writes |
|---|---|---|
| `preflight` | Verifies the TFC/TFE and StackGuardian tokens, the TFC organization and the workspace selection, and that every connector, secret and runner group named in `terraform.tfvars` exists and agrees with the VCS kinds and repository URLs. Failures name the `terraform.tfvars` field to fix. Runs automatically before `apply`, `import` and `all`; `--skip-preflight` bypasses it. | |
| `apply` | Runs the transformer (`tofu apply` in `transformer/terraform-cloud/`) against the TFC/TFE API: reads the selected workspaces and their variables, writes one payload file per project and pulls each workspace's current Terraform state. | `export/sg-payload.*.json`, `export/migration-summary.md` and `.json`, `export/states/`, `export/state-export-failures.log` |
| `enrich` | Merges TFC variable set variables into the payloads through the TFC API (the Terraform provider cannot enumerate sets). Skipped with `--no-variable-sets`. | the payload files, in place |
| `convert` | Converts HCL-string variable values in each payload to JSON. | the payload files, in place |
| `validate` | Checks each payload against `schema/sg-payload.schema.json`. | |
| `import` | Shows the per-workflow plan, asks for confirmation (`-y`/`--yes` skips it), creates the missing workflow groups, imports every payload file into its group, uploads each workflow's state, then registers VCS triggers (`--no-vcs-triggers` skips that part). | `export/run-result.json`, `export/run-summary.md`, `export/terraform-version-fallbacks.log` |
| `triggers` | Registers VCS triggers for already-imported workflows, on its own. | |
| `checklist` | Creates the placeholder secrets for sensitive variables and writes the post-import checklist. Runs automatically after `import`. | `export/post-import-checklist.md` |

Phases are numbered inside `all`, long steps show a live progress line, and every phase reports how long it took. Output is concise by default; `-v`/`--verbose` streams the full output of OpenTofu, sg-cli and the other tools. `completion` prints a tab-completion script for bash or zsh (`source <(./sg-migrate.sh completion)`).

**Resume.** `all` records each completed phase and a hash of its inputs in `.sg/state.json` and skips phases whose inputs have not changed since. After a failure, re-run `all`: payload files that were imported in full are skipped, files with failures are retried. `--fresh` ignores the saved state and redoes every phase. A Ctrl-C prints how to resume.

**Docker or native.** `./sg-migrate.sh` runs the migrator inside the Docker image built from `Dockerfile`, which bundles OpenTofu, `jq`, `hcl2json`, `yajsv` and `sg-cli`, so a run behaves the same on Linux, macOS and WSL 2. Without Docker, or with `--native`/`--local` (or `SG_NATIVE=1`), it runs on the host: the IaC CLI is `SG_TF_BIN`, else `tofu`, else `terraform` (1.3 or newer), and the other tools are downloaded once into `.sg/cached/`. `--build` rebuilds the image. `clean`, `completion` and `update` always run on the host.

**Authentication.** StackGuardian: `SG_API_TOKEN` and `SG_ORG` (or `--org`). TFC/TFE: `tfOrg` and `tfHostname` in `terraform.tfvars` name the organization and the host (`app.terraform.io` for Terraform Cloud); the token is taken from `TFE_TOKEN`, then `TF_TOKEN_<hostname>`, then the `terraform login` credentials file (`~/.terraform.d/credentials.tfrc.json`, mounted read-only into the container). `apply` and `all` verify the token first and fail fast when it is missing or expired. Tokens are only ever read from the environment; `init` never writes them to disk.

**Regions.** StackGuardian runs in the EU (`api.app.stackguardian.io`, the default) and the US (`api.us.stackguardian.io`). `--region us` or `SG_REGION=us` picks the API and the UI host together; `init` remembers the region in `.sg/state.json`, and the import plan and `run-result.json` show which API a run used. `SG_BASE_URL` and `SG_UI_URL` override the region's hosts for private or test environments.

**Updating.** `./sg-migrate.sh update` fast-forwards the git checkout (`git pull --ff-only`) and rebuilds the Docker image only when `Dockerfile` changed. It refuses a checkout that is not a git clone, is on a detached HEAD or has modified tracked files. `terraform.tfvars`, `export/` and `.sg/` are untracked and survive every update. To stay on a release, check out its tag; `git checkout master` follows the latest again. After an update, `./sg-migrate.sh init --upgrade` appends the settings a newer version introduced to your `terraform.tfvars`, each with its default and comment, keeps the previous file as `.bak` and changes nothing else; it asks no questions, so it works in CI. A default is the same as leaving the setting out, so this is optional; until you run it, preflight lists the settings your file predates.

## Selecting what to migrate

`terraform.tfvars` holds the widest selection:

| Setting | Meaning |
|---|---|
| `tfProjects` | TFC projects to migrate, by name or slug; `[]` = all. |
| `workspacenames` | Workspace name globs; `["*"]` = all. |
| `tfWorkspaceTags` / `tfWorkspaceIgnoreTags` | Only workspaces carrying every listed tag / leave workspaces carrying a listed tag out. |
| `tfWorkspaceIgnoreNames` | Workspace name globs to leave out, applied after the filters above. |

Flags narrow a single run, and every phase applies the same selection: `--project <name or slug>`, `--workspace <glob>` (replaces `workspacenames` for the run; `'*'` = all), `--exclude-workspace <glob>` (adds to `tfWorkspaceIgnoreNames`), `--tag <name>` and `--exclude-tag <name>` (export only). All are repeatable. Include flags replace the file's list, exclude flags add to it. A selection that matches nothing is an error. This is how you migrate one team first and the rest later, or drive the selection from a CI trigger.

Payload files are named after what they hold: `sg-payload.<project>.json` for a project's workspaces, `sg-payload.<project>.<group>.json` for a workspace that has its own workflow group (see [Workflow groups and names](#workflow-groups-and-names)). `--project` selects both.

## Settings and precedence

Every workflow setting has three layers in `terraform.tfvars`, resolved per workspace:

```
workspaceOverrides[<workspace>]  >  projectOverrides[<TFC project name>]  >  SGDefault*
```

The `SGDefault*` values apply to every workflow: the cloud connector (`SGDefaultDeploymentPlatformConfig`), the VCS connector (`SGDefaultVCSAuthIntegrationID`), the VCS kind and repository URL prefix (`SGDefaultSourceConfigDestKind`, `SGDefaultIACVCSRepoPrefix`), approvers (`SGDefaultWfApprovers`; a workspace without auto-apply gets an approval step before apply), runners, the Terraform version and VCS triggers (`SGDefaultEnableVCSTriggers`). `projectOverrides`, keyed by the TFC project name, sets any of them plus the target workflow group for every workspace of a project. `workspaceOverrides`, keyed by the workspace name, does the same for one workspace and can also set `workflowName`. `init` writes `projectOverrides` when you answer no to "use these connectors and groups for all projects"; re-running `init` keeps hand-written `projectOverrides` and `workspaceOverrides` blocks (comments inside them are not preserved) and carries over every setting it does not ask about.

**Connectors.** Only the connector id is configured; its kind is looked up in StackGuardian. The VCS connector, the VCS kind and the repository URL prefix must agree with each other and with where the TFC repositories live. Preflight checks this globally and per `projectOverrides` entry, and `init` takes the kind and the prefix from the VCS provider of the selected TFC workspaces.

**Runners.** `SGDefaultRunnerConstraints = { type = "shared" }` uses StackGuardian's runners; `{ type = "private", names = ["<runner-group>"] }` puts every workflow on a private runner group, with per-project and per-workspace exceptions through `RunnerConstraints` in the overrides. `null` sends no runner constraints, so the organization's execution preset decides.

**Execution presets.** StackGuardian organization admins can define an execution preset (Settings → Runner groups → Execution presets): default runner constraints plus a Terraform and an OpenTofu configuration that the API applies to new workflows whose payload leaves those fields out. `SGTerraformVersionSource = "preset"` sends no Terraform version, `SGDefaultRunnerConstraints = null` sends no runner constraints, and `SGDefaultTerraformVersion = null` keeps carrying TFC pins but hands unpinned and rejected versions to the preset. `init` offers these choices with the organization's current preset shown, preflight prints what the preset would supply, and the import plan marks such cells as `preset (…)`. A custom runtime image or a runner-provided binary in the preset is inherited in every mode.

**Terraform version.** With `SGTerraformVersionSource = "carry"` (the default), a workspace's pinned version is carried over and tried first at import; workspaces set to `latest` or to a constraint get `SGDefaultTerraformVersion`. StackGuardian's managed runtimes go up to **Terraform 1.5.7**, the last MPL-licensed release; newer versions are BSL-licensed and not bundled. When the API rejects a workflow for that reason, the importer re-imports it with `SGDefaultTerraformVersion` (or, when that is `null`, without a version so the execution preset decides), patches the payload file to match, prints a notice and records the case in `export/terraform-version-fallbacks.log`. Those workflows run a different Terraform than in TFC, so check compatibility before their first run. To keep a newer version, point `workspaceOverrides[<name>].terraformVersion` at a binary provided by a private runner (or use a custom runtime image) and re-import.

**Parent workflow group.** `SGParentWorkflowGroup = "<name>"` makes every migrated group a child of one group (`<name>/tfc-<project>`); the parent is created when missing.

**Settings for one run.** For a run driven from a pipeline, settings can be passed as flags instead of edited into the file: `--cloud-connector <id>`, `--vcs-connector <id>` (the kind and the repository URL prefix follow the connector), `--runner-group <name>|shared`, `--workflow-group <name>` and `--set KEY=VALUE` for any transformer variable (an HCL or JSON value; bare text is a string). With `--project` they become that project's `projectOverrides` for the run; without it they set the `SGDefault*` values. They apply on top of `terraform.tfvars` for that run only and reach the workflows through the export (`all`, or `apply` then `import`); a later run without them updates the workflows back to the file's values. `run-result.json` records them under `configuration`.

**One workspace, one target.** `--workflow <name>` names the workflow a workspace is migrated into (default: the workspace name), and `--workflow-group <name>` together with exactly one `--workspace <name>` (a name, not a glob) puts that workspace into its own group. Both become that workspace's `workspaceOverrides` entry (`workflowName`, `workflowGroup`) for the run; to set them for many workspaces, write those fields into `terraform.tfvars`.

## Variables

**What is migrated.** Non-sensitive TFC `terraform` variables become the workflow's Terraform inputs; non-sensitive `env` variables become plain-text environment variables. HCL-typed values are converted to JSON by the `convert` phase.

**Variable sets.** The `enrich` phase resolves global, project- and workspace-scoped sets per workspace with TFC precedence (priority sets override workspace variables; otherwise workspace variables win) and merges the result into the payloads. Sensitive set variables cannot be read from the API and are reported instead. `--no-variable-sets` skips the phase.

**Not migrated.** Variables matching `ignoreVarPatterns` (default `^TFC_` and `^TFE_`, for example `TFC_WORKSPACE_NAME` or the `TFC_AWS_*` dynamic-credential settings) only mean something inside Terraform Cloud and are dropped, from workspaces and variable sets alike; `ignoreVarPatterns = []` keeps them. Cloud credential environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `GOOGLE_CREDENTIALS`, …) are dropped too, because the workflow's cloud connector provides the credentials; which family is stripped follows each workflow's connector kind (`AWS_*`, `AZURE_*`, `GCP_*`). `stripCloudAuthVars = false` keeps them; `cloudAuthVarPatterns` changes the patterns per family. Terraform input variables are never touched. Everything dropped is listed in `migration-summary.md`.

**Sensitive variables.** TFC never returns sensitive values. The export omits them (listed in the summary); after the import the migrator creates a StackGuardian secret `tfc-<workflow>-<VAR>` with the value `CHANGE_ME` for each, references it from the workflow as `${secret::<name>}` (as an environment variable or a Terraform input) and lists it in the checklist. Set the real values in the StackGuardian UI. Existing secrets are never overwritten, and a variable the workflow already sets to something else (for example a secret you wired up yourself) is left alone. `--no-secret-stubs` leaves secrets untouched.

**Re-imports and variables you changed in StackGuardian.** When a workflow already exists, the importer reads it and merges, in one of three modes:

| Mode | Behavior |
|---|---|
| `--merge-vars` (default) | Variables that only the workflow has (added in StackGuardian) are kept. Variables the migration sets get the migrated value. New ones are added. |
| `--add-vars` | Everything the workflow has is kept, values included. Only names it does not have yet are added. |
| `--replace-vars` | The workflow gets exactly the migrated set. Variables added in StackGuardian are lost. This is also the only way to drop a variable that was deleted in TFC. |

Environment variables are matched by name, Terraform inputs by key. If the existing workflow cannot be read, it is not updated: the failure is reported and the next run retries it.

## Workflow groups and names

**One group per project.** Each TFC project is imported into the StackGuardian workflow group the transformer assigned to it: `projectOverrides[<project>].workflowGroup`, or `tfc-<project>` by default. An existing group is reused (`reuse` in the plan), a missing one is created (`create`); `--no-create-groups` requires every group to exist. Two projects may share a group only when their workflow names do not overlap. Groups are never modified after creation.

**One workspace, its own group.** `workspaceOverrides[<ws>].workflowGroup` (or `--workspace <ws> --workflow-group <name>`) puts a single workspace into its own group; its payload goes to `sg-payload.<project>.<group>.json`.

**Workflows never move.** StackGuardian cannot move or rename a workflow, and the migrator never tries. When a workspace was imported before and its target group changed, the plan shows `moved!` and stops: keep the old group, or delete the workflows there first. When its workflow name changed, the new name is imported next to the old workflow, and the plan and the checklist list the old one for deletion ("Workflows left behind"). A `workflowName` that matches a workflow this workspace did not create is flagged too, because the import would overwrite it.

**Workflow names.** A workflow is named after its workspace, adjusted to StackGuardian's rules where needed (1 to 100 characters; letters, digits, `-` and `_`; collisions are disambiguated). For ordinary workspace names nothing changes; every adjustment is listed in the summary and the checklist.

**Deprecated.** `.sg/workflow-groups.json` (`--mapping FILE`), the older per-project group map, is still honored on top with a warning; use `projectOverrides[<project>].workflowGroup` instead.

## Import behavior

**The plan.** Before anything is created, `import` prints one row per workflow: name, group, action (`create`; `update` for a workflow that exists in the group; `skip` for an unchanged file imported in full), Terraform version, runner, triggers, variables and secrets, plus a table of the groups to create or reuse when needed. Problems (a workflow that would have to move, two files with overlapping names in one group) are printed as ✗ lines and stop the run. `--dry-run` prints the plan and stops; with `all --dry-run` the local export phases still run. The plan is also written to `export/run-result.json` and `export/run-summary.md`.

**Probe first.** With more than one workflow to import, the importer first imports a single one and requires both the create and its state upload to succeed before the rest is imported in parallel (`--concurrency`, default 4). An environment problem then costs one workflow, not all of them.

**Create or update.** Workflows that already exist in the target group are updated in place and their state re-uploaded; only new ones are created. Workflows without Terraform variables and workflows in a nested group (`SGParentWorkflowGroup`) are created through the StackGuardian API directly rather than through sg-cli; the result is the same. A change in `terraform.tfvars` (connector, runner, approvers, version) reaches existing workflows through `apply` and `import`: the regenerated payload differs, the plan shows `update`, and the workflow is updated. Re-running `import` is therefore safe and idempotent.

**State.** The migrator uploads each workspace's Terraform state itself and checks that the store accepted it. A workflow without its state counts as a failed import: it is listed in the checklist and retried on the next `import`. The export side is idempotent too: `apply` pulls state only for workspaces not yet exported (`forceStateRefresh = true` re-pulls everything), and workspaces that do not use remote execution may have incomplete state, which the summary notes.

**Triggers.** VCS triggers are remapped from each workspace's TFC settings (tracked branch, push, pull request plans, file triggers) and registered after the import; `SGDefaultEnableVCSTriggers = false` imports workflows without any. They are re-registered only when their configuration changed; `triggers` runs that pass alone.

**Retries and errors.** Imports are retried with backoff (`SG_RETRIES`, default 4); definitive API errors are not retried. Known API errors come with a hint that names the `terraform.tfvars` field to fix. By default each workflow gets one ✓ or ✗ line; sg-cli's own output is shown with `-v`.

**Run result.** `import` and `all` end by writing `export/run-result.json` (outcome `planned`, `blocked`, `success` or `failed`; the result per workflow; the groups; the region and API used; the run configuration) and `export/run-summary.md` with the same content as Markdown.

## Running in CI

Without a terminal every prompt takes its default: `init` cannot run the wizard, and `import` and `all` need `-y`.

1. Generate `terraform.tfvars` once with `./sg-migrate.sh init` on a workstation and keep it next to the pipeline (it is gitignored in this repository). Pass it with `--tfvars FILE` or `SG_TFVARS`.
2. Provide `TFE_TOKEN`, `SG_API_TOKEN` and `SG_ORG` as secrets.
3. Pick the scope per trigger with `--project`, `--workspace` or `--tag`, and the connectors with `--cloud-connector`, `--vcs-connector` and `--workflow-group` when they are trigger inputs too.
4. Run `./sg-migrate.sh all --dry-run` on a pull request and `./sg-migrate.sh -y all` on merge.
5. Publish `export/run-summary.md` (for example `cat export/run-summary.md >> "$GITHUB_STEP_SUMMARY"`); `export/run-result.json` has the same data for scripts.
6. Cache `.sg/` and `export/` between runs to keep the resume logic; without them every run re-exports and updates every workflow, which is correct but slower.
7. Never publish `export/states/` as an artifact: it holds real Terraform state.

## Running the phases by hand

Each phase runs a script you can also call yourself, from the repository root:

| Phase | Command |
|---|---|
| `apply` | `cd transformer/terraform-cloud && tofu init && tofu apply -auto-approve -var-file=terraform.tfvars` (`terraform` works the same) |
| `enrich` | `scripts/enrich_variable_sets.sh <tfc-org> export/sg-payload.*.json` |
| `convert` | `for f in export/sg-payload.*.json; do scripts/convert_hcl_to_json.sh "$f"; done` (rewrites each file in place) |
| `validate` | `scripts/validate_payload.sh export/sg-payload.*.json` |
| `import` | `sg-cli workflow create --bulk --workflow-group <group> --org <org> sg-payload.<project>.json`, once per payload file |

For the import by hand, the workflow group must already exist, and sg-cli takes one payload file per group (`CLIConfiguration.WorkflowGroup.name` in the file says which). Get [sg-cli](https://github.com/StackGuardian/sg-cli) from its releases (`sg-cli_<OS>_<ARCH>.tar.gz`) and export `SG_API_TOKEN`; `--dry-run` previews a payload. Re-running the command with a modified payload updates the workflows as long as `ResourceName` stays the same. The hand path lacks what `./sg-migrate.sh import` adds: the plan, the state upload check, the version fallback, trigger registration and the checklist.

To change a workflow's settings, prefer `workspaceOverrides` in `terraform.tfvars` and a re-apply over editing the payload files. [`example_payload.jsonc`](transformer/terraform-cloud/example_payload.jsonc) is the annotated reference for the payload shape, and `schema/sg-payload.schema.json` the validation schema.

## Output files

Under `export/` (`exportPath` in `terraform.tfvars`, `--export-dir` for the scripts):

| File | Written by | Content |
|---|---|---|
| `sg-payload.<project>.json`, `sg-payload.<project>.<group>.json` | apply, enrich, convert | The workflow definitions, one file per workflow group. |
| `migration-summary.md`, `migration-summary.json` | apply | What was migrated and what needs attention: skipped sensitive variables, dropped variables, version fallbacks, renamed workspaces, workspaces whose state could not be exported, the group each project maps to. Read it before importing. |
| `states/` | apply | One Terraform state file per workspace (`exportStateFiles = false` skips the export). Real state: do not publish it. |
| `state-export-failures.log` | apply | Workspaces whose state could not be pulled, with the reason. |
| `run-result.json`, `run-summary.md` | import | The plan and its outcome, for scripts and for humans. |
| `terraform-version-fallbacks.log` | import | Workflows created with the fallback Terraform version. |
| `post-import-checklist.md` | checklist | Everything that still needs a human, with links into StackGuardian. |

Under `.sg/` (gitignored): `state.json` (completed phases, per-file import records, the region), `cached/` (downloaded tools on a native run) and the deprecated `workflow-groups.json`. `clean` removes `export/`, the transformer's local state and `.sg/cached/` and resets the run state; `clean --all` also removes `terraform.tfvars` and `.sg/`.

## Environment variables

`./sg-migrate.sh --help` lists them. When to use each:

| Variable | Use it when |
|---|---|
| `SG_API_TOKEN`, `SG_ORG` | Always; `--org` is the alternative for the organization. |
| `TFE_TOKEN` | Recommended for TFC/TFE: a long-lived token avoids re-running `terraform login`. |
| `SG_REGION`, `SG_BASE_URL`, `SG_UI_URL` | Your organization is in the US region, or you target a private StackGuardian environment. |
| `SG_TFVARS` | The tfvars file lives outside the checkout (same as `--tfvars`). |
| `SG_NATIVE=1`, `SG_TF_BIN` | Run without Docker; pick `tofu` or `terraform` for the export. |
| `SG_RETRIES` | Flaky network: more import retry attempts (default 4). |
| `SG_TF_PARALLELISM` | Many workspaces: parallelism of the export (default 20). |
| `NO_COLOR` | Plain output without colors and progress animation (automatic when the output is not a terminal). |
