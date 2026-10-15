#!/bin/bash
# test_postsync_smoke.sh -- the PostSync smoke-test hooks in deploy/
# (components/postsync-smoke): one per user-facing app, each URL aimed at a
# Service of that app, and the hook script's pass/fail logic against a fake
# curl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
cd "$REPO_ROOT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Services that come from a Helm chart, not from deploy/.
CHART_SERVICES="immich/immich-server"
EXPECTED="deploy/apps/books deploy/apps/home deploy/apps/immich/resources deploy/apps/mealie deploy/apps/paperless deploy/apps/seafile deploy/apps/syncthing deploy/apps/theater deploy/platform/keycloak"

echo "rendered hooks"
found=$(find deploy -name job-postsync-smoke.yaml -type f | sed 's|/job-postsync-smoke.yaml$||' | sort | tr '\n' ' ')
expect_eq "one hook per user-facing app" "$(tr ' ' '\n' <<<"$EXPECTED" | sort | tr '\n' ' ')" "$found"

for d in $EXPECTED; do
  f="$d/job-postsync-smoke.yaml"
  [ -f "$f" ] || continue
  ns=$(yq '.metadata.namespace' "$f")
  expect_eq "$d: PostSync hook" PostSync "$(yq '.metadata.annotations["argocd.argoproj.io/hook"]' "$f")"
  n=$(yq '.spec.template.spec.containers[0].args | length' "$f")
  if [ "$n" -gt 0 ]; then ok "$d: $n URL(s)"; else bad "$d: no URL"; fi
  for url in $(yq '.spec.template.spec.containers[0].args[]' "$f"); do
    host=${url#http://}
    host=${host%%/*}
    port=${host#*:}
    [ "$port" = "$host" ] && port=80
    host=${host%%:*}
    if [ -f "$d/service-$host.yaml" ]; then
      ports=" $(yq '.spec.ports[].port' "$d/service-$host.yaml" | tr '\n' ' ') "
      case "$ports" in
        *" $port "*) ok "$d: $url -> Service $ns/$host" ;;
        *) bad "$d: $url: Service $host has no port $port (ports:$ports)" ;;
      esac
    elif [[ " $CHART_SERVICES " == *" $ns/$host "* ]]; then
      ok "$d: $url -> chart Service $ns/$host"
    else
      bad "$d: $url: no Service $host in $d"
    fi
  done
done

echo "hook script"
script=$(yq '.spec.template.spec.containers[0].command[2]' components/postsync-smoke/job.yaml)
mkdir -p "$tmp/bin"
# Fake curl: answers with $tmp/codes/<host> (one code per line, consumed in
# order; the last one repeats), default 200. Code 000 = connection failure.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
url=${*: -1}
host=${url#http://}
host=${host%%/*}
f="$CODES/$host"
code=200
if [ -f "$f" ]; then
  code=$(head -n 1 "$f")
  [ "$(wc -l < "$f")" -gt 1 ] && sed -i.bak 1d "$f"
fi
printf '%s' "$code"
[ "$code" = 000 ] && exit 7
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"
export CODES="$tmp/codes"

run() { # run <urls...>: the hook script; prints output and rc
  local rc=0 out
  out=$(PATH="$tmp/bin:$PATH" sh -c "$script" postsync-smoke "$@" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
reset() { rm -rf "$CODES"; mkdir -p "$CODES"; }

reset
o=$(run http://a:1/ping http://b:2/health)
expect_contains "all 200: passes" "rc=0" "$o"
expect_contains "all 200: reports each URL" "ok   200 http://b:2/health" "$o"

reset
printf '302\n' > "$CODES/a:1"
o=$(run http://a:1/)
expect_contains "a redirect passes" "rc=0" "$o"

reset
printf '503\n' > "$CODES/b:2"
o=$(run http://a:1/ping http://b:2/health)
expect_contains "a 503 fails the hook" "rc=1" "$o"
expect_contains "the failing URL is named" "FAIL 503 http://b:2/health" "$o"
expect_contains "the other URL still passes" "ok   200 http://a:1/ping" "$o"

reset
printf '000\n' > "$CODES/a:1"
o=$(run http://a:1/ping)
expect_contains "no connection fails the hook" "FAIL 000 http://a:1/ping" "$o"

reset
printf '503\n000\n200\n' > "$CODES/a:1"
o=$(run http://a:1/ping)
expect_contains "a URL that recovers within the retries passes" "rc=0" "$o"

reset
printf '503\n503\n503\n503\n503\n503\n200\n' > "$CODES/a:1"
o=$(run http://a:1/ping)
expect_contains "six failed tries fail the hook" "rc=1" "$o"

finish
