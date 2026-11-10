# shellcheck shell=bash
# Live test library (sourced by run.sh): the guards, the sandbox
# checkout, StackGuardian API helpers and the check helpers. See README.md.
#
# Everything the tests create in StackGuardian sits under one parent workflow
# group (SG_LIVE_ROOT_GROUP, the migrator's SGParentWorkflowGroup); cleanup
# only ever deletes inside it, plus the secrets the sandbox's state recorded.

LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$LIVE_DIR/../.." && pwd)"
# shellcheck source=../../scripts/tools.sh
source "$REPO/scripts/tools.sh"
JQ="$(sg_resolve jq sg_ensure_jq)"

SG_LIVE_ROOT_GROUP="${SG_LIVE_ROOT_GROUP:-tfc-migration}"
SG_LIVE_PREFIX="${SG_LIVE_PREFIX:-mig-test}"
SANDBOX="${SG_LIVE_DIR:-${TMPDIR:-/tmp}/sg-migrator-live}"
set +x

live_die() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}

# live_guard — refuse to run anywhere but an allowed, non-production org.
live_guard() {
  local o ok=0
  [ -n "${SG_API_TOKEN:-}" ] || live_die "SG_API_TOKEN is not set (run under: op run --env-file <env file> -- ...)"
  [ -n "${SG_ORG:-}" ] || live_die "SG_ORG is not set"
  [ -n "${TFC_ORG:-}" ] || live_die "TFC_ORG is not set"
  [ -n "${SG_BASE_URL:-}" ] || live_die "SG_BASE_URL is not set: the live tests need an explicit API host"
  for o in ${SG_LIVE_ALLOWED_ORGS:-}; do [ "$o" = "$SG_ORG" ] && ok=1; done
  [ "$ok" -eq 1 ] || live_die "SG_ORG '$SG_ORG' is not in SG_LIVE_ALLOWED_ORGS"
  case "$SG_BASE_URL" in
  *://api.app.stackguardian.io* | *://api.us.stackguardian.io*)
    [ "${SG_LIVE_ALLOW_PROD:-0}" = 1 ] || live_die "$SG_BASE_URL is a production API; set SG_LIVE_ALLOW_PROD=1 to allow it"
    ;;
  esac
  case "$SG_LIVE_ROOT_GROUP" in "" | */*) live_die "SG_LIVE_ROOT_GROUP must be one plain group name" ;; esac
  export SG_ORG SG_BASE_URL SG_UI_URL
}

# --- StackGuardian API --------------------------------------------------------

# sg_call <METHOD> <path under /orgs/<org>/> [body] — the body on stdout; the
# status in SG_CODE. The token goes through stdin, never the command line.
sg_call() {
  local tmp
  tmp="$(mktemp)"
  SG_CODE="$(printf 'Authorization: apikey %s\n' "$SG_API_TOKEN" |
    curl -sS -o "$tmp" -w '%{http_code}' -H @- -H 'Content-Type: application/json' \
      -X "$1" ${3:+--data "$3"} "$SG_BASE_URL/api/v1/orgs/$SG_ORG/$2")" || SG_CODE=000
  cat "$tmp"
  rm -f "$tmp"
}

# sg_names <path of a listall> — the ResourceNames, one per line (204 = none).
sg_names() { sg_call GET "$1" | "$JQ" -r '.msg[]?.ResourceName' 2>/dev/null || true; }

# sg_wf <group path> <workflow> — the workflow's JSON (.msg).
sg_wf() { sg_call GET "wfgrps/$1/wfs/$2/" | "$JQ" -c '.msg | objects' 2>/dev/null; }

# live_clean — delete every workflow and child group under the root group, and
# the secrets named in the sandbox state; the root itself stays.
live_clean() {
  local g w s root="$SG_LIVE_ROOT_GROUP"
  for g in $(sg_names "wfgrps/$root/wfgrps/listall/"); do
    for w in $(sg_names "wfgrps/$root/$g/wfs/listall/"); do sg_call DELETE "wfgrps/$root/$g/wfs/$w/" >/dev/null; done
    sg_call DELETE "wfgrps/$root/$g/" >/dev/null
    [ "${SG_CODE:-}" = 200 ] || printf '! could not delete group %s/%s (HTTP %s)\n' "$root" "$g" "$SG_CODE" >&2
  done
  for w in $(sg_names "wfgrps/$root/wfs/listall/"); do sg_call DELETE "wfgrps/$root/wfs/$w/" >/dev/null; done
  for s in $(live_secret_names); do
    sg_call DELETE "secrets/$s/" >/dev/null
    case "$SG_CODE" in 200 | 204 | 404) ;; *) printf '! could not delete secret %s (HTTP %s)\n' "$s" "$SG_CODE" >&2 ;; esac
  done
}

# live_secret_names — secrets this harness may delete: the ones the sandbox's
# state recorded, and the org's secrets carrying the fixture prefix
# (tfc-<prefix>-...), which a lost sandbox would otherwise leave behind.
live_secret_names() {
  {
    [ -f "$SANDBOX/.sg/state.json" ] && "$JQ" -r '.secrets // {} | keys[]' "$SANDBOX/.sg/state.json"
    sg_names "secrets/listall/" | grep -E "^tfc-${SG_LIVE_PREFIX}[-_]" || true
  } | sort -u
}

# --- sandbox ------------------------------------------------------------------

# live_sandbox — a fresh copy of the checkout (no export, state, tfvars or
# provider cache), so a run never touches the real checkout's files.
live_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX"
  (cd "$REPO" && tar -cf - --exclude ./export --exclude ./.sg --exclude ./docs --exclude ./.git --exclude ./TASKS.md \
    --exclude '*.tfstate*' --exclude '*.tfvars' --exclude '.terraform' --exclude ./tests/live/tfc-fixture . ) |
    (cd "$SANDBOX" && tar -xf -)
  mkdir -p "$SANDBOX/.sg"
  live_tfvars >"$SANDBOX/transformer/terraform-cloud/terraform.tfvars"
}

# live_tfvars — the scenarios' terraform.tfvars: the fixture projects only.
# The workspaces that hit known bugs (no VCS; more than 20 env vars) are left
# out (LIVE_IGNORE_NAMES) but by their own scenarios, so the failures don't
# cascade into every other scenario.
live_tfvars() {
  local ignore="${LIVE_IGNORE_NAMES:-[\"$SG_LIVE_PREFIX-novcs\", \"$SG_LIVE_PREFIX-big\"]}"
  cat <<EOF
tfOrg                         = "$TFC_ORG"
tfHostname                    = "app.terraform.io"
workspacenames                = ["*"]
exportStateFiles              = true
tfWorkspaceTags               = null
tfWorkspaceIgnoreTags         = null
tfWorkspaceIgnoreNames        = $ignore
tfProjects                    = ["$SG_LIVE_PREFIX-a", "$SG_LIVE_PREFIX-b"]
exportPath                    = "export"
ignoreVarPatterns             = ["^TFC_", "^TFE_"]
stripCloudAuthVars            = true
SGDefaultWfApprovers          = []
SGDefaultIACVCSRepoPrefix     = "https://github.com"
SGDefaultVCSAuthIntegrationID = "/integrations/${SG_LIVE_VCS_CONNECTOR:-github_com}"
SGDefaultDeploymentPlatformConfig = [
  { "kind" : "AWS_RBAC", "config" : { "integrationId" : "/integrations/${SG_LIVE_CLOUD_CONNECTOR:-sg-non-prod}", "profileName" : "default" } }
]
SGDefaultRunnerConstraints    = { type = "shared" }
SGDefaultSourceConfigDestKind = "GITHUB_COM"
SGTerraformVersionSource      = "carry"
SGDefaultTerraformVersion     = "TERRAFORM-1.5.7"
SGDefaultEnableVCSTriggers    = true
forceStateRefresh             = false
SGParentWorkflowGroup         = "$SG_LIVE_ROOT_GROUP"
projectOverrides              = {}
workspaceOverrides            = {}
EOF
}

# migrate <args...> — run the sandbox's sg-migrate.sh (natively, or through the
# Docker wrapper with SG_LIVE_DOCKER=1); output in $SANDBOX/last.log.
migrate() {
  local rc=0
  local -a native=(--native)
  [ "${SG_LIVE_DOCKER:-0}" = 1 ] && native=()
  (cd "$SANDBOX" && NO_COLOR=1 SG_NONINTERACTIVE=1 ./sg-migrate.sh ${native[@]+"${native[@]}"} "$@") >"$SANDBOX/last.log" 2>&1 || rc=$?
  cp "$SANDBOX/last.log" "$SANDBOX/log.$LIVE_SCENARIO.$((++LIVE_STEP))"
  return "$rc"
}

# --- checks -------------------------------------------------------------------

LIVE_PASS=0 LIVE_FAIL=0 LIVE_KNOWN=0 LIVE_SCENARIO="" LIVE_STEP=0
LIVE_FAILED=()

# check <description> <command...> — one ✓/✗ line.
check() {
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$d"
    LIVE_PASS=$((LIVE_PASS + 1))
  else
    printf '  ✗ %s\n' "$d"
    LIVE_FAIL=$((LIVE_FAIL + 1))
    LIVE_FAILED+=("$LIVE_SCENARIO: $d")
  fi
}

# known <description> <command...> — a known bug pinned by the suite: the check
# is expected to fail (!), and passing means the bug is fixed (✗, drop the pin).
known() {
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✗ %s (fixed? the known-bug pin now passes)\n' "$d"
    LIVE_FAIL=$((LIVE_FAIL + 1))
    LIVE_FAILED+=("$LIVE_SCENARIO: $d (pin passes)")
  else
    printf '  ! %s (known bug)\n' "$d"
    LIVE_KNOWN=$((LIVE_KNOWN + 1))
  fi
}

# jqt <json> <filter> — true when the filter yields true.
jqt() { "$JQ" -e "$2" <<<"$1" >/dev/null 2>&1; }

# log_has <regex> — the last migrator run printed a matching line.
log_has() { grep -Eq "$1" "$SANDBOX/last.log"; }
