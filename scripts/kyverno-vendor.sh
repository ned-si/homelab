#!/bin/bash
# kyverno-vendor.sh -- vendor upstream kyverno/policies files, unchanged.
#
#   scripts/kyverno-vendor.sh           download every file listed in
#                                       policies/kyverno/upstream/SOURCE at its
#                                       `commit:` and rewrite the sha256 lines
#   scripts/kyverno-vendor.sh --check   offline: every listed file exists and
#                                       matches its sha256, and no other policy
#                                       file sits under policies/kyverno/upstream
#
# SOURCE lists the files by their upstream path; the local copy has the same
# path under policies/kyverno/upstream/. To add or drop a policy, edit the list
# in SOURCE (any sha256 for a new line) and run the script. Renovate moves the
# `commit:` line; the renovate-render workflow runs this script, so the files
# follow the commit in the same pull request.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/policies/kyverno/upstream"
SRC="$DIR/SOURCE"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

[ -f "$SRC" ] || { echo "kyverno-vendor: $SRC missing" >&2; exit 1; }
repo=$(sed -n 's/^repo: *//p' "$SRC")
commit=$(sed -n 's/^commit: *//p' "$SRC")
[[ "$repo" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "kyverno-vendor: bad repo: $repo" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "kyverno-vendor: bad commit: $commit" >&2; exit 1; }
files=()
while read -r _ path; do
  [[ "$path" =~ ^[A-Za-z0-9_./-]+\.yaml$ && "$path" != *..* ]] || { echo "kyverno-vendor: bad path: $path" >&2; exit 1; }
  files+=("$path")
done < <(grep -E '^[0-9a-f]{64}  ' "$SRC")
[ "${#files[@]}" -gt 0 ] || { echo "kyverno-vendor: no files in $SRC" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  rc=0
  while read -r want path; do
    f="$DIR/$path"
    if [ ! -f "$f" ]; then echo "kyverno-vendor: missing $path" >&2; rc=1; continue; fi
    [ "$(sha "$f")" = "$want" ] || { echo "kyverno-vendor: $path differs from upstream $commit (edit SOURCE and re-vendor, never the file)" >&2; rc=1; }
  done < <(grep -E '^[0-9a-f]{64}  ' "$SRC")
  while IFS= read -r f; do
    rel=${f#"$DIR"/}
    grep -qE "^[0-9a-f]{64}  ${rel//./\\.}\$" "$SRC" || { echo "kyverno-vendor: $rel is not listed in SOURCE" >&2; rc=1; }
  done < <(find "$DIR" -name '*.yaml' -type f ! -name controls.yaml | sort)
  [ "$rc" -eq 0 ] && echo "kyverno-vendor: ${#files[@]} files match ${repo#https://github.com/}@${commit:0:12}"
  exit "$rc"
fi

raw="https://raw.githubusercontent.com/${repo#https://github.com/}/$commit"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sums="$tmp/sums"
: > "$sums"
for path in "${files[@]}"; do
  mkdir -p "$tmp/files/$(dirname "$path")"
  curl -fsSL --retry 3 -m 30 -o "$tmp/files/$path" "$raw/$path"
  printf '%s  %s\n' "$(sha "$tmp/files/$path")" "$path" >> "$sums"
done
# Replace the tree only once every download succeeded.
find "$DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
cp -R "$tmp/files/." "$DIR/"
{ grep -vE '^[0-9a-f]{64}  ' "$SRC"; cat "$sums"; } > "$tmp/SOURCE"
cp "$tmp/SOURCE" "$SRC"
echo "kyverno-vendor: ${#files[@]} files from ${repo#https://github.com/}@${commit:0:12}"
