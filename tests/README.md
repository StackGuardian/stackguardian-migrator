# Tests

The migrator is bash that runs in three different setups: inside its Docker image (Linux, GNU tools, bash 5), natively on macOS (`/bin/bash` 3.2, BSD tools) and natively on Linux / WSL 2. The bugs that reached customers so far came from the gaps between those setups. GNU `tr` rejected a character set that macOS `tr` accepted, and bash 3.2 expanded a brace default differently. So the suite runs the same tests in each setup.

## Running

| Command | Where | What it stands for |
|---|---|---|
| `make test` | this machine | macOS: `/bin/bash` 3.2 + BSD tools, i.e. a `--native` run on a Mac |
| `make test-gnu` | the migrator's own image + test tools | every Docker run (`./sg-migrate.sh` with Docker), GNU tools, OpenTofu |
| `make test-bash32` | Debian with bash 3.2.57 as `/bin/bash`, jq 1.6 | macOS bash quirks without a Mac; an old jq |
| `make test-bsd` | Chimera Linux (FreeBSD-derived core tools) | macOS `tr`/`sed`/`grep`/`find` behavior without a Mac |
| `make test-ubuntu` | Ubuntu 24.04, no hcl2json on PATH | a `--native` run in WSL 2 / on a Linux box, including the pinned tool downloads |
| `make test-docker` | all four images | |
| `make test-all` | this machine + all four images | run this before a release |

Requirements: [bats-core](https://github.com/bats-core/bats-core) for `make test` (`brew install bats-core`), Docker for the rest. `shellcheck` is used when it is installed. The images mount the checkout read-only and keep their tool cache in the container, so a test run never changes the checkout or its `.sg/cached/`.

`tests/run.sh [bats args]` is the entrypoint of every target (e.g. `tests/run.sh -f slug tests/unit/names.bats`). It runs bats under `/bin/bash`, the scripts' shebang, even when a newer bash comes first on PATH, and prints what it is testing against:

```
platform: Darwin arm64 (native)
bash:     3.2.57(1)-release
userland: tr BSD-like, sed BSD
tools:    jq jq-1.7, hcl2json cached, bats 1.14.0, shellcheck 0.11.0
```

## What is covered

- `lint-portability.sh` is a grep-based lint for constructs that differ between GNU, BSD and bash 3.2. shellcheck doesn't check these. Examples: a `-` next to an escape in a `tr` set, `sed -i`, `date -d`, `stat -c`, `readlink -f`, `grep -P`, `timeout`, bash 4 syntax (`declare -A`, `mapfile`, `${x,,}`, `[[ -v ]]`, ...), and the two bash 3.2 expansion quirks we hit. If a line is fine as it is, mark it `# portable: <reason>`. `unit/fixtures/lint-bad.sh` keeps one bad example per rule, and `lint.bats` checks that each one is flagged.
- `unit/lint.bats` runs the lint on the repo, then `bash -n` with `/bin/bash`, then shellcheck. shellcheck checks the libraries through `migrate.sh`, with SC2034 off because the parser sets globals that the libraries read.
- `unit/names.bats` covers secret names, project slugs, the Terraform version ceiling, duration and column helpers, and UI links.
- `unit/scope.bats` covers `ws_selected` and `project_selected`, and checks that the bash globs and the jq globs (`WS_SCOPE_JQ`) select the same workspaces.
- `unit/tfvars.bats` covers reading (`false`, explicit `null`, the run overlay), the HCL string and map writers, the wizard's file and `init --upgrade`.
- `unit/sg_api.bats` covers the variable merge modes, the execution-preset fill and descriptions, connector lookups, and the API error hints.
- `unit/state_tools.bats` covers the run state (phase hashes, import records, replaced workflows), `sg_sha`, `sg_retry` and `sg_tf_bin`.

To confirm the suite does its job, run it against the code before the fixes in this change. The old `secret_name_for` fails on `gnu` and `bash32` with the customer's error (`tr: range-endpoints of '_-\012' are in reverse collating sequence order`), and the lint flags it on every target. The old `_tfvars_str` fails on `bash32` and natively on macOS.

## Not covered yet (next layers)

1. **Integration tests for the import flow.** Commit a mock SG API (`tests/mock/sg_api.py`) and fixture payloads, then run `import` end to end with the real `sg-cli` against the mock. That covers the plan, create/update/skip, PATCH on a 409, the version-ceiling fallback, state upload and retry, triggers, secret stubs, the checklist, `run-result.json`, `--dry-run`, the scope flags and the three vars modes. This has been done by hand before. The switches the mock needs are known: existing groups and workflows, a 409 for an existing name, the ceiling 400, an Azure-style state PUT, and failing a chosen workflow.
2. **Wrapper tests.** Run `sg-migrate.sh` with a fake `docker` on PATH to check the `--tfvars` path rewriting, the env it forwards, and when it runs natively instead. Test `update` against a local git remote: dirty tree, detached HEAD, fast-forward, and a rebuild only when the `Dockerfile` changed.
3. **Transformer tests.** Use `tofu test` with `override_data` for the four `tfe` data sources, so TFC isn't needed. That covers naming and collisions, override precedence, payload file splits, carry vs. preset version, `stripCloudAuthVars` and the preconditions.
4. **CI.** None for now. When it comes, the Make targets are the jobs. A `macos-latest` runner can run `make test` natively, but hosted Windows runners can't run Linux containers.

## Open items

- **Real macOS is only tested where a developer runs `make test`.** The `bsd` and `bash32` images come close: Chimera's `tr` accepts `_-\n` like macOS, and the Linux bash 3.2 build reproduces the macOS `$$\{` quirk. They are not macOS, though. Apple's tools are older FreeBSD versions with their own patches.
- **Windows is covered as WSL 2 only** (the documented setup): the `ubuntu` target plus `gnu` for the container. Git Bash or MSYS isn't tested or supported. It would need `MSYS_NO_PATHCONV` for the `docker -v` arguments.
- **`hcl2json` doesn't unescape `$${` / `%%{`.** OpenTofu reads `"$${x}"` as `${x}`, but the scripts' `tfvars_get` sees `$${x}`. This only affects names that contain a template sequence, which no real connector or org name does. The test checks the HCL text for that case.
- **The `ubuntu` target needs network at test time.** It downloads hcl2json into its cache, which is the point of that target.
- **Switching between terraform and tofu on one checkout** was checked by hand with the `local` and `null` providers (both directions plan "No changes"), not with `tfe`. The transformer test layer should cover it.
- **The `bsd` image is pinned by digest**, so its userland doesn't change under the tests. To refresh it, pull `chimeralinux/chimera` and update the digest in `docker/Dockerfile.bsd`.
