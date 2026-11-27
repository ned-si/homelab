#!/bin/bash
# site-check.sh [--all] -- the `site` job: build site/ and check the result
# (.kiro/specs/public-website/design.md, "The site job").
#
# The markup check also covers the landing page (apps/website/landing/),
# every page's translation or fallback stub (site/content/) and
# the dashboard's golden pages (dashboard/internal/web/testdata/); the
# copies of site/assets/css/layout.css (landing page, dashboard, tech radar)
# and of the palette, theme-*.css, must equal their source byte for byte.
# Both palettes pass the contrast check, and no other stylesheet holds a
# colour (.kiro/specs/site-theme-language/design.md#palette).
#
# Without --all it exits 0 when SITE_BASE..HEAD (default HEAD^1, main for a
# pull request's merge commit) touches neither site/, apps/website/, the
# dashboard's page (dashboard/internal/web/) nor these checks. SITE_OUT:
# build directory (default a temp dir, removed on exit).
# Writes built=true to $GITHUB_OUTPUT when the build succeeded.
# Needs hugo, htmltest, exiftool and python3 on PATH.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${SITE_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(site/|apps/website/|dashboard/internal/web/|drumcharts/|scripts/ci/(site[-_]|layout-check))' <<<"$changed"; then
    echo "site: nothing under site/, apps/website/, dashboard/internal/web/ or drumcharts/ changed; skipped"
    exit 0
  fi
fi

for t in hugo htmltest exiftool python3; do
  command -v "$t" >/dev/null || { echo "site-check: $t is not on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
out=${SITE_OUT:-$work/public}
case "$out" in /*) ;; *) out="$root/$out" ;; esac

rc=0
fail() { echo "site: FAIL $*" >&2; rc=1; }

echo "== hugo build"
if hugo --source site --destination "$out" --cleanDestinationDir --minify \
    --panicOnWarning --printPathWarnings --printI18nWarnings --gc; then
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "built=true" >> "$GITHUB_OUTPUT"; fi

  echo "== htmltest (internal links, anchors, images)"
  # htmltest writes its log under the working directory.
  (cd "$work" && htmltest -c "$root/site/.htmltest.yml" "$out") || fail "htmltest: broken internal link, anchor or image"

  echo "== markup"
  python3 scripts/ci/site_markup.py "$out" || fail "markup: see the lines above"
  python3 scripts/ci/site_markup.py apps/website/landing nedsi.io || fail "landing markup: see the lines above"
  python3 scripts/ci/site_markup.py --content site/content || fail "translations: see the lines above"
  # The dashboard's goldens are its rendered pages, so its nav is checked too,
  # each at its own URL: fr-* under /fr/, the not-found pages as 404.html.
  for g in dashboard/internal/web/testdata/*.golden.html; do
    name=$(basename "$g" .golden.html)
    d="$work/dashboard/$name"
    file=index.html
    case $name in *notfound) file=404.html ;; esac
    case $name in fr-*) file=fr/$file ;; esac
    mkdir -p "$(dirname "$d/$file")" && cp "$g" "$d/$file"
    python3 scripts/ci/site_markup.py "$d" homelab.nedsi.io || fail "dashboard markup ($name): see the lines above"
  done
else
  fail "hugo build (warnings fail it too)"
fi

echo "== shared layout copies"
for copy in apps/website/landing/layout.css dashboard/internal/web/assets/layout.css \
  techradar/internal/radar/assets/layout.css apps/website/techradar/layout.css \
  drumcharts/internal/site/assets/layout.css; do
  cmp -s site/assets/css/layout.css "$copy" || fail "$copy differs from site/assets/css/layout.css; run \`task site:layout-sync\`"
done

echo "== palette copies, contrast and colour literals"
palette_copies=(apps/website/landing dashboard/internal/web/assets techradar/internal/radar/assets apps/website/techradar
  drumcharts/internal/site/assets)
for theme in dark light; do
  for copy in "${palette_copies[@]}"; do
    cmp -s "site/assets/css/theme-$theme.css" "$copy/theme-$theme.css" \
      || fail "$copy/theme-$theme.css differs from site/assets/css/theme-$theme.css; run \`task site:layout-sync\`"
  done
done
python3 scripts/ci/site_contrast.py site/assets/css || fail "contrast: see the lines above"
python3 scripts/ci/site_markup.py --css site/assets/css/layout.css site/assets/css/main.css \
  site/assets/css/syntax.css apps/website/landing/landing.css \
  dashboard/internal/web/assets/dashboard.css techradar/internal/radar/assets/techradar.css \
  drumcharts/internal/site/assets/charts.css \
  || fail "colour literals: see the lines above"

echo "== drafts and future-dated pages"
# Unpublished pages live in draft pull requests, never on main.
for kind in drafts future; do
  pages=$(hugo list "$kind" --source site | tail -n +2)
  if [ -n "$pages" ]; then
    fail "$kind: publish or remove these pages (draft: false, a past date):"
    printf '%s\n' "$pages" | cut -d, -f1 >&2
  fi
done

echo "== image metadata"
images=(-ext jpg -ext jpeg -ext png -ext webp -ext heic)
# Exit status 2 means no file matched the condition. The $ names are
# exiftool's tags, not shell variables.
# shellcheck disable=SC2016
meta=$(exiftool -q -q -r "${images[@]}" -if '$EXIF:all or $XMP:all or $IPTC:all or $GPS:all' \
  -p '$Directory/$FileName' site) || [ $? -eq 2 ]
if [ -n "$meta" ]; then
  fail "image metadata (EXIF, XMP, IPTC or GPS); run \`task site:strip\`:"
  printf '%s\n' "$meta" >&2
fi
big=$(find site -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.heic' \) -size +1024k)
if [ -n "$big" ]; then
  echo "site: warning: images above 1 MiB (Hugo can resize them):"
  printf '%s\n' "$big"
fi

echo "== content"
files=$(git ls-files -co --exclude-standard site)
mails=$(printf '%s\n' "$files" | tr '\n' '\0' \
  | xargs -0 grep -nIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- \
  | grep -vE ':(nedsi@pm\.me|julien@nedsi\.io)$' || true)
if [ -n "$mails" ]; then
  fail "e-mail addresses other than nedsi@pm.me and julien@nedsi.io:"
  printf '%s\n' "$mails" | cut -d: -f1,2 >&2
fi
locals=$(git ls-files site | grep -E '\.local\.' || true)
if [ -n "$locals" ]; then
  fail "local-only files tracked under site/:"
  printf '%s\n' "$locals" >&2
fi

[ "$rc" -eq 0 ] && echo "site: all checks passed"
exit "$rc"
