# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A migration tool that extracts workloads from other IaC platforms and transforms them into StackGuardian Workflow definitions (`sg-payload.json`), ready for bulk import via [sg-cli](https://github.com/StackGuardian/sg-cli). Currently the only implemented source is **Terraform Cloud / Enterprise (TFC/TFE)**.

There is no application code to build — the "engine" is Terraform itself. The migrator is a Terraform root module that uses the `tfe` provider to read workspaces and the `local`/`null` providers to write the output payload and pull state files.

## Architecture

The migration is a user-driven pipeline, not a single program:

1. **Extract + transform** — `transformer/terraform-cloud/` is a Terraform root module. `terraform apply` reads TFC/TFE workspaces and emits one `<exportPath>/sg-payload.<project>.json` per TFC project, a `migration-summary.md`/`.json` report, and per-workspace `.tfstate` files when `exportStateFiles` is true.
2. **Enrich (variable sets)** — `scripts/enrich_variable_sets.sh` merges TFC Variable Set variables into the payloads via the TFC API (the provider can't enumerate sets). Resolves global/project/workspace scope + TFC precedence per workspace; non-sensitive only.
3. **Tuning** — adjust per-workspace differences (integration IDs, VCS auth, runners, approvers, version) via the `workspaceOverrides` variable and re-apply; or hand-edit the payload files. `example_payload.jsonc` is the annotated field reference.
4. **HCL→JSON conversion** — `scripts/convert_hcl_to_json.sh` rewrites HCL-string variable values in each payload to real JSON.
5. **Validation** — `scripts/validate_payload.sh` checks each payload against `schema/sg-payload.schema.json` (downloads `yajsv`).
6. **Import** — `sg-cli workflow create --bulk`, run once per project file, each into its own workflow group.

### Orchestration & tooling

The five phases are wrapped by an orchestrator so users don't run them by hand:

- `sg-migrate.sh` (host entrypoint, repo root) — runs `scripts/migrate.sh` **inside the Docker image** (`Dockerfile`), bind-mounting the repo at `/app` and forwarding `SG_API_TOKEN`/`SG_ORG`/`SG_BASE_URL`/`TFE_TOKEN`/`TF_TOKEN_*`. For TFC auth it prefers a long-lived `TFE_TOKEN` (env); otherwise it mounts `~/.terraform.d/credentials.tfrc.json` read-only. Runs natively instead when `--native`/`--local` is passed, `SG_NATIVE=1` is set, the command is `clean`/`completion`/help (or no command is given), or Docker is absent. Exports `SG_PROG` so `migrate.sh` shows `./sg-migrate.sh` in its usage/hints.
- `scripts/migrate.sh` — the actual orchestrator (sources `scripts/lib/*.sh`, see below). Subcommands `init|preflight|apply|enrich|convert|validate|import|triggers|checklist|all|clean|completion` (no command prints the help menu; `enrich` runs in `all` unless `--no-variable-sets`). Flags beyond the basics: `--dry-run` (import: plan only), `--fresh` (ignore run state), `--project SEG` / `--workspace NAME` (repeatable filters; apply maps `--workspace` to `-var workspacenames=[...]`, import works on a jq-filtered temp copy), `--skip-preflight`, `--no-secret-stubs`. Resolves each tool via `sg_resolve` (PATH first — the image installs them — else `sg_ensure_*` cache). `apply`/`all` first run `require_tfc_auth`, which resolves the token the tfe provider will use (`TFE_TOKEN`, `TF_TOKEN_<host>`, or the `terraform login` file for `tfHostname`) and verifies it with `GET /api/v2/account/details`, failing fast on a missing or rejected (expired) credential. Runs `convert` and `import` in parallel (`--concurrency`, default 4), raises `terraform apply -parallelism`, and retries `sg-cli` imports with backoff (`sg_retry`, `SG_RETRIES`). Import resolves each project's workflow group, checks existence via the SG API, shows a plan (`exists`/`create`), prompts (skip with `-y`), **creates the missing `tfc-<project>` groups via the API**, then imports. sg-cli exits 0 even when individual workflows fail, so `do_import` parses its output: a workflow rejected as above SG's managed Terraform ceiling (1.5.7, last MPL/FOSS release) is re-imported with `SGDefaultTerraformVersion` (read from `terraform.tfvars`), the payload patched in place, and the case logged to `export/terraform-version-fallbacks.log` plus a printed notice; any other per-workflow failure fails the run. The trigger pass skips workflows that do not exist in SG, and `sg_api_post` returns 22 on 4xx so `sg_retry` (via `SG_NO_RETRY_RC`) does not retry definitive errors. `clean` removes local artifacts (`export/`, TF state, tool cache); `clean --all` also removes config. `completion bash|zsh` prints a completion script (`cmd_completion`; commands/options come from `SG_COMMANDS`/`SG_OPTIONS`, keep them in sync with the parser and the host flags); like `clean` it always runs natively. Output is concise by default — `apply` captures terraform's init/plan output and shows only progress + the final summary (or the full log on failure, `TF_IN_AUTOMATION=1`/`-no-color`); `-v`/`--verbose` (`SG_VERBOSE`) streams everything and un-gates the convert detail lines. Colored logging via `sg_step`/`sg_log`/`sg_success`/`sg_warn`/`sg_err`; paths shown relative via `sg_rel` (all auto-off when not a TTY / `NO_COLOR`).
- `scripts/lib/` — sourced libraries (a `lib/` gitignore rule is negated for this dir): `prompt.sh` (`sg_ask`/`sg_confirm`/`sg_select`; tty or `SG_ANSWERS_FILE` for tests; `SG_NONINTERACTIVE=1`/`-y`/no TTY → defaults), `tfvars.sh` (`tfvars_get` cached hcl2json reads, `tfvars_write` renders the wizard's `W_*` vars), `tfc_api.sh` (`tfc_http`/`tfc_get_all` paginated, `tfc_list_{orgs,projects,workspaces}`, `tfc_token` with provider precedence, `require_tfc_auth`), `sg_api.sh` (`_sg_api` 0/22/1 contract + `SG_HTTP_CODE`, `sg_list_integrations`, `sg_*_exists`, `sg_list_workflows`, `sg_create_secret`, `sg_patch_workflow`, `wfgroup_*`), `wizard.sh` (`wizard_run`: 4 steps TFC → SG → defaults → review), `preflight.sh` (`preflight_run <apply|import|all>`, once per process), `state.sh` (`.sg/state.json`: `phases.<name>.input_sha`, `import.<seg>.{imported,failed,tf_fallback}`, `triggers.<seg>`, `secrets.<name>`; `run_phase` in migrate.sh skips unchanged phases), `report.sh` (`show_migration_summary` after apply, `show_import_plan` per-workflow table), `errors.sh` (`explain_api_error` regex→hint table, `SG_API_HINTS`), `checklist.sh` (`create_secret_stubs` → SG secret `tfc-<wf>-<VAR>` = `CHANGE_ME`, referenced as `${secret::<name>}` via PATCH + payload patch; `write_checklist` → `export/post-import-checklist.md`). Parallel jobs (`run_parallel`) run in subshells, so `do_import`/`do_set_triggers` write `.import-result.<seg>.json` / `.triggers-result.<seg>.json` into the export dir and the caller merges them into state.
- `scripts/tools.sh` — sourced by the other scripts (sets `SG_REPO_ROOT` to its parent dir). Provides `sg_resolve` (PATH-or-cache), `sg_ensure_{jq,hcl2json,yajsv,sgcli}` (pinned downloads into `.sg/cached/`; `sg-cli` is the Go binary), `sg_retry`, the color vars + log helpers. The Docker image bundles these tools at build time (`yajsv` built from source so arm64 works), so in-container runs never download.
- **Variable sets** — `scripts/enrich_variable_sets.sh <tfc-org> <payload...>` (run by `cmd_enrich`, which reads `tfOrg`/`tfHostname` from `terraform.tfvars` via `hcl2json` — variable sets live in the **TFC** org, not `SG_ORG`). Lists all sets + vars via the TFC API (Bearer token from the `terraform login` creds file or `TFE_TOKEN`), computes per-workspace effective vars (scope: global/project/workspace; precedence: priority sets > workspace vars > non-priority sets), and merges them into each workflow (matched by workspace name parsed from `TfStateFilePath`). Sensitive set vars and key conflicts are reported. Skipped by `--no-variable-sets`.
- **Workflow groups** — each TFC project maps to an SG workflow group `tfc-<project-segment>`, created via `POST /api/v1/orgs/{org}/wfgrps/` (auth `Authorization: apikey <token>`) if missing. (Both the API calls and sg-cli honor the undocumented `SG_BASE_URL` for non-prod targets.) Groups are addressed by name, so no generated ID is tracked. `.sg/workflow-groups.json` (gitignored, optional) overrides the target group per segment (`{"<segment>": "<existing-group>"}`); override groups are not auto-created. `--no-create-groups` requires all groups to pre-exist.

### The transformer (`transformer/terraform-cloud/`)

The whole transformation lives in `locals.tf` — there are no `outputs.tf`/`main.tf` business logic files; `main.tf` only pins provider versions.

- `data.tf` — four data sources: `tfe_workspace_ids` (selects workspaces by name/tags), `tfe_workspace` (per-workspace details), `tfe_variables` (per-workspace variables), `tfe_projects` (project id→name, used to name per-project payload files).
- `locals.tf` — builds `local.workflowPayload` (workspace name → SG workflow object), groups it into `local.payloadByProject`, and assembles `local.summary`. This is the core mapping from TFC concepts to StackGuardian's payload schema. Key mappings:
  - TFC `terraform` (non-sensitive) variables → `VCSConfig.iacInputData.data` (kept as strings here; `try(jsondecode(...), v.value)` only decodes values that are already valid JSON).
  - TFC `env` (non-sensitive) variables → `EnvironmentVariables` as `PLAIN_TEXT`.
  - `auto_apply` → inverted into `approvalPreApply` / gated `Approvers`.
  - `terraform_version` → `TERRAFORM-<version>` only for a pinned semver; otherwise `SGDefaultTerraformVersion`.
  - `project_id` → `CLIConfiguration.WorkflowGroup.name` = `tfc-<project-segment>` (matches the per-project filename and the group the importer creates/targets).
  - Sensitive variables (terraform + env) are skipped and recorded in the summary.
  - Per-workspace `var.workspaceOverrides[<name>]` fields take precedence over the `SGDefault*` values (resolved via `try(var.workspaceOverrides[name].<field>, null) != null ? ... : <default>`).
  - `local.resourceNames` sanitizes workspace names to a valid SG `ResourceName` (≤100 chars, `^[-a-zA-Z0-9_]+$`, collision-disambiguated). For normal TFC names this is a no-op; any actual rename is reported in the summary. This is the single place to adjust naming rules.
- `resources.tf` — writes one `sg-payload.<project>.json` per project directly via `for_each` (no `mv`), plus `migration-summary.{md,json}`. When `exportStateFiles=true`, `null_resource.exportState` pulls each workspace's state **directly from the TFC/TFE API** (`GET /api/v2/workspaces/{id}/current-state-version` → `hosted-state-download-url`) via a `local-exec` `curl`/`jq` script — no `terraform init` or providers per workspace (avoids the plugin-cache concurrency bug and per-workspace provider downloads). The token is read at runtime from `~/.terraform.d/credentials.tfrc.json` (the `terraform login` file) or `TFE_TOKEN`, so it never enters TF state. Idempotent (keyed by workspace name/id; `forceStateRefresh` re-pulls), with per-workspace failures (no token / no state / download error) recorded in `state-export-failures.log` instead of aborting. `cmd_apply` ensures `jq`/`curl` are on PATH for the apply.
- `summary.tmpl` — renders `local.summary` to `migration-summary.md`.
- `variables.tf` / `terraform.tfvars.example` — inputs. `SGDefault*` variables supply global defaults baked into every workflow (deployment platform, VCS auth, repo prefix, source kind, approvers, Terraform version, runner constraints — `SGDefaultRunnerConstraints`, validated to `shared` or `private`+`names`); `workspaceOverrides` overrides them per workspace; `forceStateRefresh` controls state re-pull. Requires Terraform `>= 1.3` (for `optional()` object attributes).

### `scripts/convert_hcl_to_json.sh`

Run from repo root, once per payload file (`for f in export/sg-payload.*.json; do ./scripts/convert_hcl_to_json.sh "$f"; done`). Rewrites the file **in place** (atomically — writes to a temp file, then `mv`s over the original). Downloads pinned `jq` and `hcl2json` binaries to a temp dir at runtime. For each workflow it walks `.VCSConfig.iacInputData.data` and, for any string value that looks like an HCL object/list (`{`/`[`), wraps it as `temp = <value>` and pipes through `hcl2json` to get real JSON. Plain scalar strings (ids, names) and already-converted objects pass through untouched.

### `scripts/validate_payload.sh` + `schema/`

`schema/sg-payload.schema.json` is a self-contained draft-07 schema for the generated payload array, with constraints (ResourceName length, `kind`/`sourceConfigDestKind` enums) derived from the StackGuardian OpenAPI spec (request body `#/components/schemas/Workflow`). The OpenAPI spec is **not committed** — download it from the [API Explorer](https://docs.stackguardian.io/api-reference/) if the schema needs regenerating. The schema is intentionally lenient (unknown fields allowed) — it checks the fields the transformer emits, not every optional API field. `scripts/validate_payload.sh` downloads `yajsv` and validates one or more payload files against it.

## Common commands

```shell
# Run the transformer
cd transformer/terraform-cloud
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply -auto-approve -var-file=terraform.tfvars

# Convert HCL-string vars to JSON, then validate (from repo root, per file)
for f in export/sg-payload.*.json; do ./scripts/convert_hcl_to_json.sh "$f"; done
./scripts/validate_payload.sh export/sg-payload.*.json

# Bulk import (from the export dir, sg-cli fetched per README) — once per project file
export SG_API_TOKEN=<token>
./sg-cli workflow create --bulk --workflow-group "<WFGRP_ID>" --org "<ORG>" -- sg-payload.<project>.json
```

`terraform login` must be run first so the `tfe` provider can authenticate to TFC/TFE.

## Conventions

- Terraform variable/local naming is **camelCase** (e.g. `workflowNames`, `exportStateFiles`, `SGDefaultVCSAuthIntegrationID`) — not the usual snake_case. Match it.
- Output payload keys are PascalCase to match StackGuardian's API schema (`ResourceName`, `DeploymentPlatformConfig`, `VCSConfig`, ...). Keep `example_payload.jsonc` in sync when you change the generated shape.
- Run `terraform fmt` on `.tf` changes (see commit history).
- `export/`, `*.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — they hold generated output and secrets.

## Adding a new source platform

The `transformer/` directory is the extension point: each platform is its own self-contained Terraform root module (mirror `terraform-cloud/`). The contract a transformer must satisfy is producing `sg-payload.*.json` arrays matching `example_payload.jsonc`; everything downstream (`scripts/convert_hcl_to_json.sh`, sg-cli import) is platform-agnostic.
