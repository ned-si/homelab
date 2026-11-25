#!/bin/bash
# dashboard-screenshots.sh <out-dir> -- the screenshot step of the `dashboard`
# job (.kiro/specs/homelab-dashboard/design.md, "Screenshot check").
#
# Starts the web role on 127.0.0.1 with a throwaway key, pushes the fixture
# with internal/tools/pushfixture and renders the page with
# chrome-headless-shell into <out-dir>, one PNG per width: a phone (390), 4:3
# (1024), 16:10 (1440), 16:9 (1920, 2560), in the dark theme, then the same
# widths in the light theme (dashboard-light-<width>.png) from a static copy
# of the page with the light /theme.css: a browser keeps no Domain=nedsi.io
# cookie on 127.0.0.1. The layout depends on the width only (no
# viewport-height units), so each shot is taller than the page.
# Fails on a Chrome error, a missing PNG, a CSP violation or failed load in
# Chrome's log, a card off the column grid or a lone card stretched across
# its row (internal/tools/gridcheck), or a status other than 200 for the page
# or the stylesheet. No pixel diff: the PNGs are for looking at in the pull
# request.
#
# CHROME (default chrome-headless-shell) is the browser; needs go on PATH.
set -euo pipefail
out=${1:?usage: dashboard-screenshots.sh <out-dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
chrome=${CHROME:-chrome-headless-shell}
command -v "$chrome" >/dev/null || { echo "dashboard-screenshots: $chrome is not on PATH" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)/dashboard"

work=$(mktemp -d)
pid=
spid=
trap 'for p in $pid $spid; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"' EXIT

go build -o "$work/homelab-dashboard" ./cmd/homelab-dashboard
go build -o "$work/pushfixture" ./internal/tools/pushfixture
go build -o "$work/gridcheck" ./internal/tools/gridcheck
"$work/pushfixture" keygen "$work"
"$work/homelab-dashboard" web --listen 127.0.0.1:8080 --push-listen 127.0.0.1:9465 \
  --metrics-addr 127.0.0.1:9464 --public-keys "$work/public-keys" >"$work/web.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  curl -fs -m 2 -o /dev/null http://127.0.0.1:9464/healthz && break
  sleep 0.2
done
"$work/pushfixture" push "$work/private-key" http://127.0.0.1:9465
# The panels that span a row; any other card across a whole row is stretched.
wide=$(curl -fs -m 10 http://127.0.0.1:8080/ | grep -o 'class="panel stats"' | wc -l | tr -d ' ')

# The light copy: the page, its stylesheet and the light palette.
www=$work/www
mkdir -p "$www/assets"
curl -fs -m 10 -o "$www/index.html" http://127.0.0.1:8080/
css=$(grep -o '/assets/dashboard\.[0-9a-f]*\.css' "$www/index.html" | head -n 1)
curl -fs -m 10 -o "$www$css" "http://127.0.0.1:8080$css"
curl -fs -m 10 -o "$www/theme.css" -H 'Cookie: theme=light' http://127.0.0.1:8080/theme.css
python3 -m http.server --bind 127.0.0.1 --directory "$www" 8090 >"$work/http.log" 2>&1 &
spid=$!
for _ in $(seq 1 50); do
  curl -fs -m 2 -o /dev/null http://127.0.0.1:8090/theme.css && break
  sleep 0.2
done

rc=0
for shot in dark:http://127.0.0.1:8080/ light:http://127.0.0.1:8090/; do
theme=${shot%%:*} url=${shot#*:}
name=dashboard
[ "$theme" = light ] && name=dashboard-light
for size in 390x9000 1024x5000 1440x5000 1920x5000 2560x5000; do
  png="$out/$name-${size%%x*}.png"
  rm -f "$png"
  # --no-sandbox: the runner's AppArmor profile blocks Chrome's user
  # namespaces; the page is the local fixture.
  if ! "$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
      --enable-logging=stderr --v=0 --window-size="${size/x/,}" \
      --screenshot="$png" "$url" 2>"$work/chrome-$size.log"; then
    echo "dashboard-screenshots: FAIL Chrome exited non-zero at $size" >&2
    rc=1
  fi
  if [ ! -s "$png" ] || [ "$(head -c 8 "$png" | od -An -tx1 | tr -d ' \n')" != 89504e470d0a1a0a ]; then
    echo "dashboard-screenshots: FAIL no PNG at $size" >&2
    rc=1
  fi
  # Chrome words a CSP block "Refused to ..." or "... violates the following
  # Content Security Policy directive ...", depending on the version.
  if grep -E 'Refused to|Content Security Policy|Failed to load|net::ERR_' "$work/chrome-$size.log"; then
    echo "dashboard-screenshots: FAIL Chrome reported a blocked or failed load at $size" >&2
    rc=1
  fi
  if [ -s "$png" ] && ! "$work/gridcheck" --wide "$wide" "internal/web/assets/theme-$theme.css" "$png"; then
    echo "dashboard-screenshots: FAIL a card is off the column grid at $size ($theme)" >&2
    rc=1
  fi
done
done

# Every request for the page and the stylesheet answered 200, and both came.
requests=$(jq -c 'select(.msg == "request" and (.path == "/" or .path == "/theme.css" or (.path | startswith("/assets/"))))' "$work/web.log")
if jq -e 'select(.status != 200)' <<<"$requests" >/dev/null; then
  echo "dashboard-screenshots: FAIL a page or stylesheet request was not 200:" >&2
  jq -c 'select(.status != 200)' <<<"$requests" >&2
  rc=1
fi
for p in / /assets/ /theme.css; do
  if ! jq -e --arg p "$p" 'select(.path == $p or ($p != "/" and (.path | startswith($p))))' <<<"$requests" >/dev/null; then
    echo "dashboard-screenshots: FAIL Chrome never requested $p" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "dashboard-screenshots: dashboard-{,light-}{390,1024,1440,1920,2560}.png in $out"
exit "$rc"
