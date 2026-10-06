#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Dump every database in the cluster to local disk, and prove each dump arrived
# intact.
#
# WHY THIS EXISTS ALONGSIDE THE S3 BACKUPS
#
# platform/backup-verify/ and the CNPG `barmanObjectStore` config are the real,
# continuous, off-site backup. They need an S3 bucket and credentials.
#
# This script needs nothing but a kubeconfig. It is what you run:
#
#   - right now, before touching anything, because a migration without a backup
#     is a gamble
#   - before any upgrade on docs/roadmap.md
#   - before the house move
#
# It is a POINT-IN-TIME LOGICAL DUMP, not point-in-time recovery. It cannot
# restore to 14:32 yesterday. That is what WAL archiving is for. What it can do
# is survive the cluster being destroyed, which is the failure this is about.
#
# NOTHING HERE WRITES TO THE CLUSTER. Every command is a read, run inside the
# database pod, streamed to stdout.
#
# ---------------------------------------------------------------------------
# INTEGRITY: every dump is verified, not assumed.
#
# `kubectl exec` streams binary over a websocket. A truncated or mangled stream
# produces a file that looks plausible and restores to nothing, which is the
# classic silent backup failure. Three independent checks per Postgres dump,
# because each one misses something the others catch:
#
#   1. sha256 computed AT THE SOURCE and compared locally.
#      Catches corruption in transit. pg_dump's custom format has no internal
#      checksums, so nothing else will find a flipped byte -- measured: a 4-byte
#      overwrite mid-archive passes a full pg_restore parse silently.
#
#   2. `set -o pipefail` on the pg_dump pipeline.
#      Catches pg_dump itself failing. Without this, a dump that died early
#      produces a short stream whose checksum matches on BOTH sides -- the
#      checksum only proves the bytes travelled, not that they are a whole dump.
#
#   3. The archive magic (`PGDMP`) and a non-zero size, checked locally.
#      Catches a file that is actually an error message, and costs nothing.
#
# There is deliberately NO `pg_restore --list` round-trip back into the pod.
# It was tried and removed: `kubectl exec -i` with redirected stdin hangs
# intermittently -- it wedged for 15 minutes on the fifth of seven databases --
# and it adds nothing, because a pg_dump that exited 0 has by definition written
# a structurally valid archive, and the checksum proves the copy is identical.
# A verification step that can hang forever is worse than no verification step.
#
# On how the source-side checksum is taken without any disk: the pod has a
# read-only root filesystem, /controller sits on a node disk that is already 83%
# full, and the only large writable path is the live PGDATA volume -- writing a
# dump there could fill it and stop the database. So the dump is teed through a
# FIFO into sha256sum, which needs no storage, with the sum going to stderr and
# the dump to stdout. kubectl keeps those streams separate.
#
# `pg_restore --list` alone is NOT sufficient and was rejected on evidence: a
# file truncated by 10% still lists its full table of contents and exits 0,
# because the TOC lives at the start.
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

    # -Fc: custom format. Compressed, and pg_restore can inspect it, which is
    # what makes verification possible at all.
    #
    # The FIFO carries the same bytes to sha256sum that go to stdout, so the sum
    # describes the SOURCE data rather than being recomputed from whatever
    # arrived -- which would prove nothing. It occupies no disk.
    #
    # pipefail is why bash rather than sh: it makes the pipeline exit non-zero
    # when pg_dump fails, which is the only way to distinguish "a short dump"
    # from "a complete dump of a small database".
    #
    # SC2016: single quotes are required. Every `$` in this block belongs to the
    # shell INSIDE the pod -- `$$` must be that pod's pid for the fifo name to be
    # unique there, not this laptop's. Double quotes would expand all of it here
    # and send an already-substituted script over the wire.
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
# 2. MariaDB (Seafile). Not CloudNativePG, so no PITR and no generated
#    credentials -- the root password comes from the Secret `seafile-db`.
# ---------------------------------------------------------------------------
if kubectl -n seafile get deploy mariadb >/dev/null 2>&1; then
  f="$DEST/mariadb-seafile.sql.gz"

  # --single-transaction keeps InnoDB consistent without locking the tables, so
  # Seafile keeps working while this runs. --routines/--events/--triggers because
  # the default omits them and their absence only shows up at restore time.
  #
  # The password is read from the Secret, not from the pod's
  # MARIADB_ROOT_PASSWORD: a pod's environment is fixed when it starts, so after
  # a rotation the running pod still holds the old value. It travels through a
  # pipe into `read` in the pod and reaches mariadb-dump as MYSQL_PWD, so it is
  # never on an argv here or in the pod (visible to `ps` and /proc).
  # shellcheck disable=SC2016
  sha=$(kubectl -n seafile get secret seafile-db -o jsonpath='{.data.root-password}' 2>/dev/null \
        | base64 -d \
        | kubectl -n seafile exec -i deploy/mariadb -- \
          sh -c 'IFS= read -r MYSQL_PWD; export MYSQL_PWD; \
                 mariadb-dump -u root \
                   --single-transaction --routines --events --triggers \
                   --databases ccnet_db seafile_db seahub_db \
                 2>/tmp/m.err | gzip -c > /tmp/m.sql.gz \
                 && sha256sum /tmp/m.sql.gz | cut -d" " -f1' 2>/dev/null | tr -d '\r')

  if [ -n "$sha" ]; then
    kubectl -n seafile exec deploy/mariadb -- cat /tmp/m.sql.gz > "$f" 2>/dev/null
    kubectl -n seafile exec deploy/mariadb -- rm -f /tmp/m.sql.gz /tmp/m.err >/dev/null 2>&1

    if verify_sha "$f" "$sha"; then
      # mariadb-dump writes a completion marker as its last line. Its absence is
      # how you detect a dump that died halfway.
      if gzip -dc "$f" 2>/dev/null | tail -3 | grep -q 'Dump completed'; then
        tbl=$(gzip -dc "$f" 2>/dev/null | grep -c '^CREATE TABLE')
        printf '%-34s %-12s %-10s %s\n' "ok  sha+end-marker" \
          "$(du -h "$f" | cut -f1)" "$tbl" "$(basename "$f")" | tee -a "$MANIFEST"
        echo "    sha256  $sha" >> "$MANIFEST"
        pass "$(basename "$f")"
      else
        printf '%-34s %-12s %-10s %s\n' "FAIL (truncated dump)" \
          "$(du -h "$f" | cut -f1)" - "$(basename "$f")" | tee -a "$MANIFEST"
        fail "$(basename "$f")"
      fi
    else
      printf '%-34s %-12s %-10s %s\n' "FAIL (sha mismatch)" - - "$(basename "$f")" | tee -a "$MANIFEST"
      fail "$(basename "$f")"
    fi
  else
    printf '%-34s %-12s %-10s %s\n' "FAIL (mariadb-dump)" - - "$(basename "$f")" | tee -a "$MANIFEST"
    fail "$(basename "$f")"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Paperless SQLite
#
#    NOT a file copy. Copying a live SQLite file can capture a torn write.
#    The image has no `sqlite3` binary -- checked -- but it does have Python,
#    whose sqlite3.Connection.backup() is the online backup API: it cooperates
#    with the running writer instead of reading bytes from underneath it.
#
#    This resolves the open question in docs/backups.md about sqlite3 being
#    absent from the image.
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
