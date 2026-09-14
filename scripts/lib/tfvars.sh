#!/bin/bash
# Read access to transformer/terraform-cloud/terraform.tfvars (sourced; needs
# tools.sh and TFVARS to be set). The file is converted once with hcl2json and
# cached for the life of the process.

_TFVARS_JSON=""
_TFVARS_JSON_FOR=""

# tfvars_json — the whole tfvars file as JSON (empty object when missing),
# merged with the run's configuration overlay (TFVARS_OVERLAY_JSON from
# lib/scope.sh: --set / --cloud-connector / ...), so every reader sees the
# values the run actually uses. Objects merge deeply, so an overlay entry for
# one project keeps the other projectOverrides of the file.
tfvars_json() {
  local overlay="${TFVARS_OVERLAY_JSON:-{\}}"
  if [ -z "$_TFVARS_JSON" ] || [ "$_TFVARS_JSON_FOR" != "$TFVARS|$overlay" ]; then
    if [ -f "$TFVARS" ]; then
      _TFVARS_JSON="$("$(sg_resolve hcl2json sg_ensure_hcl2json)" "$TFVARS" 2>/dev/null || echo '{}')"
    else
      _TFVARS_JSON='{}'
    fi
    if [ "$overlay" != "{}" ]; then
      _TFVARS_JSON="$(printf '%s' "$_TFVARS_JSON" | "$(sg_resolve jq sg_ensure_jq)" -c --argjson o "$overlay" '. * $o')"
    fi
    _TFVARS_JSON_FOR="$TFVARS|$overlay"
  fi
  printf '%s' "$_TFVARS_JSON"
}

# tfvars_get <jq-expr> [default] — raw value of an expression over the tfvars
# JSON, e.g. tfvars_get '.tfOrg'. Prints the default when null/missing.
tfvars_get() {
  local expr="$1" def="${2-}" v
  # Not `// empty`: jq's // also swallows false, and false is a real value here
  # (stripCloudAuthVars = false, exportStateFiles = false).
  v="$(tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -r "[$expr][0] | if . == false then \"false\" else (. // empty) end" 2>/dev/null || true)"
  printf '%s' "${v:-$def}"
}

# tfvars_get_json <jq-expr> — compact JSON value of an expression (or null).
tfvars_get_json() {
  tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -c "[$1][0] | if . == false then false else (. // null) end" 2>/dev/null || echo null
}

# tfvars_has <key> — exit 0 when the top-level key is present in the file (an
# explicit `key = null` counts as present; a missing key means the variable's
# default applies).
tfvars_has() {
  tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -e --arg k "$1" 'has($k)' >/dev/null 2>&1
}

# tfvars_is_null <key> — exit 0 when the file sets the key to null explicitly.
tfvars_is_null() {
  tfvars_has "$1" && [ "$(tfvars_get_json ".$1")" = "null" ]
}

# tfvars_invalidate — forget the cached conversion (after writing the file).
tfvars_invalidate() { _TFVARS_JSON=""; }

# tfvars_valid — exit 0 when the file exists and hcl2json can parse it;
# the parser's message is printed on stdout otherwise.
tfvars_valid() {
  [ -f "$TFVARS" ] || return 1
  # shellcheck disable=SC2069  # stderr is the result; stdout (the JSON) is discarded
  "$(sg_resolve hcl2json sg_ensure_hcl2json)" "$TFVARS" 2>&1 >/dev/null
}

# _tfvars_hcl <json> — pretty-print a JSON value so it reads like HCL in the file.
_tfvars_hcl() { printf '%s' "$1" | "$(sg_resolve jq sg_ensure_jq)" --indent 2 '.' 2>/dev/null || printf '%s' "$1"; }

# _tfvars_map <json-object> [notes-json] — a name-keyed HCL map, one entry
# per key, attribute names aligned:
#   "Project Name" = { # <note for that key, when given>
#     workflowGroup            = "platform-prod"
#     DeploymentPlatformConfig = [{"kind":"AWS_RBAC","config":{...}}]
#   }
# Attribute values are emitted as JSON, which HCL accepts and hcl2json
# round-trips (tfvars_valid); ${ and %{ inside strings are escaped like
# _tfvars_str does. "{}" for an empty or missing object.
_tfvars_map() {
  local j="${1:-}" notes="${2:-}" out
  [ -n "$j" ] && [ "$j" != "null" ] || j='{}'
  [ -n "$notes" ] && [ "$notes" != "null" ] || notes='{}'
  out="$(printf '%s' "$j" | "$(sg_resolve jq sg_ensure_jq)" -r --argjson notes "$notes" '
    def hcl: tojson | gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");
    def pad($w): . + (" " * ($w - length));
    if (. // {}) == {} then "{}" else
      "{\n" + ([to_entries[] | .key as $k | (.value | keys | map(length) | max // 0) as $w
        | "  \($k | tojson) = {" + (if ($notes[$k] // "") != "" then " # \($notes[$k])" else "" end) + "\n"
        + ([.value | to_entries[] | "    \(.key | pad($w)) = \(.value | hcl)"] | join("\n")) + "\n  }"] | join("\n")) + "\n}"
    end' 2>/dev/null)" || out=""
  printf '%s' "${out:-\{\}}"
}

# _tfvars_map_commented <json-object> [notes-json] — the map's entries (without
# the outer braces), every line commented out: ready to be moved into the real
# map above. Empty output for an empty map.
_tfvars_map_commented() {
  local out
  out="$(_tfvars_map "$@")"
  [ "$out" != "{}" ] || return 0
  printf '%s\n' "$out" | sed '1d;$d' | sed 's/^/# /'
}

# _tfvars_str <text> — a quoted HCL string literal (backslashes, quotes and
# template sequences escaped, so any connector or org name round-trips).
_tfvars_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$\{/\$\$\{}"
  s="${s//%\{/%%\{}"
  printf '"%s"' "$s"
}

# tfvars_write <dest> — render terraform.tfvars from W_* variables set by the
# wizard (lists/objects are passed as compact JSON, which HCL accepts). Keeps
# the same order and comments as terraform.tfvars.example so the file stays
# hand-editable afterwards.
#   W_TFORG W_TFHOST W_WSNAMES_JSON W_TAGS_JSON W_IGNORE_TAGS_JSON W_IGNORE_NAMES_JSON W_EXPORT_STATE
#   W_APPROVERS_JSON W_REPO_PREFIX W_VCS_INTEGRATION W_DPC_JSON W_RUNNER_JSON
#   W_DEST_KIND W_TF_SOURCE W_TF_VERSION W_TRIGGERS W_IGNORE_PATTERNS_JSON
#   W_STRIP_CLOUD W_PROJECT_OVERRIDES_JSON W_WS_OVERRIDES_JSON
#   W_PROJECT_TEMPLATE_JSON/_NOTES W_WS_TEMPLATE_JSON/_NOTES (commented examples)
# W_RUNNER_JSON and W_TF_VERSION may be the literal "null" (defer to the org's
# execution preset). The two override maps are re-rendered from JSON, so a
# hand-written block survives a re-run of the wizard (its inner comments do not).
# The template maps are written as comments: one ready-to-uncomment entry per
# selected project / workspace, pre-filled with the effective values.
tfvars_write() {
  local dest="$1" host_line tf_version_hcl
  if [ "${W_TF_VERSION:-null}" = "null" ]; then tf_version_hcl="null"; else tf_version_hcl="$(_tfvars_str "$W_TF_VERSION")"; fi
  # Always written (the default for Terraform Cloud), so a generated file sets
  # every variable and 'init --upgrade' has nothing to add to it.
  host_line="$(printf '\n# TFC/TFE hostname (app.terraform.io for Terraform Cloud)\ntfHostname = %s\n' "$(_tfvars_str "${W_TFHOST:-app.terraform.io}")")"
  cat >"$dest" <<TFVARS
# Generated by 'sg-migrate.sh init' on $(date -u +%Y-%m-%dT%H:%M:%SZ). Safe to edit by hand;
# re-run 'sg-migrate.sh init' to go through the wizard again.

# Terraform Cloud/Enterprise organization name
tfOrg = $(_tfvars_str "$W_TFORG")
$host_line
# List of workspace names to export. Use wildcards (e.g., ["*"]) for all workspaces
workspacenames = $W_WSNAMES_JSON

# Export Terraform state
exportStateFiles = $W_EXPORT_STATE

# Only include workspaces carrying these tags (null = all)
tfWorkspaceTags = $W_TAGS_JSON

# Exclude workspaces carrying these tags (null = none). Excludes win over includes.
tfWorkspaceIgnoreTags = $W_IGNORE_TAGS_JSON

# Exclude workspaces by name (globs, e.g. ["sandbox-*", "*-scratch"]); applied after
# the filters above. sg-migrate.sh --exclude-workspace adds to this list for one run.
tfWorkspaceIgnoreNames = ${W_IGNORE_NAMES_JSON:-[]}

# Directory to export Terraform files to
exportPath = "export"

# TFC/TFE-specific variables that are not migrated (regexes on the variable
# name), e.g. TFC_WORKSPACE_NAME or TFC_AWS_RUN_ROLE_ARN. [] keeps everything.
ignoreVarPatterns = $W_IGNORE_PATTERNS_JSON

# Cloud credential env variables (ARM_*, AWS_ACCESS_KEY_ID, GOOGLE_CREDENTIALS,
# ...) are replaced by each workflow's cloud connector and are not migrated;
# the family follows the connector kind. See cloudAuthVarPatterns in variables.tf.
stripCloudAuthVars = ${W_STRIP_CLOUD:-true}

# Emails of the users who must approve plans (approvalPreApply is set for
# workspaces without auto-apply)
SGDefaultWfApprovers = $W_APPROVERS_JSON

# Prefix for your repo URL
SGDefaultIACVCSRepoPrefix = $(_tfvars_str "$W_REPO_PREFIX")

# VCS connector used to clone the repositories (/integrations/<name>)
SGDefaultVCSAuthIntegrationID = $(_tfvars_str "$W_VCS_INTEGRATION")

# Cloud connector the workflows deploy with
SGDefaultDeploymentPlatformConfig = $(_tfvars_hcl "$W_DPC_JSON")

# Runners for every workflow: { type = "shared" } for SG-hosted runners,
# { type = "private", names = ["<runner-group>"] } for a private runner group, or
# null to let the org's execution preset decide (Settings -> Runner groups).
SGDefaultRunnerConstraints = $(_tfvars_hcl "${W_RUNNER_JSON:-null}")

# Choose from: GITHUB_COM, BITBUCKET_ORG, GITLAB_COM, AZURE_DEVOPS, GIT_OTHER
SGDefaultSourceConfigDestKind = $(_tfvars_str "$W_DEST_KIND")

# Where the workflows get their Terraform version from: "carry" keeps each
# workspace's pinned TFC version (the fallback below covers the rest); "preset"
# sends no version, so the org's execution preset applies.
SGTerraformVersionSource = $(_tfvars_str "${W_TF_SOURCE:-carry}")

# Fallback for "carry": SG Terraform version used when a workspace's version is
# not a pinned semver, or when the SG API rejects a pinned version as above the
# managed ceiling (1.5.7, the last MPL/FOSS release; newer versions are BSL and
# not bundled). null = leave those workflows to the org's execution preset.
SGDefaultTerraformVersion = $tf_version_hcl

# Pre-configure VCS triggers on each workflow from the workspace's TFC settings
SGDefaultEnableVCSTriggers = $W_TRIGGERS

# Re-pull state for every workspace on each apply (default: idempotent)
forceStateRefresh = false

# Per-project settings, keyed by the TFC project name: connectors, runners,
# approvers and the workflow group (workflowGroup, default tfc-<project>) for
# every workspace of that project. Precedence: workspaceOverrides >
# projectOverrides > SGDefault*. See terraform.tfvars.example for every field.
projectOverrides = $(_tfvars_map "${W_PROJECT_OVERRIDES_JSON:-}")
$(if [ -n "${W_PROJECT_TEMPLATE_JSON:-}" ] && [ "$W_PROJECT_TEMPLATE_JSON" != "{}" ]; then
    printf '\n# Ready to use: one entry per selected project, pre-filled with the values\n# chosen above. Move a project into projectOverrides = { } and change what should differ.\n'
    _tfvars_map_commented "$W_PROJECT_TEMPLATE_JSON" "${W_PROJECT_TEMPLATE_NOTES:-}"
  fi)

# Per-workspace overrides, keyed by workspace name; they win over the project
# and default values for that workspace only. Fields: DeploymentPlatformConfig,
# RunnerConstraints, Approvers, vcsAuthIntegrationID, vcsRepoPrefix,
# sourceConfigDestKind, terraformVersion, extraEnvironmentVariables, VCSTriggers.
workspaceOverrides = $(_tfvars_map "${W_WS_OVERRIDES_JSON:-}")
$(if [ -n "${W_WS_TEMPLATE_JSON:-}" ] && [ "$W_WS_TEMPLATE_JSON" != "{}" ]; then
    printf '\n# Ready to use: one entry per selected workspace, pre-filled with what it gets\n# today (terraformVersion = what it runs in TFC). Move a workspace into\n# workspaceOverrides = { } and change what should differ.\n'
    _tfvars_map_commented "$W_WS_TEMPLATE_JSON" "${W_WS_TEMPLATE_NOTES:-}"
  fi)
TFVARS
  tfvars_invalidate
  # Settings the wizard does not manage (tfProjects, cloudAuthVarPatterns, a
  # hand-added variable) are carried over from the previous file as they were
  # (W_PREV_JSON, read by wizard_run before this rewrite), so a re-run of init
  # never drops them.
  if [ -n "${W_PREV_JSON:-}" ] && [ "$W_PREV_JSON" != "{}" ]; then
    local jqb rendered extra k
    jqb="$(sg_resolve jq sg_ensure_jq)"
    rendered="$("$(sg_resolve hcl2json sg_ensure_hcl2json)" "$dest" 2>/dev/null | "$jqb" -c 'keys' || echo '[]')"
    extra="$(printf '%s' "$W_PREV_JSON" | "$jqb" -r --argjson have "$rendered" 'keys - $have | .[]')"
    if [ -n "$extra" ]; then
      {
        printf '\n# Kept from the previous file (not asked by init):\n'
        while IFS= read -r k; do
          [ -n "$k" ] || continue
          printf '%s = %s\n' "$k" "$(_tfvars_hcl "$(printf '%s' "$W_PREV_JSON" | "$jqb" -c --arg k "$k" '.[$k]')")"
        done <<<"$extra"
      } >>"$dest"
    fi
  fi
}

# tfvars_example — the shipped terraform.tfvars.example (every setting, with
# its default and comment); the reference for what a complete file contains.
tfvars_example() { printf '%s' "${TFVARS_EXAMPLE:-$SG_REPO_ROOT/transformer/terraform-cloud/terraform.tfvars.example}"; }

# tfvars_variables_tf — the module's variables.tf, the source of truth for
# which settings exist.
tfvars_variables_tf() { printf '%s' "${TFVARS_VARIABLES_TF:-$SG_REPO_ROOT/transformer/terraform-cloud/variables.tf}"; }

# tfvars_variable_names — every variable the module declares, in file order.
tfvars_variable_names() { sed -nE 's/^variable "([^"]+)".*/\1/p' "$(tfvars_variables_tf)"; }

# _tfvars_variable_attr <name> <attr> — a single-line attribute of a variable
# block (`default = []`, `description = "..."`); empty when absent or when the
# value spans several lines (a `{`/`[` with nothing after it).
_tfvars_variable_attr() {
  awk -v name="$1" -v attr="$2" '
    $0 ~ "^variable \"" name "\"" { inblock = 1; next }
    inblock && /^}/ { exit }
    inblock && $0 ~ "^  " attr " *=" {
      sub("^  " attr " *= *", ""); sub(/ *$/, "")
      if ($0 == "{" || $0 == "[") exit
      print; exit
    }' "$(tfvars_variables_tf)"
}

# tfvars_missing_keys — the variables the module declares that the current
# file neither sets nor mentions as a commented-out `# key = ...` (the way the
# example and the upgrade present settings that are rarely changed, such as
# cloudAuthVarPatterns), one per line: a file written by an older init.
tfvars_missing_keys() {
  local have
  have="$(tfvars_json | "$(sg_resolve jq sg_ensure_jq)" -r 'keys[]')"
  tfvars_variable_names | while IFS= read -r k; do
    grep -qx -- "$k" <<<"$have" && continue
    grep -qE "^# ?$k *=" "$TFVARS" 2>/dev/null && continue
    printf '%s\n' "$k"
  done
}

# _tfvars_example_paragraph <key> — the paragraph of terraform.tfvars.example
# (blank-line separated) that assigns <key>, commented out or not; empty when
# the example has none.
_tfvars_example_paragraph() {
  # When the match is a commented example, only the paragraph's comment lines
  # are returned: an uncommented setting sharing the paragraph must not be
  # appended a second time.
  awk -v RS= -v key="$1" '
    {
      n = split($0, lines, "\n"); hit = 0
      for (i = 1; i <= n; i++) if (lines[i] ~ ("^(# ?)?" key " *=")) { hit = (lines[i] ~ /^#/) ? 2 : 1; break }
      if (!hit) next
      for (i = 1; i <= n; i++) if (hit == 1 || lines[i] ~ /^#/) print lines[i]
      exit
    }' "$(tfvars_example)"
}

# tfvars_upgrade — append the settings the file lacks, each with its comment
# and default, under a dated header: the example's paragraph when it has one
# (the commented examples of the override maps and cloudAuthVarPatterns stay
# commented as guidance), plus `key = <default>` from variables.tf when the
# example does not set the key itself and the default fits on one line.
# Nothing already in the file is touched (comments and formatting included),
# so this is safe for a hand-edited file and for CI. Prints the added keys,
# one per line; exit 0 with no output when the file is up to date.
tfvars_upgrade() {
  local missing k para def desc out=""
  missing="$(tfvars_missing_keys)"
  [ -n "$missing" ] || return 0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    para="$(_tfvars_example_paragraph "$k")"
    def="$(_tfvars_variable_attr "$k" default)"
    if [ -n "$para" ] && grep -qE "^$k *=" <<<"$para"; then
      out="$out$para"$'\n\n'
    else
      if [ -z "$para" ]; then
        desc="$(_tfvars_variable_attr "$k" description | sed -E 's/^"(.*)"$/\1/; s/\\"/"/g' | fold -s -w 76 | sed 's/^/# /; s/ *$//')"
        [ -n "$desc" ] && out="$out$desc"$'\n'
      fi
      if [ -n "$def" ]; then
        out="$out$k = $def"$'\n'
      else
        out="$out# $k: the default (see variables.tf) applies; set it here to change it."$'\n'
      fi
      [ -n "$para" ] && out="$out$para"$'\n'
      out="$out"$'\n'
    fi
  done <<<"$missing"
  cp "$TFVARS" "$TFVARS.bak"
  {
    printf '\n# --- Added by %s init --upgrade on %s: settings this file predates, with their\n# --- defaults (same as leaving them out). Review and adjust.\n\n' "${PROG:-sg-migrate.sh}" "$(date -u +%Y-%m-%d)"
    printf '%s' "$out"
  } >>"$TFVARS"
  tfvars_invalidate
  # Never leave a broken file behind: roll back when the result does not parse.
  if ! tfvars_valid >/dev/null; then
    cp "$TFVARS.bak" "$TFVARS"
    tfvars_invalidate
    sg_err "the upgraded file did not parse — restored the previous version; please report this"
    return 1
  fi
  printf '%s\n' "$missing"
}
