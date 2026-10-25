#!/bin/bash
# vendor-upstream.sh <dir> [--check] -- vendor upstream files, unchanged.
#
#   scripts/vendor-upstream.sh <dir>          download every file listed in
#                                             <dir>/SOURCE at its `commit:` and
#                                             rewrite the sha256 lines
#   scripts/vendor-upstream.sh <dir> --check  offline: every listed file exists
#                                             and matches its sha256, and no
#                                             other YAML file sits under <dir>
#                                             (controls.yaml aside)
#
# <dir>/SOURCE: `repo:` (a github.com URL), `commit:` (40 hex), optional
# `path:` (the upstream directory the file lines are relative to), then one
# `<sha256>  <file>` line per file; the local copy is <dir>/<file>. To add or
# drop a file, edit the list (any sha256 for a new line) and run the script.
# Renovate moves `commit:`; the renovate-render workflow runs this script for
# every vendored directory, so the files follow the commit in the same PR.
#
# Directories: policies/kyverno/upstream (scripts/kyverno-vendor.sh),
# platform/tetragon/policies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${1:-}" ] || { echo "usage: vendor-upstream.sh <dir> [--check]" >&2; exit 64; }
DIR="$ROOT/${1%/}"
NAME=${1%/}
SRC="$DIR/SOURCE"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

[ -f "$SRC" ] || { echo "vendor-upstream: $SRC missing" >&2; exit 1; }
repo=$(sed -n 's/^repo: *//p' "$SRC")
commit=$(sed -n 's/^commit: *//p' "$SRC")
upath=$(sed -n 's/^path: *//p' "$SRC")
[[ "$repo" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "vendor-upstream: $NAME: bad repo: $repo" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "vendor-upstream: $NAME: bad commit: $commit" >&2; exit 1; }
[[ -z "$upath" || ( "$upath" =~ ^[A-Za-z0-9_./-]+$ && "$upath" != *..* ) ]] || { echo "vendor-upstream: $NAME: bad path: $upath" >&2; exit 1; }
files=()
while read -r _ path; do
  [[ "$path" =~ ^[A-Za-z0-9_./-]+\.yaml$ && "$path" != *..* ]] || { echo "vendor-upstream: $NAME: bad file: $path" >&2; exit 1; }
  files+=("$path")
done < <(grep -E '^[0-9a-f]{64}  ' "$SRC")
[ "${#files[@]}" -gt 0 ] || { echo "vendor-upstream: no files in $SRC" >&2; exit 1; }

if [ "${2:-}" = "--check" ]; then
  rc=0
  while read -r want path; do
    f="$DIR/$path"
    if [ ! -f "$f" ]; then echo "vendor-upstream: $NAME: missing $path" >&2; rc=1; continue; fi
    [ "$(sha "$f")" = "$want" ] || { echo "vendor-upstream: $NAME/$path differs from upstream $commit (edit SOURCE and re-vendor, never the file)" >&2; rc=1; }
  done < <(grep -E '^[0-9a-f]{64}  ' "$SRC")
  while IFS= read -r f; do
    rel=${f#"$DIR"/}
    grep -qE "^[0-9a-f]{64}  ${rel//./\\.}\$" "$SRC" || { echo "vendor-upstream: $NAME/$rel is not listed in SOURCE" >&2; rc=1; }
  done < <(find "$DIR" -name '*.yaml' -type f ! -name controls.yaml | sort)
  [ "$rc" -eq 0 ] && echo "vendor-upstream: $NAME: ${#files[@]} files match ${repo#https://github.com/}@${commit:0:12}"
  exit "$rc"
fi

raw="https://raw.githubusercontent.com/${repo#https://github.com/}/$commit${upath:+/$upath}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sums="$tmp/sums"
: > "$sums"
for path in "${files[@]}"; do
  mkdir -p "$tmp/files/$(dirname "$path")"
  curl -fsSL --retry 3 -m 30 -o "$tmp/files/$path" "$raw/$path"
  printf '%s  %s\n' "$(sha "$tmp/files/$path")" "$path" >> "$sums"
done
# Replace the files only once every download succeeded; controls.yaml and
# SOURCE stay.
find "$DIR" -name '*.yaml' -type f ! -name controls.yaml -delete
find "$DIR" -mindepth 1 -type d -empty -delete
cp -R "$tmp/files/." "$DIR/"
{ grep -vE '^[0-9a-f]{64}  ' "$SRC"; cat "$sums"; } > "$tmp/SOURCE"
cp "$tmp/SOURCE" "$SRC"
echo "vendor-upstream: $NAME: ${#files[@]} files from ${repo#https://github.com/}@${commit:0:12}"
