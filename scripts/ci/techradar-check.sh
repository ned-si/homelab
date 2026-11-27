#!/bin/bash
# techradar-check.sh [--all] -- the `techradar` job: the Go module in
# techradar/ and the page it renders into apps/website/techradar/
# (.kiro/specs/tech-radar/design.md, "CI").
#
# go mod verify and tidy, golangci-lint (dashboard/.golangci.yaml, one
# configuration for both modules), go vet, govulncheck (a tool directive in
# go.mod), go test -race with coverage and the golden page, `techradar
# check` (the committed page equals a fresh render) and site_markup.py over
# the page.
#
# Without --all it exits 0 when TECHRADAR_BASE..HEAD (default HEAD^1, main
# for a pull request's merge commit) touches none of techradar/, the rendered
# page, docs/, the specs and this script: the entries link into docs/ and
# .kiro/specs/, so a renamed file there must fail here. Needs go and
# golangci-lint on PATH.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${TECHRADAR_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(techradar/|apps/website/techradar/|docs/|\.kiro/specs/|scripts/ci/techradar|scripts/ci/site_markup\.py$)' <<<"$changed"; then
    echo "techradar: nothing the radar reads changed; skipped"
    exit 0
  fi
fi

for t in go golangci-lint python3; do
  command -v "$t" >/dev/null || { echo "techradar-check: $t is not on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd techradar

rc=0
step() { # name command... -- runs every step, fails the job at the end
  echo "== $1"
  shift
  "$@" || { echo "techradar: FAIL $*" >&2; rc=1; }
}

step "go mod verify" go mod verify
step "go mod tidy" go mod tidy -diff
step "golangci-lint" golangci-lint run --config ../dashboard/.golangci.yaml ./...
step "go vet" go vet ./...
step "govulncheck" go tool govulncheck ./...
step "go test" go test -race -count=1 -coverpkg=./... -coverprofile="$work/cover.out" ./...
step "coverage" "$root/scripts/ci/coverage-report.sh" go techradar "$work/cover.out"
step "rendered page is current" go run ./cmd/techradar check -root "$root" -out ../apps/website/techradar
step "site_markup" python3 ../scripts/ci/site_markup.py ../apps/website/techradar techradar.nedsi.io

[ "$rc" -eq 0 ] && echo "techradar: all checks passed"
exit "$rc"
