#!/bin/bash
# repo-policy.sh [render-dir]
#
# The `repo-policy` CI check: every repository invariant in one place.
#   1. scripts/ci/check-pins.sh       every workflow/action `uses:` is pinned
#   2. scripts/ci/repo_policy.py      invariants over the checkout and the render
#                                     (renders first with render_apps.py unless a
#                                     render directory is given)
#   3. when present (they arrive with the restructured layout):
#      scripts/secrets-check.sh (strict), scripts/leak-check.sh,
#      scripts/placeholder-check.sh, scripts/check-restic-repos.sh,
#      scripts/render-deploy.sh --check, kube-linter on deploy/
# Every step runs; the script fails if any step failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
render=${1:-}
rc=0
summary=()

step() { # name cmd...
  local name=$1
  shift
  echo "::group::$name"
  if "$@"; then
    summary+=("| $name | pass |")
  else
    summary+=("| $name | FAIL |")
    rc=1
  fi
  echo "::endgroup::"
}

step check-pins bash scripts/ci/check-pins.sh .

if [ -z "$render" ]; then
  render="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/render-policy"
  step render python3 scripts/ci/render_apps.py --out "$render"
fi
if [ -f "$render/index.json" ]; then
  step repo_policy.py python3 scripts/ci/repo_policy.py --render "$render" --repo-root .
else
  summary+=("| repo_policy.py | FAIL (no render index) |")
  rc=1
fi

[ -x scripts/secrets-check.sh ] && step secrets-check env SECRETS_CHECK_STRICT=1 scripts/secrets-check.sh
[ -x scripts/leak-check.sh ] && step leak-check scripts/leak-check.sh
[ -x scripts/placeholder-check.sh ] && step placeholder-check scripts/placeholder-check.sh
[ -x scripts/check-restic-repos.sh ] && step check-restic-repos scripts/check-restic-repos.sh
[ -x scripts/render-deploy.sh ] && step render-deploy-check scripts/render-deploy.sh --check
if [ -d deploy ]; then
  if [ -f .kube-linter.yaml ]; then
    step kube-linter kube-linter lint deploy --config .kube-linter.yaml
  else
    step kube-linter kube-linter lint deploy
  fi
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### repo-policy"
    echo "| step | result |"
    echo "|---|---|"
    printf '%s\n' "${summary[@]}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
printf '%s\n' "${summary[@]}"
exit "$rc"
