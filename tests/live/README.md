# Live tests

The unit suites and the portability lint (`make test`) never call an API. The
live tests run the whole migrator against a real TFC/TFE org and a
StackGuardian **sandbox** org, then check through the API what landed there.
They catch what the mocks can't: pagination, 409s, the execution preset, state
uploads, nested workflow groups, and what TFC returns for variable sets.

They are for maintainers. They need two orgs you are free to change, and they
are not part of `make test-all`.

## Setup (once)

1. Run `terraform login` (or export `TFE_TOKEN`) for a TFC org you own.
2. Store a StackGuardian API token for the sandbox org in 1Password.
3. Write an env file outside the checkout, for example
   `~/.config/sg-migrator-test/env.tpl`. It holds `op://` references only,
   never values:

   ```
   SG_API_TOKEN=op://<vault>/<item>/credential
   SG_ORG=<sandbox org>
   SG_BASE_URL=<the sandbox org's API URL>
   SG_UI_URL=<its UI URL>
   SG_LIVE_ALLOWED_ORGS=<sandbox org>
   TFC_ORG=<tfc org>
   TF_VAR_tfc_org=<tfc org>
   TF_VAR_vcs_repo=<owner/repo, any repository the org's VCS connection can read>
   TF_VAR_github_app_installation_id=<ghain-..., the org's GitHub App installation>
   ```

   Optional settings:
   - `SG_LIVE_ROOT_GROUP` (default `tfc-migration`);
   - `SG_LIVE_PREFIX` (default `mig-test`);
   - `SG_LIVE_VCS_CONNECTOR` / `SG_LIVE_CLOUD_CONNECTOR`: the sandbox's connector names;
   - `SG_LIVE_DIR`: the sandbox checkout, default `$TMPDIR/sg-migrator-live`.
4. Run `make live-seed`. It creates the fixture in TFC (`tfc-fixture/`):
   - two projects, six workspaces and four variable sets, all named `<prefix>-*`;
   - a small state in every workspace.

   Nothing outside those projects and sets is changed. The fixture's state is
   kept locally in `tfc-fixture/` and is gitignored.

## Running

```shell
make test-live                         # every scenario, in order
make test-live SCENARIOS="dryrun all"  # some of them
make live-clean                        # remove what the tests created in StackGuardian
SG_LIVE_DOCKER=1 make test-live        # through the Docker wrapper instead of --native
```

Each run does the following:
- cleans the StackGuardian side;
- copies the checkout into the sandbox dir, leaving out `export/`, `.sg/`, tfvars
  and state, so the real checkout is never touched;
- writes the sandbox's `terraform.tfvars` (the fixture projects only, everything
  under the root group);
- runs the scenarios one after another, since later ones build on the import of `all`.

Each migrator run's output is kept in the sandbox as `log.<scenario>.<step>`.
Each check prints one of three marks:
- `✓`: passed;
- `✗`: failed;
- `!`: a known bug the suite pins. It turns into `✗` once the bug is fixed, so
  the pin gets removed.

## Guards

- The run refuses to start when `SG_ORG` is not in `SG_LIVE_ALLOWED_ORGS`, or
  when `SG_BASE_URL` is a production API, unless `SG_LIVE_ALLOW_PROD=1`.
- Everything goes under one parent workflow group (`SGParentWorkflowGroup`).
  Cleanup deletes only:
  - the workflows and child groups inside it;
  - the secrets the sandbox's state recorded, or that carry the fixture prefix.

  The root group itself stays.
- The token reaches `curl` through stdin, never the command line. `op run` masks
  it in the output.
