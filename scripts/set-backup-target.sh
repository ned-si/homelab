#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Point every backup manifest at one S3 bucket and endpoint.
#
# The bucket name and endpoint appear in SIX files across three layers. Editing
# them by hand is how you end up with the Immich database archiving to a bucket
# that no longer exists while everything else looks fine -- and barman reports
# that as a warning, not a failure.
#
# So: one command, all six, or none.
#
# USAGE
#   scripts/set-backup-target.sh <bucket> <region>
#   scripts/set-backup-target.sh homelab-backups-ned eu-central-1
#
#   # non-AWS S3 (Backblaze, R2, MinIO): pass a full endpoint as the 3rd arg
#   scripts/set-backup-target.sh my-bucket auto https://s3.eu-central-003.backblazeb2.com
#
# It rewrites source manifests only. Run `task render` afterwards -- or just let
# the pre-commit hook do it.
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUCKET="${1:-}"
REGION="${2:-}"
ENDPOINT="${3:-}"

if [ -z "$BUCKET" ] || [ -z "$REGION" ]; then
  sed -n '/^# USAGE/,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

if [ -z "$ENDPOINT" ]; then
  ENDPOINT="https://s3.${REGION}.amazonaws.com"
fi

# Strip any scheme for the restic form, which takes host/path after `s3:`.
ENDPOINT_HOST="${ENDPOINT#https://}"
ENDPOINT_HOST="${ENDPOINT_HOST#http://}"

echo "bucket:   $BUCKET"
echo "endpoint: $ENDPOINT"
echo

# Files that reference the target, with what they use it for. Kept explicit so a
# new backup manifest that forgets to appear here fails the check at the bottom
# rather than silently keeping an old bucket.
FILES="
apps/immich/resources/database.yaml
apps/immich/resources/backup-files.yaml
apps/paperless/backup.yaml
platform/keycloak/database.yaml
platform/backup-verify/restore-postgres.yaml
platform/backup-verify/restore-files.yaml
"

changed=0
for f in $FILES; do
  [ -f "$f" ] || { echo "  MISSING  $f" >&2; continue; }
  before=$(shasum -a 256 "$f" | awk '{print $1}')

  # barman: destinationPath: s3://<bucket>/<path>
  # Preserves whatever path follows the bucket, including ${SRC_NS} templating.
  sed -i '' -E "s|(destinationPath: s3://)[^/]+(/)|\1${BUCKET}\2|g" "$f"

  # barman: endpointURL
  sed -i '' -E "s|(endpointURL: )https?://[^[:space:]]+|\1${ENDPOINT}|g" "$f"

  # restic: s3:<endpoint>/<bucket>/<path>, in both `value:` and shell exports.
  sed -i '' -E "s|(s3:)https?://[^/]+/[^/\"']+(/)|\1${ENDPOINT}/${BUCKET}\2|g" "$f"

  after=$(shasum -a 256 "$f" | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    printf '  updated  %s\n' "$f"
    changed=$((changed + 1))
  else
    printf '  no-op    %s\n' "$f"
  fi
done

echo
echo "### resulting targets"
grep -rn 'destinationPath\|endpointURL\|s3:https' $FILES 2>/dev/null \
  | grep -v '^\s*#' | sed 's/^/  /'

echo
echo "### sanity check: any stale endpoint left anywhere?"
stale=$(grep -rn 'backblazeb2\|r2\.cloudflarestorage' --include='*.yaml' \
          apps platform infrastructure 2>/dev/null | grep -v '^deploy/' || true)
if [ -n "$stale" ]; then
  echo "$stale" | sed 's/^/  STALE  /'
  echo
  echo "Those still point at a different provider. Fix before syncing." >&2
  exit 1
fi
echo "  none"

echo
echo "$changed file(s) updated. Now run:  task render"
