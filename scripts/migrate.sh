#!/bin/bash
# End-to-end StackGuardian migration orchestrator.
#
# Runs apply -> convert -> validate -> import, resolving tooling from PATH first
# (e.g. inside the Docker image) and falling back to cached downloads when run
# natively. Designed to run both on the host and inside the migrator container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"

# SCRIPT_DIR holds the sibling scripts; SG_REPO_ROOT (from tools.sh) is the repo
# root used for all repo-relative paths.
TRANSFORMER_DIR="$SG_REPO_ROOT/transformer/terraform-cloud"
TFVARS="$TRANSFORMER_DIR/terraform.tfvars"
PROG="${SG_PROG:-$0}"
EXPORT_DIR="${SG_EXPORT_DIR:-$SG_REPO_ROOT/export}"
MAPPING="${SG_WFGROUP_MAP:-$SG_REPO_ROOT/.sg/workflow-groups.json}"
ORG="${SG_ORG:-}"
SG_BASE_URL="${SG_BASE_URL:-https://api.app.stackguardian.io}"
ASSUME_YES=0
PURGE=0
CREATE_GROUPS=1
ENRICH_VARSETS=1
VCS_TRIGGERS=1
VERBOSE="${SG_VERBOSE:-0}"
CONC="${SG_CONCURRENCY:-4}"
TF_PARALLELISM="${SG_TF_PARALLELISM:-20}"
RETRIES="${SG_RETRIES:-4}"
RETRY_BASE="${SG_RETRY_BASE:-2}"
PF=()

usage() {
  cat >&2 <<EOF
Usage: $PROG [options] <command>

Commands:
  init        Create terraform.tfvars from the template
  apply       Run the transformer (terraform apply) to generate payloads + state
  enrich      Merge TFC Variable Set variables into the payloads (via the TFC API)
  convert     Convert HCL-string variables to JSON in each payload (parallel)
  validate    Validate each payload against the SG schema
  import      Import each payload to StackGuardian (parallel, with confirmation),
              then register VCS triggers (unless --no-vcs-triggers)
  triggers    Register VCS triggers for already-imported workflows (second pass)
  all         apply -> enrich -> convert -> validate -> import
  clean       Remove local working artifacts for a fresh start (export/, TF state,
              tool cache). Add --all to also remove config (terraform.tfvars, mapping).
  completion  Print a shell completion script for the current session:
              \`source <($0 completion zsh)\` (or bash)

Each TFC project maps to an SG workflow group named tfc-<project>, created via the
API if missing. Override a project's target group in .sg/workflow-groups.json
(\`{"<project-segment>": "<existing-group>"}\`); override groups are not auto-created.

Options:
  --org NAME         StackGuardian org for import (or set SG_ORG)
  --export-dir DIR   Payload/state output dir (default: ./export)
  --mapping FILE     Optional project-segment -> group override map (default: .sg/workflow-groups.json)
  --concurrency N    Max parallel jobs for convert/import (default: 4)
  --no-create-groups Do not create missing workflow groups; require them to exist
  --no-variable-sets Skip merging TFC Variable Set variables in the 'all' flow
  --no-vcs-triggers  Skip registering VCS triggers after import
  --all              With 'clean': also remove config (terraform.tfvars, mapping, .sg)
  -v, --verbose      Show full terraform/tool output (default: concise)
  -y, --yes          Skip the import confirmation prompt
  -h, --help         Show this help

Environment:
  SG_API_TOKEN       StackGuardian API token (required for import)
  SG_ORG             StackGuardian org (alternative to --org)
  SG_RETRIES         Import retry attempts on failure (default: 4)
  SG_TF_PARALLELISM  terraform apply -parallelism (default: 20)
EOF
}

die() {
  sg_err "$*"
  exit 1
}

throttle() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$1" ]; do sleep 0.2; done; }

# run_parallel <fn> <max> <items...> — runs fn over items, up to max at a time.
# Each job's stdout+stderr is buffered to its own file (so concurrent tools see
# a non-TTY and don't scatter spinner output across the terminal), then flushed
# as a clean labeled block in submission order. Returns non-zero if any failed.
run_parallel() {
  local fn="$1" max="$2"
  shift 2
  local statusdir i=0 rc=0 item
  statusdir="$(mktemp -d)"
  for item in "$@"; do
    throttle "$max"
    (
      "$fn" "$item" >"$statusdir/$i.out" 2>&1
      echo "$?" >"$statusdir/$i.rc"
    ) &
    i=$((i + 1))
  done
  wait
  i=0
  for item in "$@"; do
    printf '%s── %s ──%s\n' "$C_CYAN" "$(basename "$item")" "$C_RESET" >&2
    [ -s "$statusdir/$i.out" ] && cat "$statusdir/$i.out" >&2
    [ "$(cat "$statusdir/$i.rc" 2>/dev/null)" = "0" ] || rc=1
    i=$((i + 1))
  done
  rm -rf "$statusdir"
  return "$rc"
}

# Populate PF with the generated payload files.
payload_files() {
  shopt -s nullglob
  PF=("$EXPORT_DIR"/sg-payload.*.json)
  shopt -u nullglob
}

seg_of() {
  local b
  b="$(basename "$1")"
  b="${b#sg-payload.}"
  echo "${b%.json}"
}

cmd_init() {
  sg_step "Phase: init"
  mkdir -p "$SG_REPO_ROOT/.sg" "$SG_CACHE_BIN"
  if [ ! -f "$TFVARS" ]; then
    cp "$TRANSFORMER_DIR/terraform.tfvars.example" "$TFVARS"
    sg_log "created $(sg_rel "$TFVARS") — edit it before 'apply'"
  else
    sg_log "$(sg_rel "$TFVARS") already exists"
  fi
  sg_log "workflow groups are created automatically as tfc-<project>; no mapping needed"
  completion_hint
  sg_success "init complete"
}

# completion_hint — tell the user how to enable tab completion for their shell.
# A child process cannot register completions in the parent shell, so this only
# prints the one-liner (nothing is written to the user's rc files).
completion_hint() {
  local sh
  case "$(basename "${SHELL:-}")" in bash) sh=bash ;; *) sh=zsh ;; esac
  sg_log "tab completion for this shell session: source <(./sg-migrate.sh completion $sh)"
}

# --- StackGuardian API helpers (workflow groups) ---------------------------

# group_for <segment> -> the SG workflow group for a project segment: an entry
# from the optional override map, else the default tfc-<segment>.
group_for() {
  local seg="$1" override=""
  if [ -f "$MAPPING" ]; then
    override="$("$JQ_BIN" -r --arg k "$seg" '.[$k] // empty' "$MAPPING" 2>/dev/null || true)"
  fi
  [ -n "$override" ] && echo "$override" || echo "tfc-$seg"
}

# wfgroup_http_code <group> -> HTTP status of GET (200 exists, 404 missing).
wfgroup_http_code() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: apikey $SG_API_TOKEN" \
    "$SG_BASE_URL/api/v1/orgs/$ORG/wfgrps/$1/"
}

# wfgroup_create <group> — create a workflow group (idempotent at call sites).
wfgroup_create() {
  local body
  body="$("$JQ_BIN" -nc --arg n "$1" '{ResourceName:$n, Description:"Created by stackguardian-migrator (Terraform Cloud import)"}')"
  sg_retry "$RETRIES" "$RETRY_BASE" -- \
    curl -fsS -X POST \
    -H "Authorization: apikey $SG_API_TOKEN" -H "Content-Type: application/json" \
    -d "$body" "$SG_BASE_URL/api/v1/orgs/$ORG/wfgrps/" >/dev/null
}

# wf_triggers_endpoint <group> <wf> -> the VCS-triggers webhook URL for a workflow.
wf_triggers_endpoint() {
  echo "$SG_BASE_URL/api/v1/orgs/$ORG/wfgrps/$1/wfs/$2/webhooks/vcs_triggers/"
}

# do_set_triggers <payload> — for each workflow in the file with a non-null
# VCSTriggers block, register its VCS triggers via the dedicated webhooks
# endpoint (the bulk create API silently drops VCSTriggers; this second pass is
# what actually wires up the repo webhook). Sends {VCSConfig, VCSTriggers} taken
# straight from the (converted) payload. Per-workflow failures are surfaced but
# do not abort the rest of the file.
do_set_triggers() {
  local f="$1" seg grp n i wf body rc=0 set=0 skip=0
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  n="$("$JQ_BIN" 'length' "$f")"
  for ((i = 0; i < n; i++)); do
    if [ "$("$JQ_BIN" -r --argjson i "$i" '(.[$i].VCSTriggers // null) != null' "$f")" != "true" ]; then
      skip=$((skip + 1))
      continue
    fi
    wf="$("$JQ_BIN" -r --argjson i "$i" '.[$i].ResourceName' "$f")"
    # A workflow that failed to import has nothing to attach triggers to.
    if [ "$(sg_http_code GET "$SG_BASE_URL/api/v1/orgs/$ORG/wfgrps/$grp/wfs/$wf/")" != "200" ]; then
      sg_warn "  $grp/$wf does not exist in SG (import failed?) — skipping triggers"
      rc=1
      continue
    fi
    body="$("$JQ_BIN" -c --argjson i "$i" '{VCSConfig: .[$i].VCSConfig, VCSTriggers: .[$i].VCSTriggers}' "$f")"
    if SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- \
      sg_api_post "$(wf_triggers_endpoint "$grp" "$wf")" "$body"; then
      set=$((set + 1))
    else
      sg_warn "  vcs triggers failed: $grp/$wf"
      rc=1
    fi
  done
  sg_log "$(basename "$f"): set triggers on $set workflow(s) (skipped $skip without triggers)"
  return "$rc"
}

# sg_http_code <method> <url> — prints the HTTP status (000 on network error).
sg_http_code() {
  curl -sS -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: apikey $SG_API_TOKEN" "$2" 2>/dev/null || echo 000
}

# sg_api_post <url> <json-body> — POST to the SG API. Exit 0 on 2xx, 22 on a
# definitive 4xx (not retryable; response echoed), 1 on 5xx/network (retryable).
sg_api_post() {
  local url="$1" body="$2" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    -H "Authorization: apikey $SG_API_TOKEN" -H "Content-Type: application/json" \
    -d "$body" "$url" 2>/dev/null || echo 000)"
  case "$code" in
  2*)
    rm -f "$tmp"
    return 0
    ;;
  4*)
    sg_err "  HTTP $code from ${url#"$SG_BASE_URL"}: $(head -c 400 "$tmp")"
    rm -f "$tmp"
    return 22
    ;;
  *)
    sg_warn "  HTTP $code from ${url#"$SG_BASE_URL"}"
    rm -f "$tmp"
    return 1
    ;;
  esac
}

# set_triggers_pass — run do_set_triggers over all payload files (assumes
# JQ_BIN/SG_API_TOKEN/ORG are already set up by the caller).
set_triggers_pass() {
  local total
  total="$("$JQ_BIN" -s 'map(map(select((.VCSTriggers // null) != null)) | length) | add // 0' "${PF[@]}")"
  if [ "$total" -eq 0 ]; then
    sg_log "no workflows carry VCS triggers — nothing to register"
    return 0
  fi
  sg_log "registering VCS triggers for $total workflow(s), up to $CONC in parallel (retries: $RETRIES)"
  if run_parallel do_set_triggers "$CONC" "${PF[@]}"; then
    sg_success "vcs triggers registered"
  else
    sg_err "one or more VCS trigger registrations failed (re-run: $PROG triggers)"
    return 1
  fi
}

cmd_triggers() {
  sg_step "Phase: vcs triggers"
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  command -v curl >/dev/null 2>&1 || die "curl is required for VCS trigger registration."
  export SG_API_TOKEN SG_BASE_URL
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."
  set_triggers_pass
}

cmd_clean() {
  sg_step "Phase: clean"
  sg_log "removing local working artifacts..."
  rm -rf "$EXPORT_DIR"
  rm -rf "$TRANSFORMER_DIR/.terraform" "$TRANSFORMER_DIR/.terraform.lock.hcl" \
    "$TRANSFORMER_DIR/terraform.tfstate" "$TRANSFORMER_DIR/terraform.tfstate.backup"
  rm -rf "$SG_CACHE_DIR"
  if [ "$PURGE" -eq 1 ]; then
    rm -f "$TFVARS" "$MAPPING"
    rm -rf "$SG_REPO_ROOT/.sg"
    sg_log "also removed config (terraform.tfvars, workflow-groups.json, .sg)"
  fi
  sg_success "clean complete"
}

cmd_apply() {
  sg_step "Phase: apply (terraform)"
  command -v terraform >/dev/null 2>&1 || die "terraform not found on PATH"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS"). Run: $0 init (then edit it)."
  # State export (TFC API) calls curl + jq from terraform's local-exec; make sure
  # both are on PATH for the apply (jq from cache if not already installed).
  command -v curl >/dev/null 2>&1 || die "curl is required for state export"
  local jqdir tflog rc=0
  jqdir="$(dirname "$(sg_resolve jq sg_ensure_jq)")"

  if [ "$VERBOSE" -eq 1 ]; then
    (cd "$TRANSFORMER_DIR" && export PATH="$jqdir:$PATH" TF_IN_AUTOMATION=1 &&
      terraform init -input=false &&
      terraform apply -auto-approve -compact-warnings -parallelism="$TF_PARALLELISM" -var-file=terraform.tfvars) || rc=$?
  else
    # Quiet: capture terraform's verbose plan/output; surface only progress, the
    # final summary, and (on failure) the captured log.
    tflog="$(mktemp)"
    sg_log "initializing terraform (providers)..."
    (cd "$TRANSFORMER_DIR" && export PATH="$jqdir:$PATH" TF_IN_AUTOMATION=1 && terraform init -input=false -no-color) >"$tflog" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      sg_log "reading workspaces, generating payloads, exporting state..."
      (cd "$TRANSFORMER_DIR" && export PATH="$jqdir:$PATH" TF_IN_AUTOMATION=1 &&
        terraform apply -auto-approve -compact-warnings -no-color -parallelism="$TF_PARALLELISM" -var-file=terraform.tfvars) >"$tflog" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      sg_err "terraform failed (rc=$rc):"
      cat "$tflog" >&2
    else
      grep -E '^(Apply complete|No changes)' "$tflog" | sed 's/^/  /' >&2 || true
    fi
    rm -f "$tflog"
  fi

  [ "$rc" -eq 0 ] || return "$rc"
  sg_success "apply complete — payloads in $(sg_rel "$EXPORT_DIR")"
}

cmd_enrich() {
  sg_step "Phase: variable sets"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS") (run: $PROG init)."
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR") (run 'apply' first)."
  # Variable sets belong to the TFC org (tfOrg in terraform.tfvars), not SG_ORG.
  local jqb h2j tforg tfhost
  jqb="$(sg_resolve jq sg_ensure_jq)"
  h2j="$(sg_resolve hcl2json sg_ensure_hcl2json)"
  tforg="$("$h2j" "$TFVARS" | "$jqb" -r '.tfOrg // empty')"
  [ -n "$tforg" ] || die "tfOrg not found in $(sg_rel "$TFVARS")"
  tfhost="$("$h2j" "$TFVARS" | "$jqb" -r '.tfHostname // empty')"
  SG_TFC_HOSTNAME="${tfhost:-app.terraform.io}" "$SCRIPT_DIR/enrich_variable_sets.sh" "$tforg" "${PF[@]}"
}

do_convert() { "$SCRIPT_DIR/convert_hcl_to_json.sh" "$1"; }

cmd_convert() {
  sg_step "Phase: convert (HCL → JSON)"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR") (run 'apply' first)."
  sg_log "converting ${#PF[@]} payload(s), up to $CONC in parallel"
  if run_parallel do_convert "$CONC" "${PF[@]}"; then
    sg_success "converted ${#PF[@]} payload(s)"
  else
    sg_err "conversion failed for one or more payloads"
    return 1
  fi
}

cmd_validate() {
  sg_step "Phase: validate"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."
  if "$SCRIPT_DIR/validate_payload.sh" "${PF[@]}"; then
    sg_success "all ${#PF[@]} payload(s) valid"
  else
    sg_err "validation failed"
    return 1
  fi
}

# sgcli_bulk <group> <file> <out> — run the bulk create, teeing output to <out>.
# sg-cli exits 0 even when individual workflows fail, so callers must inspect
# the output ("Failed to create <name>: ..." lines).
sgcli_bulk() {
  "$SGCLI_BIN" workflow create --bulk --workflow-group "$1" --org "$ORG" "$2" 2>&1 | tee "$3"
  return "${PIPESTATUS[0]}"
}

# Regex for the API's rejection of a Terraform version above SG's managed
# ceiling. SG bundles managed runtimes only up to the last MPL-licensed (FOSS)
# Terraform release; newer versions are BSL and are not shipped.
TF_CEILING_RE='Failed to create ([^:]+): 400: .*above the highest managed version \(([0-9.]+)\)'

# names_json <name...> — JSON array of the given names (for jq --argjson).
names_json() { printf '%s\n' "$@" | "$JQ_BIN" -R . | "$JQ_BIN" -s .; }

# do_import <payload> — bulk-import one file. Workflows rejected because their
# Terraform version is above the SG ceiling are re-imported with
# SG_DEFAULT_TF_VERSION (the payload file is patched in place so re-runs and
# the trigger pass see what was actually imported); each fallback is appended to
# terraform-version-fallbacks.log. Any other per-workflow failure fails the file.
do_import() {
  local f="$1" seg grp out rc=0 ceiling="" failed=() fb=() name line tmp names
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  sg_log "importing $(basename "$f") -> $grp"
  out="$(mktemp)"
  sg_retry "$RETRIES" "$RETRY_BASE" -- sgcli_bulk "$grp" "$f" "$out" || rc=1

  while IFS= read -r line; do
    if [[ "$line" =~ $TF_CEILING_RE ]]; then
      fb+=("${BASH_REMATCH[1]}")
      ceiling="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed\ to\ create\ ([^:]+): ]]; then
      failed+=("${BASH_REMATCH[1]}")
    fi
  done <"$out"
  rm -f "$out"

  if [ "${#fb[@]}" -gt 0 ]; then
    sg_warn "${#fb[@]} workflow(s) pinned above SG's managed Terraform ceiling ($ceiling); re-importing with $SG_DEFAULT_TF_VERSION"
    names="$(names_json "${fb[@]}")"
    tmp="$(mktemp "$EXPORT_DIR/.fallback.$seg.XXXXXX")"
    # Patch the affected workflows in the payload and re-import only those.
    "$JQ_BIN" --arg v "$SG_DEFAULT_TF_VERSION" --argjson names "$names" \
      'map(if (.ResourceName as $n | $names | index($n)) != null then .TerraformConfig.terraformVersion = $v else . end)' "$f" >"$tmp.full" &&
      "$JQ_BIN" --argjson names "$names" \
        'map(select(.ResourceName as $n | $names | index($n) != null))' "$tmp.full" >"$tmp" ||
      {
        rm -f "$tmp" "$tmp.full"
        die "could not patch $(basename "$f") for the Terraform version fallback"
      }
    out="$(mktemp)"
    sg_retry "$RETRIES" "$RETRY_BASE" -- sgcli_bulk "$grp" "$tmp" "$out" || rc=1
    for name in "${fb[@]}"; do
      if grep -q "Failed to create $name:" "$out"; then
        failed+=("$name")
      else
        line="$("$JQ_BIN" -r --arg n "$name" '.[] | select(.ResourceName == $n) | .TerraformConfig.terraformVersion' "$f")"
        printf '%s/%s: %s -> %s (above SG managed ceiling %s)\n' "$grp" "$name" "$line" "$SG_DEFAULT_TF_VERSION" "$ceiling" >>"$EXPORT_DIR/terraform-version-fallbacks.log"
      fi
    done
    rm -f "$out"
    mv -f "$tmp.full" "$f"
    rm -f "$tmp"
  fi

  if [ "${#failed[@]}" -gt 0 ]; then
    sg_err "$(basename "$f"): ${#failed[@]} workflow(s) failed to import: ${failed[*]}"
    return 1
  fi
  return "$rc"
}

# Print the customer-facing notice when any workflow fell back to the default
# Terraform version during this import.
tf_fallback_notice() {
  local log="$EXPORT_DIR/terraform-version-fallbacks.log"
  [ -s "$log" ] || return 0
  sg_warn "Terraform version fallback applied to $(wc -l <"$log" | tr -d ' ') workflow(s):"
  sed 's/^/  /' "$log" >&2
  cat >&2 <<NOTICE
  StackGuardian ships managed Terraform runtimes only up to the last MPL-licensed
  (FOSS) release; newer versions are BSL-licensed and are not bundled. The
  workflows above were created with $SG_DEFAULT_TF_VERSION instead of the version
  pinned in TFC, so they will run a different Terraform than before - verify the
  configuration is compatible before the first run. To keep a newer version, set
  workspaceOverrides[<name>].terraformVersion to a binary path mounted from a
  private runner, or use a custom runtime container template
  (wfStepTemplateRevisionId), and re-import.
NOTICE
}

cmd_import() {
  sg_step "Phase: import"
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  command -v curl >/dev/null 2>&1 || die "curl is required for workflow-group checks/creation."
  # Both our API calls and sg-cli honor SG_BASE_URL (e.g. non-prod); export it
  # so the sg-cli child process inherits the same target.
  export SG_API_TOKEN SG_BASE_URL
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"

  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."

  # Build the plan: resolve each project's group, check existence, and decide
  # which groups need creating. Override groups (from the map) must already exist.
  local fail=0 to_create=" " f seg grp count override is_override code status
  printf '%sImport plan%s (org: %s%s%s, %s)\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$ORG" "$C_RESET" "$SG_BASE_URL" >&2
  printf '  %s%-34s %-26s %-9s %s%s\n' "$C_BOLD" "FILE" "WORKFLOW GROUP" "WORKFLOWS" "STATUS" "$C_RESET" >&2
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    count="$("$JQ_BIN" 'length' "$f")"
    override=""
    [ -f "$MAPPING" ] && override="$("$JQ_BIN" -r --arg k "$seg" '.[$k] // empty' "$MAPPING" 2>/dev/null || true)"
    if [ -n "$override" ]; then
      grp="$override"
      is_override=1
    else
      grp="tfc-$seg"
      is_override=0
    fi

    code="$(wfgroup_http_code "$grp")"
    case "$code" in
    200) status="${C_GREEN}exists${C_RESET}" ;;
    404)
      if [ "$is_override" -eq 1 ]; then
        status="${C_RED}missing!${C_RESET}"
        fail=1
      elif [ "$CREATE_GROUPS" -eq 1 ]; then
        status="${C_YELLOW}create${C_RESET}"
        case "$to_create" in *" $grp "*) ;; *) to_create="$to_create$grp " ;; esac
      else
        status="${C_RED}missing!${C_RESET}"
        fail=1
      fi
      ;;
    401 | 403) die "auth failed (HTTP $code) for org '$ORG' — check SG_API_TOKEN" ;;
    000) die "could not reach $SG_BASE_URL" ;;
    *) die "unexpected HTTP $code checking group '$grp'" ;;
    esac
    printf '  %-34s %-26s %-9s %s\n' "$(basename "$f")" "$grp" "$count" "$status" >&2
  done
  if [ "$fail" -ne 0 ]; then
    die "some groups are missing (override groups are not auto-created; create them or remove the override)."
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '%sProceed?%s This imports to %s and creates any "create" groups. [y/N] ' "$C_BOLD$C_YELLOW" "$C_RESET" "$ORG" >&2
    read -r ans || ans=""
    case "$ans" in y | Y | yes | YES) ;; *) die "Aborted." ;; esac
  fi

  # Create the missing tfc-* groups before importing into them.
  for grp in $to_create; do
    sg_log "creating workflow group $grp"
    wfgroup_create "$grp" || die "failed to create workflow group $grp"
  done

  SGCLI_BIN="$(sg_resolve sg-cli sg_ensure_sgcli)"
  # Fallback Terraform version for workflows the API rejects as above the
  # managed ceiling: SGDefaultTerraformVersion from terraform.tfvars, else 1.5.7.
  SG_DEFAULT_TF_VERSION="${SG_DEFAULT_TF_VERSION:-}"
  if [ -z "$SG_DEFAULT_TF_VERSION" ] && [ -f "$TFVARS" ]; then
    SG_DEFAULT_TF_VERSION="$("$(sg_resolve hcl2json sg_ensure_hcl2json)" "$TFVARS" | "$JQ_BIN" -r '.SGDefaultTerraformVersion // empty')"
  fi
  SG_DEFAULT_TF_VERSION="${SG_DEFAULT_TF_VERSION:-TERRAFORM-1.5.7}"
  rm -f "$EXPORT_DIR/terraform-version-fallbacks.log"

  sg_log "importing ${#PF[@]} payload(s), up to $CONC in parallel (retries: $RETRIES)"
  local import_rc=0
  run_parallel do_import "$CONC" "${PF[@]}" || import_rc=1
  tf_fallback_notice
  if [ "$import_rc" -eq 0 ]; then
    sg_success "import complete (${#PF[@]} payload(s))"
  else
    sg_err "one or more workflows failed to import (see above); VCS triggers are still registered for the ones that succeeded"
  fi

  # VCS triggers are not accepted by the bulk create API; register them in a
  # second pass against the dedicated webhooks endpoint (skip with --no-vcs-triggers).
  if [ "$VCS_TRIGGERS" -eq 1 ]; then
    set_triggers_pass || import_rc=1
  fi
  return "$import_rc"
}

# Single source of truth for shell completion (keep in sync with the parser below
# and the host-only flags in sg-migrate.sh).
SG_COMMANDS="init apply enrich convert validate import triggers all clean completion"
SG_OPTIONS="--org --export-dir --mapping --concurrency --no-create-groups --no-variable-sets --no-vcs-triggers --all -v --verbose -y --yes -h --help --native --local --build"

# cmd_completion <bash|zsh> — print a completion script for sg-migrate.sh /
# migrate.sh to stdout. Both shells fall back to the basename when the command
# is invoked by path, so ./sg-migrate.sh completes too.
cmd_completion() {
  local shell="${1:-}"
  case "$shell" in
  bash)
    cat <<BASH
# bash completion for sg-migrate.sh — generated by: sg-migrate.sh completion bash
_sg_migrate() {
  local cur prev cmds opts w has_cmd=0
  cur="\${COMP_WORDS[COMP_CWORD]}"; prev="\${COMP_WORDS[COMP_CWORD-1]}"
  cmds="$SG_COMMANDS"
  opts="$SG_OPTIONS"
  case "\$prev" in
    --export-dir) COMPREPLY=(\$(compgen -d -- "\$cur")); return ;;
    --mapping) COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
    --org | --concurrency) COMPREPLY=(); return ;;
    completion) COMPREPLY=(\$(compgen -W "bash zsh" -- "\$cur")); return ;;
  esac
  for w in "\${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
    case " \$cmds " in *" \$w "*) has_cmd=1 ;; esac
  done
  if [[ "\$cur" == -* ]]; then
    COMPREPLY=(\$(compgen -W "\$opts" -- "\$cur"))
  elif [ "\$has_cmd" -eq 0 ]; then
    COMPREPLY=(\$(compgen -W "\$cmds" -- "\$cur"))
  fi
}
complete -F _sg_migrate sg-migrate.sh migrate.sh
BASH
    ;;
  zsh)
    cat <<ZSH
#compdef sg-migrate.sh migrate.sh
# zsh completion for sg-migrate.sh — generated by: sg-migrate.sh completion zsh
_sg_migrate() {
  local -a cmds
  cmds=(
    'init:Create terraform.tfvars from the template'
    'apply:Run the transformer (terraform apply)'
    'enrich:Merge TFC Variable Set variables into the payloads'
    'convert:Convert HCL-string variables to JSON'
    'validate:Validate payloads against the SG schema'
    'import:Import payloads to StackGuardian, then register VCS triggers'
    'triggers:Register VCS triggers for already-imported workflows'
    'all:apply -> enrich -> convert -> validate -> import'
    'clean:Remove local working artifacts'
    'completion:Print a shell completion script'
  )
  _arguments -s \\
    '--org[StackGuardian org for import]:org' \\
    '--export-dir[Payload/state output dir]:dir:_files -/' \\
    '--mapping[Project-segment -> group override map]:file:_files' \\
    '--concurrency[Max parallel jobs for convert/import]:n' \\
    '--no-create-groups[Require workflow groups to pre-exist]' \\
    '--no-variable-sets[Skip merging TFC Variable Sets]' \\
    '--no-vcs-triggers[Skip registering VCS triggers after import]' \\
    '--all[With clean: also remove config]' \\
    '(-v --verbose)'{-v,--verbose}'[Show full terraform/tool output]' \\
    '(-y --yes)'{-y,--yes}'[Skip the import confirmation prompt]' \\
    '(-h --help)'{-h,--help}'[Show help]' \\
    '(--native --local)'{--native,--local}'[Run natively instead of in Docker]' \\
    '--build[Rebuild the Docker image first]' \\
    '1:command:->cmd' \\
    '2:shell:->shell'
  case "\$state" in
    cmd) _describe -t commands 'command' cmds ;;
    shell) [[ "\${words[CURRENT-1]}" == completion ]] && _values 'shell' bash zsh ;;
  esac
}
compdef _sg_migrate sg-migrate.sh migrate.sh
ZSH
    ;;
  *) die "usage: $PROG completion <bash|zsh>" ;;
  esac
}

CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
  -y | --yes) ASSUME_YES=1 ;;
  --org)
    ORG="$2"
    shift
    ;;
  --org=*) ORG="${1#*=}" ;;
  --export-dir)
    EXPORT_DIR="$2"
    shift
    ;;
  --export-dir=*) EXPORT_DIR="${1#*=}" ;;
  --mapping)
    MAPPING="$2"
    shift
    ;;
  --mapping=*) MAPPING="${1#*=}" ;;
  --concurrency)
    CONC="$2"
    shift
    ;;
  --concurrency=*) CONC="${1#*=}" ;;
  --no-create-groups) CREATE_GROUPS=0 ;;
  --no-variable-sets) ENRICH_VARSETS=0 ;;
  --no-vcs-triggers) VCS_TRIGGERS=0 ;;
  -v | --verbose) VERBOSE=1 ;;
  --all) PURGE=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  init | apply | enrich | convert | validate | import | triggers | all | clean) CMD="$1" ;;
  completion)
    cmd_completion "${2:-}"
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage
    exit 1
    ;;
  esac
  shift
done
# No command: show the help menu instead of running the whole pipeline.
if [ -z "$CMD" ]; then
  usage
  exit 0
fi
export SG_VERBOSE="$VERBOSE"

case "$CMD" in
init) cmd_init ;;
clean) cmd_clean ;;
apply) cmd_apply ;;
enrich) cmd_enrich ;;
convert) cmd_convert ;;
validate) cmd_validate ;;
import) cmd_import ;;
triggers) cmd_triggers ;;
all)
  if [ ! -f "$TFVARS" ]; then
    cmd_init
    die "Edit $(sg_rel "$TFVARS"), then re-run '$PROG all'."
  fi
  # Fail fast on import prerequisites before the (long) apply.
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set (needed for import)."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  cmd_apply
  if [ "$ENRICH_VARSETS" -eq 1 ]; then cmd_enrich; fi
  cmd_convert
  cmd_validate
  cmd_import
  ;;
esac
