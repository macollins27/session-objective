#!/usr/bin/env bash
# SO-ROLE: tool
# objective-show.sh — the /objective operator surface. Prints the session's file.
#
# It is the ONLY script near the objective home the Bash guard permits, because it has
# no write path of any kind: it resolves a path, checks it is a file, and cats it. The
# guard admits it only as a bare command — no pipe, redirection, chaining or
# substitution — so nothing can ride along with it.
#
# FAILURE DIRECTION: prints to stderr and exits 1 when it cannot find a file. It
# blesses nothing and gates nothing, so it has no blocking exit.
#
# Usage: objective-show.sh [<path-to-objective.md> | <session-id>]
# With no argument it falls back to $CLAUDE_SESSION_ID, then to the single file under
# the objective home if there is exactly one.
set -uo pipefail

SO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/objective-lib.sh
. "$SO_DIR/lib/objective-lib.sh"

ARG="${1:-}"
FILE=""
if [ -n "$ARG" ] && [ -f "$ARG" ]; then
  FILE="$ARG"
elif [ -n "$ARG" ]; then
  FILE="$(so_home)/sessions/$ARG/objective.md"
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  FILE="$(so_home)/sessions/$CLAUDE_SESSION_ID/objective.md"
else
  N=0; ONE=""
  while IFS= read -r c; do [ -n "$c" ] || continue; N=$((N + 1)); ONE="$c"; done \
    <<< "$(find "$(so_home)/sessions" -maxdepth 2 -name objective.md -type f 2>/dev/null)"
  if [ "$N" = "1" ]; then FILE="$ONE"; fi
fi

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  printf 'session-objective: no objective file found%s. Pass the path shown in the SESSION OBJECTIVE block in context.\n' "${ARG:+ for '$ARG'}" >&2
  exit 1
fi
printf '%s\n' "$FILE"
printf -- '---\n'
cat "$FILE"
