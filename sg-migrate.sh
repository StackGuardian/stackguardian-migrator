#!/bin/bash
# Host entrypoint for the StackGuardian migrator.
#
# Runs scripts/migrate.sh inside the Docker image (so all tooling is isolated and
# identical across OSes). Mounts the repo at /app, mounts the Terraform Cloud
# credentials file read-only, and forwards SG_API_TOKEN/SG_ORG.
#
# Runs natively (no Docker) when: --native/--local is passed, SG_NATIVE=1 is set,
# the command is 'clean' (a local filesystem op), or docker is unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tools.sh
source "$SCRIPT_DIR/scripts/tools.sh"
IMAGE="${SG_IMAGE:-stackguardian/migrator:local}"
CREDS="${TF_CREDENTIALS_FILE:-$HOME/.terraform.d/credentials.tfrc.json}"

# Parse host-only flags (--native/--local, --build); everything else passes through.
NATIVE="${SG_NATIVE:-0}"
BUILD=0
ARGS=()
for a in "$@"; do
  case "$a" in
  --native | --local) NATIVE=1 ;;
  --build) BUILD=1 ;;
  *) ARGS+=("$a") ;;
  esac
done

# Help, 'clean' and 'completion' only touch the local shell/filesystem — no
# container. With no command at all, migrate.sh prints the help menu.
HAS_CMD=0
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$a" in
  clean | completion | -h | --help) NATIVE=1; HAS_CMD=1 ;;
  init | preflight | apply | enrich | convert | validate | import | triggers | checklist | all) HAS_CMD=1 ;;
  esac
done
[ "$HAS_CMD" -eq 1 ] || NATIVE=1
# Let migrate.sh print the name the user actually invoked in its help/hints.
export SG_PROG="${0##*/}"
case "$0" in */*) SG_PROG="./${0##*/}" ;; esac
# The shell the user is typing in (for the completion hint): the parent process,
# not $SHELL, which is only the login shell and is often wrong (bash vs zsh).
SG_SHELL="$(ps -p "$PPID" -o comm= 2>/dev/null | sed 's/^-//; s#.*/##')"
case "$SG_SHELL" in bash | zsh) ;; *) SG_SHELL="$(basename "${SHELL:-zsh}")" ;; esac
export SG_SHELL

if [ "$NATIVE" = "1" ] || ! command -v docker >/dev/null 2>&1; then
  [ "$NATIVE" = "1" ] || sg_warn "docker not found; running natively"
  exec "$SCRIPT_DIR/scripts/migrate.sh" ${ARGS[@]+"${ARGS[@]}"}
fi

if [ "$BUILD" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  sg_log "building image $IMAGE ..."
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

DOCKER_ARGS=(--rm -i
  -v "$SCRIPT_DIR:/app" -w /app
  -e SG_API_TOKEN -e SG_ORG -e SG_BASE_URL -e SG_CONCURRENCY -e SG_RETRIES -e SG_TF_PARALLELISM
  -e TFE_TOKEN -e SG_PROG -e SG_SHELL -e SG_NONINTERACTIVE -e SG_UI_URL)

# Interactive TTY only when attached to one (so the confirmation prompt works,
# but CI/non-tty invocations still run — use -y there).
if [ -t 0 ] && [ -t 1 ]; then DOCKER_ARGS+=(-t); fi

# TFC auth: prefer a long-lived TFE_TOKEN (forwarded via -e above); otherwise
# mount the `terraform login` credentials file read-only.
if [ -n "${TFE_TOKEN:-}" ]; then
  :
elif [ -f "$CREDS" ]; then
  DOCKER_ARGS+=(-v "$CREDS:/root/.terraform.d/credentials.tfrc.json:ro")
else
  # Only apply/all need TFC auth; migrate.sh fails fast there with a clear message.
  case " ${ARGS[*]-} " in *" apply "* | *" all "*)
    sg_err "no Terraform Cloud/Enterprise credentials found. Set TFE_TOKEN=<long-lived API token> (recommended) or run 'terraform login' first."
    exit 1 ;;
  esac
fi

# Forward any TF_TOKEN_* env vars (alternative TFC/TFE auth) if present.
while IFS='=' read -r name _; do
  case "$name" in TF_TOKEN_*) DOCKER_ARGS+=(-e "$name") ;; esac
done < <(env)

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" /app/scripts/migrate.sh ${ARGS[@]+"${ARGS[@]}"}
