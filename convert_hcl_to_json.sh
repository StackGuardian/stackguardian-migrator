#!/bin/bash
set -euo pipefail

log() { echo "[convert_hcl_to_json] $*" >&2; }

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Normalize OS/arch to the names used by the jq and hcl2json release assets.
OS=$(uname -s)
case "$OS" in
  Darwin) OS="macos" ;;
  Linux) OS="linux" ;;
  *) echo "Unsupported OS: $OS" >&2; exit 1 ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
  x86_64 | amd64) ARCH="amd64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

JQ_BIN="$WORKDIR/jq"
HCL2JSON_BIN="$WORKDIR/hcl2json"

install_jq() {
  local url="https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-${OS}-${ARCH}"
  if ! curl -fsSL -o "$JQ_BIN" "$url"; then
    echo "Failed to download jq from $url" >&2
    exit 1
  fi
  chmod +x "$JQ_BIN"
}

install_hcl2json() {
  # hcl2json uses "darwin" rather than "macos" for the OS segment.
  local hcl_os="$OS"
  [[ "$hcl_os" == "macos" ]] && hcl_os="darwin"
  local url="https://github.com/tmccombs/hcl2json/releases/download/v0.6.7/hcl2json_${hcl_os}_${ARCH}"
  if ! curl -fsSL -o "$HCL2JSON_BIN" "$url"; then
    echo "Failed to download hcl2json from $url" >&2
    exit 1
  fi
  chmod +x "$HCL2JSON_BIN"
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

log "Downloading jq and hcl2json..."
install_jq
install_hcl2json

# Read entire JSON array into a variable
json_data=$(cat "$INPUT_FILE_JSON")

# Use jq to get the length of array
length=$($JQ_BIN length <<<"$json_data")
log "Processing $length workflow(s) from $INPUT_FILE_JSON"

# Accumulate updated objects as newline-delimited JSON
tmpfile="$WORKDIR/updated.ndjson"
: >"$tmpfile"

JSON_PATH=".VCSConfig.iacInputData.data"

for ((i = 0; i < length; i++)); do
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
    else
      log "  workflow $((i + 1)): parsing failed, keeping original value for '$key'"
    fi
  done < <($JQ_BIN -r 'keys[]' <<<"$val")

  # Assign the converted data back at JSON_PATH
  updated_obj=$($JQ_BIN --argjson nv "$new_val" "$JSON_PATH = \$nv" <<<"$obj")

  echo "$updated_obj" >>"$tmpfile"
done

# Combine updated objects into an array, writing to a temp file first so the
# input is only overwritten once the conversion fully succeeds.
outfile="$WORKDIR/output.json"
$JQ_BIN -s '.' "$tmpfile" >"$outfile"
mv "$outfile" "$INPUT_FILE_JSON"
log "Done. Updated $INPUT_FILE_JSON in place."
