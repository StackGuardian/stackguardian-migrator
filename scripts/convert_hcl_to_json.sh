#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools.sh
source "$SCRIPT_DIR/tools.sh"

# Detail lines are shown only in verbose mode; warnings always show.
log() {
  [ "${SG_VERBOSE:-0}" = "1" ] || return 0
  printf '%s[convert]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2
}

INPUT_FILE_JSON="${1:-}"
if [ -z "$INPUT_FILE_JSON" ]; then
  echo "Usage: $0 <input_file.json>"
  exit 1
fi
if [ ! -f "$INPUT_FILE_JSON" ]; then
  echo "Input file not found: $INPUT_FILE_JSON" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Resolve tooling from PATH (Docker image) or download+cache (native).
JQ_BIN=$(sg_resolve jq sg_ensure_jq)
HCL2JSON_BIN=$(sg_resolve hcl2json sg_ensure_hcl2json)

# Read entire JSON array into a variable
json_data=$(cat "$INPUT_FILE_JSON")

# Use jq to get the length of array
length=$($JQ_BIN length <<<"$json_data")
log "Processing $length workflow(s) from $(sg_rel "$INPUT_FILE_JSON")"

# Accumulate updated objects as newline-delimited JSON
tmpfile="$WORKDIR/updated.ndjson"
: >"$tmpfile"

JSON_PATH=".VCSConfig.iacInputData.data"
converted=0
touched=0

for ((i = 0; i < length; i++)); do
  wf_converted=0
  # Extract ith object
  obj=$($JQ_BIN ".[$i]" <<<"$json_data")

  # Extract the value at JSON_PATH from the object
  val=$($JQ_BIN -c "$JSON_PATH" <<<"$obj")

  # If val is null or not an object, leave the object untouched
  if [[ "$val" == "null" || $($JQ_BIN 'type' <<<"$val") != "\"object\"" ]]; then
    echo "$obj" >>"$tmpfile"
    continue
  fi

  # Start from the original data; only convert keys that hold HCL collections.
  new_val="$val"

  while IFS= read -r key; do
    [ -z "$key" ] && continue

    # Only string values are candidates for HCL conversion; objects/arrays
    # (e.g. already-converted data) and other scalars are left as-is.
    vtype=$($JQ_BIN -r --arg k "$key" '.[$k] | type' <<<"$val")
    if [[ "$vtype" != "string" ]]; then
      continue
    fi

    # -r decodes JSON string escapes correctly (no manual unquoting).
    raw=$($JQ_BIN -r --arg k "$key" '.[$k]' <<<"$val")

    # Left-trim whitespace to inspect the first meaningful character.
    trimmed=${raw#"${raw%%[![:space:]]*}"}

    # Only treat values that look like an HCL object/list as HCL; plain
    # scalar strings (ids, names, ...) must pass through unchanged.
    if [[ "$trimmed" != "{"* && "$trimmed" != "["* ]]; then
      continue
    fi

    # Wrap as an HCL attribute so hcl2json can parse the bare expression.
    parsed=$(printf 'temp = %s\n' "$raw" | "$HCL2JSON_BIN" 2>/dev/null | "$JQ_BIN" -c '.temp' 2>/dev/null) || parsed=""

    if [[ -n "$parsed" && "$parsed" != "null" ]]; then
      log "  workflow $((i + 1)): converted '$key' from HCL to JSON"
      new_val=$($JQ_BIN --arg k "$key" --argjson v "$parsed" '. + {($k): $v}' <<<"$new_val")
      converted=$((converted + 1))
      wf_converted=1
    else
      sg_warn "$(sg_rel "$INPUT_FILE_JSON") workflow $((i + 1)): could not parse '$key' as HCL; keeping original value"
    fi
  done < <($JQ_BIN -r 'keys[]' <<<"$val")

  # Assign the converted data back at JSON_PATH
  updated_obj=$($JQ_BIN --argjson nv "$new_val" "$JSON_PATH = \$nv" <<<"$obj")
  touched=$((touched + wf_converted))

  echo "$updated_obj" >>"$tmpfile"
done

# Combine updated objects into an array, writing to a temp file first so the
# input is only overwritten once the conversion fully succeeds.
outfile="$WORKDIR/output.json"
$JQ_BIN -s '.' "$tmpfile" >"$outfile"
mv "$outfile" "$INPUT_FILE_JSON"
# One result line per file (the orchestrator shows it as-is).
if [ "$converted" -gt 0 ]; then
  sg_log "$(basename "$INPUT_FILE_JSON"): $converted HCL value(s) converted to JSON in $touched of $length workflow(s)"
else
  sg_log "$(basename "$INPUT_FILE_JSON"): nothing to convert ($length workflow(s), values already JSON)"
fi
