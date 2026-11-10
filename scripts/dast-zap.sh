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
# .zap/rules.tsv, without its host-scoped rows, is passed to ZAP as its rule
# configuration.
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
# ZAP's -c file takes exactly <id>\t<action>\t<comment>: host-scoped rows
# (<id>@<host>) and the expiry column are for zap_sarif.py only.
grep -v -E '^[^#[:space:]]+@' .zap/rules.tsv | cut -f1-3 >"$out/rules.tsv"

if [ "$FULL_SCAN" = "true" ]; then
  scan=(zap-full-scan.py -a -j)
else
  # -T 20: at most 20 minutes for ZAP to start and the passive scan to finish
  # (10 was not enough for Mealie's crawl, run 42469742825).
  scan=(zap-baseline.py -a -j -T 20)
fi

docker pull -q "$ZAP_IMAGE" >/dev/null

rc_all=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  # -I: warnings do not change the exit code. ZAP exits 0 (pass), 1 (FAIL rows
  # hit), 2 (warnings) or 3 (scan error); only a missing report or 3 is an
  # error here, the gate is in zap_sarif.py.
  # One retry on a scan error (exit 3 or no report): a slow crawl or a
  # transient failure should not fail the whole run.
  set +e
  for attempt in 1 2; do
    docker run --rm -v "$out:/zap/wrk:rw" "$ZAP_IMAGE" \
      "${scan[@]}" -I -t "https://$h" -c rules.tsv -J "$h.json" \
      >"$out/$h.log" 2>&1
    rc=$?
    if [ "$rc" -lt 3 ] && [ -s "$out/$h.json" ]; then break; fi
    [ "$attempt" = 1 ] && echo "$h: scan error (exit $rc), retrying once"
  done
  set -e
  if [ "$rc" -ge 3 ] || [ ! -s "$out/$h.json" ]; then
    echo "::warning::$h: scan did not complete (exit $rc)"
    rc_all=1
  else
    echo "$h: scanned"
  fi
done <"$hosts"

exit "$rc_all"
