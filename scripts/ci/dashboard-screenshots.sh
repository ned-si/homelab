#!/bin/bash
# dashboard-screenshots.sh <out-dir> -- the screenshot step of the `dashboard`
# job (.kiro/specs/homelab-dashboard/design.md, "Screenshot check").
#
# Starts the web role on 127.0.0.1 with a throwaway key, pushes the fixture
# with internal/tools/pushfixture and renders the page with
# chrome-headless-shell into <out-dir>, one PNG per width: a phone (390), 4:3
# (1024), 16:10 (1440), 16:9 (1920, 2560). The layout depends on the width
# only (no viewport-height units), so each shot is taller than the page.
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
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT

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

rc=0
for size in 390x9000 1024x5000 1440x5000 1920x5000 2560x5000; do
  png="$out/dashboard-${size%%x*}.png"
  rm -f "$png"
  # --no-sandbox: the runner's AppArmor profile blocks Chrome's user
  # namespaces; the page is the local fixture.
  if ! "$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
      --enable-logging=stderr --v=0 --window-size="${size/x/,}" \
      --screenshot="$png" http://127.0.0.1:8080/ 2>"$work/chrome-$size.log"; then
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
  if [ -s "$png" ] && ! "$work/gridcheck" --wide "$wide" internal/web/assets/dashboard.css "$png"; then
    echo "dashboard-screenshots: FAIL a card is off the column grid at $size" >&2
    rc=1
  fi
done

# Every request for the page and the stylesheet answered 200, and both came.
requests=$(jq -c 'select(.msg == "request" and (.path == "/" or (.path | startswith("/assets/"))))' "$work/web.log")
if jq -e 'select(.status != 200)' <<<"$requests" >/dev/null; then
  echo "dashboard-screenshots: FAIL a page or stylesheet request was not 200:" >&2
  jq -c 'select(.status != 200)' <<<"$requests" >&2
  rc=1
fi
for p in / /assets/; do
  if ! jq -e --arg p "$p" 'select(.path == $p or ($p != "/" and (.path | startswith($p))))' <<<"$requests" >/dev/null; then
    echo "dashboard-screenshots: FAIL Chrome never requested $p" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "dashboard-screenshots: dashboard-{390,1024,1440,1920,2560}.png in $out"
exit "$rc"
