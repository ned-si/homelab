#!/bin/bash
# dashboard-check.sh [--all] -- the `dashboard` job: the Go module in
# dashboard/ (.kiro/specs/homelab-dashboard/design.md, "CI on pull requests").
#
# go mod verify and tidy, golangci-lint (dashboard/.golangci.yaml), go vet,
# govulncheck (a tool directive in go.mod), go test -race with the golden
# files, go build, and the builder image's Go version against go.mod.
#
# Without --all it exits 0 when DASHBOARD_BASE..HEAD (default HEAD^1, main for
# a pull request's merge commit) touches neither dashboard/, this script nor
# the publishing workflow. Needs go and golangci-lint on PATH.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${DASHBOARD_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(dashboard/|scripts/ci/dashboard-check\.sh$|\.github/workflows/dashboard-publish\.yaml$)' <<<"$changed"; then
    echo "dashboard: nothing under dashboard/ changed; skipped"
    exit 0
  fi
fi

for t in go golangci-lint; do
  command -v "$t" >/dev/null || { echo "dashboard-check: $t is not on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd dashboard

rc=0
step() { # name command... -- runs every step, fails the job at the end
  echo "== $1"
  shift
  "$@" || { echo "dashboard: FAIL $*" >&2; rc=1; }
}

step "go mod verify" go mod verify
step "go mod tidy" go mod tidy -diff
step "golangci-lint" golangci-lint run ./...
step "go vet" go vet ./...
step "govulncheck" go tool govulncheck ./...
step "go test" go test -race -count=1 ./...
step "go build" go build -o "$work/homelab-dashboard" ./cmd/homelab-dashboard

echo "== builder image vs go.mod"
# go mod tidy drops a toolchain line equal to the go line.
want=$(sed -nE 's/^toolchain go([0-9.]+)$/\1/p' go.mod)
[ -n "$want" ] || want=$(sed -nE 's/^go ([0-9.]+)$/\1/p' go.mod)
have=$(sed -nE 's/^FROM .*golang:([0-9.]+)-.* AS build$/\1/p' Dockerfile)
if [ -z "$want" ] || [ "$want" != "$have" ]; then
  echo "dashboard: FAIL the builder image runs Go ${have:-?}, go.mod wants ${want:-?}" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "dashboard: all checks passed"
exit "$rc"
