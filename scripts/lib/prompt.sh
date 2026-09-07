#!/bin/bash
# Interactive prompt helpers for the migrator (sourced; needs tools.sh).
#
# Every prompt is written to stderr and read from the terminal; the answer is
# printed on stdout so callers capture it: v="$(sg_ask "Org" "demo")".
# Non-interactive runs (SG_NONINTERACTIVE=1, or no usable TTY) get the default
# answer, and fail when a prompt has none. Tests can script answers by pointing
# SG_ANSWERS_FILE at a file with one answer per line, consumed in order.

# sg_interactive — true when we can talk to a terminal (and were not told not to).
sg_interactive() {
  [ "${SG_NONINTERACTIVE:-0}" != "1" ] || return 1
  [ -n "${SG_ANSWERS_FILE:-}" ] && return 0
  (: </dev/tty) 2>/dev/null
}

# The scripted-answers file is opened once, here, on fd 9: prompts run inside
# $(...) subshells, which inherit the descriptor and advance the shared offset,
# so answers are consumed in order across calls.
if [ -n "${SG_ANSWERS_FILE:-}" ]; then
  exec 9<"$SG_ANSWERS_FILE"
fi

# _sg_read <prompt-text> — print the prompt, read one line (tty or answers
# file). Returns 1 on EOF so callers never loop on an exhausted input.
_sg_read() {
  local ans
  printf '%s' "$1" >&2
  if [ -n "${SG_ANSWERS_FILE:-}" ]; then
    IFS= read -r ans <&9 || { printf '\n' >&2; return 1; }
    printf '%s\n' "$ans" >&2
  else
    IFS= read -r ans </dev/tty || { printf '\n' >&2; return 1; }
  fi
  printf '%s' "$ans"
}

# sg_ask <question> [default] — free-text answer (default when empty).
sg_ask() {
  local q="$1" def="${2-}" ans
  if ! sg_interactive; then
    [ -n "$def" ] || { sg_err "'$q' has no default and the run is non-interactive"; return 1; }
    printf '%s' "$def"
    return 0
  fi
  if [ -n "$def" ]; then
    ans="$(_sg_read "$(printf '%s? %s%s %s[%s]%s: ' "$C_BOLD" "$q" "$C_RESET" "$C_DIM" "$def" "$C_RESET")")" || { sg_err "input closed while asking '$q'"; return 1; }
  else
    ans="$(_sg_read "$(printf '%s? %s%s: ' "$C_BOLD" "$q" "$C_RESET")")" || { sg_err "input closed while asking '$q'"; return 1; }
  fi
  printf '%s' "${ans:-$def}"
}

# sg_ask_required <question> — like sg_ask, but re-prompts until non-empty.
sg_ask_required() {
  local ans
  while :; do
    ans="$(sg_ask "$1")" || return 1
    [ -n "$ans" ] && { printf '%s' "$ans"; return 0; }
    sg_warn "a value is required"
  done
}

# sg_confirm <question> [Y|N] — exit 0 for yes, 1 for no. Default Y unless "N".
sg_confirm() {
  local q="$1" def="${2:-Y}" ans hint
  if ! sg_interactive; then
    [ "$def" = "Y" ] && return 0 || return 1
  fi
  [ "$def" = "Y" ] && hint="Y/n" || hint="y/N"
  ans="$(_sg_read "$(printf '%s? %s%s %s[%s]%s ' "$C_BOLD" "$q" "$C_RESET" "$C_DIM" "$hint" "$C_RESET")")" || { sg_err "input closed while asking '$q'"; return 1; }
  ans="${ans:-$def}"
  case "$ans" in y | Y | yes | YES | Yes) return 0 ;; *) return 1 ;; esac
}

# sg_select <question> <item>... — numbered menu; prints the chosen item's value.
# Items are "value" or "value|description". The first item is the default.
# SG_SELECT_OTHER=1 adds an "Other (type a value)" entry for free text.
sg_select() {
  local q="$1"
  shift
  local -a vals descs
  local i n item ans
  n=0
  for item in "$@"; do
    vals[n]="${item%%|*}"
    case "$item" in *"|"*) descs[n]="${item#*|}" ;; *) descs[n]="" ;; esac
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { sg_err "sg_select: no items for '$q'"; return 1; }
  if ! sg_interactive; then
    printf '%s' "${vals[0]}"
    return 0
  fi
  printf '%s? %s%s\n' "$C_BOLD" "$q" "$C_RESET" >&2
  # Descriptions line up in one column sized to the longest value (capped so a
  # single very long name cannot push everything off-screen).
  local w
  w="$(sg_maxlen 10 "${vals[@]}")"
  [ "$w" -gt 40 ] && w=40
  for ((i = 0; i < n; i++)); do
    if [ -n "${descs[i]}" ]; then
      printf "  %s%2d)%s %-${w}s %s%s%s\n" "$C_CYAN" "$((i + 1))" "$C_RESET" "${vals[i]}" "$C_DIM" "— ${descs[i]}" "$C_RESET" >&2
    else
      printf '  %s%2d)%s %s\n' "$C_CYAN" "$((i + 1))" "$C_RESET" "${vals[i]}" >&2
    fi
  done
  [ "${SG_SELECT_OTHER:-0}" = "1" ] && printf '  %s%2d)%s Other (type a value)\n' "$C_CYAN" "$((n + 1))" "$C_RESET" >&2
  while :; do
    ans="$(_sg_read "$(printf '  %schoice%s %s[1]%s: ' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET")")" || { sg_err "input closed while asking '$q'"; return 1; }
    ans="${ans:-1}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
      printf '%s' "${vals[ans - 1]}"
      return 0
    fi
    if [ "${SG_SELECT_OTHER:-0}" = "1" ] && [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -eq "$((n + 1))" ]; then
      sg_ask_required "value"
      return $?
    fi
    # Typing an item's value verbatim also works.
    for ((i = 0; i < n; i++)); do
      [ "$ans" = "${vals[i]}" ] && { printf '%s' "$ans"; return 0; }
    done
    sg_warn "enter a number between 1 and $n"
  done
}
