#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check https://charts.nedsi.io against the latest ned-si/drum-charts release
# (.kiro/specs/drum-charts-site/requirements.md, acceptance criteria 2 and 3):
# the song pages linked from / are exactly the release's PDFs minus the
# legend, each song page and /legend/ has one page image per PDF page, every
# /pdf/<slug>.pdf has the SHA-256 of its release asset, and no MP3 of the
# release is served.
#
# A Renovate digest pull request not merged yet shows here as a difference:
# the site lags the release until it deploys.
#
# Needs gh, jq, curl, pdfinfo and shasum.
#
# USAGE
#   scripts/charts-check.sh      prints the release tag; exit 1 on the first
#                                difference, printed
# ---------------------------------------------------------------------------
set -euo pipefail

site=https://charts.nedsi.io
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

die() {
  echo "FAIL $*" >&2
  exit 1
}

release=$(gh release view --repo ned-si/drum-charts --json tagName,assets)
tag=$(jq -r .tagName <<<"$release")
echo "release $tag"

# <slug> <digest> per PDF, sorted.
jq -r '.assets[] | select(.name | endswith(".pdf")) | "\(.name | rtrimstr(".pdf")) \(.digest)"' \
  <<<"$release" | sort >"$tmp/pdfs"
[ -s "$tmp/pdfs" ] || die "$tag has no PDF"
grep -q '^legend ' "$tmp/pdfs" || die "$tag has no legend.pdf"

curl -fsS -m 10 "$site/" -o "$tmp/index.html" || die "$site/ does not answer 200"
# Song slugs follow drum-charts' <artist>-<title>, so /legend/ and /fr/ drop out.
grep -oE 'href="/[a-z0-9]+(-[a-z0-9]+)+/"' "$tmp/index.html" \
  | sed -E 's|href="/(.*)/"|\1|' | sort -u >"$tmp/linked"
grep -v '^legend ' "$tmp/pdfs" | cut -d' ' -f1 >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/linked" >"$tmp/diff"; then
  die "the song pages linked from $site/ are not the PDFs of $tag minus legend.pdf:
$(cat "$tmp/diff")"
fi

# check_chart <slug> <digest> <page path>
check_chart() {
  slug=$1 digest=$2 page=$3
  pdf="$tmp/$slug.pdf"
  curl -fsS -m 10 "$site/pdf/$slug.pdf" -o "$pdf" || die "$site/pdf/$slug.pdf does not answer 200"
  got="sha256:$(shasum -a 256 "$pdf" | cut -d' ' -f1)"
  [ "$got" = "$digest" ] || die "$site/pdf/$slug.pdf has $got, the asset of $tag $digest"
  pages=$(pdfinfo "$pdf" | sed -n 's/^Pages: *//p')
  [ -n "$pages" ] || die "$site/pdf/$slug.pdf: no page count"

  curl -fsS -m 10 "$site$page" -o "$tmp/page.html" || die "$site$page does not answer 200"
  grep -oE '<img [^>]*src="[^"]*"' "$tmp/page.html" | sed -E 's|.*src="([^"]*)"|\1|' >"$tmp/imgs"
  : >"$tmp/want-imgs"
  for i in $(seq 1 "$pages"); do
    echo "/pages/$slug-$i.svg" >>"$tmp/want-imgs"
  done
  if ! diff -u "$tmp/want-imgs" "$tmp/imgs" >"$tmp/diff"; then
    die "$site$page does not have one <img> per page of $slug.pdf ($pages):
$(cat "$tmp/diff")"
  fi
  while read -r src; do
    got=$(curl -s -m 10 -o /dev/null -w '%{http_code} %{content_type}' "$site$src") || got="000"
    [ "$got" = "200 image/svg+xml" ] || die "$site$src: got '$got', want '200 image/svg+xml'"
  done <"$tmp/imgs"
  echo "ok   $page ($pages pages)"
}

while read -r slug digest; do
  if [ "$slug" = legend ]; then
    check_chart legend "$digest" /legend/
  else
    check_chart "$slug" "$digest" "/$slug/"
  fi
done <"$tmp/pdfs"

jq -r '.assets[] | select(.name | endswith(".mp3")) | .name' <<<"$release" >"$tmp/mp3s"
while read -r mp3; do
  for path in "/pdf/$mp3" "/$mp3"; do
    got=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$site$path") || got="000"
    [ "$got" = 404 ] || die "$site$path: got $got, want 404"
  done
done <"$tmp/mp3s"
echo "ok   $(wc -l <"$tmp/mp3s" | tr -d ' ') MP3s answer 404"

echo "charts-check: $site matches $tag"
