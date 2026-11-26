#!/bin/bash
# site-serve-check.sh <public dir> -- serve the built blog, the landing page and
# the tech radar with apps/website/nginx.conf on the image's nginx, as the
# cluster mounts them, and check the host split, the 405, every redirect's
# Location (.kiro/specs/public-website/design.md#serving) and the theme
# stylesheet and endpoint (.kiro/specs/site-theme-language/requirements.md,
# Requirement 5.1).
# Needs docker and curl.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
public=${1:?usage: site-serve-check.sh <public dir>}

# The base image of site/Dockerfile, by digest: the same nginx as the cluster.
image=$(sed -n 's/^FROM //p' site/Dockerfile | head -n 1)
name=site-serve-check
html=$(mktemp -d)
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$html"' EXIT

cp -R "$public/." "$html/"
chmod -R a+rX "$html"

docker run -d --name "$name" --read-only --tmpfs /tmp \
  -v "$root/apps/website/nginx.conf:/etc/nginx-site/nginx.conf:ro" \
  -v "$root/apps/website/theme.conf:/etc/nginx-site/theme.conf:ro" \
  -v "$root/apps/website/landing:/usr/share/nginx/landing:ro" \
  -v "$root/apps/website/techradar:/usr/share/nginx/techradar:ro" \
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

# header <host> <path> <name> <want or -> [curl options...]: the response
# header <name> (lower case) equals <want>; - means absent.
header() {
  host=$1 path=$2 name=$3 want=$4
  shift 4
  got=$(curl -s -m 5 -o /dev/null -D - -H "Host: $host" "$@" "http://127.0.0.1:8080$path" \
    | tr -d '\r' | grep -i "^$name:" | sed 's/^[^:]*: //' || true)
  [ "$want" = - ] && want=""
  if [ "$got" = "$want" ]; then
    echo "ok   $host$path $name: ${want:-(none)}"
  else
    echo "FAIL $host$path $name: got '$got', want '${want:-(none)}'"
    rc=1
  fi
}
# body <host> <path> <text> [curl options...]: the body holds <text>.
body() {
  host=$1 path=$2 text=$3
  shift 3
  if curl -s -m 5 -H "Host: $host" "$@" "http://127.0.0.1:8080$path" | grep -F -- "$text" >/dev/null; then
    echo "ok   $host$path holds '$text'"
  else
    echo "FAIL $host$path: no '$text'"
    rc=1
  fi
}
light="theme=light; Domain=nedsi.io; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax"
dark="theme=; Domain=nedsi.io; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
# theme <host>: Requirement 5.1 on one host.
theme() {
  h=$1
  check 200 - 8080 "$h" /theme.css
  header "$h" /theme.css cache-control no-store
  header "$h" /theme.css vary Cookie
  header "$h" /theme.css set-cookie -
  body "$h" /theme.css 'color-scheme: dark'
  body "$h" /theme.css 'color-scheme: dark' -H 'Cookie: theme=dark'
  body "$h" /theme.css 'color-scheme: light' -H 'Cookie: theme=light'
  header "$h" /theme.css vary Cookie -H 'Cookie: theme=light'
  check 303 /about/ 8080 "$h" /set-theme/light/about/
  header "$h" /set-theme/light/about/ set-cookie "$light"
  header "$h" /set-theme/light/about/ cache-control no-store
  check 303 / 8080 "$h" /set-theme/light/
  header "$h" /set-theme/light/ set-cookie "$light" -H 'Sec-Fetch-Site: same-site'
  header "$h" /set-theme/light/ set-cookie "$light" -H 'Sec-Fetch-Site: none'
  check 303 / 8080 "$h" /set-theme/dark/
  header "$h" /set-theme/dark/ set-cookie "$dark"
  check 303 / 8080 "$h" /set-theme/light/ -H 'Sec-Fetch-Site: cross-site'
  header "$h" /set-theme/light/ set-cookie - -H 'Sec-Fetch-Site: cross-site'
  check 303 / 8080 "$h" /set-theme/light/ -H 'Sec-Purpose: prefetch'
  header "$h" /set-theme/light/ set-cookie - -H 'Sec-Purpose: prefetch'
  header "$h" /set-theme/dark/ set-cookie - -H 'Sec-Purpose: prefetch;prerender'
  for bad in /set-theme/blue/ /set-theme/light/%5cexample.com/ /set-theme/light/%0d%0aX:y /set-theme/light /set-theme/; do
    check 404 - 8080 "$h" "$bad"
    header "$h" "$bad" set-cookie -
  done
  # nginx merges the slashes: the same host, never //example.com/.
  check 303 /example.com/ 8080 "$h" /set-theme/light//example.com/
  for p in / /does-not-exist; do
    header "$h" "$p" set-cookie -
  done
}

for _ in $(seq 1 20); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:8080/ && break
  sleep 1
done

check 200 - 8080 blog.nedsi.io /
check 404 - 8080 blog.nedsi.io /does-not-exist
check 405 - 8080 blog.nedsi.io / -X POST
check 200 - 8080 nedsi.io /
check 200 - 8080 nedsi.io /layout.css
check 200 - 8080 nedsi.io /landing.css
check 405 - 8080 nedsi.io / -X POST
check 301 https://nedsi.io/a?b=1 8080 www.nedsi.io '/a?b=1'
check 301 https://nedsi.io/ 8081 nedsi.io /
check 301 https://nedsi.io/a?b=1 8081 www.nedsi.io '/a?b=1'
check 301 https://blog.nedsi.io/posts/ 8081 blog.nedsi.io /posts/
check 301 https://homelab.nedsi.io/x 8081 homelab.nedsi.io /x
check 405 - 8081 nedsi.io / -X POST
check 200 - 8080 techradar.nedsi.io /
check 200 - 8080 techradar.nedsi.io /techradar.css
check 404 - 8080 techradar.nedsi.io /does-not-exist
check 405 - 8080 techradar.nedsi.io / -X POST
check 301 https://techradar.nedsi.io/x 8081 techradar.nedsi.io /x
# The landing page links to the blog.
curl -s -m 5 -H 'Host: nedsi.io' http://127.0.0.1:8080/ | grep -q 'href="https://blog.nedsi.io/"' \
  || { echo "FAIL nedsi.io: no link to https://blog.nedsi.io/"; rc=1; }

theme blog.nedsi.io
theme nedsi.io
theme techradar.nedsi.io
check 404 - 8080 blog.nedsi.io /fr/does-not-exist
# Hugo minifies the blog: no quotes around attribute values.
body blog.nedsi.io /fr/does-not-exist '<html lang=fr-CH>'
body blog.nedsi.io /does-not-exist '<html lang=en-GB>'
# French under /fr/ (site-theme-language Requirement 5.1).
for p in /fr/ /fr/about/ /fr/privacy/; do
  check 200 - 8080 blog.nedsi.io "$p"
  header blog.nedsi.io "$p" cache-control "public, max-age=300"
  body blog.nedsi.io "$p" '<html lang=fr-CH>'
done
check 301 /fr/ 8080 blog.nedsi.io /fr
check 200 - 8080 blog.nedsi.io /fr/index.xml
body blog.nedsi.io /fr/index.xml '<language>fr-ch</language>'
body blog.nedsi.io /index.xml '<language>en-gb</language>'
check 200 - 8080 nedsi.io /fr/
header nedsi.io /fr/ cache-control "public, max-age=300"
body nedsi.io /fr/ 'lang="fr-CH"'
body nedsi.io / 'lang="en-GB"'
check 301 /fr/ 8080 nedsi.io /fr
check 404 - 8080 nedsi.io /index-fr.html
header blog.nedsi.io /about/ cache-control "public, max-age=300" -H 'Cookie: theme=light'
curl -s -m 5 -H 'Host: blog.nedsi.io' http://127.0.0.1:8080/robots.txt | grep -qx 'Disallow: /set-theme/' \
  || { echo "FAIL blog.nedsi.io/robots.txt: no Disallow: /set-theme/"; rc=1; }

# The old dashboard path goes to the dashboard's own host.
check 301 https://homelab.nedsi.io/ 8080 blog.nedsi.io /homelab
check 301 https://homelab.nedsi.io/ 8080 blog.nedsi.io /homelab/
check 301 https://homelab.nedsi.io/snapshot.json 8080 blog.nedsi.io /homelab/snapshot.json
check 404 - 8080 blog.nedsi.io /homelabx

[ "$rc" -eq 0 ] || docker logs "$name"
[ "$rc" -eq 0 ] && echo "site-serve-check: all checks passed"
exit "$rc"
