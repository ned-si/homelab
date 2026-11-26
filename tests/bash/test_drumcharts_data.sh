#!/bin/bash
# Tests for the pin check of scripts/ci/drumcharts-data.sh: a malformed pin
# must fail before cosign or docker run (both are fakes that record a call).
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/ci/drumcharts-data.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/repo/drumcharts"
for t in cosign docker; do
  printf '#!/bin/bash\necho %s >> "%s/calls"\n' "$t" "$tmp" > "$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
git -C "$tmp/repo" init -q
digest=$(printf 'a%.0s' $(seq 64))

# check <name> <source.yaml content>: the script exits 1 and calls nothing.
check() {
  rm -f "$tmp/calls"
  printf '%s\n' "$2" > "$tmp/repo/drumcharts/source.yaml"
  out=$(cd "$tmp/repo" && PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/out" 2>&1); rc=$?
  expect_eq "$1: exit 1" 1 "$rc"
  expect_contains "$1: message" "not a pinned drum-charts image" "$out"
  expect_eq "$1: no cosign or docker call" "" "$(cat "$tmp/calls" 2>/dev/null)"
}

check "tag only" "image: ghcr.io/ned-si/drum-charts:main"
check "digest only" "image: ghcr.io/ned-si/drum-charts@sha256:$digest"
check "other owner" "image: ghcr.io/someone/drum-charts:main@sha256:$digest"
check "short digest" "image: ghcr.io/ned-si/drum-charts:main@sha256:abc"
check "two lines" "image: ghcr.io/ned-si/drum-charts:main@sha256:$digest
image: ghcr.io/someone/drum-charts:main@sha256:$digest"

# The well-formed pin reaches cosign.
rm -f "$tmp/calls"
printf 'image: ghcr.io/ned-si/drum-charts:main@sha256:%s\n' "$digest" > "$tmp/repo/drumcharts/source.yaml"
(cd "$tmp/repo" && PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/out" >/dev/null 2>&1)
expect_contains "a pinned image is verified first" "cosign" "$(head -1 "$tmp/calls" 2>/dev/null)"

finish
