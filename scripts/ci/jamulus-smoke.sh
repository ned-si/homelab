#!/bin/bash
# jamulus-smoke.sh <image> -- runs the Jamulus image as the cluster does
# (read-only root, non-root, no capabilities) and pings it with jamulus-ping
# and with the probe's --once (platform/jamulus-probe/exporter.py)
# (.kiro/specs/self-hosted-jamulus/design.md#publishing). Used by the
# `jamulus` job of ci.yaml and by jamulus-publish.yaml. Needs docker and
# python3.
set -euo pipefail
image=${1:?usage: jamulus-smoke.sh <image>}
root=$(git rev-parse --show-toplevel)
tag=$(sed -nE 's/^ARG JAMULUS_TAG=(r[0-9]+_[0-9]+_[0-9]+)$/\1/p' "$root/jamulus/Dockerfile")
[ -n "$tag" ] || { echo "jamulus-smoke: no JAMULUS_TAG in jamulus/Dockerfile" >&2; exit 1; }
version=$(echo "${tag#r}" | tr _ .)
rc=0
fail() {
  echo "jamulus-smoke: FAIL $*" >&2
  [ "$rc" -ne 0 ] || rc=1
}
out=$(docker run --rm "$image" --version 2>&1 || true)
grep -qF "$version" <<<"$out" || fail "--version prints '$out', want $version"
trap 'docker rm -f jamulus >/dev/null 2>&1 || true' EXIT
docker run -d --name jamulus --read-only --tmpfs /tmp --user 65532:65532 \
  --cap-drop ALL --security-opt no-new-privileges -p 127.0.0.1:41124:41124/udp \
  "$image" --server --nogui --port 41124 --numchannels 8 --fastupdate --discononquit >/dev/null
answered=false
for _ in $(seq 1 20); do
  if docker exec jamulus jamulus-ping; then answered=true; break; fi
  sleep 1
done
$answered || fail "jamulus-ping got no echo within 20 s"

if once=$(python3 "$root/platform/jamulus-probe/exporter.py" --once 127.0.0.1:41124); then
  grep -qF 'clients=0' <<<"$once" || fail "exporter.py --once prints '$once', want clients=0"
else
  fail "exporter.py --once prints '$once'"
fi
echo "== docker logs jamulus"
docker logs jamulus 2>&1
[ "$rc" -eq 0 ] && echo "jamulus-smoke: $image $version answers jamulus-ping and --once"
exit "$rc"
