#!/usr/bin/env bash
# dast-zap.sh <hosts-file> <out-dir>
#
# Run one ZAP scan per hostname (one line each in <hosts-file>), one after the
# other, in the container $ZAP_IMAGE (digest-pinned in dast.yaml). Passive
# baseline by default; FULL_SCAN=true runs the active scan, which sends attack
# traffic.
#
# Per host, <out-dir>/<host>.json is ZAP's JSON report and <out-dir>/<host>.log
# everything ZAP printed. Nothing about findings goes to stdout: the logs of a
# public repository's workflows are public. scripts/zap_sarif.py turns the
# reports into SARIF and prints counts.
#
# .zap/rules.tsv is passed to ZAP as its rule configuration.
#
# Exit 0 when every scan produced a report, 1 when at least one did not (the
# other hosts are still scanned), 64 on usage errors.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <hosts-file> <out-dir>" >&2; exit 64; }
hosts=$1
out=$2
: "${ZAP_IMAGE:?ZAP_IMAGE must be set}"
FULL_SCAN=${FULL_SCAN:-false}

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$out"
# ZAP runs as its own non-root user in the container and writes into the mount.
chmod 777 "$out"
cp .zap/rules.tsv "$out/rules.tsv"

if [ "$FULL_SCAN" = "true" ]; then
  scan=(zap-full-scan.py -a -j)
else
  # -T 10: at most 10 minutes for ZAP to start and the passive scan to finish.
  scan=(zap-baseline.py -a -j -T 10)
fi

docker pull -q "$ZAP_IMAGE" >/dev/null

rc_all=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  # -I: warnings do not change the exit code. ZAP exits 0 (pass), 1 (FAIL rows
  # hit), 2 (warnings) or 3 (scan error); only a missing report or 3 is an
  # error here, the gate is in zap_sarif.py.
  set +e
  docker run --rm -v "$out:/zap/wrk:rw" "$ZAP_IMAGE" \
    "${scan[@]}" -I -t "https://$h" -c rules.tsv -J "$h.json" \
    >"$out/$h.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ge 3 ] || [ ! -s "$out/$h.json" ]; then
    echo "::warning::$h: scan did not complete (exit $rc)"
    rc_all=1
  else
    echo "$h: scanned"
  fi
done <"$hosts"

exit "$rc_all"
