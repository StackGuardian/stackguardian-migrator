# Git VCS Transformer

Create StackGuardian workflows from Terraform repositories hosted on GitHub or GitLab.

This transformer connects to your VCS provider, discovers all Terraform repositories, and generates an `sg-payload.json` that can be used to bulk-create workflows on the [StackGuardian Platform](https://app.stackguardian.io).

## How it works

1. **Discover** — Lists repositories in your GitHub org or GitLab group via API
2. **Scan** — Fetches the file tree of each repo and detects directories containing `.tf` files
3. **Transform** — Maps each Terraform project to a StackGuardian workflow payload, inferring:
   - Terraform version (from `required_version`)
   - Cloud provider (from `provider` blocks → `DeploymentPlatformConfig`)
   - VCS source config (repo URL, branch, working directory)
   - Extra CLI args (when `.tfvars` files are detected)
4. **Output** — Writes `sg-payload.json` for review and bulk import

## Prerequisites

- Python 3.10+
- A GitHub PAT or GitLab PAT with repo read access
- [sg-cli](https://github.com/StackGuardian/sg-cli) for importing workflows

## Install

```bash
cd transformer/git-vcs
pip install .
```

## Usage

```bash
# Scan a GitHub organization
sg-git-scan --provider github --token ghp_xxx --org my-org

# Scan a GitLab group
sg-git-scan --provider gitlab --token glpat-xxx --org my-group

# Limit to 50 repos, custom output path
sg-git-scan --provider github --token ghp_xxx --org my-org --max-repos 50 --output export/sg-payload.json
```

## CLI Options

```
Required:
  --provider, -p       VCS provider (github or gitlab)
  --token, -t          VCS access token

Target:
  --org, -o            Organization (GitHub) or group (GitLab)
  --user, -u           User whose repos to scan

Filtering:
  --max-repos, -m      Maximum repositories to scan
  --include-archived   Include archived repositories
  --include-forks      Include forked repositories

StackGuardian defaults:
  --wfgrp              Workflow group name (default: imported-workflows)
  --vcs-auth           SG VCS integration path (e.g., /integrations/github_com)
  --managed-state      Enable SG-managed Terraform state

Output:
  --output, -O         Output file (default: sg-payload.json)
  --quiet, -q          Minimal output
  --verbose, -v        Debug output
```

## After generating sg-payload.json

Use the `example_payload.jsonc` file as a reference and edit the `sg-payload.json` to configure:

- `DeploymentPlatformConfig` — Cloud connector (AWS/Azure/GCP integration ID)
- `VCSConfig.customSource.config.auth` — VCS integration for private repos
- `RunnerConstraints` — Shared or private runner
- `Approvers` — Approval emails
- `MiniSteps` — Notifications and workflow chaining
- `EnvironmentVariables` — Env vars for the workflows

### Bulk import workflows to StackGuardian Platform

```bash
export SG_API_TOKEN=<YOUR_SG_API_TOKEN>
sg-cli workflow create --bulk --org "<ORG NAME>" -- sg-payload.json
```

## Output Format

The `sg-payload.json` is a JSON array of workflow definitions. See `example_payload.jsonc` for the full annotated schema.

Each workflow maps:

| SG Field | Source |
|---|---|
| `ResourceName` | Repo name (+ subdir for monorepos) |
| `WfType` | `TERRAFORM` |
| `TerraformConfig.terraformVersion` | Parsed from `required_version` in `.tf` files |
| `VCSConfig.customSource.config.repo` | Repository URL |
| `VCSConfig.customSource.config.ref` | Default branch |
| `VCSConfig.customSource.config.workingDir` | Subdirectory (for monorepos) |
| `DeploymentPlatformConfig` | Inferred from providers (placeholder if unknown) |
| `Tags` | Repo topics + `terraform` |
