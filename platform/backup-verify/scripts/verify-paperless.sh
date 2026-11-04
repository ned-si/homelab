#!/bin/sh
# Monthly Paperless restore test, run by CronJob backup-verify-paperless in the
# three containers of one pod, which share the scratch volume $WORK:
#
#   restore  init, restic image     the newest paperless-export snapshot (at
#                                   most MAX_AGE_HOURS old) into $WORK/restore,
#                                   with `restic restore --verify`
#   import   init, paperless image  `migrate` on an empty SQLite database, then
#                                   `document_importer --passphrase`, the counts
#                                   and one PDF; no web server, no Celery
#                                   worker or beat, only a throwaway Valkey
#                                   sidecar for the cache
#   report   restic image           PASS or FAIL, the push, the scratch files
#                                   deleted
#
# Pass when the documents imported = the documents in manifest.json = the count
# in export-meta.json (taken from the database copy the export came from), at
# least one, and one imported PDF opens. None of the three counts the
# documents in the trash, which the exporter writes too (measured on 3.4.2).
#
# restore and import never fail the pod on a check: they append `FAIL <reason>`
# to $WORK/result, so report always pushes the outcome. A crash before report
# (an OOM kill) fails the Job instead, which fires KubeJobFailed.
#
# Read-only on the backup: restic with --no-lock and the verifier key; the
# throwaway Paperless lives in $WORK and is deleted by report.
set -eu
set -f

# shellcheck source=platform/backup-verify/scripts/common.sh
. /scripts/common.sh

S3_BASE="s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups"
REPOSITORY="$S3_BASE/paperless/media"
TAG=paperless-export
MAX_AGE_HOURS="${MAX_AGE_HOURS:-72}"
WORK="${WORK:-/work}"
RESULT="$WORK/result"
EXPORT="$WORK/restore/export"

fail() {
  log "FAIL paperless-export: $*"
  echo "FAIL $*" >> "$RESULT"
}

step_restore() {
  rm -rf "${WORK:?}/restore" "$WORK/paperless" "$RESULT"
  mkdir -p "$WORK/restore"
  date -u +%s > "$WORK/start"
  export RESTIC_REPOSITORY="$REPOSITORY"
  log "=== restore: $RESTIC_REPOSITORY tag $TAG"
  if ! restic --no-lock snapshots --json --tag "$TAG" --latest 1 > "$WORK/snap.json" \
      || [ "$(jq length "$WORK/snap.json")" -eq 0 ]; then
    fail "no snapshot with tag $TAG, or the repository cannot be read"
    return 0
  fi
  snap_ts=$(snapshot_epoch "$WORK/snap.json")
  echo "METRIC backup_verify_snapshot_timestamp_seconds $snap_ts" >> "$RESULT"
  age_h=$(( ($(date -u +%s) - snap_ts) / 3600 ))
  log "newest snapshot: $(jq -r '[.[].time] | max' "$WORK/snap.json") (${age_h} h old)"
  if [ "$age_h" -gt "$MAX_AGE_HOURS" ]; then
    fail "newest snapshot is ${age_h} h old (max $MAX_AGE_HOURS h)"
    return 0
  fi
  if ! restic --no-lock restore latest --tag "$TAG" --target "$WORK/restore" --verify \
      > "$WORK/restore.log" 2>&1; then
    tail -20 "$WORK/restore.log"
    fail "restic restore failed"
    return 0
  fi
  tail -2 "$WORK/restore.log"
  if [ ! -s "$EXPORT/manifest.json" ] || [ ! -s "$EXPORT/export-meta.json" ]; then
    fail "the snapshot has no manifest.json or export-meta.json"
    return 0
  fi
  echo "OK restore" >> "$RESULT"
}

# Run in `manage.py shell` of the throwaway Paperless: the three counts and
# one PDF. Prints the lines for $RESULT.
CHECK='
import json, os, random
import pikepdf
from documents.models import Document

export = os.environ["EXPORT"]
# The exporter also writes the documents in the trash (deleted_at set) and
# the importer restores them; the default manager hides them, as in
# export-meta.json.
with open(os.path.join(export, "manifest.json")) as f:
    manifest = sum(1 for o in json.load(f)
                   if o.get("model") == "documents.document"
                   and not (o.get("fields") or {}).get("deleted_at"))
with open(os.path.join(export, "export-meta.json")) as f:
    meta = int(json.load(f)["documents"])
imported = Document.objects.count()
print(f"METRIC backup_verify_documents {imported}")
print(f"LOG documents: imported {imported}, manifest.json {manifest}, export-meta.json {meta}")
if hasattr(Document, "global_objects"):
    print(f"LOG documents in the trash: imported {Document.global_objects.count() - imported}")
if not imported == manifest == meta:
    print(f"FAIL document counts differ: imported {imported}, manifest.json {manifest}, export-meta.json {meta}")
if imported == 0:
    print("FAIL no document in the export")
pdfs = [d for d in Document.objects.all() if d.has_archive_version or d.mime_type == "application/pdf"]
if imported and not pdfs:
    print("FAIL no imported document has a PDF")
elif pdfs:
    doc = random.choice(pdfs)
    path = doc.archive_path if doc.has_archive_version else doc.source_path
    try:
        with pikepdf.open(path) as pdf:
            pages = len(pdf.pages)
        if pages < 1:
            print(f"FAIL document {doc.pk}: the PDF has no page")
        else:
            print(f"LOG document {doc.pk}: the PDF opens, {pages} page(s)")
    except Exception as e:
        print(f"FAIL document {doc.pk}: the PDF does not open: {type(e).__name__}")
print("OK import")
'

step_import() {
  if ! grep -q '^OK restore' "$RESULT" 2>/dev/null; then
    log "import: skipped, the restore did not finish"
    return 0
  fi
  if [ -z "${PASSPHRASE:-}" ]; then
    fail "the export passphrase is empty"
    return 0
  fi
  # The importer rebuilds the search index and expects its directory.
  mkdir -p "$PAPERLESS_DATA_DIR/index" "$PAPERLESS_MEDIA_ROOT" "$PAPERLESS_CONSUMPTION_DIR"
  # A throwaway key: the throwaway instance only needs one to load its settings.
  PAPERLESS_SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')
  export PAPERLESS_SECRET_KEY EXPORT
  cd /usr/src/paperless/src
  log "=== import: migrate"
  if ! python3 manage.py migrate --no-input -v 0 > "$WORK/migrate.log" 2>&1; then
    tail -20 "$WORK/migrate.log"
    fail "migrate on an empty database failed"
    return 0
  fi
  log "=== import: document_importer $EXPORT"
  if ! python3 manage.py document_importer --no-progress-bar \
      --passphrase "$PASSPHRASE" "$EXPORT" > "$WORK/import.log" 2>&1; then
    tail -20 "$WORK/import.log"
    fail "document_importer failed"
    return 0
  fi
  tail -5 "$WORK/import.log"
  if ! python3 manage.py shell -v 0 -c "$CHECK" > "$WORK/check.log" 2>&1; then
    tail -20 "$WORK/check.log"
    fail "the count and PDF check did not run"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      LOG\ *) log "${line#LOG }" ;;
      FAIL\ *) fail "${line#FAIL }" ;;
      METRIC\ *|OK\ *) echo "$line" >> "$RESULT" ;;
    esac
  done < "$WORK/check.log"
}

step_report() {
  start=$(cat "$WORK/start" 2>/dev/null || date -u +%s)
  ok=1
  if grep -q '^FAIL' "$RESULT" 2>/dev/null; then
    ok=0
  elif ! grep -q '^OK import' "$RESULT" 2>/dev/null; then
    log "FAIL paperless-export: the import step did not finish"
    ok=0
  fi
  metrics=$(sed -n 's/^METRIC //p' "$RESULT" 2>/dev/null || true)
  rm -rf "${WORK:?}/restore" "$WORK/paperless"
  if [ "$ok" -eq 1 ]; then
    log "PASS paperless-export: imported into a throwaway Paperless, counts match, a PDF opens"
  else
    grep '^FAIL' "$RESULT" 2>/dev/null | sed 's/^/  /' || true
    log "PAPERLESS RESTORE TEST FAILED"
  fi
  old_ifs=$IFS
  IFS='
'
  # shellcheck disable=SC2086 # one metric per line
  set -- $metrics
  IFS=$old_ifs
  push_result paperless-restore paperless-export "$ok" "$start" "$@" || return 1
  [ "$ok" -eq 1 ]
}

case "${1:-}" in
  restore) step_restore ;;
  import) step_import ;;
  report) step_report ;;
  *) echo "usage: $0 restore|import|report" >&2; exit 2 ;;
esac
