#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Dump every database in the cluster to local disk, and prove each dump arrived
# intact. Needs only a kubeconfig; run it before a migration or an upgrade.
# A point-in-time logical dump, not PITR (that is WAL archiving). Read-only.
#
# Each Postgres dump is checked three ways:
#   1. sha256 taken at the source and compared locally: pg_dump's custom
#      format has no checksums, and a flipped byte passes pg_restore.
#   2. `set -o pipefail`: a pg_dump that died early still checksums equal.
#   3. the `PGDMP` magic and a non-zero size.
# No `pg_restore --list` round-trip: `kubectl exec -i` with stdin hangs, and a
# truncated file still lists its full TOC. The source sum goes through a FIFO,
# because the pod has no free disk.
# ---------------------------------------------------------------------------
#
# USAGE
#   scripts/dump-databases.sh                    -> ~/homelab-backups/<utc>/
#   BACKUP_DIR=/Volumes/ext scripts/dump-databases.sh
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
: "${KUBECONFIG:=$REPO/kubeconfig-homelab}"
export KUBECONFIG

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${BACKUP_DIR:-$HOME/homelab-backups}/$STAMP"

# Refuse to write inside the repo. A dump is plaintext data; it must not be one
# `git add -A` away from being committed.
case "$(cd "$(dirname "$DEST")" 2>/dev/null && pwd || echo "$DEST")" in
  "$REPO"|"$REPO"/*)
    echo "REFUSING: BACKUP_DIR is inside the repository ($DEST)." >&2
    echo "Database dumps are plaintext. Put them somewhere git cannot reach." >&2
    exit 1
    ;;
esac

mkdir -p "$DEST" || exit 1
chmod 700 "$DEST"

MANIFEST="$DEST/MANIFEST.txt"

# Results go to a file, not shell variables. The Postgres loop reads from a pipe,
# so it runs in a subshell and any counter incremented there is discarded when it
# exits -- which would make this script report success while producing nothing.
STATUS="$(mktemp)"
trap 'rm -f "$STATUS"' EXIT
pass() { echo "PASS $1" >> "$STATUS"; }
fail() { echo "FAIL $1" >> "$STATUS"; }

note() { printf '%s\n' "$*" | tee -a "$MANIFEST"; }

note "homelab database dump"
note "taken:      $STAMP (UTC)"
note "kubeconfig: $KUBECONFIG"
note "server:     $(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v1\.[0-9.]*\)".*/\1/p' | tail -1)"
note ""
note "Restore instructions: docs/backups.md"
note "Re-verify a dump:     shasum -a 256 <file>   and compare with this manifest"
note ""
printf '%-34s %-12s %-10s %s\n' STATUS SIZE TABLES FILE | tee -a "$MANIFEST"

# --- shared verification -----------------------------------------------------
# $1 file  $2 sha-from-pod  -> 0 if the local bytes match what the pod produced
verify_sha() {
  local f="$1" want="$2" got
  got=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$got" ]
}

# ---------------------------------------------------------------------------
# 1. PostgreSQL, via CloudNativePG
# ---------------------------------------------------------------------------
kubectl get clusters.postgresql.cnpg.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.currentPrimary}{"\n"}{end}' \
| while read -r ns cl pod; do
    [ -z "${pod:-}" ] && continue
    f="$DEST/pg-${ns}-${cl}.dump"

    # -Fc: custom format. The FIFO sends the same bytes to sha256sum, so the
    # sum describes the source. pipefail tells a short dump from a small one.
    # SC2016: every `$` belongs to the shell inside the pod (`$$` names its
    # FIFO there).
    # shellcheck disable=SC2016
    kubectl -n "$ns" exec "$pod" -c postgres -- bash -c '
      set -uo pipefail
      F=/controller/.dumpsum.$$
      mkfifo "$F" || { echo "MKFIFO_FAILED" >&2; exit 90; }
      sha256sum < "$F" >&2 &
      SP=$!
      pg_dump -U postgres -Fc -d app | tee "$F"
      RC=$?
      wait $SP
      rm -f "$F"
      exit $RC
    ' > "$f" 2>"$f.err"
    rc=$?

    sha=$(grep -oE '[0-9a-f]{64}' "$f.err" 2>/dev/null | head -1)

    if [ "$rc" -ne 0 ]; then
      printf '%-34s %-12s %-10s %s\n' "FAIL (pg_dump rc=$rc)" \
        "$(du -h "$f" 2>/dev/null | cut -f1)" - "$(basename "$f")" | tee -a "$MANIFEST"
      grep -v '[0-9a-f]\{64\}' "$f.err" | head -3 | sed 's/^/    /'
      fail "$(basename "$f")"; continue
    fi

    if [ -z "$sha" ] || ! verify_sha "$f" "$sha"; then
      printf '%-34s %-12s %-10s %s\n' "FAIL (sha mismatch)" \
        "$(du -h "$f" | cut -f1)" - "$(basename "$f")" | tee -a "$MANIFEST"
      fail "$(basename "$f")"; continue
    fi

    # Local, instant, cannot hang: a pg_dump custom archive always begins with
    # the five bytes "PGDMP".
    if [ "$(head -c 5 "$f")" != "PGDMP" ]; then
      printf '%-34s %-12s %-10s %s\n' "FAIL (not a pg_dump archive)" \
        "$(du -h "$f" | cut -f1)" - "$(basename "$f")" | tee -a "$MANIFEST"
      fail "$(basename "$f")"; continue
    fi

    # Recorded for the manifest so a future restore has something to compare
    # against. Read with psql, which needs no stdin.
    tbl=$(kubectl -n "$ns" exec "$pod" -c postgres -- psql -U postgres -d app -tAc \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" \
            2>/dev/null | tr -d '\r')

    rm -f "$f.err"
    printf '%-34s %-12s %-10s %s\n' "ok  sha+pipefail+magic" \
      "$(du -h "$f" | cut -f1)" "${tbl:-?}" "$(basename "$f")" | tee -a "$MANIFEST"
    echo "    sha256  $sha" >> "$MANIFEST"
    pass "$(basename "$f")"
  done

# ---------------------------------------------------------------------------
# 2. Paperless SQLite, through Python's sqlite3.Connection.backup() (the
#    image has no sqlite3 binary): an online backup, not a file copy.
# ---------------------------------------------------------------------------
if kubectl -n paperless get deploy paperless >/dev/null 2>&1; then
  f="$DEST/sqlite-paperless.db"

  sha=$(kubectl -n paperless exec deploy/paperless -- python3 -c '
import sqlite3, hashlib, sys
src = sqlite3.connect("file:/data/data/db.sqlite3?mode=ro", uri=True)
dst = sqlite3.connect("/tmp/pl.db")
src.backup(dst)          # online backup, consistent snapshot
dst.execute("PRAGMA journal_mode=DELETE")   # no stray -wal beside the copy
row = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close(); src.close()
if row != "ok":
    sys.stderr.write("integrity_check: %s\n" % row); sys.exit(1)
h = hashlib.sha256()
with open("/tmp/pl.db","rb") as fh:
    for b in iter(lambda: fh.read(1 << 20), b""):
        h.update(b)
print(h.hexdigest())
' 2>/dev/null | tr -d '\r')

  if [ -n "$sha" ]; then
    kubectl -n paperless exec deploy/paperless -- cat /tmp/pl.db > "$f" 2>/dev/null
    kubectl -n paperless exec deploy/paperless -- rm -f /tmp/pl.db >/dev/null 2>&1

    if verify_sha "$f" "$sha"; then
      # SQLite files start with a fixed 16-byte magic. Cheap proof it is a
      # database and not an error message that got redirected into the file.
      if head -c 15 "$f" | grep -q 'SQLite format 3'; then
        printf '%-34s %-12s %-10s %s\n' "ok  sha+integrity_check" \
          "$(du -h "$f" | cut -f1)" - "$(basename "$f")" | tee -a "$MANIFEST"
        echo "    sha256  $sha" >> "$MANIFEST"
        pass "$(basename "$f")"
      else
        printf '%-34s %-12s %-10s %s\n' "FAIL (not a SQLite file)" - - "$(basename "$f")" | tee -a "$MANIFEST"
        fail "$(basename "$f")"
      fi
    else
      printf '%-34s %-12s %-10s %s\n' "FAIL (sha mismatch)" - - "$(basename "$f")" | tee -a "$MANIFEST"
      fail "$(basename "$f")"
    fi
  else
    printf '%-34s %-12s %-10s %s\n' "FAIL (sqlite backup)" - - "$(basename "$f")" | tee -a "$MANIFEST"
    fail "$(basename "$f")"
  fi
fi

# `grep -c` prints 0 and exits 1 when there is no match, so a `|| echo 0`
# fallback appends a SECOND zero and the result is the two-line string "0\n0".
# That then fails `[ "$n_fail" -ne 0 ]` with "integer expression expected", which
# would have made the final exit-code check unreliable. No fallback needed.
n_pass=$(grep -c '^PASS' "$STATUS" 2>/dev/null)
n_fail=$(grep -c '^FAIL' "$STATUS" 2>/dev/null)

echo | tee -a "$MANIFEST"
echo "verified=$n_pass  failed=$n_fail" | tee -a "$MANIFEST"
echo "total: $(du -sh "$DEST" | cut -f1)" | tee -a "$MANIFEST"
echo "dumps written to: $DEST" | tee -a "$MANIFEST"
echo | tee -a "$MANIFEST"
cat <<'EOF' | tee -a "$MANIFEST"
WHAT THIS DOES NOT COVER
  - the media library (26TB NFS)      deliberate, see docs/backups.md
  - app config volumes (*/config)     restic CronJobs cover these once S3 exists
  - point-in-time recovery            needs WAL archiving; these are snapshots
  - off-site                          THIS IS ON ONE MACHINE. Copy it somewhere else.
EOF

if [ "$n_fail" -ne 0 ]; then
  echo >&2
  echo "$n_fail dump(s) FAILED verification. Do not treat this as a backup." >&2
  grep '^FAIL' "$STATUS" | sed 's/^/  /' >&2
  exit 1
fi

[ "$n_pass" -gt 0 ] || { echo "no databases were dumped -- is the cluster reachable?" >&2; exit 1; }
exit 0
