#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check https://charts.nedsi.io against the current song release of each
# ned-si/drum-charts chart
# (.kiro/specs/drum-charts-per-song-releases/design.md#the-live-check): the
# song pages linked from / are exactly the songs in songs/ on main, and per
# chart (the songs and the legend) its page has one page image per PDF page
# and links its release, /pdf/<slug>.pdf has the SHA-256 of the release's
# asset, and the release's MP3 is not served. A chart's current release is
# its newest published <slug>-<yyyy-mm-dd>-<7 hex> release.
#
# A Renovate digest pull request not merged yet shows here as a difference:
# the site lags the releases until it deploys.
#
# Needs gh, jq, curl, pdfinfo and shasum.
#
# USAGE
#   scripts/charts-check.sh      one ok line per chart with its tag; exit 1
#                                on the first difference, printed
# ---------------------------------------------------------------------------
set -euo pipefail

site=https://charts.nedsi.io
repo=ned-si/drum-charts
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

die() {
  echo "FAIL $*" >&2
  exit 1
}

gh api "repos/$repo/contents/songs?ref=main" \
  --jq '.[] | select(.type == "file") | .name | select(endswith(".ly")) | rtrimstr(".ly")' \
  | sort >"$tmp/songs"
[ -s "$tmp/songs" ] || die "$repo has no songs/*.ly on main"
gh api --paginate --slurp "repos/$repo/releases" >"$tmp/releases.json"

curl -fsS -m 10 "$site/" -o "$tmp/index.html" || die "$site/ does not answer 200"
# Any link matching the slug rule is a song, except the legend and the language root.
{ grep -oE 'href="/[a-z0-9]+(-[a-z0-9]+)*/"' "$tmp/index.html" || true; } \
  | sed -E 's|href="/(.*)/"|\1|' | grep -vxE 'legend|fr' | sort -u >"$tmp/linked" || true
if ! diff -u "$tmp/songs" "$tmp/linked" >"$tmp/diff"; then
  die "the song pages linked from $site/ are not the songs of $repo:
$(cat "$tmp/diff")"
fi

# check_chart <slug> <page path>
check_chart() {
  slug=$1 page=$2
  # Slugs are [a-z0-9-], so the slug is safe inside the regex.
  release=$(jq -c --arg s "$slug" '
    [.[][] | select(.draft == false and (.tag_name | test("^" + $s + "-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7}$")))]
    | sort_by(.created_at) | last' "$tmp/releases.json")
  [ "$release" != null ] || die "$slug: no song release"
  tag=$(jq -r .tag_name <<<"$release")
  digest=$(jq -r --arg n "$slug.pdf" '[.assets[] | select(.name == $n) | .digest] | first // empty' <<<"$release")
  [ -n "$digest" ] || die "$tag has no $slug.pdf"

  pdf="$tmp/$slug.pdf"
  curl -fsS -m 10 "$site/pdf/$slug.pdf" -o "$pdf" || die "$site/pdf/$slug.pdf does not answer 200"
  got="sha256:$(shasum -a 256 "$pdf" | cut -d' ' -f1)"
  [ "$got" = "$digest" ] || die "$site/pdf/$slug.pdf has $got, the asset of $tag $digest"
  pages=$(pdfinfo "$pdf" 2>/dev/null | sed -n 's/^Pages: *//p' || true)
  [ -n "$pages" ] || die "$site/pdf/$slug.pdf: no page count"

  curl -fsS -m 10 "$site$page" -o "$tmp/page.html" || die "$site$page does not answer 200"
  { grep -oE '<img [^>]*src="[^"]*"' "$tmp/page.html" || true; } | sed -E 's|.*src="([^"]*)"|\1|' >"$tmp/imgs"
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
  grep -qF "href=\"https://github.com/$repo/releases/tag/$tag\"" "$tmp/page.html" \
    || die "$site$page does not link the release $tag"

  jq -r '.assets[] | select(.name | endswith(".mp3")) | .name' <<<"$release" >"$tmp/mp3s"
  while read -r mp3; do
    for path in "/pdf/$mp3" "/$mp3"; do
      got=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$site$path") || got="000"
      [ "$got" = 404 ] || die "$site$path: got $got, want 404"
    done
  done <"$tmp/mp3s"
  echo "ok   $page ($pages pages, $tag)"
}

check_chart legend /legend/
while read -r slug; do
  check_chart "$slug" "/$slug/"
done <"$tmp/songs"

echo "charts-check: $site matches the current release of each of $(($(wc -l <"$tmp/songs") + 1)) charts"
