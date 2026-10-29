# Shared setup for the unit tests (loaded with `load helpers`).
#
# Sources the migrator's libraries the way migrate.sh does, with every
# path that would touch the checkout (state file, tfvars) moved into the
# test's own temp dir. Tools come from PATH (the test images install them)
# or the usual .sg/cached download.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

load_libs() {
  export NO_COLOR=1
  export SG_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  # shellcheck source=../../scripts/tools.sh
  source "$REPO/scripts/tools.sh"
  local l
  for l in prompt tfvars scope sg_api state report errors checklist; do
    # shellcheck source=/dev/null
    source "$REPO/scripts/lib/$l.sh"
  done
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
  HCL2JSON_BIN="$(sg_resolve hcl2json sg_ensure_hcl2json)"
  TFVARS="$BATS_TEST_TMPDIR/terraform.tfvars"
}

# write_tfvars <content> — the test's terraform.tfvars.
write_tfvars() {
  printf '%s\n' "$1" >"$TFVARS"
  tfvars_invalidate
}
