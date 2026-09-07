#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"

SCHEMA="$SG_REPO_ROOT/schema/sg-payload.schema.json"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <payload.json> [more.json ...]" >&2
  echo "   e.g. $0 export/sg-payload.*.json" >&2
  exit 1
fi
if [ ! -f "$SCHEMA" ]; then
  echo "Schema not found: $SCHEMA" >&2
  exit 1
fi

# Resolve yajsv from PATH (Docker image) or download+cache (native).
YAJSV_BIN=$(sg_resolve yajsv sg_ensure_yajsv)

sg_log "validating $# file(s) against schema/sg-payload.schema.json"
# yajsv prints "<file>: valid" per file and exits non-zero if any file fails.
# Strip the repo-root prefix from its output for readable, relative paths
# (pipefail off so the pipeline's status is sed's; yajsv's status via PIPESTATUS).
set +o pipefail
"$YAJSV_BIN" -s "$SCHEMA" "$@" 2>&1 | sed "s#${SG_REPO_ROOT}/##g" | awk '!seen[$0]++'
exit "${PIPESTATUS[0]}"
