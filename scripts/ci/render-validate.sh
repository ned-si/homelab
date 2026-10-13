#!/bin/bash
# render-validate.sh -- the CI `render` job's checks in one command, for the
# `ci-render` pre-push hook (.pre-commit-config.yaml):
#   1. scripts/ci/render_apps.py   render every Application in scope
#   2. scripts/ci/kubeconform.sh   strict schemas over that render
#   3. scripts/ci/repo-policy.sh   repository invariants over that render
# Every step runs; exit 1 if any failed. The render goes to a temporary
# directory that is removed on exit (it can hold credentials from legacy
# inline Helm values, so it is never written into the checkout).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
out=$(mktemp -d "${TMPDIR:-/tmp}/render-validate.XXXXXX")
trap 'rm -rf "$out"' EXIT
rc=0

if python3 scripts/ci/render_apps.py --out "$out/render" > "$out/render.log" 2>&1; then
  tail -n 1 "$out/render.log"
  scripts/ci/kubeconform.sh "$out/render" || rc=1
  scripts/ci/repo-policy.sh "$out/render" || rc=1
else
  cat "$out/render.log"
  echo "render-validate: render failed; repo-policy renders by itself" >&2
  rc=1
  scripts/ci/repo-policy.sh || true
fi
exit "$rc"
