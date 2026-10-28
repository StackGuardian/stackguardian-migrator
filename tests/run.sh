#!/bin/bash
# Test entrypoint, the same on the host (macOS) and in every test image.
#
# Runs the suites under /bin/bash — the migrator's shebang, so bash 3.2 on
# macOS — even when bats itself would pick a newer bash from PATH: a shim dir
# with bash -> /bin/bash goes first on PATH for the whole run.
#
# Usage: tests/run.sh [bats args...]   (default: every unit suite)

set -eu
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v bats >/dev/null 2>&1 || {
  echo "bats not found (brew install bats-core, or run 'make test-docker')" >&2
  exit 1
}

shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT
ln -s /bin/bash "$shim/bash"
PATH="$shim:$PATH"
export PATH

# What this run actually tests against.
tr_flavor() { if printf x | tr -c 'A-Za-z0-9_-\n' '-' >/dev/null 2>&1; then echo "BSD-like"; else echo "GNU"; fi; } # portable: probes the difference
sed_flavor() { if sed --version >/dev/null 2>&1; then echo "GNU"; else echo "BSD"; fi; }
printf 'platform: %s %s (%s)\n' "$(uname -s)" "$(uname -m)" "${SG_TEST_TARGET:-native}"
printf 'bash:     %s\n' "$(/bin/bash -c 'echo $BASH_VERSION')"
printf 'userland: tr %s, sed %s\n' "$(tr_flavor)" "$(sed_flavor)"
printf 'tools:    jq %s, hcl2json %s, bats %s, shellcheck %s\n' \
  "$(jq --version 2>/dev/null || echo cached)" \
  "$(command -v hcl2json >/dev/null && echo on PATH || echo cached)" \
  "$(bats --version | sed 's/^Bats //')" \
  "$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p' || true)"
echo

if [ "$#" -eq 0 ]; then set -- "$REPO/tests/unit"; fi
exec bats "$@"
