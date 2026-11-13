#!/bin/bash
# site.sh serve|build|strip -- the site:* tasks of the Taskfile.
#
# serve and build run the Hugo of HUGO_VERSION in .github/workflows/ci.yaml.
# On macOS the release's package is downloaded once, checked against
# HUGO_DARWIN_SHA256 and unpacked, not installed, under
# ~/Library/Caches/homelab-site/. Elsewhere the hugo on PATH must be that
# version. build runs scripts/ci/site-check.sh --all, which also needs
# htmltest and exiftool (`task tools`). strip removes all metadata from the
# images under site/.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

pin() { sed -n "s/^  $1: \"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" .github/workflows/ci.yaml; }

hugo_dir() {
  local v dir tmp
  v=$(pin HUGO_VERSION)
  [ -n "$v" ] || { echo "site.sh: HUGO_VERSION not found in ci.yaml" >&2; exit 1; }
  if [ "$(uname -s)" != Darwin ]; then
    hugo version | grep -q "v$v" || { echo "site.sh: hugo on PATH is not v$v" >&2; exit 1; }
    dirname "$(command -v hugo)"
    return
  fi
  dir="$HOME/Library/Caches/homelab-site/hugo-$v"
  if [ ! -x "$dir/hugo" ]; then
    tmp=$(mktemp -d)
    curl -fsSL --retry 3 -m 300 -o "$tmp/hugo.pkg" \
      "https://github.com/gohugoio/hugo/releases/download/v$v/hugo_extended_${v}_darwin-universal.pkg"
    if ! echo "$(pin HUGO_DARWIN_SHA256)  $tmp/hugo.pkg" | shasum -a 256 -c --quiet -; then
      rm -rf "$tmp"; echo "site.sh: sha256 mismatch for the Hugo $v package" >&2; exit 1
    fi
    pkgutil --expand-full "$tmp/hugo.pkg" "$tmp/x" >/dev/null
    mkdir -p "$dir"
    install -m 0755 "$tmp/x/Payload/hugo" "$dir/hugo"
    rm -rf "$tmp"
  fi
  echo "$dir"
}

case "${1:-}" in
  serve)
    PATH="$(hugo_dir):$PATH" exec hugo server --source site --buildDrafts --buildFuture ;;
  build)
    PATH="$(hugo_dir):$PATH" exec scripts/ci/site-check.sh --all ;;
  strip)
    exec exiftool -all= -overwrite_original -r -ext jpg -ext jpeg -ext png -ext webp -ext heic site ;;
  *)
    echo "usage: site.sh serve|build|strip" >&2; exit 64 ;;
esac
