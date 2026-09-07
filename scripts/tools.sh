#!/bin/bash
# Shared tool bootstrap + cache for the StackGuardian migrator.
#
# Source this file; it exposes the repo root and sg_* helpers that download and
# cache the required CLIs under .sg/cached/ (override with SG_CACHE_DIR). Each
# sg_ensure_* function prints the absolute path to a ready-to-run binary on
# stdout; all human-facing logs go to stderr so the path can be captured with
# command substitution: JQ_BIN=$(sg_ensure_jq).

# This file lives in scripts/; the repo root is its parent directory.
SG_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SG_CACHE_DIR="${SG_CACHE_DIR:-$SG_REPO_ROOT/.sg/cached}"
SG_CACHE_BIN="$SG_CACHE_DIR/bin"

# Pinned versions.
SG_JQ_VERSION="jq-1.8.1"
SG_HCL2JSON_VERSION="v0.6.7"
SG_YAJSV_VERSION="v1.4.1"

# Colored logging — disabled when stderr is not a TTY, NO_COLOR is set, or
# TERM=dumb, so piped/CI output stays clean.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

# sg_rel <path> — render a path relative to the repo root for readable logs
# (operations still use absolute paths; this is display-only).
sg_rel() {
  case "$1" in
  "$SG_REPO_ROOT"/*) printf '%s' "${1#"$SG_REPO_ROOT"/}" ;;
  "$SG_REPO_ROOT") printf '.' ;;
  *) printf '%s' "$1" ;;
  esac
}

sg_log() { printf '%s[sg-migrate]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
sg_warn() { printf '%s[sg-migrate] WARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
sg_err() { printf '%s[sg-migrate] ERROR%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
sg_success() { printf '%s[sg-migrate] ✓%s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*" >&2; }
sg_step() { printf '\n%s==> %s%s\n' "$C_CYAN$C_BOLD" "$*" "$C_RESET" >&2; }
sg_dim() { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
# sg_row <label> <value> — an aligned "  label   value" line (review/summary tables).
sg_row() { printf '  %s%-26s%s %s\n' "$C_BOLD" "$1" "$C_RESET" "$2" >&2; }

# sg_fmt_secs <seconds> — 14s / 1m 12s / 1h 02m, for "done in ..." messages.
sg_fmt_secs() {
  local s="${1:-0}"
  if [ "$s" -ge 3600 ]; then printf '%dh %02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  elif [ "$s" -ge 60 ]; then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"
  else printf '%ds' "$s"; fi
}

# sg_maxlen <min> <string>... — the longest string's length, but at least <min>
# (used to size table columns to their content).
sg_maxlen() {
  local w="$1" s
  shift
  for s in "$@"; do [ "${#s}" -gt "$w" ] && w="${#s}"; done
  printf '%s' "$w"
}

# In-place progress line for long-running steps. Animated only when stderr is a
# TTY with colors on (same switch as the colors); plain log lines otherwise, so
# CI logs never fill up with spinner frames.
SG_ANIMATE=0
[ -n "$C_RESET" ] && SG_ANIMATE=1
_SG_SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SG_SPIN_I=0
sg_spin_frame() {
  [ "$SG_ANIMATE" = "1" ] || return 0
  printf '\r%s[sg-migrate]%s %s%s%s %s\033[K' "$C_CYAN" "$C_RESET" "$C_CYAN" "${_SG_SPIN_FRAMES[_SG_SPIN_I % 10]}" "$C_RESET" "$1" >&2
  _SG_SPIN_I=$((_SG_SPIN_I + 1))
}
sg_spin_clear() {
  [ "$SG_ANIMATE" = "1" ] && printf '\r\033[K' >&2
  return 0
}

# sg_run_quiet <running-label> <done-label> <logfile> <cmd...> — run cmd with
# stdout+stderr captured in logfile, showing "<running-label> (elapsed)" as a
# live line meanwhile, then a "<done-label> (took Ns)" log line. Returns the
# command's exit code; the caller decides what to do with the log.
sg_run_quiet() {
  local running="$1" done_label="$2" log="$3" pid rc=0 t0=$SECONDS
  shift 3
  "$@" >"$log" 2>&1 &
  pid=$!
  if [ "$SG_ANIMATE" = "1" ]; then
    while kill -0 "$pid" 2>/dev/null; do
      sg_spin_frame "$running $C_DIM($(sg_fmt_secs $((SECONDS - t0))))$C_RESET"
      sleep 0.2
    done
    sg_spin_clear
  else
    sg_log "$running..."
  fi
  wait "$pid" || rc=$?
  [ "$rc" -eq 0 ] && sg_log "$done_label $C_DIM($(sg_fmt_secs $((SECONDS - t0))))$C_RESET"
  return "$rc"
}

sg_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) echo "amd64" ;;
  aarch64 | arm64) echo "arm64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    return 1
    ;;
  esac
}

# sg_retry <max_attempts> <base_delay_seconds> -- <command...>
# Runs the command, retrying with exponential backoff (capped at 60s, with a
# little jitter) until it succeeds or attempts are exhausted. Returns the
# command's last exit code. Used to ride out transient API failures/rate limits.
# Exit codes listed in SG_NO_RETRY_RC (space-separated) are returned immediately
# (e.g. a definitive HTTP 4xx). Only the command name is echoed on failure so
# that tokens passed as arguments never land in the log.
sg_retry() {
  local max="$1" base="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local attempt=1 delay="$base" rc=0
  while :; do
    "$@" && return 0
    rc=$?
    case " ${SG_NO_RETRY_RC:-} " in *" $rc "*)
      sg_err "$(basename "$1") failed (exit ${rc}, not retryable)"
      return "$rc"
      ;;
    esac
    if [ "$attempt" -ge "$max" ]; then
      sg_err "$(basename "$1") failed after ${attempt} attempt(s) (exit ${rc})"
      return "$rc"
    fi
    local jitter=$((RANDOM % (base + 1)))
    sg_warn "attempt ${attempt}/${max} failed (exit ${rc}); retrying in $((delay + jitter))s..."
    sleep "$((delay + jitter))"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -gt 60 ] && delay=60
  done
}

# sg_resolve <command-name> <ensure-fn>: prefer a binary already on PATH (e.g.
# installed in the Docker image); otherwise download+cache via the ensure fn.
# Prints the path to use on stdout.
sg_resolve() {
  local name="$1" ensure="$2"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [ -n "$ensure" ]; then
    "$ensure"
    return $?
  fi
  echo "Required tool '$name' not found on PATH" >&2
  return 1
}

# sg_download <url> <dest>
sg_download() {
  local url="$1" dest="$2"
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required but not found" >&2
    return 1
  }
  mkdir -p "$(dirname "$dest")"
  if ! curl -fsSL -o "$dest" "$url"; then
    echo "Failed to download: $url" >&2
    return 1
  fi
}

sg_ensure_jq() {
  local bin="$SG_CACHE_BIN/jq" arch os
  if [ ! -x "$bin" ]; then
    arch=$(sg_arch) || return 1
    case "$(uname -s)" in Darwin) os="macos" ;; Linux) os="linux" ;; *)
      echo "Unsupported OS: $(uname -s)" >&2
      return 1
      ;;
    esac
    sg_log "caching jq ${SG_JQ_VERSION}..."
    sg_download "https://github.com/jqlang/jq/releases/download/${SG_JQ_VERSION}/jq-${os}-${arch}" "$bin" || return 1
    chmod +x "$bin"
  fi
  echo "$bin"
}

sg_ensure_hcl2json() {
  local bin="$SG_CACHE_BIN/hcl2json" arch os
  if [ ! -x "$bin" ]; then
    arch=$(sg_arch) || return 1
    case "$(uname -s)" in Darwin) os="darwin" ;; Linux) os="linux" ;; *)
      echo "Unsupported OS: $(uname -s)" >&2
      return 1
      ;;
    esac
    sg_log "caching hcl2json ${SG_HCL2JSON_VERSION}..."
    sg_download "https://github.com/tmccombs/hcl2json/releases/download/${SG_HCL2JSON_VERSION}/hcl2json_${os}_${arch}" "$bin" || return 1
    chmod +x "$bin"
  fi
  echo "$bin"
}

sg_ensure_yajsv() {
  local bin="$SG_CACHE_BIN/yajsv" arch os
  if [ ! -x "$bin" ]; then
    arch=$(sg_arch) || return 1
    case "$(uname -s)" in Darwin) os="darwin" ;; Linux) os="linux" ;; *)
      echo "Unsupported OS: $(uname -s)" >&2
      return 1
      ;;
    esac
    if [ "$os" = "linux" ] && [ "$arch" = "arm64" ]; then
      echo "No yajsv prebuilt binary for linux/arm64; install yajsv manually." >&2
      return 1
    fi
    sg_log "caching yajsv ${SG_YAJSV_VERSION}..."
    sg_download "https://github.com/neilpa/yajsv/releases/download/${SG_YAJSV_VERSION}/yajsv.${os}.${arch}" "$bin" || return 1
    chmod +x "$bin"
  fi
  echo "$bin"
}

# Caches the sg-cli Go binary (latest release) for the host OS/arch and prints
# its path. Release assets are named sg-cli_<OS>_<ARCH>.tar.gz (Darwin/Linux,
# arm64/x86_64).
sg_ensure_sgcli() {
  local bin="$SG_CACHE_BIN/sg-cli" os arch tmp realcli
  if [ ! -x "$bin" ]; then
    case "$(uname -s)" in Darwin) os="Darwin" ;; Linux) os="Linux" ;; *)
      echo "Unsupported OS: $(uname -s)" >&2
      return 1
      ;;
    esac
    case "$(uname -m)" in x86_64 | amd64) arch="x86_64" ;; aarch64 | arm64) arch="arm64" ;; *)
      echo "Unsupported architecture: $(uname -m)" >&2
      return 1
      ;;
    esac
    sg_log "caching sg-cli (latest release, ${os}/${arch})..."
    tmp=$(mktemp -d)
    if ! curl -fsSL "https://github.com/StackGuardian/sg-cli/releases/latest/download/sg-cli_${os}_${arch}.tar.gz" -o "$tmp/sg-cli.tar.gz"; then
      echo "Failed to download sg-cli" >&2
      rm -rf "$tmp"
      return 1
    fi
    tar -xzf "$tmp/sg-cli.tar.gz" -C "$tmp"
    realcli=$(find "$tmp" -maxdepth 2 -type f -name sg-cli | head -1)
    [ -n "$realcli" ] || {
      echo "sg-cli binary not found in release archive" >&2
      rm -rf "$tmp"
      return 1
    }
    mkdir -p "$SG_CACHE_BIN"
    cp "$realcli" "$bin"
    chmod +x "$bin"
    rm -rf "$tmp"
  fi
  echo "$bin"
}
