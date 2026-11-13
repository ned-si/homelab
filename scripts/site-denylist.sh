#!/bin/bash
# site-denylist.sh -- fail when a file under site/ contains a term of
# site/denylist.local.txt (git-ignored; one term per line, # comments, case
# insensitive). Prints the file and line of each match, never the term.
# Passes when the list is absent, as in CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

list=site/denylist.local.txt
[ -f "$list" ] || exit 0
pats=$(mktemp)
trap 'rm -f "$pats"' EXIT
tr -d '\r' < "$list" | grep -vE '^[[:space:]]*(#|$)' > "$pats" || true
[ -s "$pats" ] || exit 0

files=$(git ls-files -co --exclude-standard site)
[ -n "$files" ] || exit 0
hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -niIF -f "$pats" -- | cut -d: -f1,2 || true)
if [ -n "$hits" ]; then
  echo "site-denylist: a term of $list appears in:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
