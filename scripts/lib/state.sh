#!/bin/bash
# Run state for resumable 'all' runs (sourced; needs tools.sh).
#
# .sg/state.json records, per phase, a hash of the inputs it last ran with and
# when. 'all' skips a phase whose inputs are unchanged; --fresh wipes the file.
# Import results are recorded per payload file (hash, imported/failed
# workflows) so a re-run only touches files that changed or had failures, and
# the post-import checklist knows what actually landed.
#
# Layout: { "phases": { "<phase>": {"at": iso, "input_sha": sha} },
#           "import":  { "<seg>":   {"at": iso, "payload_sha": sha, "group": g,
#                                    "imported": [...], "failed": [...]} } }

STATE_FILE="${SG_STATE_FILE:-$SG_REPO_ROOT/.sg/state.json}"

# sg_sha <string> — short sha256 of a string.
sg_sha() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -c1-16
  else printf '%s' "$1" | sha256sum | cut -c1-16; fi
}

# sg_sha_files <file>... — sha256 over the contents of the given files (sorted).
sg_sha_files() {
  local f
  {
    for f in "$@"; do [ -f "$f" ] && cat "$f"; done
  } | if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-16
}

state_read() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo '{}'; }

# state_update <jq-filter> [jq args...] — apply a filter to the state document.
state_update() {
  local filter="$1" tmp
  shift
  mkdir -p "$(dirname "$STATE_FILE")"
  tmp="$(mktemp)"
  state_read | "$(sg_resolve jq sg_ensure_jq)" "$@" "$filter" >"$tmp" && mv -f "$tmp" "$STATE_FILE"
}

state_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# state_phase_done <phase> <input-sha> — exit 0 when the phase last completed
# with exactly these inputs. Prints the completion time on stdout.
state_phase_done() {
  local at
  at="$(state_read | "$(sg_resolve jq sg_ensure_jq)" -r --arg p "$1" --arg s "$2" '.phases[$p] | select(.input_sha == $s) | .at // empty')"
  [ -n "$at" ] && printf '%s' "$at"
}

# state_mark_phase <phase> <input-sha>
state_mark_phase() { state_update '.phases[$p] = {at: $at, input_sha: $s}' --arg p "$1" --arg s "$2" --arg at "$(state_now)"; }

# state_import_done <seg> <payload-sha> — exit 0 when this payload file was
# fully imported (no failures) with exactly this content.
state_import_done() {
  state_read | "$(sg_resolve jq sg_ensure_jq)" -e --arg s "$1" --arg sha "$2" \
    '.import[$s] | select(.payload_sha == $sha and ((.failed // []) | length) == 0)' >/dev/null 2>&1
}

# state_record_import <seg> <result-json> — merge a do_import result
# ({group, payload_sha, imported, failed}) for a payload file.
state_record_import() { state_update '.import[$s] = ($r + {at: $at})' --arg s "$1" --argjson r "$2" --arg at "$(state_now)"; }

state_reset() { rm -f "$STATE_FILE"; }
