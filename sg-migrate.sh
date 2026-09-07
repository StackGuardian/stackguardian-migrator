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

# 'clean' only touches the local filesystem — no container needed.
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  [ "$a" = "clean" ] && NATIVE=1
done

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
  -e TFE_TOKEN)

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
  sg_warn "no TFC auth found — set TFE_TOKEN (long-lived API token) or run 'terraform login'"
fi

# Forward any TF_TOKEN_* env vars (alternative TFC/TFE auth) if present.
while IFS='=' read -r name _; do
  case "$name" in TF_TOKEN_*) DOCKER_ARGS+=(-e "$name") ;; esac
done < <(env)

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" /app/scripts/migrate.sh ${ARGS[@]+"${ARGS[@]}"}
