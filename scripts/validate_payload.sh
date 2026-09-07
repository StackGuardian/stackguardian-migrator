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

# yajsv prints "<file>: pass" / "<file>: fail: <reason>" per file and exits
# non-zero if any file fails. Re-render its lines in the migrator's style
# (✓/✗ + file name; the raw lines with -v) — pipefail off so the pipeline's
# status is the loop's; yajsv's own status comes back via PIPESTATUS.
set +o pipefail
"$YAJSV_BIN" -s "$SCHEMA" "$@" 2>&1 | sed "s#${SG_REPO_ROOT}/##g" | awk '!seen[$0]++' | while IFS= read -r line; do
  if [ "${SG_VERBOSE:-0}" = "1" ]; then
    printf '  %s\n' "$line" >&2
    continue
  fi
  case "$line" in
  *": pass") printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$(basename "${line%: pass}")" >&2 ;;
  *": fail: "*) printf '  %s✗%s %s: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$(basename "${line%%: fail: *}")" "${line#*: fail: }" >&2 ;;
  *": error: "*) printf '  %s✗%s %s: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$(basename "${line%%: error: *}")" "${line#*: error: }" >&2 ;;
  *) printf '      %s\n' "$line" >&2 ;;
  esac
done
exit "${PIPESTATUS[0]}"
