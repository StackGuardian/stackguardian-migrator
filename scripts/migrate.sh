#!/bin/bash
# End-to-end StackGuardian migration orchestrator.
#
# Runs apply -> convert -> validate -> import, resolving tooling from PATH first
# (e.g. inside the Docker image) and falling back to cached downloads when run
# natively. Designed to run both on the host and inside the migrator container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Captured before the libraries load: lib/checklist.sh gives SG_UI_URL a
# default, and region_apply must know whether the user set it explicitly.
SG_UI_URL_SET="${SG_UI_URL:-}"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"
# shellcheck source=lib/tfvars.sh
source "$SCRIPT_DIR/lib/tfvars.sh"
# shellcheck source=lib/scope.sh
source "$SCRIPT_DIR/lib/scope.sh"
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
# The tfvars file: terraform.tfvars in the module dir unless --tfvars / SG_TFVARS
# points elsewhere (CI keeps its copy outside the checkout). abs_path keeps it
# valid after the cd into the module dir that terraform needs.
abs_path() {
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(cd "$(dirname "$1")" 2>/dev/null && pwd || dirname "$1")" "$(basename "$1")" ;; esac
}
TFVARS_DEFAULT="$TRANSFORMER_DIR/terraform.tfvars"
TFVARS="$TFVARS_DEFAULT"
[ -n "${SG_TFVARS:-}" ] && TFVARS="$(abs_path "$SG_TFVARS")"
PROG="${SG_PROG:-$0}"
EXPORT_DIR="${SG_EXPORT_DIR:-$SG_REPO_ROOT/export}"
MAPPING="${SG_WFGROUP_MAP:-$SG_REPO_ROOT/.sg/workflow-groups.json}"
ORG="${SG_ORG:-}"
# StackGuardian region: --region / SG_REGION picks the API and UI hosts (eu is
# the default; us; dash = the internal QA environment). An explicit SG_BASE_URL
# or SG_UI_URL always wins over the region's host. Applied by region_apply once
# the flags are parsed and the state consulted.
SG_REGION="${SG_REGION:-}"
SG_BASE_URL_SET="${SG_BASE_URL:-}"
SG_BASE_URL="${SG_BASE_URL:-https://api.app.stackguardian.io}"
SG_UI_URL="${SG_UI_URL:-https://app.stackguardian.io}"
# region_urls <region> — "<api-url> <ui-url>", exit 1 for an unknown region.
region_urls() {
  case "$1" in
  eu) printf 'https://api.app.stackguardian.io https://app.stackguardian.io' ;;
  us) printf 'https://api.us.stackguardian.io https://us.stackguardian.io' ;;
  dash) printf 'https://testapi.qa.stackguardian.io https://dash.qa.stackguardian.io' ;; # internal QA
  *) return 1 ;;
  esac
}
region_apply() {
  local urls
  SG_REGION="${SG_REGION:-eu}"
  urls="$(region_urls "$SG_REGION")" || die "unknown --region '$SG_REGION' (eu or us)"
  [ -z "$SG_BASE_URL_SET" ] && SG_BASE_URL="${urls% *}"
  [ -z "$SG_UI_URL_SET" ] && SG_UI_URL="${urls#* }"
  export SG_BASE_URL SG_UI_URL
}
ASSUME_YES=0
PURGE=0
UPGRADE=0
# Set once the export ran (or was found up to date) in this process: the run
# configuration flags reach the workflows through the payload the export writes.
RAN_APPLY=0
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
  if [ -n "$ORG" ] && [ -z "$SG_REGION" ] && [ -z "$SG_BASE_URL_SET" ]; then
    # The region init ran with; older state files only carry the API host.
    SG_REGION="$(state_read | "$(sg_resolve jq sg_ensure_jq)" -r '.config.sg_region // empty' 2>/dev/null || true)"
    if [ -z "$SG_REGION" ]; then
      SG_BASE_URL_SET="$(state_read | "$(sg_resolve jq sg_ensure_jq)" -r '.config.sg_base_url // empty' 2>/dev/null || true)"
      [ -n "$SG_BASE_URL_SET" ] && SG_BASE_URL="$SG_BASE_URL_SET"
    fi
  fi
fi


usage() {
  cat >&2 <<EOF
Usage: $PROG [options] <command>

Commands:
  init        Guided setup: discovers TFC/SG resources and writes terraform.tfvars
              (--upgrade: append the settings an older file lacks, with defaults;
              nothing else is touched, no prompts)
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
  update      Pull the latest version of the migrator (git pull --ff-only) and rebuild
              the Docker image if the Dockerfile changed. Runs on the host.

Each TFC project is imported into the workflow group the transformer assigned to
it: projectOverrides.<project>.workflowGroup in terraform.tfvars, or tfc-<project>.
An existing group is reused, a missing one is created (--no-create-groups to
require it). Workflows are never moved: when a project's workflows already live
in another group the plan stops and says so.

Options:
  --org NAME         StackGuardian org for import (or set SG_ORG)
  --region eu|us     StackGuardian region: eu = api.app/app.stackguardian.io (default),
                     us = api.us/us.stackguardian.io (or set SG_REGION; init remembers it)
  --export-dir DIR   Payload/state output dir (default: ./export)
  --tfvars FILE      Use this tfvars file instead of transformer/terraform-cloud/terraform.tfvars
                     (or set SG_TFVARS); the file the transformer, enrich and preflight read
  --mapping FILE     Deprecated: project-segment -> group override map (default: .sg/workflow-groups.json);
                     use projectOverrides.<project>.workflowGroup instead
  --concurrency N    Max parallel jobs for convert/import (default: 4)
  --no-create-groups Do not create missing workflow groups; require them to exist
  --no-variable-sets Skip merging TFC Variable Set variables in the 'all' flow
  --no-vcs-triggers  Skip registering VCS triggers after import
  --skip-preflight   Skip the preflight checks (not recommended)
  --dry-run          With 'import' or 'all': show the per-workflow plan and stop before anything is
                     created in StackGuardian ('all' still runs the local export phases);
                     the plan is also written to export/run-result.json and run-summary.md
  --no-secret-stubs  Do not create placeholder SG secrets for sensitive variables
  --fresh            Ignore the saved run state: redo every phase and re-import everything
  --project NAME     Only handle this TFC project, by name or slug (repeatable; apply exports
                     only its workspaces, later phases use sg-payload.<slug>.json)
  --workspace GLOB   Only handle matching workspaces (repeatable; "team-*", "*" = all;
                     replaces workspacenames for this run, every phase selects the same ones)
  --exclude-workspace GLOB
                     Leave matching workspaces out (repeatable; adds to tfWorkspaceIgnoreNames)
  --tag NAME         Only workspaces carrying every given tag (repeatable; replaces
                     tfWorkspaceTags for the export)
  --exclude-tag NAME Leave workspaces carrying the tag out (repeatable; adds to tfWorkspaceIgnoreTags)
  --all              With 'clean': also remove config (terraform.tfvars, mapping, .sg)
  --upgrade          With 'init': append missing settings to an existing terraform.tfvars

Run configuration (on top of terraform.tfvars, for this run only; with --project
they apply to that project's workflows, otherwise as the defaults):
  --cloud-connector ID   Cloud connector (/integrations/<name>); its kind is looked up in SG
  --vcs-connector ID     VCS connector; kind and repo URL prefix follow the connector
  --runner-group NAME    Private runner group for the workflows ("shared" = SG runners)
  --workflow-group NAME  Workflow group for the project's workflows (needs --project)
  --set KEY=VALUE        Any transformer variable, e.g. --set SGDefaultTerraformVersion=null
                         (repeatable; HCL/JSON value, bare text is a string)
  -v, --verbose      Show full terraform/tool output (default: concise)
  -y, --yes          Skip the import confirmation prompt
  -h, --help         Show this help

Environment:
  SG_API_TOKEN       StackGuardian API token (required for import)
  SG_ORG             StackGuardian org (alternative to --org)
  SG_RETRIES         Import retry attempts on failure (default: 4)
  SG_TF_PARALLELISM  terraform apply -parallelism (default: 20)
  SG_TFVARS          tfvars file to use (same as --tfvars)
  SG_REGION          StackGuardian region (same as --region)
  SG_BASE_URL        StackGuardian API base URL; overrides the region's host
  SG_UI_URL          StackGuardian UI base for checklist links; overrides the region's host
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
  # --project accepts the TFC name or the payload segment (lib/scope.sh).
  if [ "${#PROJECT_FILTER[@]}" -gt 0 ]; then
    keep=()
    for f in "${PF[@]}"; do
      seg="$(seg_of "$f")"
      project_selected "$seg" && keep+=("$f")
    done
    PF=(${keep[@]+"${keep[@]}"})
  fi
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
  if [ "$UPGRADE" -eq 1 ]; then
    # Bring an older file up to date without asking anything: append the
    # settings it lacks with their defaults and comments, touch nothing else.
    [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS") — nothing to upgrade. Run: $PROG init"
    local added parse_err
    if ! parse_err="$(tfvars_valid)"; then die "$(sg_rel "$TFVARS") is not valid HCL: ${parse_err:-parse error}"; fi
    added="$(tfvars_upgrade)" || die "could not upgrade $(sg_rel "$TFVARS")"
    if [ -z "$added" ]; then
      sg_success "$(sg_rel "$TFVARS") is up to date — every setting of this version is present"
    else
      sg_success "appended $(wc -l <<<"$added" | tr -d ' ') setting(s) to $(sg_rel "$TFVARS") with their defaults (previous version kept as $(basename "$TFVARS").bak):"
      sed 's/^/    /' <<<"$added" >&2
      sg_dim "review them at the end of the file; a default is the same as leaving the setting out"
    fi
    return 0
  fi
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
# payload_group <file> — the workflow group the transformer wrote into the
# file's entries (CLIConfiguration.WorkflowGroup.name); "" when absent or mixed.
payload_group() {
  "$JQ_BIN" -r '[.[] | .CLIConfiguration.WorkflowGroup.name // empty] | unique | if length == 1 then .[0] else "" end' "$1" 2>/dev/null
}

# mapped_group <segment> — the legacy .sg/workflow-groups.json entry, if any.
mapped_group() {
  [ -f "$MAPPING" ] || return 0
  "$JQ_BIN" -r --arg k "$1" '.[$k] // empty' "$MAPPING" 2>/dev/null || true
}

# group_for <segment> — a project's target workflow group: the legacy mapping
# entry (deprecated), else the group in the payload (projectOverrides.<project>
# .workflowGroup or tfc-<project>, written by the transformer), else
# tfc-<segment>. Silent: also runs inside run_parallel subshells.
group_for() {
  local seg="$1" f="$EXPORT_DIR/sg-payload.$seg.json" g
  g="$(mapped_group "$seg")"
  [ -n "$g" ] || { [ -f "$f" ] && g="$(payload_group "$f")"; }
  printf '%s' "${g:-tfc-$seg}"
}

# plan_groups <payload>... — the workflow-group part of the import plan. Each
# file's target group is checked and shown as reuse (exists), create (missing,
# created before the import) or missing! (--no-create-groups). Two things block
# an import and are collected in PLAN_PROBLEMS: a project whose workflows
# already live in another group (StackGuardian cannot move workflows between
# groups), and two projects sharing a group with overlapping workflow names (a
# name is unique within a group). Sets PLAN_TO_CREATE, PLAN_N_CREATE,
# PLAN_TOTAL_WF; the caller shows the problems and stops after the full plan.
plan_groups() {
  local f seg grp count code status plain prev still n_still names fw gw i legacy=0 line
  local -a paths=("$@") files=() groups=() counts=() statuses=() plains=()
  PLAN_TO_CREATE=" "
  PLAN_N_CREATE=0
  PLAN_TOTAL_WF=0
  PLAN_PROBLEMS=()
  ws_jq_args
  for f in "${paths[@]}"; do
    seg="$(seg_of "$f")"
    names="$("$JQ_BIN" -c "${WS_JQ_ARGS[@]}" "$WS_SCOPE_JQ"'[.[] | select(.ResourceName | ws_selected) | .ResourceName]' "$f")"
    count="$("$JQ_BIN" 'length' <<<"$names")"
    PLAN_TOTAL_WF=$((PLAN_TOTAL_WF + count))
    grp="$(group_for "$seg")"
    [ -n "$(mapped_group "$seg")" ] && legacy=$((legacy + 1))
    if [ -z "$(payload_group "$f")" ] && [ "$count" -gt 0 ]; then
      sg_warn "$(basename "$f") carries no (or mixed) CLIConfiguration.WorkflowGroup.name — re-run 'apply'; using $grp"
    fi

    code="$(wfgroup_http_code "$grp")"
    case "$code" in
    200) status="${C_GREEN}reuse${C_RESET}"; plain=reuse ;;
    404)
      if [ "$CREATE_GROUPS" -eq 1 ]; then
        status="${C_YELLOW}create${C_RESET}"; plain=create
        case "$PLAN_TO_CREATE" in *" $grp "*) ;; *)
          PLAN_TO_CREATE="$PLAN_TO_CREATE$grp "
          PLAN_N_CREATE=$((PLAN_N_CREATE + 1))
          ;;
        esac
      else
        status="${C_RED}missing!${C_RESET}"; plain="missing!"
        PLAN_PROBLEMS+=("workflow group '$grp' ($(basename "$f")) does not exist and --no-create-groups is set — create it in StackGuardian or drop the flag")
      fi
      ;;
    401 | 403) die "auth failed (HTTP $code) for org '$ORG' — check SG_API_TOKEN" ;;
    000) die "could not reach $SG_BASE_URL" ;;
    *) die "unexpected HTTP $code checking group '$grp'" ;;
    esac

    # Never move: if this project's workflows were imported into another group
    # before (state), or would sit in the default tfc-<segment> group when the
    # target is now a different one, and they still exist there, refuse.
    prev="$(state_read | "$JQ_BIN" -r --arg s "$seg" '.import[$s].group // empty')"
    [ -z "$prev" ] && [ "$grp" != "tfc-$seg" ] && prev="tfc-$seg"
    if [ -n "$prev" ] && [ "$prev" != "$grp" ] && [ "$(wfgroup_http_code "$prev")" = "200" ]; then
      still="$("$JQ_BIN" -nc --argjson ex "$(sg_list_workflows "$prev")" --argjson mine "$names" '[$mine[] | select(. as $n | $ex | index($n) != null)]')"
      n_still="$("$JQ_BIN" 'length' <<<"$still")"
      if [ "$n_still" -gt 0 ]; then
        status="${C_RED}moved!${C_RESET}"; plain="moved!"
        PLAN_PROBLEMS+=("$(basename "$f"): $n_still workflow(s) already live in group '$prev' but the target is now '$grp' — StackGuardian cannot move workflows between groups; keep '$prev' (projectOverrides.\"<project>\".workflowGroup) or delete them from '$prev' first: $("$JQ_BIN" -r 'join(", ")' <<<"$still")")
      else
        sg_dim "$(basename "$f"): previous group '$prev' no longer holds these workflows — importing into '$grp'"
      fi
    fi
    files+=("$(basename "$f")")
    groups+=("$grp")
    counts+=("$count")
    statuses+=("$status")
    plains+=("$plain")
  done
  # Plain copy of the table for the run result (report.sh write_run_result).
  PLAN_GROUP_ROWS="$(for ((i = 0; i < ${#files[@]}; i++)); do
    "$JQ_BIN" -nc --arg f "${files[i]}" --arg g "${groups[i]}" --argjson n "${counts[i]}" --arg s "${plains[i]}" '{file: $f, group: $g, workflows: $n, status: $s}'
  done | "$JQ_BIN" -sc .)"

  # Two projects may share a group only when their workflow names do not overlap.
  while IFS= read -r line; do
    [ -n "$line" ] && PLAN_PROBLEMS+=("$line")
  done < <(for ((i = 0; i < ${#paths[@]}; i++)); do
    "$JQ_BIN" -c --arg seg "$(seg_of "${paths[i]}")" --arg grp "${groups[i]}" "${WS_JQ_ARGS[@]}" \
      "$WS_SCOPE_JQ"'{seg: $seg, grp: $grp, names: [.[] | select(.ResourceName | ws_selected) | .ResourceName]}' "${paths[i]}"
  done | "$JQ_BIN" -sr '
      group_by(.grp)[] | select(length > 1) | .[0].grp as $g
      | ([.[].names[]] | group_by(.) | map(select(length > 1) | .[0])) as $dups
      | select(($dups | length) > 0)
      | "workflow name(s) \($dups | join(", ")) appear in more than one project mapped to group \u0027\($g)\u0027 (\([.[].seg] | join(", "))) — a workflow name is unique within a group; give one of the projects its own workflowGroup"')

  fw="$(sg_maxlen 4 "${files[@]}")"
  gw="$(sg_maxlen 14 "${groups[@]}")"
  printf '%sImport plan%s (org: %s%s%s, %s)\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$ORG" "$C_RESET" "$SG_BASE_URL" >&2
  printf "  %s%-${fw}s  %-${gw}s  %-9s %s%s\n" "$C_BOLD" "FILE" "WORKFLOW GROUP" "WORKFLOWS" "STATUS" "$C_RESET" >&2
  for ((i = 0; i < ${#files[@]}; i++)); do
    printf "  %-${fw}s  %-${gw}s  %-9s %s\n" "${files[i]}" "${groups[i]}" "${counts[i]}" "${statuses[i]}" >&2
  done
  if [ "$legacy" -gt 0 ]; then
    sg_warn "$(sg_rel "$MAPPING") overrides the group of $legacy project(s) — this file is deprecated; set projectOverrides.\"<project>\".workflowGroup in $(sg_rel "$TFVARS") instead (project names: workspaceProjects in $(sg_rel "$EXPORT_DIR")/migration-summary.json) and re-run 'apply'"
  fi
  for line in ${PLAN_PROBLEMS[@]+"${PLAN_PROBLEMS[@]}"}; do
    printf '  %s✗%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$line" >&2
  done
}

# do_set_triggers <payload> — for each workflow in the file with a non-null
# VCSTriggers block, register its VCS triggers via the dedicated webhooks
# endpoint (the bulk create API silently drops VCSTriggers; this second pass is
# what actually wires up the repo webhook). Sends {VCSConfig, VCSTriggers} taken
# straight from the (converted) payload. The endpoint upserts, so a re-run is
# safe; to avoid needless calls the sha of each body is kept in state
# (triggers.<seg>.sha) and an unchanged, already-set workflow is skipped
# (--fresh re-sends everything). Per-workflow failures are surfaced but do not
# abort the rest of the file.
do_set_triggers() {
  local f="$1" seg grp n i wf body sha prev rc=0 skip=0 ok=() failed=() missing=() unchanged=() shas='{}'
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  prev="$(state_read | "$JQ_BIN" -c --arg s "$seg" '.triggers[$s] // {}')"
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
    sha="$(sg_sha "$body")"
    if [ "$FRESH" -eq 0 ] && [ "$("$JQ_BIN" -r --arg w "$wf" --arg h "$sha" '((.sha // {})[$w] // "") == $h and ((.set // []) | index($w) != null)' <<<"$prev")" = "true" ]; then
      unchanged+=("$wf")
      shas="$("$JQ_BIN" -c --arg w "$wf" --arg h "$sha" '.[$w] = $h' <<<"$shas")"
      continue
    fi
    if SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_set_vcs_triggers "$grp" "$wf" "$body"; then
      ok+=("$wf")
      shas="$("$JQ_BIN" -c --arg w "$wf" --arg h "$sha" '.[$w] = $h' <<<"$shas")"
    else
      sg_warn "  vcs triggers failed: $grp/$wf"
      failed+=("$wf")
      rc=1
    fi
  done
  sg_log "$(basename "$f"): triggers set on ${#ok[@]} workflow(s), ${#unchanged[@]} unchanged, skipped $skip without triggers"
  "$JQ_BIN" -nc --arg g "$grp" --argjson sha "$shas" \
    --argjson ok "$([ "${#ok[@]}" -gt 0 ] && names_json "${ok[@]}" || echo '[]')" \
    --argjson unchanged "$([ "${#unchanged[@]}" -gt 0 ] && names_json "${unchanged[@]}" || echo '[]')" \
    --argjson failed "$([ "${#failed[@]}" -gt 0 ] && names_json "${failed[@]}" || echo '[]')" \
    --argjson missing "$([ "${#missing[@]}" -gt 0 ] && names_json "${missing[@]}" || echo '[]')" \
    '{group: $g, set: ($ok + $unchanged), unchanged: $unchanged, failed: $failed, missing: $missing, sha: $sha}' >"$EXPORT_DIR/.triggers-result.$seg.json"
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
    # Only the module's own file; a --tfvars / SG_TFVARS file belongs to the user.
    rm -f "$TFVARS_DEFAULT" "$MAPPING"
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
tf_apply() { cd "$TRANSFORMER_DIR" && export PATH="$TF_PATH" TF_IN_AUTOMATION=1 && terraform apply -auto-approve -compact-warnings -parallelism="$TF_PARALLELISM" -var-file="$TFVARS" "$@"; }

cmd_apply() {
  phase_begin "apply (terraform)"
  RAN_APPLY=1
  command -v terraform >/dev/null 2>&1 || die "terraform not found on PATH"
  [ -f "$TFVARS" ] || die "Missing $(sg_rel "$TFVARS"). Run: $PROG init"
  # terraform auto-loads terraform.tfvars from the module dir on top of -var-file.
  if [ "$TFVARS" != "$TFVARS_DEFAULT" ] && [ -f "$TFVARS_DEFAULT" ]; then
    sg_warn "$(sg_rel "$TFVARS_DEFAULT") exists too: terraform loads it first, $(sg_rel "$TFVARS") overrides per variable — remove it if that is not intended"
  fi
  preflight_run apply
  # State export (TFC API) calls curl + jq from terraform's local-exec; make sure
  # both are on PATH for the apply (jq from cache if not already installed).
  command -v curl >/dev/null 2>&1 || die "curl is required for state export"
  local tflog rc=0
  local -a tfvar_args=()
  TF_PATH="$(dirname "$(sg_resolve jq sg_ensure_jq)"):$PATH"
  # The CLI scope goes to terraform as -var flags (lib/scope.sh): --workspace
  # replaces workspacenames for this run, --exclude-workspace adds to
  # tfWorkspaceIgnoreNames; the module applies the tag filters on top.
  scope_tfvar_args
  tfvar_args=(${SCOPE_TFVAR_ARGS[@]+"${SCOPE_TFVAR_ARGS[@]}"})
  # Scope flags are logged here; the configuration overlay was logged by overlay_build.
  [ -n "$(scope_describe)" ] && sg_log "run scope: $(scope_describe)"

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
  TFVARS="$TFVARS" SG_TFC_HOSTNAME="$(tfc_hostname)" "$SCRIPT_DIR/enrich_variable_sets.sh" "$tforg" "${PF[@]}"
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

# state_path_of <file> <wf> — the payload entry's TfStateFilePath ("" if none).
state_path_of() { "$JQ_BIN" -r --arg n "$2" '.[] | select(.ResourceName == $n) | .CLIConfiguration.TfStateFilePath // empty' "$1"; }

# upload_state <group> <wf> <file> <out> — upload the workflow's state file
# ourselves and append a "[state] uploaded|failed|none <wf>[: why]" marker to
# <out> for do_import. Returns 1 only when the workflow has a state file that
# did not land.
upload_state() {
  local grp="$1" name="$2" file="$3" out="$4" path why
  path="$(state_path_of "$file" "$name")"
  if [ -z "$path" ]; then
    printf '[state] none %s\n' "$name" >>"$out"
    return 0
  fi
  if [ ! -f "$path" ]; then
    sg_warn "  $name: state file missing: $(sg_rel "$path")"
    printf '[state] failed %s: state file missing (%s)\n' "$name" "$path" >>"$out"
    return 1
  fi
  if why="$(sg_upload_tfstate "$grp" "$name" "$path")"; then
    sg_log "  $name: state file uploaded"
    printf '[state] uploaded %s\n' "$name" >>"$out"
    return 0
  fi
  sg_warn "  $name: state file upload failed — $why"
  printf '[state] failed %s: %s\n' "$name" "$why" >>"$out"
  return 1
}

# import_bulk <group> <file> <out> — import one payload file: sg-cli for the
# workflows that have Terraform variables, a direct API POST for the ones
# without — sg-cli drops an empty iacInputData.data and the API then rejects
# the workflow. TODO(sg-cli): workaround; remove the split once sg-cli ships
# with sg-sdk-go >= v1.5.7 (see sg_create_workflow). The direct path writes
# the same "Failed to create <name>: <code>: <body>" lines sg-cli prints, so
# do_import parses both alike.
#
# State files are the migrator's responsibility on both paths: whatever
# sg-cli reports as a failed upload is uploaded again by upload_state, and
# every workflow ends up with a "[state] ..." marker in <out>.
#
# Workflows that already exist (re-runs, retries, the probe) come back from
# sg-cli as "Failed to create <wf>: 409: Workflow ID not unique" — its own
# update path never triggers (TODO(sg-cli), see sg_update_workflow) — and are
# updated here via PATCH, state included; their failure line is dropped.
#
# Like sg-cli, exits 0 even when individual workflows were rejected —
# do_import reads those from <out>; non-zero only when a call itself could
# not be made.
import_bulk() {
  local grp="$1" file="$2" out="$3" rc=0 n_direct with_vars entry name err line cur="" cli_out pat known upd_names create_file
  local -a redo=() exists=() updated=()
  : >"$out"

  # Workflows that already exist in the group (the plan's "update" rows) are
  # PATCHed straight away, with their state re-uploaded; only the rest goes
  # through the create path below. The 409 handling further down stays as the
  # safety net for a workflow created between the plan and this call.
  create_file="$file"
  known="$(sg_list_workflows "$grp")"
  printf '%s' "$known" | "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 || known='[]'
  upd_names="$("$JQ_BIN" -c --argjson ex "$known" '[.[].ResourceName | select(. as $n | $ex | index($n) != null)]' "$file")"
  if [ "$("$JQ_BIN" 'length' <<<"$upd_names")" -gt 0 ]; then
    sg_log "$("$JQ_BIN" 'length' <<<"$upd_names") workflow(s) already exist in $grp — updating them"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      entry="$("$JQ_BIN" -c --arg n "$name" 'first(.[] | select(.ResourceName == $n))' "$file")"
      if err="$(SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_update_workflow "$grp" "$entry" 2>/dev/null)"; then
        sg_log "  $name: updated"
        printf '[updated] %s\n' "$name" >>"$out"
        upload_state "$grp" "$name" "$file" "$out" || true
      else
        # Same shape as sg-cli's failure line (parsed by do_import).
        printf 'Failed to update %s: %s\n' "$name" "$(tail -n1 <<<"$err")" | tee -a "$out"
      fi
    done < <("$JQ_BIN" -r '.[]' <<<"$upd_names")
    create_file="$(mktemp)"
    "$JQ_BIN" --argjson u "$upd_names" 'map(select(.ResourceName as $n | $u | index($n) == null))' "$file" >"$create_file"
  fi

  n_direct="$("$JQ_BIN" '[.[] | select((.VCSConfig.iacInputData.data // {}) | length == 0)] | length' "$create_file")"
  with_vars="$create_file"
  if [ "$n_direct" -gt 0 ]; then
    with_vars="$(mktemp)"
    "$JQ_BIN" 'map(select((.VCSConfig.iacInputData.data // {}) | length > 0))' "$create_file" >"$with_vars"
  fi
  if [ "$("$JQ_BIN" length "$with_vars")" -gt 0 ]; then
    cli_out="$(mktemp)"
    sg_retry "$RETRIES" "$RETRY_BASE" -- sgcli_bulk "$grp" "$with_vars" "$cli_out" || rc=1
    # sg-cli's own state upload, per workflow: trust its success, redo its
    # failures (it sends no x-ms-blob-type, and misreads anything but a
    # literal "HTTP/1.1 200 OK" as a failure). A 409 is an existing workflow.
    while IFS= read -r line; do
      case "$line" in
      *"Processing workflow: "*) cur="${line##*Processing workflow: }" ;;
      *"Failed to create "*)
        cur=""
        name="${line##*Failed to create }"
        name="${name%%:*}"
        case "$line" in *": 409: "* | *"not unique"*) exists+=("$name") ;; esac
        ;;
      *"State file uploaded successfully"*) [ -n "$cur" ] && printf '[state] uploaded %s\n' "$cur" >>"$out" ;;
      *"Failed to upload state file for "*) name="${line##*Failed to upload state file for }"; redo+=("${name%%:*}") ;;
      *"cannot access state file"*) [ -n "$cur" ] && redo+=("$cur") ;;
      *"TfStateFilePath not provided for "*) name="${line##*TfStateFilePath not provided for }"; printf '[state] none %s\n' "${name%%:*}" >>"$out" ;;
      esac
    done <"$cli_out"
    if [ "${#exists[@]}" -gt 0 ]; then
      sg_log "${#exists[@]} workflow(s) already exist — updating them via the API (sg-cli's update path does not trigger on the 409)"
      for name in "${exists[@]}"; do
        entry="$("$JQ_BIN" -c --arg n "$name" 'first(.[] | select(.ResourceName == $n))' "$file")"
        if err="$(SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_update_workflow "$grp" "$entry" 2>/dev/null)"; then
          sg_log "  $name: updated"
          updated+=("$name")
          redo+=("$name")
          printf '[updated] %s\n' "$name" >>"$out"
        else
          sg_warn "  $name: update failed — $(tail -n1 <<<"$err")"
        fi
      done
    fi
    if [ "${#updated[@]}" -gt 0 ]; then
      # Drop the create-failure line of every workflow that was updated instead.
      pat="$(mktemp)"
      for name in "${updated[@]}"; do printf 'Failed to create %s: ' "$name" >>"$pat"; echo >>"$pat"; done
      grep -v -F -f "$pat" "$cli_out" >>"$out" || true
      rm -f "$pat"
    else
      cat "$cli_out" >>"$out"
    fi
    rm -f "$cli_out"
    if [ "${#redo[@]}" -gt 0 ]; then
      sg_log "uploading the state of ${#redo[@]} workflow(s) directly (sg-cli reported the upload failed, or did not attempt it)"
      for name in "${redo[@]}"; do upload_state "$grp" "$name" "$file" "$out" || true; done
    fi
  fi
  [ "$with_vars" != "$create_file" ] && rm -f "$with_vars"
  if [ "$n_direct" -eq 0 ]; then
    [ "$create_file" != "$file" ] && rm -f "$create_file"
    return "$rc"
  fi

  sg_log "$n_direct workflow(s) have no Terraform variables — creating them via the API directly (sg-cli drops an empty iacInputData.data)"
  while IFS= read -r entry; do
    name="$("$JQ_BIN" -r '.ResourceName' <<<"$entry")"
    if err="$(SG_NO_RETRY_RC=22 sg_retry "$RETRIES" "$RETRY_BASE" -- sg_create_workflow "$grp" "$entry" 2>/dev/null)"; then
      if [ "$(tail -n1 <<<"$err")" = "updated" ]; then
        sg_log "  $name: already existed — updated"
        printf '[updated] %s\n' "$name" >>"$out"
      else
        sg_log "  $name: created"
      fi
      upload_state "$grp" "$name" "$file" "$out" || true
    else
      # Same shape as sg-cli's failure line (parsed by do_import).
      printf 'Failed to create %s: %s\n' "$name" "$(tail -n1 <<<"$err")" | tee -a "$out"
    fi
  done < <("$JQ_BIN" -c '.[] | select((.VCSConfig.iacInputData.data // {}) | length == 0)' "$create_file")
  [ "$create_file" != "$file" ] && rm -f "$create_file"
  return "$rc"
}

# Regex for the API's rejection of a Terraform version above SG's managed
# ceiling. SG bundles managed runtimes only up to the last MPL-licensed (FOSS)
# Terraform release; newer versions are BSL and are not shipped.
TF_CEILING_RE='Failed to create ([^:]+): 400: .*above the highest managed version \(([0-9.]+)\)'

# do_import <payload> — bulk-import one file. Workflows rejected because their
# Terraform version is above the SG ceiling are re-imported with
# SG_DEFAULT_TF_VERSION (the payload file is patched in place so re-runs and
# the trigger pass see what was actually imported); each fallback is appended to
# terraform-version-fallbacks.log. Any other per-workflow failure fails the file.
do_import() {
  local f="$1" seg grp out rc=0 ceiling="" failed=() fb=() st_ok=() st_failed=() upd=() name line tmp names work all_names patch
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  # With --workspace / --exclude-workspace, import only the selected workflows
  # (a filtered copy).
  work="$f"
  if ws_narrowed; then
    ws_jq_args
    work="$(mktemp "$EXPORT_DIR/.subset.$seg.XXXXXX")"
    "$JQ_BIN" "${WS_JQ_ARGS[@]}" "$WS_SCOPE_JQ"'map(select(.ResourceName | ws_selected))' "$f" >"$work"
    if [ "$("$JQ_BIN" 'length' "$work")" -eq 0 ]; then
      sg_log "$(basename "$f"): no selected workflows — skipped"
      rm -f "$work"
      return 0
    fi
  fi
  sg_log "importing $(basename "$f") -> $grp"
  out="$(mktemp)"
  import_bulk "$grp" "$work" "$out" || rc=1
  all_names="$("$JQ_BIN" -c '[.[].ResourceName]' "$work")"

  while IFS= read -r line; do
    if [[ "$line" =~ $TF_CEILING_RE ]]; then
      fb+=("${BASH_REMATCH[1]}")
      ceiling="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed\ to\ (create|update)\ ([^:]+):\ [0-9]+:\ (.*)$ ]]; then
      failed+=("${BASH_REMATCH[2]}")
      explain_api_error "${BASH_REMATCH[3]}"
    elif [[ "$line" =~ Failed\ to\ (create|update)\ ([^:]+): ]]; then
      failed+=("${BASH_REMATCH[2]}")
    elif [[ "$line" =~ ^\[state\]\ uploaded\ (.+)$ ]]; then
      st_ok+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^\[state\]\ failed\ ([^:]+): ]]; then
      st_failed+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^\[updated\]\ (.+)$ ]]; then
      upd+=("${BASH_REMATCH[1]}")
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
    import_bulk "$grp" "$tmp" "$out" || rc=1
    for name in "${fb[@]}"; do
      if grep -qE "Failed to (create|update) $name:" "$out"; then
        failed+=("$name")
      else
        line="$("$JQ_BIN" -r --arg n "$name" '.[] | select(.ResourceName == $n) | .TerraformConfig.terraformVersion' "$f")"
        printf '%s/%s: %s -> %s (above SG managed ceiling %s)\n' "$grp" "$name" "$line" "${SG_DEFAULT_TF_VERSION:-execution preset}" "$ceiling" >>"$EXPORT_DIR/terraform-version-fallbacks.log"
        grep -q "^\[state\] uploaded $name\$" "$out" && st_ok+=("$name")
        grep -q "^\[state\] failed $name:" "$out" && st_failed+=("$name")
        grep -q "^\[updated\] $name\$" "$out" && upd+=("$name")
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
    --argjson st_ok "$([ "${#st_ok[@]}" -gt 0 ] && names_json "${st_ok[@]}" || echo '[]')" \
    --argjson st_failed "$([ "${#st_failed[@]}" -gt 0 ] && names_json "${st_failed[@]}" || echo '[]')" \
    --argjson upd "$([ "${#upd[@]}" -gt 0 ] && names_json "${upd[@]}" || echo '[]')" \
    '{group: $g, payload_sha: $sha, imported: ($all - $failed), updated: ($upd - $failed | unique), failed: $failed, tf_fallback: ($fallback - $failed),
      state_uploaded: ($st_ok - $failed - $st_failed | unique), state_failed: ($st_failed - $failed | unique)}' \
    >"$EXPORT_DIR/.import-result.$seg.json"

  if [ "${#failed[@]}" -gt 0 ]; then
    sg_err "$(basename "$f"): ${#failed[@]} workflow(s) failed to import: ${failed[*]}"
    return 1
  fi
  if [ "${#st_failed[@]}" -gt 0 ]; then
    sg_err "$(basename "$f"): ${#st_failed[@]} workflow(s) created but without their Terraform state in SG: ${st_failed[*]}"
    return 1
  fi
  return "$rc"
}

# probe_import <payload>... — fail fast: import a single workflow (the first
# selected one of the first file) and require both the create and its state
# upload to succeed before the rest is imported in parallel. An environment
# problem (wrong connector kind, a store that rejects the upload, a read-only
# token) then costs one workflow instead of all of them. The probe workflow is
# re-imported with its file afterwards (updated via PATCH, state included).
probe_import() {
  local f="$1" seg grp name dir probe res
  seg="$(seg_of "$f")"
  grp="$(group_for "$seg")"
  ws_jq_args
  name="$("$JQ_BIN" -r "${WS_JQ_ARGS[@]}" "$WS_SCOPE_JQ"'first(.[] | select(.ResourceName | ws_selected) | .ResourceName) // empty' "$f")"
  [ -n "$name" ] || return 0
  dir="$(mktemp -d "$EXPORT_DIR/.probe.XXXXXX")"
  probe="$dir/$(basename "$f")"
  "$JQ_BIN" --arg n "$name" 'map(select(.ResourceName == $n))' "$f" >"$probe"
  sg_log "probing with one workflow before importing the rest: $grp/$name"
  do_import "$probe" || true
  res="$EXPORT_DIR/.import-result.$seg.json"
  if [ -f "$res" ] && [ "$("$JQ_BIN" '(.failed | length) + (.state_failed | length)' "$res")" -eq 0 ]; then
    if [ "$("$JQ_BIN" '.state_uploaded | length' "$res")" -gt 0 ]; then
      sg_success "probe ok — $name is in SG with its state; importing the rest"
    else
      sg_success "probe ok — $name is in SG (no state file to upload); importing the rest"
    fi
    rm -rf "$dir" "$res"
    return 0
  fi
  [ -f "$res" ] && state_record_import "$seg" "$(cat "$res")"
  rm -rf "$dir" "$res"
  die "probe failed for $grp/$name (see above) — nothing else was imported; fix the cause and re-run '$PROG import'"
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
  if overlay_requested && [ "$RAN_APPLY" -ne 1 ]; then
    sg_warn "the run configuration flags shape the export and were not applied to the existing payload files — run '$PROG all' (or 'apply', then 'import') for them to reach the workflows"
  fi

  payload_files
  [ "${#PF[@]}" -gt 0 ] || die "No payload files in $(sg_rel "$EXPORT_DIR")."

  # The workflow-group part of the plan (reuse/create/missing!/moved!, name
  # collisions); problems are shown here and stop the run after the full plan.
  local q grp f seg
  plan_groups "${PF[@]}"
  [ "$PLAN_TOTAL_WF" -gt 0 ] || die "no workflow in $(sg_rel "$EXPORT_DIR")/ is in scope ($(scope_describe)) — check the globs, or re-run 'apply' with them"

  # Files already imported in full with identical content are skipped (the
  # plan shows their workflows as "skip"); --fresh or a --workspace filter
  # re-imports them.
  local -a todo=() skip_segs=()
  local skipped=0 import_rc=0
  for f in "${PF[@]}"; do
    seg="$(seg_of "$f")"
    if [ "$FRESH" -eq 0 ] && ! ws_narrowed && state_import_done "$seg" "$(sg_sha_files "$f")"; then
      skipped=$((skipped + 1))
      skip_segs+=("$seg")
      continue
    fi
    todo+=("$f")
  done
  PLAN_SKIP_SEGS="$([ "${#skip_segs[@]}" -gt 0 ] && names_json "${skip_segs[@]}" || echo '[]')"

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
  if [ "${#PLAN_PROBLEMS[@]}" -gt 0 ]; then
    write_run_result blocked
    die "${#PLAN_PROBLEMS[@]} problem(s) block the import (the ✗ lines above) — nothing was changed in $ORG"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    write_run_result planned
    sg_success "dry run — nothing was created or changed (plan written to $(sg_rel "$EXPORT_DIR")/run-result.json and run-summary.md)"
    return 0
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    q="Import $PLAN_TOTAL_WF workflow(s) into $ORG"
    [ "$PLAN_N_CREATE" -gt 0 ] && q="$q and create $PLAN_N_CREATE workflow group(s)"
    sg_interactive || die "no terminal to confirm the import — re-run with -y to import without a prompt"
    if ! sg_confirm "$q?" N; then
      sg_warn "import cancelled — nothing was changed in $ORG"
      sg_dim "re-run '$PROG all' (or '$PROG import') to come back to this plan; the export phases are saved and skipped"
      return 1
    fi
  fi

  # Create the missing tfc-* groups before importing into them.
  for grp in $PLAN_TO_CREATE; do
    sg_log "creating workflow group $grp"
    wfgroup_create "$grp" || die "failed to create workflow group $grp"
  done

  SGCLI_BIN="$(sg_resolve sg-cli sg_ensure_sgcli)"
  rm -f "$EXPORT_DIR/terraform-version-fallbacks.log"

  [ "$skipped" -gt 0 ] && sg_log "skipping $skipped payload file(s) already imported and unchanged (--fresh to re-import)"
  if [ "${#todo[@]}" -gt 0 ]; then
    # More than one workflow to import: try a single one first (fail fast).
    if [ "$PLAN_TOTAL_WF" -gt 1 ]; then probe_import "${todo[0]}"; fi
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
  write_run_result "$([ "$import_rc" -eq 0 ] && echo success || echo failed)"
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
  sg_dim "run result: $(sg_rel "$EXPORT_DIR")/run-result.json, run-summary.md (markdown, e.g. for a CI job summary)"
}

# Single source of truth for shell completion (keep in sync with the parser below
# and the host-only flags in sg-migrate.sh). One "cmd:description" per line; the
# zsh script shows the descriptions, SG_COMMANDS is derived from the first column.
SG_COMMAND_DESCS="init:Guided setup — generates terraform.tfvars
preflight:Verify tokens and every id in terraform.tfvars before running
apply:Run the transformer (terraform apply)
enrich:Merge TFC Variable Set variables into the payloads
convert:Convert HCL-string variables to JSON
validate:Validate payloads against the SG schema
import:Import payloads to StackGuardian, then register VCS triggers
triggers:Register VCS triggers for already-imported workflows
checklist:Write the post-import checklist (and create secret stubs)
all:preflight -> apply -> enrich -> convert -> validate -> import -> checklist
clean:Remove local working artifacts
completion:Print a shell completion script
update:Pull the latest migrator version (git) and rebuild the image if needed"
SG_COMMANDS="$(printf '%s\n' "$SG_COMMAND_DESCS" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
SG_OPTIONS="--org --region --export-dir --tfvars --mapping --concurrency --no-create-groups --no-variable-sets --no-vcs-triggers --skip-preflight --dry-run --no-secret-stubs --fresh --project --workspace --exclude-workspace --tag --exclude-tag --all --upgrade --set --cloud-connector --vcs-connector --runner-group --workflow-group -v --verbose -y --yes -h --help --native --local --build"

# cmd_completion <bash|zsh> — print a completion script for sg-migrate.sh /
# migrate.sh to stdout. Both shells fall back to the basename when the command
# is invoked by path, so ./sg-migrate.sh completes too. The zsh script works
# both sourced and saved into a \$fpath dir as _sg-migrate.sh.
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
    --mapping | --tfvars) COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
    --region) COMPREPLY=(\$(compgen -W "eu us" -- "\$cur")); return ;;
    --org | --concurrency | --project | --workspace | --exclude-workspace | --tag | --exclude-tag | --set | --cloud-connector | --vcs-connector | --runner-group | --workflow-group) COMPREPLY=(); return ;;
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
$(printf '%s\n' "$SG_COMMAND_DESCS" | sed "s/.*/    '&'/")
  )
  # Every option has a distinct description on purpose: _arguments folds
  # options that share one text into a single "--verbose -v -- ..." row, and
  # with a multi-entry matcher-list (oh-my-zsh's default) such rows make zsh
  # list the whole table one cell per line, repeated per matcher.
  _arguments -s \\
    '--org[StackGuardian org for import]:org' \\
    '--region[StackGuardian region]:region:(eu us)' \\
    '--export-dir[Payload/state output dir]:dir:_files -/' \\
    '--tfvars[tfvars file to use instead of terraform.tfvars]:file:_files' \\
    '--mapping[Project-segment -> group override map]:file:_files' \\
    '--concurrency[Max parallel jobs for convert/import]:n' \\
    '--no-create-groups[Require workflow groups to pre-exist]' \\
    '--no-variable-sets[Skip merging TFC Variable Sets]' \\
    '--no-vcs-triggers[Skip registering VCS triggers after import]' \\
    '--skip-preflight[Skip the preflight checks]' \\
    '--dry-run[With import or all: show the plan and stop before importing]' \\
    '--no-secret-stubs[Do not create placeholder SG secrets for sensitive vars]' \\
    '--fresh[Ignore saved run state: redo every phase]' \\
    '*--project[Only this TFC project (name or slug)]:project' \\
    '*--workspace[Only matching workspaces (glob)]:glob' \\
    '*--exclude-workspace[Leave matching workspaces out (glob)]:glob' \\
    '*--tag[Only workspaces carrying this tag]:tag' \\
    '*--exclude-tag[Leave workspaces carrying this tag out]:tag' \\
    '--all[With clean: also remove config]' \\
    '--upgrade[With init: append missing settings to terraform.tfvars]' \\
    '*--set[Transformer variable for this run (KEY=VALUE)]:setting' \\
    '--cloud-connector[Cloud connector for this run (kind looked up in SG)]:id' \\
    '--vcs-connector[VCS connector for this run (kind looked up in SG)]:id' \\
    '--runner-group[Private runner group for this run (shared = SG runners)]:name' \\
    '--workflow-group[Workflow group for the --project workflows]:name' \\
    '(-v --verbose)-v[Same as --verbose]' \\
    '(-v --verbose)--verbose[Show full terraform/tool output]' \\
    '(-y --yes)-y[Same as --yes]' \\
    '(-y --yes)--yes[Skip the import confirmation prompt]' \\
    '(-h --help)-h[Same as --help]' \\
    '(-h --help)--help[Show help]' \\
    '(--native --local)--native[Run natively instead of in Docker]' \\
    '(--native --local)--local[Same as --native]' \\
    '--build[Rebuild the Docker image first]' \\
    '1:command:->cmd' \\
    '2:shell:->shell'
  case "\$state" in
    cmd) _describe -t commands 'command' cmds ;;
    shell) [[ "\${words[CURRENT-1]}" == completion ]] && _values 'shell' bash zsh ;;
  esac
}
# Sourced (source <(... completion)): register. Autoloaded from a file in \$fpath
# (installed as _sg-migrate.sh): this run *is* the completion call, so complete now.
case "\${funcstack[1]}" in
  _*) _sg_migrate "\$@" ;;
  *) compdef _sg_migrate sg-migrate.sh migrate.sh ;;
esac
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
  # Recorded in export/run-result.json (write_run_result).
  SG_RUN_ARGS="$*"
  while [ $# -gt 0 ]; do
    case "$1" in
    -y | --yes) ASSUME_YES=1 ;;
    --org)
      ORG="$2"
      shift
      ;;
    --org=*) ORG="${1#*=}" ;;
    --region)
      SG_REGION="$2"
      shift
      ;;
    --region=*) SG_REGION="${1#*=}" ;;
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
    --tfvars)
      TFVARS="$(abs_path "$2")"
      shift
      ;;
    --tfvars=*) TFVARS="$(abs_path "${1#*=}")" ;;
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
    --exclude-workspace)
      WS_EXCLUDE+=("$2")
      shift
      ;;
    --exclude-workspace=*) WS_EXCLUDE+=("${1#*=}") ;;
    --tag)
      TAG_FILTER+=("$2")
      shift
      ;;
    --tag=*) TAG_FILTER+=("${1#*=}") ;;
    --exclude-tag)
      TAG_EXCLUDE+=("$2")
      shift
      ;;
    --exclude-tag=*) TAG_EXCLUDE+=("${1#*=}") ;;
    -v | --verbose) VERBOSE=1 ;;
    --all) PURGE=1 ;;
    --upgrade) UPGRADE=1 ;;
    --set)
      SET_VARS+=("$2")
      shift
      ;;
    --set=*) SET_VARS+=("${1#*=}") ;;
    --cloud-connector)
      CLOUD_CONNECTOR="$2"
      shift
      ;;
    --cloud-connector=*) CLOUD_CONNECTOR="${1#*=}" ;;
    --vcs-connector)
      VCS_CONNECTOR="$2"
      shift
      ;;
    --vcs-connector=*) VCS_CONNECTOR="${1#*=}" ;;
    --runner-group)
      RUNNER_GROUP="$2"
      shift
      ;;
    --runner-group=*) RUNNER_GROUP="${1#*=}" ;;
    --workflow-group)
      WORKFLOW_GROUP="$2"
      shift
      ;;
    --workflow-group=*) WORKFLOW_GROUP="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    init | apply | enrich | convert | validate | import | triggers | all | clean | preflight | checklist) CMD="$1" ;;
    completion)
      cmd_completion "${2:-}"
      exit 0
      ;;
    update)
      # Host-only: needs the checkout's git, not the container.
      sg_err "'update' runs on the host: use ./sg-migrate.sh update"
      exit 2
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
  region_apply

  # The run configuration flags (lib/scope.sh) shape a run, not the file.
  case "$CMD" in
  init | clean | completion)
    overlay_requested && die "--set / --cloud-connector / --vcs-connector / --runner-group / --workflow-group apply to a run (apply, import, all), not to '$CMD' — edit $(sg_rel "$TFVARS") instead"
    ;;
  *)
    export SG_API_TOKEN SG_BASE_URL
    overlay_build
    ;;
  esac

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
    apply_sha="$(sg_sha "$(sg_sha_files "$TFVARS")|$(scope_sha_input)")"
    run_phase apply "$apply_sha" cmd_apply
    if [ "$ENRICH_VARSETS" -eq 1 ]; then run_phase enrich "$apply_sha" cmd_enrich; fi
    run_phase convert "$(payload_sha)" cmd_convert
    run_phase validate "$(payload_sha)" cmd_validate
    RAN_APPLY=1 # the export ran, or its inputs (flags included) were unchanged
    cmd_import
    ;;
  esac
}

main "$@"
