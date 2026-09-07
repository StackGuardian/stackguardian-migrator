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
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"
# shellcheck source=lib/tfvars.sh
source "$SCRIPT_DIR/lib/tfvars.sh"
# shellcheck source=lib/tfc_api.sh
source "$SCRIPT_DIR/lib/tfc_api.sh"
# shellcheck source=lib/sg_api.sh
source "$SCRIPT_DIR/lib/sg_api.sh"
# shellcheck source=lib/wizard.sh
source "$SCRIPT_DIR/lib/wizard.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"
# shellcheck source=lib/errors.sh
source "$SCRIPT_DIR/lib/errors.sh"
# shellcheck source=lib/checklist.sh
source "$SCRIPT_DIR/lib/checklist.sh"


# SCRIPT_DIR holds the sibling scripts; SG_REPO_ROOT (from tools.sh) is the repo
# root used for all repo-relative paths.
TRANSFORMER_DIR="$SG_REPO_ROOT/transformer/terraform-cloud"
TFVARS="${SG_TFVARS:-$TRANSFORMER_DIR/terraform.tfvars}"
PROG="${SG_PROG:-$0}"
EXPORT_DIR="${SG_EXPORT_DIR:-$SG_REPO_ROOT/export}"
MAPPING="${SG_WFGROUP_MAP:-$SG_REPO_ROOT/.sg/workflow-groups.json}"
ORG="${SG_ORG:-}"
SG_BASE_URL_SET="${SG_BASE_URL:-}"
SG_BASE_URL="${SG_BASE_URL:-https://api.app.stackguardian.io}"
ASSUME_YES=0
PURGE=0
CREATE_GROUPS=1
ENRICH_VARSETS=1
VCS_TRIGGERS=1
# shellcheck disable=SC2034  # consumed by lib/preflight.sh
SKIP_PREFLIGHT=0
# shellcheck disable=SC2034
PREFLIGHT_DONE=0
FRESH=0
DRY_RUN=0
SECRET_STUBS=1
PROJECT_FILTER=()
WS_FILTER=()
VERBOSE="${SG_VERBOSE:-0}"
CONC="${SG_CONCURRENCY:-4}"
TF_PARALLELISM="${SG_TF_PARALLELISM:-20}"
RETRIES="${SG_RETRIES:-4}"
RETRY_BASE="${SG_RETRY_BASE:-2}"
PF=()
# Phase bookkeeping: 'all' numbers its phases ("Phase 2/5: ...") and every
# phase reports how long it took.
PHASE_TOTAL=0
PHASE_N=0
PHASE_T0=$SECONDS
RUN_T0=$SECONDS
# The init wizard remembers the SG org / API host in .sg/state.json so a new
# shell without SG_ORG still works; flags and env always win.
if [ -z "$ORG" ] && [ -f "$STATE_FILE" ]; then
  ORG="$(state_read | "$(sg_resolve jq sg_ensure_jq)" -r '.config.sg_org // empty' 2>/dev/null || true)"
  [ -n "$ORG" ] && [ -z "${SG_BASE_URL_SET:-}" ] && SG_BASE_URL="$(state_read | "$(sg_resolve jq sg_ensure_jq)" -r --arg d "$SG_BASE_URL" '.config.sg_base_url // $d' 2>/dev/null || echo "$SG_BASE_URL")"
fi


usage() {
  cat >&2 <<EOF
Usage: $PROG [options] <command>

Commands:
  init        Guided setup: discovers TFC/SG resources and writes terraform.tfvars
  preflight   Verify tokens and every connector/runner/org referenced in tfvars
              (runs automatically before apply, import and all)
  apply       Run the transformer (terraform apply) to generate payloads + state
  enrich      Merge TFC Variable Set variables into the payloads (via the TFC API)
  convert     Convert HCL-string variables to JSON in each payload (parallel)
  validate    Validate each payload against the SG schema
  import      Import each payload to StackGuardian (parallel, with confirmation),
              then register VCS triggers (unless --no-vcs-triggers)
  triggers    Register VCS triggers for already-imported workflows (second pass)
  checklist   Create placeholder secrets for skipped sensitive variables and write
              export/post-import-checklist.md (runs automatically after import)
  all         preflight -> apply -> enrich -> convert -> validate -> import -> checklist
              (resumes where a previous run stopped; --fresh to redo everything)
  clean       Remove local working artifacts for a fresh start (export/, TF state,
              tool cache). Add --all to also remove config (terraform.tfvars, mapping).
  completion  Print a completion script for your shell (bash/zsh auto-detected):
              \`source <($PROG completion)\`

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
  --skip-preflight   Skip the preflight checks (not recommended)
  --dry-run          With 'import': show the per-workflow plan and stop (nothing is created)
  --no-secret-stubs  Do not create placeholder SG secrets for sensitive variables
  --fresh            Ignore the saved run state: redo every phase and re-import everything
  --project SEG      Only handle this TFC project (repeatable; matches sg-payload.<SEG>.json)
  --workspace NAME   Only handle this workspace (repeatable; apply exports only it)
  --all              With 'clean': also remove config (terraform.tfvars, mapping, .sg)
  -v, --verbose      Show full terraform/tool output (default: concise)
  -y, --yes          Skip the import confirmation prompt
  -h, --help         Show this help

Environment:
  SG_API_TOKEN       StackGuardian API token (required for import)
  SG_ORG             StackGuardian org (alternative to --org)
  SG_RETRIES         Import retry attempts on failure (default: 4)
  SG_TF_PARALLELISM  terraform apply -parallelism (default: 20)
  SG_UI_URL          StackGuardian UI base for checklist links (default: https://app.stackguardian.io)
EOF
}

die() {
  sg_err "$*"
  exit 1
}

# phase_begin <title> — "==> Phase 2/5: title" inside 'all', "==> Phase: title"
# for a single command; starts the phase timer.
phase_begin() {
  PHASE_T0=$SECONDS
  if [ "$PHASE_TOTAL" -gt 0 ]; then
    PHASE_N=$((PHASE_N + 1))
    sg_step "Phase $PHASE_N/$PHASE_TOTAL: $1"
  else
    sg_step "Phase: $1"
  fi
}
# phase_took — "12s" / "1m 04s" since phase_begin.
phase_took() { sg_fmt_secs $((SECONDS - PHASE_T0)); }

# Ctrl-C: end the live progress line cleanly and say what happens next, instead
# of a bare "^C" (a background terraform/sg-cli gets the same SIGINT from the
# terminal, so nothing keeps running).
trap 'sg_spin_clear; printf "\n" >&2; sg_warn "interrupted — re-run the same command to pick up where this left off"; exit 130' INT

# rp_progress <statusdir> <label> <total> <t0> — one frame of the live
# "<label> — done/total (elapsed)" line while run_parallel waits.
rp_progress() {
  local finished=0 f
  for f in "$1"/*.rc; do [ -e "$f" ] && finished=$((finished + 1)); done
  sg_spin_frame "$2 ${C_DIM}— $finished/$3 done ($(sg_fmt_secs $((SECONDS - $4))))${C_RESET}"
}

# run_parallel <fn> <max> <label> <items...> — runs fn over items, up to max at
# a time, with a live progress line meanwhile. Each job's stdout+stderr is
# buffered to its own file (so concurrent tools see a non-TTY and don't scatter
# spinner output across the terminal), then flushed in submission order: a job
# that printed a single line is shown as-is, longer or failed output gets a
# "── <item> ──" header (always with -v). Returns non-zero if any job failed.
run_parallel() {
  local fn="$1" max="$2" label="$3"
  shift 3
  local statusdir i=0 rc=0 item total=$# t0=$SECONDS
  statusdir="$(mktemp -d)"
  [ "$SG_ANIMATE" = "1" ] || sg_log "$label, up to $max in parallel..."
  for item in "$@"; do
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$max" ]; do
      rp_progress "$statusdir" "$label" "$total" "$t0"
      sleep 0.2
    done
    (
      "$fn" "$item" >"$statusdir/$i.out" 2>&1
      echo "$?" >"$statusdir/$i.rc"
    ) &
    i=$((i + 1))
  done
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -gt 0 ]; do
    rp_progress "$statusdir" "$label" "$total" "$t0"
    sleep 0.2
  done
  wait
  sg_spin_clear
  i=0
  for item in "$@"; do
    if [ "$(cat "$statusdir/$i.rc" 2>/dev/null)" = "0" ]; then
      if [ "$VERBOSE" -eq 1 ] || [ "$(wc -l <"$statusdir/$i.out" | tr -d ' ')" -gt 1 ]; then
        printf '%s── %s ──%s\n' "$C_CYAN" "$(basename "$item")" "$C_RESET" >&2
      fi
    else
      printf '%s── %s ──%s\n' "$C_CYAN" "$(basename "$item")" "$C_RESET" >&2
      rc=1
    fi
    [ -s "$statusdir/$i.out" ] && cat "$statusdir/$i.out" >&2
    i=$((i + 1))
  done
  rm -rf "$statusdir"
  return "$rc"
}

# payload_sha — hash of the current payload files (the input of enrich/convert/validate).
payload_sha() {
  payload_files
  sg_sha_files ${PF[@]+"${PF[@]}"}
}

# run_phase <name> <input-sha> <fn> — in 'all', skip a phase that already ran
# with identical inputs; otherwise run it and record the inputs it ran with.
# apply and enrich are keyed by the apply inputs (tfvars + workspace filter):
# enrich only depends on what apply produced, and the later convert phase
# rewrites the payloads, so a payload hash could never match again. convert and
# validate record the post-run payload hash, so an unchanged export is
# recognised on the next run.
run_phase() {
  local name="$1" sha="$2" fn="$3" at
  if at="$(state_phase_done "$name" "$sha")" && [ -n "$at" ]; then
    at="${at%:*}"
    at="${at/T/ } UTC"
    if [ "$PHASE_TOTAL" -gt 0 ]; then
      PHASE_N=$((PHASE_N + 1))
      sg_log "skipping phase $PHASE_N/$PHASE_TOTAL ($name) — inputs unchanged since $at (--fresh to redo)"
    else
      sg_log "skipping $name — inputs unchanged since $at (--fresh to redo)"
    fi
    return 0
  fi
  "$fn" || return $?
  case "$name" in
  apply | enrich) state_mark_phase "$name" "$sha" ;;
  *) state_mark_phase "$name" "$(payload_sha)" ;;
  esac
}

# Populate PF with the generated payload files.
payload_files() {
  local f seg keep
  shopt -s nullglob
  PF=("$EXPORT_DIR"/sg-payload.*.json)
  shopt -u nullglob
  if [ "${#PROJECT_FILTER[@]}" -gt 0 ]; then
    keep=()
    for f in "${PF[@]}"; do
      seg="$(seg_of "$f")"
      case " ${PROJECT_FILTER[*]} " in *" $seg "*) keep+=("$f") ;; esac
    done
    PF=(${keep[@]+"${keep[@]}"})
  fi
}

# ws_filter_json — the --workspace names as a JSON array (empty array = no filter).
ws_filter_json() {
  if [ "${#WS_FILTER[@]}" -eq 0 ]; then echo '[]'; else names_json "${WS_FILTER[@]}"; fi
}

# ws_selected <name> — exit 0 when no --workspace filter is set or it lists <name>.
ws_selected() {
  [ "${#WS_FILTER[@]}" -eq 0 ] && return 0
  case " ${WS_FILTER[*]} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
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
  if ! sg_interactive; then
    # Non-interactive (CI, no TTY, -y): fall back to the template.
    if [ ! -f "$TFVARS" ]; then
      cp "$TRANSFORMER_DIR/terraform.tfvars.example" "$TFVARS"
      sg_log "created $(sg_rel "$TFVARS") from the template — edit it before 'apply' (run 'init' in a terminal for the guided setup)"
    else
      sg_log "$(sg_rel "$TFVARS") already exists"
    fi
  else
    if [ -f "$TFVARS" ]; then
      case "$(sg_select "$(sg_rel "$TFVARS") already exists"         "keep|leave it unchanged"         "rerun|run the wizard again (current values become the defaults; a .bak copy is kept)")" in
      keep) sg_log "keeping $(sg_rel "$TFVARS")" ;;
      rerun) wizard_run || return 1 ;;
      esac
    else
      sg_log "answer a few questions to generate $(sg_rel "$TFVARS"); tokens are read from the environment and never written to disk"
      wizard_run || return 1
    fi
  fi
  # A standalone 'init' ends with what to do next; 'all' just carries on.
  [ "${1:-}" = "standalone" ] && show_next_steps
  return 0
}

# show_next_steps — the commands that make sense after init. (A child process
# cannot register completions in the parent shell, so the completion line is a
# hint only; nothing is written to the user's rc files.)
show_next_steps() {
  sg_step "Next steps"
  next_row "$PROG all" "run the migration — the import plan is shown and confirmed before anything is created"
  next_row "$PROG apply" "export only: review the payloads in $(sg_rel "$EXPORT_DIR")/ first, then '$PROG import'"
  next_row "source <($PROG completion)" "tab completion for this shell session"
}
next_row() { printf '  %s%-38s%s %s%s%s\n' "$C_BOLD" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET" >&2; }

# current_shell — bash|zsh: the shell the user is typing in (detected by
# sg-migrate.sh from its parent process), else the login shell.
current_shell() {
  case "${SG_SHELL:-}" in bash | zsh) printf '%s' "$SG_SHELL"; return ;; esac
  case "$(basename "${SHELL:-}")" in bash) printf 'bash' ;; *) printf 'zsh' ;; esac
}

# --- workflow-group mapping (API helpers live in lib/sg_api.sh) -------------

# group_for <segment> -> the SG workflow group for a project segment: an entry
# from the optional override map, else the default tfc-<segment>.
group_for() {
  local seg="$1" override=""
  if [ -f "$MAPPING" ]; then
    override="$("$JQ_BIN" -r --arg k "$seg" '.[$k] // empty' "$MAPPING" 2>/dev/null || true)"
  fi
  [ -n "$override" ] && echo "$override" || echo "tfc-$seg"
}

# do_set_triggers <payload> — for each workflow in the file with a non-null
# VCSTriggers block, register its VCS triggers via the dedicated webhooks
# endpoint (the bulk create API silently drops VCSTriggers; this second pass is
# what actually wires up the repo webhook). Sends {VCSConfig, VCSTriggers} taken
# straight from the (converted) payload. Per-workflow failures are surfaced but
# do not abort the rest of the file.
do_set_triggers() {
  local f="$1" seg grp n i wf body rc=0 set=0 skip=0 ok=() failed=() missing=()
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  n="$("$JQ_BIN" 'length' "$f")"
  for ((i = 0; i < n; i++)); do
    if [ "$("$JQ_BIN" -r --argjson i "$i" '(.[$i].VCSTriggers // null) != null' "$f")" != "true" ]; then
      skip=$((skip + 1))
      continue
    fi
    wf="$("$JQ_BIN" -r --argjson i "$i" '.[$i].ResourceName' "$f")"
    ws_selected "$wf" || continue
    # A workflow that failed to import has nothing to attach triggers to.
    if ! sg_workflow_exists "$grp" "$wf"; then
      sg_warn "  $grp/$wf does not exist in SG (import failed?) — skipping triggers"
      missing+=("$wf")
      rc=1
      continue
    fi
    body="$("$JQ_BIN" -c --argjson i "$i" '{VCSConfig: .[$i].VCSConfig, VCSTriggers: .[$i].VCSTriggers}' "$f")"
    if SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- \
      sg_api_post "$(wf_triggers_endpoint "$grp" "$wf")" "$body"; then
      set=$((set + 1))
      ok+=("$wf")
    else
      sg_warn "  vcs triggers failed: $grp/$wf"
      failed+=("$wf")
      rc=1
    fi
  done
  sg_log "$(basename "$f"): set triggers on $set workflow(s) (skipped $skip without triggers)"
  "$JQ_BIN" -nc --arg g "$grp" \
    --argjson ok "$([ "${#ok[@]}" -gt 0 ] && names_json "${ok[@]}" || echo '[]')" \
    --argjson failed "$([ "${#failed[@]}" -gt 0 ] && names_json "${failed[@]}" || echo '[]')" \
    --argjson missing "$([ "${#missing[@]}" -gt 0 ] && names_json "${missing[@]}" || echo '[]')" \
    '{group: $g, set: $ok, failed: $failed, missing: $missing}' >"$EXPORT_DIR/.triggers-result.$seg.json"
  return "$rc"
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
  local rc=0 f seg
  run_parallel do_set_triggers "$CONC" "registering VCS triggers for $total workflow(s)" "${PF[@]}" || rc=1
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    if [ -f "$EXPORT_DIR/.triggers-result.$seg.json" ]; then
      state_update '.triggers[$s] = ($r + {at: $at})' --arg s "$seg" --argjson r "$(cat "$EXPORT_DIR/.triggers-result.$seg.json")" --arg at "$(state_now)"
      rm -f "$EXPORT_DIR/.triggers-result.$seg.json"
    fi
  done
  if [ "$rc" -eq 0 ]; then
    sg_success "VCS triggers registered for $total workflow(s)"
  else
    sg_err "one or more VCS trigger registrations failed (re-run: $PROG triggers)"
    return 1
  fi
}

cmd_triggers() {
  phase_begin "VCS triggers"
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
  phase_begin "clean"
  sg_log "removing local working artifacts..."
  rm -rf "$EXPORT_DIR"
  rm -rf "$TRANSFORMER_DIR/.terraform" "$TRANSFORMER_DIR/.terraform.lock.hcl" \
    "$TRANSFORMER_DIR/terraform.tfstate" "$TRANSFORMER_DIR/terraform.tfstate.backup"
  rm -rf "$SG_CACHE_DIR"
  state_reset
  if [ "$PURGE" -eq 1 ]; then
    rm -f "$TFVARS" "$MAPPING"
    rm -rf "$SG_REPO_ROOT/.sg"
    sg_log "also removed config (terraform.tfvars, workflow-groups.json, .sg)"
  fi
  sg_success "clean complete"
}

# tf_init / tf_apply — terraform in the transformer dir, with jq on PATH for the
# state export's local-exec. Always run in a subshell (sg_run_quiet backgrounds
# them; the verbose path wraps them in parentheses).
# shellcheck disable=SC2120  # extra terraform flags (-no-color) come from the quiet path
tf_init() { cd "$TRANSFORMER_DIR" && export PATH="$TF_PATH" TF_IN_AUTOMATION=1 && terraform init -input=false "$@"; }
tf_apply() { cd "$TRANSFORMER_DIR" && export PATH="$TF_PATH" TF_IN_AUTOMATION=1 && terraform apply -auto-approve -compact-warnings -parallelism="$TF_PARALLELISM" -var-file=terraform.tfvars "$@"; }

cmd_apply() {
  phase_begin "apply (terraform)"
  command -v terraform >/dev/null 2>&1 || die "terraform not found on PATH"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS"). Run: $PROG init"
  preflight_run apply
  # State export (TFC API) calls curl + jq from terraform's local-exec; make sure
  # both are on PATH for the apply (jq from cache if not already installed).
  command -v curl >/dev/null 2>&1 || die "curl is required for state export"
  local tflog rc=0
  local -a tfvar_args=()
  TF_PATH="$(dirname "$(sg_resolve jq sg_ensure_jq)"):$PATH"
  if [ "${#WS_FILTER[@]}" -gt 0 ]; then
    JQ_BIN="${JQ_BIN:-$(sg_resolve jq sg_ensure_jq)}"
    tfvar_args=(-var "workspacenames=$(ws_filter_json)")
    sg_log "limiting apply to workspace(s): ${WS_FILTER[*]}"
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    # shellcheck disable=SC2119
    (tf_init && tf_apply ${tfvar_args[@]+"${tfvar_args[@]}"}) || rc=$?
  else
    # Quiet: terraform's init/plan output goes to a log that is shown only on
    # failure; the terminal gets a live progress line per step instead.
    tflog="$(mktemp)"
    sg_run_quiet "initializing terraform providers" "terraform providers ready" "$tflog" tf_init -no-color || rc=$?
    if [ "$rc" -eq 0 ]; then
      sg_run_quiet "reading workspaces, generating payloads, exporting state" "workspaces read, payloads generated, state exported" "$tflog" \
        tf_apply -no-color ${tfvar_args[@]+"${tfvar_args[@]}"} || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      sg_err "terraform failed (rc=$rc):"
      cat "$tflog" >&2
    fi
    rm -f "$tflog"
  fi

  [ "$rc" -eq 0 ] || return "$rc"
  payload_files
  sg_success "apply complete in $(phase_took) — ${#PF[@]} payload file(s) in $(sg_rel "$EXPORT_DIR")/"
  show_migration_summary
}

cmd_enrich() {
  phase_begin "variable sets"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS") (run: $PROG init)."
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR") (run 'apply' first)."
  # Variable sets belong to the TFC org (tfOrg in terraform.tfvars), not SG_ORG.
  local tforg
  tforg="$(tfvars_get '.tfOrg')"
  [ -n "$tforg" ] || die "tfOrg not found in $(sg_rel "$TFVARS")"
  SG_TFC_HOSTNAME="$(tfc_hostname)" "$SCRIPT_DIR/enrich_variable_sets.sh" "$tforg" "${PF[@]}"
}

do_convert() { "$SCRIPT_DIR/convert_hcl_to_json.sh" "$1"; }

cmd_convert() {
  phase_begin "convert (HCL → JSON)"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR") (run 'apply' first)."
  if run_parallel do_convert "$CONC" "converting ${#PF[@]} payload file(s)" "${PF[@]}"; then
    sg_success "converted ${#PF[@]} payload file(s) in $(phase_took)"
  else
    sg_err "conversion failed for one or more payloads"
    return 1
  fi
}

cmd_validate() {
  phase_begin "validate"
  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."
  if "$SCRIPT_DIR/validate_payload.sh" "${PF[@]}"; then
    sg_success "${#PF[@]} payload file(s) valid against schema/sg-payload.schema.json"
  else
    sg_err "validation failed — fix the payload(s) above (or the transformer) and re-run '$PROG validate'"
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
  local f="$1" seg grp out rc=0 ceiling="" failed=() fb=() name line tmp names work all_names patch
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  # With --workspace, import only the selected workflows (a filtered copy).
  work="$f"
  if [ "${#WS_FILTER[@]}" -gt 0 ]; then
    work="$(mktemp "$EXPORT_DIR/.subset.$seg.XXXXXX")"
    "$JQ_BIN" --argjson names "$(ws_filter_json)" 'map(select(.ResourceName as $n | $names | index($n) != null))' "$f" >"$work"
    if [ "$("$JQ_BIN" 'length' "$work")" -eq 0 ]; then
      sg_log "$(basename "$f"): no selected workflows — skipped"
      rm -f "$work"
      return 0
    fi
  fi
  sg_log "importing $(basename "$f") -> $grp"
  out="$(mktemp)"
  sg_retry "$RETRIES" "$RETRY_BASE" -- sgcli_bulk "$grp" "$work" "$out" || rc=1
  all_names="$("$JQ_BIN" -c '[.[].ResourceName]' "$work")"

  while IFS= read -r line; do
    if [[ "$line" =~ $TF_CEILING_RE ]]; then
      fb+=("${BASH_REMATCH[1]}")
      ceiling="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed\ to\ create\ ([^:]+):\ [0-9]+:\ (.*)$ ]]; then
      failed+=("${BASH_REMATCH[1]}")
      explain_api_error "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed\ to\ create\ ([^:]+): ]]; then
      failed+=("${BASH_REMATCH[1]}")
    fi
  done <"$out"
  rm -f "$out"

  if [ "${#fb[@]}" -gt 0 ]; then
    sg_warn "${#fb[@]} workflow(s) pinned above SG's managed Terraform ceiling ($ceiling); re-importing with ${SG_TF_FALLBACK_LABEL:-$SG_DEFAULT_TF_VERSION}"
    names="$(names_json "${fb[@]}")"
    tmp="$(mktemp "$EXPORT_DIR/.fallback.$seg.XXXXXX")"
    # Patch the affected workflows in the payload and re-import only those: a
    # fixed fallback version, or (SGDefaultTerraformVersion = null) no version at
    # all so the API fills it from the org's execution preset.
    if [ -n "$SG_DEFAULT_TF_VERSION" ]; then
      patch='map(if (.ResourceName as $n | $names | index($n)) != null then .TerraformConfig.terraformVersion = $v else . end)'
    else
      patch='map(if (.ResourceName as $n | $names | index($n)) != null then del(.TerraformConfig.terraformVersion) else . end)'
    fi
    "$JQ_BIN" --arg v "$SG_DEFAULT_TF_VERSION" --argjson names "$names" "$patch" "$f" >"$tmp.full" &&
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
        printf '%s/%s: %s -> %s (above SG managed ceiling %s)\n' "$grp" "$name" "$line" "${SG_DEFAULT_TF_VERSION:-execution preset}" "$ceiling" >>"$EXPORT_DIR/terraform-version-fallbacks.log"
      fi
    done
    rm -f "$out"
    mv -f "$tmp.full" "$f"
    rm -f "$tmp"
  fi

  [ "$work" != "$f" ] && rm -f "$work"

  # Per-file result for the state file and the post-import checklist
  # (run_parallel jobs run in subshells, so the caller merges these).
  "$JQ_BIN" -nc --arg g "$grp" --arg sha "$(sg_sha_files "$f")" --argjson all "$all_names" \
    --argjson failed "$([ "${#failed[@]}" -gt 0 ] && names_json "${failed[@]}" || echo '[]')" \
    --argjson fallback "$([ "${#fb[@]}" -gt 0 ] && names_json "${fb[@]}" || echo '[]')" \
    '{group: $g, payload_sha: $sha, imported: ($all - $failed), failed: $failed, tf_fallback: ($fallback - $failed)}' \
    >"$EXPORT_DIR/.import-result.$seg.json"

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
  workflows above were created with ${SG_TF_FALLBACK_LABEL:-$SG_DEFAULT_TF_VERSION}
  instead of the version pinned in TFC, so they will run a different Terraform
  than before - verify the configuration is compatible before the first run. To
  keep a newer version, set workspaceOverrides[<name>].terraformVersion to a
  binary path mounted from a private runner, or point the org's execution preset
  (or the override) at a custom runtime image (wfStepTemplateRevisionId) that
  ships it, and re-import.
NOTICE
}

cmd_import() {
  phase_begin "import"
  [ -n "${SG_API_TOKEN:-}" ] || die "SG_API_TOKEN is not set."
  [ -n "$ORG" ] || die "StackGuardian org not set (use --org or SG_ORG)."
  command -v curl >/dev/null 2>&1 || die "curl is required for workflow-group checks/creation."
  # Both our API calls and sg-cli honor SG_BASE_URL (e.g. non-prod); export it
  # so the sg-cli child process inherits the same target.
  export SG_API_TOKEN SG_BASE_URL
  JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
  preflight_run import

  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."

  # Build the plan: resolve each project's group, check existence, and decide
  # which groups need creating. Override groups (from the map) must already exist.
  local fail=0 to_create=" " n_create=0 total_wf=0 f seg grp count override is_override code status fw gw q i
  local -a files=() groups=() counts=() statuses=()
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    count="$("$JQ_BIN" --argjson ws "$(ws_filter_json)" '[.[] | select(($ws | length) == 0 or (.ResourceName as $n | $ws | index($n) != null))] | length' "$f")"
    total_wf=$((total_wf + count))
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
        case "$to_create" in *" $grp "*) ;; *)
          to_create="$to_create$grp "
          n_create=$((n_create + 1))
          ;;
        esac
      else
        status="${C_RED}missing!${C_RESET}"
        fail=1
      fi
      ;;
    401 | 403) die "auth failed (HTTP $code) for org '$ORG' — check SG_API_TOKEN" ;;
    000) die "could not reach $SG_BASE_URL" ;;
    *) die "unexpected HTTP $code checking group '$grp'" ;;
    esac
    files+=("$(basename "$f")")
    groups+=("$grp")
    counts+=("$count")
    statuses+=("$status")
  done
  fw="$(sg_maxlen 4 "${files[@]}")"
  gw="$(sg_maxlen 14 "${groups[@]}")"
  printf '%sImport plan%s (org: %s%s%s, %s)\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$ORG" "$C_RESET" "$SG_BASE_URL" >&2
  printf "  %s%-${fw}s  %-${gw}s  %-9s %s%s\n" "$C_BOLD" "FILE" "WORKFLOW GROUP" "WORKFLOWS" "STATUS" "$C_RESET" >&2
  for ((i = 0; i < ${#files[@]}; i++)); do
    printf "  %-${fw}s  %-${gw}s  %-9s %s\n" "${files[i]}" "${groups[i]}" "${counts[i]}" "${statuses[i]}" >&2
  done
  if [ "$fail" -ne 0 ]; then
    die "some groups are missing (override groups are not auto-created; create them or remove the override)."
  fi

  # Fallback for workflows the API rejects as above the managed ceiling: a fixed
  # SGDefaultTerraformVersion (missing key = 1.5.7), or an explicit null in
  # terraform.tfvars = drop the version so the org's execution preset decides.
  # The preset itself is read so the plan can show what "preset" resolves to.
  if tfvars_is_null SGDefaultTerraformVersion; then
    SG_DEFAULT_TF_VERSION=""
  else
    SG_DEFAULT_TF_VERSION="${SG_DEFAULT_TF_VERSION:-$(tfvars_get '.SGDefaultTerraformVersion' TERRAFORM-1.5.7)}"
  fi
  # shellcheck disable=SC2034  # read by report.sh (plan) and checklist.sh
  SG_PRESET_JSON="$(sg_execution_preset)" || SG_PRESET_JSON=""
  preset_labels
  show_import_plan "${PF[@]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    sg_success "dry run — nothing was created or changed"
    return 0
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    q="Import $total_wf workflow(s) into $ORG"
    [ "$n_create" -gt 0 ] && q="$q and create $n_create workflow group(s)"
    sg_interactive || die "no terminal to confirm the import — re-run with -y to import without a prompt"
    if ! sg_confirm "$q?" N; then
      sg_warn "import cancelled — nothing was changed in $ORG"
      sg_dim "re-run '$PROG all' (or '$PROG import') to come back to this plan; the export phases are saved and skipped"
      return 1
    fi
  fi

  # Create the missing tfc-* groups before importing into them.
  for grp in $to_create; do
    sg_log "creating workflow group $grp"
    wfgroup_create "$grp" || die "failed to create workflow group $grp"
  done

  SGCLI_BIN="$(sg_resolve sg-cli sg_ensure_sgcli)"
  rm -f "$EXPORT_DIR/terraform-version-fallbacks.log"

  # Resume: skip payload files already imported in full with identical content
  # (a changed payload or a previous failure re-imports the whole file;
  # sg-cli updates existing workflows in place).
  local -a todo=()
  local skipped=0 import_rc=0
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    if [ "$FRESH" -eq 0 ] && [ "${#WS_FILTER[@]}" -eq 0 ] && state_import_done "$seg" "$(sg_sha_files "$f")"; then
      skipped=$((skipped + 1))
      continue
    fi
    todo+=("$f")
  done
  [ "$skipped" -gt 0 ] && sg_log "skipping $skipped payload file(s) already imported and unchanged (--fresh to re-import)"
  if [ "${#todo[@]}" -gt 0 ]; then
    run_parallel do_import "$CONC" "importing ${#todo[@]} payload file(s) (retries: $RETRIES)" "${todo[@]}" || import_rc=1
    for f in "${todo[@]}"; do
      seg="$(seg_of "$f")"
      if [ -f "$EXPORT_DIR/.import-result.$seg.json" ]; then
        state_record_import "$seg" "$(cat "$EXPORT_DIR/.import-result.$seg.json")"
        rm -f "$EXPORT_DIR/.import-result.$seg.json"
      fi
    done
  fi
  tf_fallback_notice
  if [ "$import_rc" -eq 0 ]; then
    sg_success "import complete (${#todo[@]} payload file(s) imported, $skipped skipped)"
  else
    sg_err "one or more workflows failed to import (see above); VCS triggers are still registered for the ones that succeeded"
  fi

  # VCS triggers are not accepted by the bulk create API; register them in a
  # second pass against the dedicated webhooks endpoint (skip with --no-vcs-triggers).
  if [ "$VCS_TRIGGERS" -eq 1 ]; then
    set_triggers_pass || import_rc=1
  fi
  [ "$SECRET_STUBS" -eq 1 ] && create_secret_stubs
  write_checklist
  finish_line "$import_rc"
  return "$import_rc"
}

# finish_line <rc> — the last line of an import / all run: outcome, total time,
# and whether the checklist still has items for a human.
finish_line() {
  local open="${CHECKLIST_OPEN:-0}" took
  took="$(sg_fmt_secs $((SECONDS - RUN_T0)))"
  if [ "$1" -ne 0 ]; then
    sg_err "finished with failures in $took — fix what is reported above and re-run '$PROG import' (only failed or changed files are retried)"
  elif [ "$open" -gt 0 ]; then
    sg_success "migration complete in $took — $open item(s) still need a human, see $(sg_rel "$EXPORT_DIR")/post-import-checklist.md"
  else
    sg_success "migration complete in $took — nothing left to do by hand"
  fi
}

# Single source of truth for shell completion (keep in sync with the parser below
# and the host-only flags in sg-migrate.sh).
SG_COMMANDS="init preflight apply enrich convert validate import triggers checklist all clean completion"
SG_OPTIONS="--org --export-dir --mapping --concurrency --no-create-groups --no-variable-sets --no-vcs-triggers --skip-preflight --dry-run --no-secret-stubs --fresh --project --workspace --all -v --verbose -y --yes -h --help --native --local --build"

# cmd_completion <bash|zsh> — print a completion script for sg-migrate.sh /
# migrate.sh to stdout. Both shells fall back to the basename when the command
# is invoked by path, so ./sg-migrate.sh completes too.
cmd_completion() {
  local shell="${1:-$(current_shell)}"
  case "$shell" in
  bash)
    cat <<BASH
# bash completion for sg-migrate.sh — generated by: sg-migrate.sh completion bash
# Sourced from zsh by mistake? Load the zsh version instead.
if [ -n "\${ZSH_VERSION:-}" ]; then
  source <("$SG_REPO_ROOT/sg-migrate.sh" completion zsh)
  return 0
fi
_sg_migrate() {
  local cur prev cmds opts w has_cmd=0
  cur="\${COMP_WORDS[COMP_CWORD]}"; prev="\${COMP_WORDS[COMP_CWORD-1]}"
  cmds="$SG_COMMANDS"
  opts="$SG_OPTIONS"
  case "\$prev" in
    --export-dir) COMPREPLY=(\$(compgen -d -- "\$cur")); return ;;
    --mapping) COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
    --org | --concurrency | --project | --workspace) COMPREPLY=(); return ;;
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
# Sourced from bash by mistake? Load the bash version instead.
if [ -n "\${BASH_VERSION:-}" ]; then
  source <("$SG_REPO_ROOT/sg-migrate.sh" completion bash)
  return 0
fi
_sg_migrate() {
  local -a cmds
  cmds=(
    'init:Guided setup — generates terraform.tfvars'
    'preflight:Verify tokens and every id in terraform.tfvars before running'
    'apply:Run the transformer (terraform apply)'
    'enrich:Merge TFC Variable Set variables into the payloads'
    'convert:Convert HCL-string variables to JSON'
    'validate:Validate payloads against the SG schema'
    'import:Import payloads to StackGuardian, then register VCS triggers'
    'triggers:Register VCS triggers for already-imported workflows'
    'checklist:Write the post-import checklist (and create secret stubs)'
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
    '--skip-preflight[Skip the preflight checks]' \\
    '--dry-run[With import: show the plan and stop]' \\
    '--no-secret-stubs[Do not create placeholder SG secrets for sensitive vars]' \\
    '--fresh[Ignore saved run state: redo every phase]' \\
    '*--project[Only this TFC project segment]:segment' \\
    '*--workspace[Only this workspace]:name' \\
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
  *) die "usage: $PROG completion [bash|zsh] (default: the shell you are running)" ;;
  esac
}

# main — argument parsing and dispatch. Kept in a function so bash parses the
# whole file before running anything: the repo is bind-mounted into the
# container, and a script edited while it runs would otherwise be read
# half-old, half-new.
main() {
  local CMD=""
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
    --skip-preflight) export SKIP_PREFLIGHT=1 ;;
    --fresh) FRESH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-secret-stubs) SECRET_STUBS=0 ;;
    --project)
      PROJECT_FILTER+=("$2")
      shift
      ;;
    --project=*) PROJECT_FILTER+=("${1#*=}") ;;
    --workspace)
      WS_FILTER+=("$2")
      shift
      ;;
    --workspace=*) WS_FILTER+=("${1#*=}") ;;
    -v | --verbose) VERBOSE=1 ;;
    --all) PURGE=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    init | apply | enrich | convert | validate | import | triggers | all | clean | preflight | checklist) CMD="$1" ;;
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
  init) cmd_init standalone ;;
  clean) cmd_clean ;;
  apply) cmd_apply ;;
  enrich) cmd_enrich ;;
  convert) cmd_convert ;;
  validate) cmd_validate ;;
  import) cmd_import ;;
  triggers) cmd_triggers ;;
  preflight)
    export SG_API_TOKEN SG_BASE_URL
    cmd_preflight
    ;;
  checklist) cmd_checklist ;;
  all)
    if [ ! -f "$TFVARS" ]; then
      cmd_init || exit 1
      if ! sg_interactive; then
        # Template copy: it still contains placeholders.
        die "Edit $(sg_rel "$TFVARS"), then re-run '$PROG all'."
      fi
      echo >&2
      if ! sg_confirm "Continue with the migration now? (No = edit $(sg_rel "$TFVARS") first, e.g. workspaceOverrides, then re-run '$PROG all')" Y; then
        sg_log "edit $(sg_rel "$TFVARS"), then re-run '$PROG all'"
        exit 0
      fi
    fi
    # Fail fast on everything the whole pipeline needs, before the (long) apply.
    export SG_API_TOKEN SG_BASE_URL
    preflight_run all
    [ "$FRESH" -eq 1 ] && { state_reset; sg_log "--fresh: previous run state discarded"; }
    JQ_BIN="$(sg_resolve jq sg_ensure_jq)"
    PHASE_TOTAL=4
    [ "$ENRICH_VARSETS" -eq 1 ] && PHASE_TOTAL=5
    local apply_sha
    apply_sha="$(sg_sha "$(sg_sha_files "$TFVARS")|$(ws_filter_json)")"
    run_phase apply "$apply_sha" cmd_apply
    if [ "$ENRICH_VARSETS" -eq 1 ]; then run_phase enrich "$apply_sha" cmd_enrich; fi
    run_phase convert "$(payload_sha)" cmd_convert
    run_phase validate "$(payload_sha)" cmd_validate
    cmd_import
    ;;
  esac
}

main "$@"
