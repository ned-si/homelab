#!/bin/bash
# site-serve-check.sh <public dir> -- serve the built blog and the landing page
# with apps/website/nginx.conf on the image's nginx, as the cluster mounts them,
# and check the host split, the 405, every redirect's Location and the
# dashboard's server-side include (.kiro/specs/public-website/design.md#serving).
# Needs docker, curl and python3.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
public=${1:?usage: site-serve-check.sh <public dir>}

# The base image of site/Dockerfile, by digest: the same nginx as the cluster.
image=$(sed -n 's/^FROM //p' site/Dockerfile | head -n 1)
name=site-serve-check
html=$(mktemp -d)
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$html"' EXIT

# A copy of the blog with the publisher's fragment under data/, where the
# Deployment mounts the website-data ConfigMap.
cp -R "$public/." "$html/"
mkdir -p "$html/data"
python3 - "$html/data/figures.html" <<'EOF'
import json, sys
sys.path.insert(0, "apps/website/publisher")
import publisher
with open("tests/website/figures.json") as f:
    doc = json.load(f)
with open(sys.argv[1], "w") as f:
    f.write(publisher.render(doc))
EOF
chmod -R a+rX "$html"

docker run -d --name "$name" --read-only --tmpfs /tmp \
  -v "$root/apps/website/nginx.conf:/etc/nginx-site/nginx.conf:ro" \
  -v "$root/apps/website/landing:/usr/share/nginx/landing:ro" \
  -v "$html:/usr/share/nginx/html:ro" \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8081:8081 \
  "$image" nginx -c /etc/nginx-site/nginx.conf -g 'daemon off;' >/dev/null

rc=0
# check <want code> <want Location or -> <port> <host> <path> [curl options...]
check() {
  want=$1 loc=$2 port=$3 host=$4 path=$5
  shift 5
  got=$(curl -s -m 5 -o /dev/null -w '%{http_code} %header{location}' -H "Host: $host" "$@" "http://127.0.0.1:$port$path") || got="000 "
  code=${got%% *} where=${got#* }
  [ "$loc" = - ] && loc=""
  if [ "$code" = "$want" ] && [ "$where" = "$loc" ]; then
    echo "ok   $code $host:$port$path ${loc:+-> $loc}"
  else
    echo "FAIL $host:$port$path: got $code '$where', want $want '$loc'"
    rc=1
  fi
}

for _ in $(seq 1 20); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:8080/ && break
  sleep 1
done

check 200 - 8080 blog.nedsi.io /
check 404 - 8080 blog.nedsi.io /does-not-exist
check 405 - 8080 blog.nedsi.io / -X POST
check 200 - 8080 nedsi.io /
check 200 - 8080 nedsi.io /landing.css
check 405 - 8080 nedsi.io / -X POST
check 301 https://nedsi.io/a?b=1 8080 www.nedsi.io '/a?b=1'
check 301 https://nedsi.io/ 8081 nedsi.io /
check 301 https://nedsi.io/a?b=1 8081 www.nedsi.io '/a?b=1'
check 301 https://blog.nedsi.io/posts/ 8081 blog.nedsi.io /posts/
check 405 - 8081 nedsi.io / -X POST
# The landing page links to the blog.
curl -s -m 5 -H 'Host: nedsi.io' http://127.0.0.1:8080/ | grep -q 'href="https://blog.nedsi.io/"' \
  || { echo "FAIL nedsi.io: no link to https://blog.nedsi.io/"; rc=1; }

# The dashboard: nginx includes the figures, and the stub while they are empty.
# page <want text>: /homelab/ has it and no SSI directive left over.
page() {
  body=$(curl -s -m 5 -H 'Host: blog.nedsi.io' http://127.0.0.1:8080/homelab/) || body=""
  if grep -qF -- '<!--#' <<<"$body"; then echo "FAIL /homelab/: an SSI directive is left in the page"; rc=1; fi
  if grep -qF -- "$1" <<<"$body"; then echo "ok   /homelab/ has '$1'"; else echo "FAIL /homelab/: no '$1'"; rc=1; fi
}
check 200 - 8080 blog.nedsi.io /homelab/
page 'id="availability"'
: > "$html/data/figures.html"
page 'No figures yet'

[ "$rc" -eq 0 ] || docker logs "$name"
[ "$rc" -eq 0 ] && echo "site-serve-check: all checks passed"
exit "$rc"
