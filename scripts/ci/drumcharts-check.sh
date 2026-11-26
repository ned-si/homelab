#!/bin/bash
# drumcharts-check.sh [--all] -- the `drumcharts` job: the Go module in
# drumcharts/ and the pinned site data it renders for charts.nedsi.io
# (.kiro/specs/drum-charts-site/design.md, "CI").
#
# The go line equals dashboard/go.mod's; go mod verify and tidy,
# golangci-lint (dashboard/.golangci.yaml), go vet, govulncheck (a tool
# directive in go.mod); drumcharts-data.sh verifies and extracts the pinned
# image, and must fail with the site-publish identity; go test -race with
# the golden tree and the real page images; `drumcharts render` of the data
# and site_markup.py over the pages.
#
# Without --all it exits 0 when DRUMCHARTS_BASE..HEAD (default HEAD^1, main
# for a pull request's merge commit) touches none of drumcharts/, dashboard/go.mod, the
# stylesheets it copies, these scripts, site_markup.py and the workflows that
# run them. Needs go, golangci-lint, python3, cosign and docker on PATH.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${DRUMCHARTS_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(drumcharts/|dashboard/go\.mod$|site/assets/css/|scripts/ci/(drumcharts|site_markup)|\.github/workflows/(ci|site-publish)\.yaml$)' <<<"$changed"; then
    echo "drumcharts: nothing the charts site reads changed; skipped"
    exit 0
  fi
fi

for t in go golangci-lint python3 cosign docker; do
  command -v "$t" >/dev/null || { echo "drumcharts-check: $t is not on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rc=0
step() { # name command... -- runs every step, fails the job at the end
  echo "== $1"
  shift
  "$@" || { echo "drumcharts: FAIL $*" >&2; rc=1; }
}

# shellcheck disable=SC2329 # run through step
same_go() {
  local want got
  want=$(grep -m1 '^go ' dashboard/go.mod)
  got=$(grep -m1 '^go ' drumcharts/go.mod)
  [ "$got" = "$want" ] || { echo "drumcharts/go.mod has '$got', dashboard/go.mod '$want'" >&2; return 1; }
}

# The pin must be signed by drum-charts' build workflow, not merely by any
# workflow of this owner.
# shellcheck disable=SC2329 # run through step
other_identity_fails() {
  if DRUMCHARTS_IDENTITY=https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main \
    scripts/ci/drumcharts-data.sh "$work/other"; then
    echo "drumcharts-data.sh accepted the site-publish identity" >&2
    return 1
  fi
}

step "go line equals dashboard/go.mod" same_go
step "drumcharts-data.sh" scripts/ci/drumcharts-data.sh "$work/data"
step "another signer identity fails" other_identity_fails

cd drumcharts
step "go mod verify" go mod verify
step "go mod tidy" go mod tidy -diff
step "golangci-lint" golangci-lint run --config ../dashboard/.golangci.yaml ./...
step "go vet" go vet ./...
step "govulncheck" go tool govulncheck ./...
step "go test" env DRUMCHARTS_DATA="$work/data" go test -race -count=1 ./...
step "drumcharts render" go run ./cmd/drumcharts render -data "$work/data" -out "$work/site"
step "site_markup" python3 ../scripts/ci/site_markup.py "$work/site" charts.nedsi.io

[ "$rc" -eq 0 ] && echo "drumcharts: all checks passed"
exit "$rc"
