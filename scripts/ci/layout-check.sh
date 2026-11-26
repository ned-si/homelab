#!/bin/bash
# layout-check.sh <public dir> -- the layout step of the `site` job
# (.kiro/specs/public-website/design.md, "Shared layout").
#
# Measures the landing page, the blog home, its About and privacy pages, the
# newest article (when there is one), the dashboard's full fixture page and
# the tech radar (apps/website/techradar/) in
# chrome-headless-shell at 1920x1080 and 390x844: the left edge and width of
# body's content box, the box of `header.site > nav.site`, the x and width
# of each nav link and, on the pages in THEMED, the box of `header.site >
# .prefs` (the preferences, site-theme-language). Fails when a value differs
# by more than 1 px from the landing page's at the same viewport. The French
# landing page, blog home, About and privacy pages are compared with the
# French landing page, because the French link texts are longer. The pages
# get the dark palette as /theme.css; the light one holds the same layout,
# because the palettes hold colours only (scripts/ci/site_contrast.py).
# <public dir> is the blog built by site-check.sh.
#
# The pages are static copies, each with one added <script src="/measure.js">
# that writes the measurements into the DOM, served on 127.0.0.1 and never
# deployed. aria-current is removed from the copies, so every link is
# measured in normal weight.
#
# CHROME (default chrome-headless-shell) is the browser; needs go, curl and
# python3 on PATH.
set -euo pipefail
public=${1:?usage: layout-check.sh <public dir>}
public=$(cd "$public" && pwd)
chrome=${CHROME:-chrome-headless-shell}
for t in "$chrome" go curl python3; do
  command -v "$t" >/dev/null || { echo "layout-check: $t is not on PATH" >&2; exit 1; }
done
root=$(git rev-parse --show-toplevel)

work=$(mktemp -d)
pids=()
cleanup() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
www=$work/www
mkdir -p "$www/assets"

# The dashboard's full page, as in dashboard-screenshots.sh, on other ports.
(cd "$root/dashboard" && go build -o "$work/homelab-dashboard" ./cmd/homelab-dashboard \
  && go build -o "$work/pushfixture" ./internal/tools/pushfixture)
"$work/pushfixture" keygen "$work"
"$work/homelab-dashboard" web --listen 127.0.0.1:18080 --push-listen 127.0.0.1:19465 \
  --metrics-addr 127.0.0.1:19464 --public-keys "$work/public-keys" >"$work/web.log" 2>&1 &
pids+=($!)
disown "$!"
for _ in $(seq 1 50); do
  curl -fs -m 2 -o /dev/null http://127.0.0.1:19464/healthz && break
  sleep 0.2
done
# pushfixture reads its fixture relative to dashboard/.
(cd "$root/dashboard" && "$work/pushfixture" push "$work/private-key" http://127.0.0.1:19465)
curl -fs -m 10 -o "$work/dashboard.html" http://127.0.0.1:18080/
css=$(grep -o '/assets/dashboard\.[0-9a-f]*\.css' "$work/dashboard.html" | head -n 1)
[ -n "$css" ] || { echo "layout-check: no stylesheet link in the dashboard page" >&2; exit 1; }
curl -fs -m 10 -o "$www$css" "http://127.0.0.1:18080$css"

# The landing page's, the radar's and the blog's stylesheets sit at
# different paths, so one root serves every copy. The radar's /layout.css is
# the landing page's: site-check.sh holds both to the same bytes.
cp "$root/apps/website/landing/layout.css" "$root/apps/website/landing/landing.css" "$www/"
cp "$root/apps/website/techradar/techradar.css" "$www/"
cp -R "$public/css" "$www/css"
cp "$root/site/assets/css/theme-dark.css" "$www/theme.css"
pages=(landing blog about privacy dashboard techradar)
# The pages whose preferences match the landing page's. The dashboard gets
# the language toggle in site-theme-language task 5; until then its
# preferences are narrower.
themed="landing blog about privacy article techradar landing-fr blog-fr about-fr privacy-fr techradar-fr"
# One comparison per language; the first page of each is the reference.
fr_pages=(landing-fr blog-fr about-fr privacy-fr techradar-fr)
cp "$root/apps/website/techradar/index-fr.html" "$work/techradar-fr.html"
cp "$root/apps/website/landing/index-fr.html" "$work/landing-fr.html"
cp "$public/fr/index.html" "$work/blog-fr.html"
cp "$public/fr/about/index.html" "$work/about-fr.html"
cp "$public/fr/privacy/index.html" "$work/privacy-fr.html"
cp "$root/apps/website/landing/index.html" "$work/landing.html"
cp "$root/apps/website/techradar/index.html" "$work/techradar.html"
cp "$public/index.html" "$work/blog.html"
cp "$public/about/index.html" "$work/about.html"
cp "$public/privacy/index.html" "$work/privacy.html"
article=
if [ -d "$public/posts" ]; then
  article=$(find "$public/posts" -mindepth 2 -maxdepth 2 -name index.html | sort | tail -n 1)
fi
if [ -n "$article" ]; then
  cp "$article" "$work/article.html"
  pages+=(article)
else
  echo "layout-check: no article under posts/; measuring the other pages"
fi
groups="${pages[*]};${fr_pages[*]}"
pages+=("${fr_pages[@]}")

cat >"$www/measure.js" <<'EOF'
(function () {
  function px(v) { return parseFloat(v) || 0; }
  var b = document.body, cs = getComputedStyle(b), r = b.getBoundingClientRect();
  var out = {
    "body left": r.left + px(cs.borderLeftWidth) + px(cs.paddingLeft),
    "body width": r.width - px(cs.borderLeftWidth) - px(cs.paddingLeft) - px(cs.paddingRight) - px(cs.borderRightWidth)
  };
  var nav = document.querySelector("header.site > nav.site");
  if (nav) {
    var n = nav.getBoundingClientRect();
    out["nav x"] = n.x; out["nav y"] = n.y; out["nav width"] = n.width; out["nav height"] = n.height;
    nav.querySelectorAll("a").forEach(function (a) {
      var l = a.getBoundingClientRect(), t = a.textContent.trim();
      out[t + " x"] = l.x; out[t + " width"] = l.width;
    });
  }
  var prefs = document.querySelector("header.site > .prefs");
  if (prefs) {
    var q = prefs.getBoundingClientRect();
    out["prefs x"] = q.x; out["prefs y"] = q.y; out["prefs width"] = q.width; out["prefs height"] = q.height;
  }
  var pre = document.createElement("pre");
  pre.id = "layout-measure";
  pre.textContent = JSON.stringify(out);
  document.body.appendChild(pre);
})();
EOF
# A script after </html> still lands in <body>; the minified pages may have
# no end tags.
for p in "${pages[@]}"; do
  sed -E 's/ aria-current="?page"?//g' "$work/$p.html" >"$www/$p.html"
  echo '<script src="/measure.js"></script>' >>"$www/$p.html"
done

python3 -m http.server --bind 127.0.0.1 --directory "$www" 18081 >"$work/http.log" 2>&1 &
pids+=($!)
disown "$!"
for _ in $(seq 1 50); do
  curl -fs -m 2 -o /dev/null http://127.0.0.1:18081/measure.js && break
  sleep 0.2
done

for size in 1920x1080 390x844; do
  for p in "${pages[@]}"; do
    # --no-sandbox: the runner's AppArmor profile blocks Chrome's user
    # namespaces; the pages are local copies.
    "$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
      --window-size="${size/x/,}" --dump-dom "http://127.0.0.1:18081/$p.html" \
      >"$work/$size-$p.dom" 2>"$work/$size-$p.log" \
      || { echo "layout-check: Chrome failed on $p at $size" >&2; cat "$work/$size-$p.log" >&2; exit 1; }
  done
done

THEMED=$themed LAYOUT_GROUPS=$groups python3 - "$work" "${pages[@]}" <<'EOF'
import html
import json
import os
import re
import sys

work, pages = sys.argv[1], sys.argv[2:]
themed = set(os.environ["THEMED"].split())
groups = [g.split() for g in os.environ["LAYOUT_GROUPS"].split(";")]
failed = False
for size in ("1920x1080", "390x844"):
    got = {}
    for page in pages:
        dom = open(f"{work}/{size}-{page}.dom", encoding="utf-8").read()
        m = re.search(r'<pre id="layout-measure">(.*?)</pre>', dom, re.S)
        if not m:
            sys.exit(f"layout-check: no measurements for {page} at {size}")
        got[page] = json.loads(html.unescape(m.group(1)))
    for group in groups:
        ref = got[group[0]]
        print(f"== {size}, {group[0]} (px): " + ", ".join(f"{k} {v:.1f}" for k, v in ref.items()))
        for page in group[1:]:
            for key in sorted(set(ref) | set(got[page])):
                if key.startswith("prefs ") and page not in themed:
                    continue
                a, b = ref.get(key), got[page].get(key)
                if a is None or b is None or abs(a - b) > 1:
                    print(f"layout-check: FAIL {page} at {size}: {key} {b}, {group[0]} {a}")
                    failed = True
sys.exit(1 if failed else 0)
EOF
echo "layout-check: ${pages[*]} match at 1920x1080 and 390x844"
