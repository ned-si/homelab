#!/bin/bash
# check-title.sh <subject>
#
# The one implementation of the commit-subject / PR-title rule. Used by the
# `pr-title` and `commits` CI steps and by scripts/pr-merge.sh.
#
# A subject passes when it matches the Conventional Commits regex below AND is
# shorter than 70 characters. The regex alone does not bound a long scope, so
# both conditions are always checked.
#
# Exit 0 = pass, 1 = fail (reason on stderr), 64 = usage.
set -euo pipefail

RX='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|security|style|test)(\([a-z0-9._/-]+\))?!?: [^ ].{0,58}[^ .]$'
MAX_LEN=70

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <subject>" >&2
  exit 64
fi

s=$1
rc=0
if ! [[ "$s" =~ $RX ]]; then
  echo "fail: not a Conventional Commits subject (type(scope)?!?: summary, no trailing dot or space): $s" >&2
  rc=1
fi
if [ "${#s}" -ge "$MAX_LEN" ]; then
  echo "fail: ${#s} characters, must be under $MAX_LEN: $s" >&2
  rc=1
fi
exit "$rc"
