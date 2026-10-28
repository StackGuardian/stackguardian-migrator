#!/bin/bash
# Portability lint for the migrator's shell code.
#
# Flags constructs that behave differently between GNU (Linux, the Docker
# image), BSD (macOS) userlands and bash 3.2 (macOS /bin/bash), which
# a shell linter does not know about. Each rule is "<id> @@ <extended regex> @@ <why>".
# Comment lines are skipped; a line can opt out with a trailing
# "# portable: <reason>".
#
# Usage: tests/lint-portability.sh [file...]   (default: every shell script)
# Exit 1 when a rule matches.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# sed/xargs options right after the command (so a later `read -r` on the same
# line is not mistaken for one).
SED_OPTS='\bsed([[:space:]]+-[a-zA-Z]+)*[[:space:]]+'
RULES=(
  # GNU tr reads "_-\n" as a range from _ to newline and dies ("range-endpoints
  # ... in reverse collating sequence order"); BSD tr takes a literal -.
  "tr-dash-escape @@ \\btr\\b.*'[^']*(-\\\\|\\\\[a-z0-9]-[^'])[^']*' @@ a '-' next to an escape is a range in GNU tr; put '-' last in the set"
  # GNU sed -i takes no argument, BSD sed -i requires one: only -i.bak (attached) works on both.
  "sed-inplace @@ ${SED_OPTS}-[a-zA-Z]*i([[:space:]]|$) @@ sed -i differs between GNU and BSD; write to a temp file and mv, or use an attached suffix (-i.bak)"
  "sed-r @@ ${SED_OPTS}-[a-zA-Z]*r([[:space:]]|$) @@ use sed -E (sed -r is GNU-only on older macOS)"
  "sed-gnu-class @@ \\bsed\\b.*\\\\[sSwW] @@ \\s and \\w in sed are GNU extensions; use [[:space:]] / [[:alnum:]_]"
  "date-flags @@ \\bdate[[:space:]]+(-d|--date|-j|-v|-r)\\b @@ date -d is GNU-only, date -j/-v is BSD-only"
  "stat-flags @@ \\bstat[[:space:]]+(-c|-f|--) @@ stat -c (GNU) and stat -f (BSD) are incompatible"
  "readlink-f @@ \\breadlink[[:space:]]+-[a-zA-Z]*f @@ readlink -f is not on older macOS; use cd + pwd"
  "grep-pcre @@ \\bgrep([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(-[a-zA-Z]*P|--perl-regexp) @@ grep -P is GNU-only"
  "xargs-r @@ \\bxargs([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(-[a-zA-Z]*r|--no-run-if-empty) @@ xargs -r is GNU-only"
  "find-gnu @@ \\bfind\\b.*[[:space:]](-printf|-regextype)\\b @@ find -printf / -regextype are GNU-only"
  "base64-w @@ \\bbase64[[:space:]]+-w @@ base64 -w is GNU-only"
  "gnu-only-cmd @@ (^|[;&|(\`]|\\\$\\()[[:space:]]*(timeout|tac|nproc|shuf)\\b @@ not on macOS (timeout, tac, nproc, shuf)"
  "cp-mv-T @@ \\b(cp|mv)[[:space:]]+-[a-zA-Z]*T @@ cp/mv -T is GNU-only"
  "echo-e @@ \\becho[[:space:]]+-e\\b @@ use printf (echo -e is not portable across shells)"
  # bash 3.2 (macOS /bin/bash)
  "bash4-assoc @@ \\b(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A @@ associative arrays need bash 4"
  "bash4-nameref @@ \\b(declare|local|typeset)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*[[:space:]] @@ namerefs need bash 4.3"
  "bash4-mapfile @@ \\b(mapfile|readarray|coproc)\\b @@ mapfile / readarray / coproc need bash 4"
  "bash4-case @@ \\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?(,,?|\\^\\^?)\\} @@ \${var,,} and \${var^^} need bash 4; use tr '[:upper:]' '[:lower:]'"
  "bash4-transform @@ \\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?@[QEPAa]\\} @@ \${var@Q} needs bash 4.4"
  "bash4-redir @@ &>>|\\|& @@ &>> and |& need bash 4"
  "bash4-negidx @@ \\\$\\{[A-Za-z_][A-Za-z0-9_]*\\[-[0-9]+\\]\\} @@ negative array indexes need bash 4.3"
  "bash4-test-v @@ \\[\\[[[:space:]]+-v[[:space:]] @@ [[ -v ]] needs bash 4.2"
  "bash4-wait-n @@ \\bwait[[:space:]]+-n\\b @@ wait -n needs bash 4.3"
  "bash5-epoch @@ \\\$\\{?EPOCH(SECONDS|REALTIME) @@ EPOCHSECONDS needs bash 5"
  # ${s//x/\$\$\{} gives $$\{ under bash 3.2 (the \{ keeps its backslash).
  "bash32-replace-escape @@ \\\$\\{[A-Za-z_][A-Za-z0-9_]*//?[^/}]*/[^}]*\\\\\\{ @@ an escaped brace in a \${var//pat/rep} replacement keeps its backslash under bash 3.2; put the replacement in a variable"
  # "${var:-{\}}" is a literal {\} under bash 3.2 (fixed in c93ab68); quote the default.
  "bash32-brace-default @@ \\\$\\{[A-Za-z_][A-Za-z0-9_]*:?[-=]\\{ @@ a brace in an unquoted \${var:-...} default breaks under bash 3.2; write \"\${var:-\"{}\"}\""
)

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  for f in "$REPO"/sg-migrate.sh "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh "$REPO"/tests/*.sh; do
    # The rule table above would match itself.
    [ "$(basename "$f")" = "lint-portability.sh" ] || files+=("$f")
  done
fi

hits=0
for rule in "${RULES[@]}"; do
  id="${rule%% @@ *}"
  rest="${rule#* @@ }"
  re="${rest%% @@ *}"
  why="${rest#* @@ }"
  for f in "${files[@]}"; do
    out="$(grep -nE -- "$re" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v '# portable:' || true)"
    [ -n "$out" ] || continue
    while IFS= read -r line; do
      printf '%s:%s: [%s] %s\n' "${f#"$REPO"/}" "${line%%:*}" "$id" "$why"
      printf '    %s\n' "$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//' | cut -c1-140)"
      hits=$((hits + 1))
    done <<<"$out"
  done
done

if [ "$hits" -gt 0 ]; then
  printf '\n%d portability issue(s); fix them or mark the line "# portable: <reason>"\n' "$hits"
  exit 1
fi
printf 'portability lint: %d file(s), no issues\n' "${#files[@]}"
