# StackGuardian Migrator

Move your Terraform Cloud or Terraform Enterprise workspaces to [StackGuardian](https://app.stackguardian.io). Every workspace becomes a StackGuardian workflow in a workflow group named after its TFC project, with its Terraform state, its variables and variable sets, and its VCS triggers. Sensitive values, which TFC does not expose, are recreated as placeholder secrets for you to fill in.

Supported source platforms: Terraform Cloud and Terraform Enterprise.

## What you need

- A StackGuardian organization and an API token (profile menu at the bottom left → API key).
- A Terraform Cloud/Enterprise API token (User Settings → Tokens, or a team or organization token).
- `git` and Docker. Without Docker the migrator runs on your machine instead and needs OpenTofu or Terraform 1.3 or newer; the other tools are downloaded on first use.
- Optional, but it makes setup quicker: the cloud connectors, VCS connectors and private runner groups the workflows should use, created in StackGuardian first so the setup can offer them.

**Windows.** Run the migrator from a WSL 2 distribution with Docker Desktop's WSL integration enabled. Clone inside the Linux file system (for example `~/stackguardian-migrator`, not under `/mnt/c/`) and set `TFE_TOKEN` inside WSL.

## Quick start

```shell
git clone https://github.com/StackGuardian/stackguardian-migrator.git
cd stackguardian-migrator

export TFE_TOKEN=<Terraform Cloud/Enterprise token>
export SG_API_TOKEN=<StackGuardian API token>
export SG_ORG=<StackGuardian organization>

./sg-migrate.sh init   # guided setup, writes terraform.tfvars
./sg-migrate.sh all    # export, plan, import (asks before importing)
```

`init` lists what your tokens can see and asks which TFC projects and workspaces to migrate, which StackGuardian connectors and runners the workflows should use, and whether the same settings apply to every project. It writes the answers to `transformer/terraform-cloud/terraform.tfvars`, which you can edit by hand at any time.

`all` verifies every reference before it starts, exports the workspaces, shows a per-workflow plan (create or update, Terraform version, runner, triggers, secrets) and asks for confirmation before anything is created in StackGuardian. It ends with a checklist of what still needs a human.

If your organization is in the US region, run `init` with `--region us` once; it is remembered. Tab completion for the current shell: `source <(./sg-migrate.sh completion)`.

## What you get

Everything lands in `export/`:

| File | What it is |
|---|---|
| `sg-payload.<project>.json` | The workflow definitions, one file per TFC project (and per workflow group). |
| `migration-summary.md` | What was migrated and what was left out, per workspace. Read it before confirming the import. |
| `run-summary.md`, `run-result.json` | The import plan and its outcome, for humans and for scripts. |
| `post-import-checklist.md` | What still needs a human after the import, with links into StackGuardian. |
| `states/` | The Terraform state of every workspace. This is real state: keep it out of artifacts and version control. |

## After the import

The checklist lists, with a link per workflow:

- **Secrets to fill in.** Sensitive TFC variables are recreated as StackGuardian secrets named `tfc-<workflow>-<VAR>` with the value `CHANGE_ME`. Set the real values in the StackGuardian UI.
- **Workflows on a different Terraform version.** StackGuardian's managed Terraform goes up to 1.5.7; workspaces pinned above it are imported with your default version. Check them before their first run.
- **Renamed workflows**, when a workspace name was not a valid workflow name.
- **Failed imports, trigger registrations or state uploads**, which the next run retries.

## Common tasks

**Migrate one project or team first.** Flags narrow a run, and every phase applies the same selection.

```shell
./sg-migrate.sh all --project Payments
./sg-migrate.sh all --workspace 'team-*' --exclude-workspace '*-sandbox'
./sg-migrate.sh all --tag migrate-now
```

**Preview without changing anything.** The export runs locally, the plan is printed and written to `export/run-summary.md`, and nothing is created in StackGuardian.

```shell
./sg-migrate.sh all --dry-run
```

**Re-run, resume, start over.** A run remembers what it completed. After a failure, or when `terraform.tfvars` changed, run `all` again: unchanged phases are skipped, workflows that already exist are updated, and files that were imported in full are left alone. Variables you added in StackGuardian are kept on a re-import; the migrated ones follow TFC (see [Variables](REFERENCE.md#variables) for the other modes). `--fresh` redoes everything.

**Different settings per project or workspace.** Set `projectOverrides` (per TFC project) or `workspaceOverrides` (per workspace) in `terraform.tfvars` for the cloud connector, VCS connector, runners, approvers, Terraform version and target group. A workspace setting wins over a project setting, which wins over the defaults. `init` writes `projectOverrides` for you when you answer that the connectors differ per project. The [example file](transformer/terraform-cloud/terraform.tfvars.example) shows every field.

**Pass connectors and the group on the command line.** For a run driven from a pipeline, the connectors can be given as flags instead of edited into the file. Only the connector id is needed; its kind is looked up in StackGuardian.

```shell
./sg-migrate.sh -y all --project Payments \
  --workflow-group payments-prod --cloud-connector aws-payments --vcs-connector github_payments
```

**Private runners or the execution preset.** Set `SGDefaultRunnerConstraints = { type = "private", names = ["<runner-group>"] }` in `terraform.tfvars` to run every workflow on a private runner group, or leave the version and runners to your organization's execution preset. `init` offers both, with your current preset shown.

**Run it from CI.** Generate `terraform.tfvars` once on a workstation, keep it next to the pipeline and pass it with `--tfvars`. Run `all --dry-run` on a pull request and `-y all` on merge, publish `export/run-summary.md`, and cache `.sg/` and `export/` between runs. See [Running in CI](REFERENCE.md#running-in-ci).

**Update the migrator.** Clone the repository rather than downloading a release, then:

```shell
./sg-migrate.sh update          # git pull --ff-only, rebuilds the image if needed
./sg-migrate.sh init --upgrade  # add the settings a new version introduced to terraform.tfvars
```

Your `terraform.tfvars`, `export/` and `.sg/` are never tracked and survive every update. To stay on a release, check out its tag.

## When something goes wrong

- Preflight fails before anything runs and names the `terraform.tfvars` field to fix. Re-run `init` or edit the file.
- Add `-v` to see the full output of OpenTofu, sg-cli and the other tools. By default only progress and results are shown.
- A run that stopped is resumed by running `all` again. Workflows that were created are updated, not duplicated.
- `export/state-export-failures.log` and `export/terraform-version-fallbacks.log` explain per-workspace problems; `export/migration-summary.md` lists everything that was skipped.
- `./sg-migrate.sh clean` removes `export/`, the run state and the tool cache for a clean start; `clean --all` also removes `terraform.tfvars`.

## Commands and options

```shell
./sg-migrate.sh --help
```

lists every command (`init`, `preflight`, `apply`, `enrich`, `convert`, `validate`, `import`, `triggers`, `checklist`, `all`, `clean`, `completion`, `update`), every flag and every environment variable. Each phase of `all` can be run on its own.

## Limits to know before you start

- **Sensitive values cannot be read from TFC.** They become `CHANGE_ME` secrets to fill in. [Variables](REFERENCE.md#variables)
- **Terraform above 1.5.7 is not bundled** by StackGuardian's managed runtimes. Such workflows fall back to your default version unless a private runner provides the binary. [Settings and precedence](REFERENCE.md#settings-and-precedence)
- **Workflows are never moved or renamed.** A changed target group stops the plan; a changed name imports a new workflow next to the old one. [Workflow groups and names](REFERENCE.md#workflow-groups-and-names)
- **TFC-specific and cloud credential variables are not migrated.** `TFC_*`/`TFE_*` variables and the `AWS_*`/`ARM_*`/`GOOGLE_*` credentials the connector replaces are dropped and listed in the summary. [Variables](REFERENCE.md#variables)
- **A re-import updates existing workflows** in place; the plan shows which. [Import behavior](REFERENCE.md#import-behavior)

## Documentation

- [REFERENCE.md](REFERENCE.md): how a run works, every setting and its precedence, what happens to variables, groups and names, the import behavior, CI, and running the phases by hand.
- [terraform.tfvars.example](transformer/terraform-cloud/terraform.tfvars.example): every setting with a comment.
- [example_payload.jsonc](transformer/terraform-cloud/example_payload.jsonc): the annotated workflow payload the transformer produces.
- [tests/README.md](tests/README.md): running the test suite.
