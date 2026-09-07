#!/bin/bash
# Read access to transformer/terraform-cloud/terraform.tfvars (sourced; needs
# tools.sh and TFVARS to be set). The file is converted once with hcl2json and
# cached for the life of the process.

_TFVARS_JSON=""
_TFVARS_JSON_FOR=""

# tfvars_json — the whole tfvars file as JSON (empty object when missing).
tfvars_json() {
  if [ -z "$_TFVARS_JSON" ] || [ "$_TFVARS_JSON_FOR" != "$TFVARS" ]; then
    if [ -f "$TFVARS" ]; then
      _TFVARS_JSON="$("$(sg_resolve hcl2json sg_ensure_hcl2json)" "$TFVARS" 2>/dev/null || echo '{}')"
    else
      _TFVARS_JSON='{}'
    fi
    _TFVARS_JSON_FOR="$TFVARS"
  fi
  printf '%s' "$_TFVARS_JSON"
}

# tfvars_get <jq-expr> [default] — raw value of an expression over the tfvars
# JSON, e.g. tfvars_get '.tfOrg'. Prints the default when null/missing.
tfvars_get() {
  local expr="$1" def="${2-}" v
  v="$(tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -r "$expr // empty" 2>/dev/null || true)"
  printf '%s' "${v:-$def}"
}

# tfvars_get_json <jq-expr> — compact JSON value of an expression (or null).
tfvars_get_json() {
  tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -c "$1 // null" 2>/dev/null || echo null
}

# tfvars_invalidate — forget the cached conversion (after writing the file).
tfvars_invalidate() { _TFVARS_JSON=""; }
