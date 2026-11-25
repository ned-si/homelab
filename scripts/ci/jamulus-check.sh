#!/bin/bash
# jamulus-check.sh [--all] -- the `jamulus` job: builds the Jamulus image for
# linux/amd64 and runs scripts/ci/jamulus-smoke.sh on it
# (.kiro/specs/self-hosted-jamulus/design.md#files).
#
# Without --all it writes checked=false to $GITHUB_OUTPUT and exits 0 when
# JAMULUS_BASE..HEAD (default HEAD^1, main for a pull request's merge commit)
# touches none of jamulus/, scripts/ci/jamulus-*.sh and
# platform/jamulus-probe/. Otherwise checked=true. Needs docker with buildx.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "checked=$1" >>"$GITHUB_OUTPUT"; fi; }
if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${JAMULUS_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(jamulus/|scripts/ci/jamulus-[^/]*\.sh$|platform/jamulus-probe/)' <<<"$changed"; then
    echo "jamulus: nothing under jamulus/ changed; skipped"
    output false
    exit 0
  fi
fi
output true
docker buildx build --platform linux/amd64 --load -t jamulus:smoke jamulus
scripts/ci/jamulus-smoke.sh jamulus:smoke
