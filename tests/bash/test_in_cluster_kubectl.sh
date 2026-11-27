#!/bin/bash
# kubectl in the cluster's own Jobs and hooks never gets --request-timeout:
# with any client override kubectl skips the in-cluster config and dials
# localhost:8080. It broke the PreSync backup hooks (#201) and again the
# restore checks (#451). Comments may name the flag.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
hits=$(git ls-files apps platform components infrastructure | grep -E '\.(sh|ya?ml)$' |
  xargs grep -n -e '--request-timeout' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
expect_eq "no --request-timeout in in-cluster scripts and manifests" "" "$hits"

# The check itself: the #201 form, a kubectl image's args, is found.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '          args: ["delete", "job", "x", "--request-timeout=60s"]\n' > "$tmp/hook.yaml"
expect_contains "the #201 args form is caught" "request-timeout" \
  "$(grep -n -e '--request-timeout' "$tmp/hook.yaml" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"

finish
