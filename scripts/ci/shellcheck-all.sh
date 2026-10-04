#!/bin/bash
# Runs ShellCheck on every tracked *.sh and every tracked file whose shebang
# names sh or bash. Exit 1 if any file has a finding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

files=()
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) files+=("$f"); continue ;;
  esac
  first=$(head -c 64 "$f" | head -n 1 || true)
  case "$first" in
    '#!'*bash*|'#!'*/sh|'#!'*/sh\ *|'#!'*env\ sh*) files+=("$f") ;;
  esac
done < <(git ls-files -z --cached --others --exclude-standard)

if [ "${#files[@]}" -eq 0 ]; then
  echo "shellcheck-all: no shell scripts"
  exit 0
fi
shellcheck --version | sed -n 2p
shellcheck -x "${files[@]}"
echo "shellcheck-all: ${#files[@]} file(s) clean"
