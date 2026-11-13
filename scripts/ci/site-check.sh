#!/bin/bash
# site-check.sh [--all] -- the `site` job: build site/ and check the result
# (.kiro/specs/public-website/design.md, "The site job").
#
# Without --all it exits 0 when SITE_BASE..HEAD (default HEAD^1, main for a
# pull request's merge commit) touches neither site/, apps/website/ nor these
# checks. SITE_OUT: build directory (default a temp dir, removed on exit).
# Writes built=true to $GITHUB_OUTPUT when the build succeeded.
# Needs hugo, htmltest, exiftool and python3 on PATH.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${1:-}" != "--all" ]; then
  changed=$(git diff --name-only "${SITE_BASE:-HEAD^1}" HEAD)
  if ! grep -qE '^(site/|apps/website/|scripts/ci/site[-_])' <<<"$changed"; then
    echo "site: nothing under site/ or apps/website/ changed; skipped"
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
    --panicOnWarning --printPathWarnings --gc; then
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "built=true" >> "$GITHUB_OUTPUT"; fi

  echo "== htmltest (internal links, anchors, images)"
  # htmltest writes its log under the working directory.
  (cd "$work" && htmltest -c "$root/site/.htmltest.yml" "$out") || fail "htmltest: broken internal link, anchor or image"

  echo "== markup"
  python3 scripts/ci/site_markup.py "$out" || fail "markup: see the lines above"
else
  fail "hugo build (warnings fail it too)"
fi

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
  | grep -v ':nedsi@pm\.me$' || true)
if [ -n "$mails" ]; then
  fail "e-mail addresses other than nedsi@pm.me:"
  printf '%s\n' "$mails" | cut -d: -f1,2 >&2
fi
locals=$(git ls-files site | grep -E '\.local\.' || true)
if [ -n "$locals" ]; then
  fail "local-only files tracked under site/:"
  printf '%s\n' "$locals" >&2
fi

[ "$rc" -eq 0 ] && echo "site: all checks passed"
exit "$rc"
