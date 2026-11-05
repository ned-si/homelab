#!/bin/bash
# scripts/ci/install-tool.sh with a stubbed curl: the TOOL_CACHE path.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin"
export STUB_LOG=$tmp/curl.log STUB_BODY=$tmp/body

# curl: logs the URL, writes $STUB_BODY to -o.
cat > "$bin/curl" <<'EOF'
#!/bin/bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; http*) echo "$1" >> "$STUB_LOG" ;; esac
  shift
done
cp "$STUB_BODY" "$out"
EOF
chmod +x "$bin/curl"
export PATH="$bin:$PATH"

printf '#!/bin/sh\necho kubectl\n' > "$STUB_BODY"
sha=$(sha256sum "$STUB_BODY" | cut -d' ' -f1)
export KUBECTL_VERSION=v1.0.0 KUBECTL_SHA256=$sha RUNNER_TEMP=$tmp/runner
unset GITHUB_PATH
cache=$tmp/cache

run() { # -> "rc|output"
  local rc=0 out
  : > "$STUB_LOG"
  out=$(TOOL_CACHE=${TOOL_CACHE_DIR:-} bash "$REPO_ROOT/scripts/ci/install-tool.sh" kubectl 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

out=$(run)
expect_eq "no cache: installs" "0" "${out%%|*}"
expect_eq "no cache: one download" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"
expect_eq "the binary is installed" "kubectl" "$("$tmp/runner/bin/kubectl")"

export TOOL_CACHE_DIR=$cache
mkdir -p "$cache"
echo stale > "$cache/0000"
out=$(run)
expect_eq "cold cache: installs" "0" "${out%%|*}"
expect_contains "cold cache: downloads" "downloaded https://dl.k8s.io/release/v1.0.0/bin/linux/amd64/kubectl" "$out"
expect_eq "the download is kept under its sha256" "$sha" "$(sha256sum "$cache/$sha" | cut -d' ' -f1)"
expect_eq "files of other pins are removed" "$sha" "$(ls "$cache")"

out=$(run)
expect_eq "warm cache: installs" "0" "${out%%|*}"
expect_eq "warm cache: no download" "0" "$(wc -l < "$STUB_LOG" | tr -d ' ')"
expect_contains "warm cache: says so" "cached https://dl.k8s.io/" "$out"

echo tampered >> "$cache/$sha"
out=$(run)
expect_eq "tampered cache: installs" "0" "${out%%|*}"
expect_contains "tampered cache: reported" "fails its sha256; downloading it again" "$out"
expect_eq "tampered cache: downloads again" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"
expect_eq "tampered cache: repaired" "$sha" "$(sha256sum "$cache/$sha" | cut -d' ' -f1)"

rm -f "$cache/$sha"
echo other > "$STUB_BODY"
out=$(run)
expect_eq "a download that fails its sha256 fails" "1" "${out%%|*}"
expect_contains "the mismatch is reported" "sha256 mismatch" "$out"
expect_eq "a bad download is not cached" "" "$(ls "$cache")"

finish
