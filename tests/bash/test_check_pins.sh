#!/bin/bash
# scripts/ci/check-pins.sh on good and bad workflow fixtures (generated in a temp dir).
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
DIGEST=$(printf 'a%.0s' $(seq 1 64))

mk() { # dir file content
  mkdir -p "$1/$(dirname "$2")"
  printf '%s\n' "$3" > "$1/$2"
}

run_pins() { # dir -> "rc|stderr"
  local rc=0 err
  err=$(bash "$REPO_ROOT/scripts/ci/check-pins.sh" "$1" 2>&1 >/dev/null) || rc=$?
  printf '%s|%s' "$rc" "$err"
}

good=$tmp/good
mk "$good" .github/workflows/ci.yaml "jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA # v7.0.1
      - uses: \"github/codeql-action/upload-sarif@$SHA\" # v4.38.2
      - uses: ./.github/actions/setup
      - uses: docker://alpine@sha256:$DIGEST"
mk "$good" .github/actions/setup/action.yml "runs:
  using: composite
  steps:
    - uses: actions/setup-python@$SHA # v6.0.0"
out=$(run_pins "$good")
expect_eq "good workflow, local action and docker digest pass" "0|" "$out"

bad=$tmp/bad
mk "$bad" .github/workflows/ci.yml "jobs:
  a:
    steps:
      - uses: actions/checkout@v5
      - uses: actions/checkout@main
      - uses: actions/checkout@$SHA
      - uses: docker://alpine:3.20
      - uses: ./.github/actions/missing
      - uses: ./.github/actions/inner"
mk "$bad" .github/actions/inner/action.yaml "runs:
  using: composite
  steps:
    - uses: actions/setup-node@v5"
out=$(run_pins "$bad")
expect_eq "bad workflow exits 1" "1" "${out%%|*}"
expect_contains "tag is rejected" ".github/workflows/ci.yml:4: not pinned to a 40-hex commit SHA: actions/checkout@v5" "$out"
expect_contains "branch is rejected" ".github/workflows/ci.yml:5: not pinned" "$out"
expect_contains "SHA without a version comment is rejected" "ci.yml:6: SHA-pinned action without a '# vX.Y.Z' comment" "$out"
expect_contains "docker without digest is rejected" "ci.yml:7: docker reference without a sha256 digest" "$out"
expect_contains "missing local action is rejected" "ci.yml:8: local action ./.github/actions/missing has no action.yml" "$out"
expect_contains "local action is checked recursively" ".github/actions/inner/action.yaml:4: not pinned to a 40-hex commit SHA: actions/setup-node@v5" "$out"

empty=$tmp/empty
mkdir -p "$empty"
out=$(run_pins "$empty")
expect_eq "no workflows passes" "0|" "$out"

out=$(run_pins "$REPO_ROOT")
expect_eq "this repository's workflows pass" "0|" "$out"

finish
