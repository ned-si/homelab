#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Point every backup manifest at one S3 bucket and endpoint.
#
# The bucket name and endpoint appear in ELEVEN files across three layers.
# Editing them by hand is how you end up with the Immich database archiving to a
# bucket that no longer exists while everything else looks fine -- and barman
# reports that as a warning, not a failure.
#
# So: one command, all eleven, or none.
#
# ---------------------------------------------------------------------------
# TWO DEFECTS FIXED IN THIS SCRIPT, BOTH OF WHICH MADE IT LIE
#
#  1. `sed -i ''` IS BSD SYNTAX AND DOES NOT WORK ON LINUX.
#
#     GNU sed treats `-i` as taking an OPTIONAL suffix attached to the flag, so
#     `-i ''` is parsed as `-i` (no suffix) followed by `''` -- an empty
#     FILENAME. GNU sed then reports `can't read : No such file or directory`,
#     exits non-zero, and edits nothing. Because the loop below compares
#     checksums rather than checking sed's status, every file would have been
#     reported `no-op` and the script would have exited 0 having changed
#     nothing. On CI, or on the owner's Linux box, "one command, all eleven"
#     would silently have been "zero".
#
#     scripts/age-key.sh:52-55 already had the portable answer -- write to a
#     temp file and move it into place -- with the comment "BSD and GNU sed
#     disagree about -i". That is the pattern used here. It also gives a real
#     exit status to check.
#
#     (The claim that this appears at lines 189/211/214 of age-key.sh is wrong:
#     that file is 84 lines long. The pattern is at 52-55.)
#
#  2. THE FINAL "SANITY CHECK" DID NOT CHECK WHAT IT CLAIMED TO.
#
#     Its stated purpose, in the comment above the FILES list, was that "a new
#     backup manifest that forgets to appear here fails the check at the
#     bottom". It grepped for `backblazeb2` and `r2.cloudflarestorage` -- two
#     literal strings for providers this repo does not use. So:
#
#       - a manifest carrying the OLD BUCKET NAME passed silently
#       - a manifest carrying `homelab-backups-REPLACE-ME` passed silently
#       - a brand-new backup manifest missing from FILES passed silently
#
#     which is precisely the failure it was written to prevent, and the one
#     that matters: apps/theater/backup.yaml, apps/seafile/backup.yaml,
#     apps/syncthing/backup.yaml, apps/mealie/backup.yaml and
#     platform/kube-prometheus-stack/routes/grafana-backup.yaml are all new,
#     and every one of them would have kept pointing at REPLACE-ME while this
#     script reported success.
#
#     The check now DISCOVERS every manifest carrying a bucket, repository or
#     endpoint reference and fails if any of them is either absent from FILES or
#     still pointing somewhere other than the requested target. FILES remains
#     the list of files to REWRITE; discovery is what makes the list honest.
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

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

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

# Where the target must be REWRITTEN.
#
# This is no longer the only guard against omissions -- the discovery check at
# the bottom is -- but it is still the list, and keeping it accurate keeps the
# discovery check quiet.
#
#   barman `destinationPath` + `endpointURL`
#     apps/immich/resources/database.yaml            immich-db
#     platform/keycloak/database.yaml                keycloak-db
#     platform/backup-verify/restore-postgres.yaml   the throwaway recovery
#                                                    cluster's externalClusters
#
#   restic `RESTIC_REPOSITORY`
#     apps/immich/resources/backup-files.yaml        immich/library (S3 job only;
#                                                    the local job's repository
#                                                    is a filesystem path and is
#                                                    deliberately untouched)
#     apps/paperless/backup.yaml                     paperless/media
#     apps/theater/backup.yaml                       theater/configs  (x7 jobs)
#     apps/seafile/backup.yaml                       seafile/shared
#     apps/syncthing/backup.yaml                     syncthing/data
#     apps/mealie/backup.yaml                        mealie/data
#     platform/kube-prometheus-stack/routes/grafana-backup.yaml
#                                                    grafana/data
#     platform/backup-verify/restore-files.yaml      the verifier's repository
#                                                    prefix
FILES="
apps/immich/resources/database.yaml
apps/immich/resources/backup-files.yaml
apps/paperless/backup.yaml
apps/theater/backup.yaml
apps/seafile/backup.yaml
apps/syncthing/backup.yaml
apps/mealie/backup.yaml
platform/keycloak/database.yaml
platform/kube-prometheus-stack/routes/grafana-backup.yaml
platform/backup-verify/restore-postgres.yaml
platform/backup-verify/restore-files.yaml
"

# Portable in-place edit. See defect 1 in the header: `sed -i ''` is BSD-only
# and on GNU sed consumes `''` as a filename, edits nothing and exits non-zero.
#
# Writing through a temp file works identically on both, and -- unlike the
# checksum comparison this script relies on to report progress -- it gives a
# status that distinguishes "sed failed" from "there was nothing to change".
#
#   $1 file, then one or more `-E`-style expressions
sed_inplace() {
  local f="$1"; shift
  local tmp
  tmp="$(mktemp)" || return 1
  if sed -E "$@" "$f" >"$tmp"; then
    mv "$tmp" "$f"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

changed=0
sed_failed=0
for f in $FILES; do
  # Reported again, and counted, by check C at the bottom.
  [ -f "$f" ] || { echo "  MISSING  $f" >&2; continue; }
  before=$(shasum -a 256 "$f" | awk '{print $1}')

  # All three substitutions in ONE pass. Three separate passes meant three
  # temp-file round trips and, more importantly, three chances for one of them
  # to fail while the others succeeded -- leaving a file with the new bucket and
  # the old endpoint, which is the hardest state to debug because both halves
  # look plausible.
  #
  #   1. barman: destinationPath: s3://<bucket>/<path>
  #      Preserves whatever path follows the bucket, including the ${SRC_NS}
  #      templating in restore-postgres.yaml.
  #   2. barman: endpointURL
  #   3. restic: s3:<endpoint>/<bucket>/<path>, in both `value:` fields and
  #      shell `export` lines.
  if ! sed_inplace "$f" \
      -e "s|(destinationPath: s3://)[^/]+(/)|\1${BUCKET}\2|g" \
      -e "s|(endpointURL: )https?://[^[:space:]]+|\1${ENDPOINT}|g" \
      -e "s|(s3:)https?://[^/]+/[^/\"']+(/)|\1${ENDPOINT}/${BUCKET}\2|g"; then
    printf '  FAILED   %s  (sed error -- file left unmodified)\n' "$f" >&2
    sed_failed=$((sed_failed + 1))
    continue
  fi

  after=$(shasum -a 256 "$f" | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    printf '  updated  %s\n' "$f"
    changed=$((changed + 1))
  else
    printf '  no-op    %s\n' "$f"
  fi
done

if [ "$sed_failed" -ne 0 ]; then
  echo >&2
  echo "$sed_failed file(s) could not be rewritten. Refusing to continue: a" >&2
  echo "partially repointed set of backup manifests is worse than none, because" >&2
  echo "the ones that did change look correct." >&2
  exit 1
fi

echo
echo "### resulting targets"
# SC2086: $FILES is a whitespace-separated list of paths and MUST word-split here
# -- quoting it would pass the whole list to grep as one filename. None of the
# paths in this repository contain spaces, and render-deploy.sh would fail on one
# that did long before this line ran.
# shellcheck disable=SC2086
grep -rn 'destinationPath\|endpointURL\|s3:https' $FILES 2>/dev/null \
  | grep -v '^\s*#' | sed 's/^/  /'

# ---------------------------------------------------------------------------
# THE CHECK THAT ACTUALLY CHECKS.
#
# See defect 2 in the header. This replaces a grep for two hardcoded provider
# hostnames with an enumeration of every source manifest that carries a bucket,
# repository or endpoint reference, and then asserts two things about each:
#
#   A. it is in $FILES, so it was rewritten -- a new backup manifest that
#      forgets to appear in the list now FAILS, which is what the comment above
#      the list always claimed;
#   B. every reference in it names THIS bucket and THIS endpoint -- so an old
#      bucket name, a leftover REPLACE-ME, or a second provider's endpoint fails
#      regardless of which provider it belongs to.
#
# `deploy/` is excluded because it is generated: `task render` regenerates it
# from these sources, and checking it here would report the same problem twice
# and then again after the render.
#
# Deliberately NOT `--include='*.yaml'` alone: `*.sops.yaml` files are encrypted
# and cannot be inspected, so their ciphertext can never match these patterns.
# That is fine and worth stating, because it means this check cannot see a stale
# endpoint inside a sealed Secret. The one field that matters there is
# `AWS_DEFAULT_REGION`, and it is warned about separately below.
# ---------------------------------------------------------------------------
echo
echo "### discovery check: every manifest that names a bucket or repository"

# THREE patterns, not one, and the distinction is load-bearing.
#
#   DISCOVER_RE  what makes a file a CANDIDATE. Deliberately broad -- it
#                includes the bare word RESTIC_REPOSITORY -- because a detector
#                that misses a file is useless while one that over-matches
#                merely names an extra file that then passes.
#
#   TARGET_RE    lines that MUST contain the bucket. Narrower on purpose:
#                apps/immich/resources/backup-files.yaml sets
#                `RESTIC_REPOSITORY: /backups/immich/library` for the LOCAL
#                NFS job -- a filesystem path with no bucket and no endpoint,
#                deliberately so, because a local job has no business holding S3
#                credentials. Checking that line against the bucket would fail
#                on a file that is correct. platform/backup-verify/
#                restore-files.yaml has the same shape in an `echo` that prints
#                the variable.
#
#   ENDPOINT_RE  lines that MUST contain the endpoint host. Same reasoning.
DISCOVER_RE='destinationPath:[[:space:]]*s3://|endpointURL:[[:space:]]*http|RESTIC_REPOSITORY|s3:https?://'
TARGET_RE='destinationPath:[[:space:]]*s3://|s3:https?://'
ENDPOINT_RE='endpointURL:[[:space:]]*http|s3:https?://'

discovered=$(grep -rlE "$DISCOVER_RE" --include='*.yaml' \
               apps platform infrastructure clusters 2>/dev/null \
             | grep -v '\.sops\.yaml$' \
             | grep -v '\.example$' \
             | sort -u)

problems=0
real=""

for f in $discovered; do
  # --- 0. STRIP COMMENTS FIRST, AND DO IT BEFORE THE MEMBERSHIP TEST. ------
  #
  # This repo documents itself heavily and prose about backups is everywhere. In
  # particular infrastructure/network-policies/*.yaml cite the exact
  # `RESTIC_REPOSITORY s3:https://...` values in comments explaining which
  # egress rule exists for which backup job -- entirely correctly, and they
  # contain no configuration at all.
  #
  # A first version of this check stripped comments only for the per-line bucket
  # test and matched whole FILES on raw content, so it reported six
  # network-policy files as UNACCOUNTED and exited 1. A check that fails on
  # correct files gets an `|| true` added to it within a week, which would put
  # this script straight back to not checking anything.
  stripped=$(sed 's/[[:space:]]*#.*$//' "$f")

  printf '%s\n' "$stripped" | grep -qE "$DISCOVER_RE" || continue
  real="$real $f"

  # --- A. is it in the rewrite list? ---------------------------------------
  in_list=0
  for g in $FILES; do
    [ "$f" = "$g" ] && { in_list=1; break; }
  done

  if [ "$in_list" -eq 0 ]; then
    printf '  UNACCOUNTED  %s\n' "$f" >&2
    printf '               names a bucket/repository but is not in FILES, so it\n' >&2
    printf '               was NOT rewritten and still points somewhere else.\n' >&2
    problems=$((problems + 1))
    continue
  fi

  # --- B. does every reference in it name the requested target? -----------
  #
  # Comments are stripped first. Several of these files discuss buckets and
  # endpoints in prose (restore examples, provider comparisons), and a comment
  # mentioning a different provider is documentation, not a misconfiguration.
  #
  # The `-F` matches are literal: a bucket name can contain regex metacharacters
  # such as `.`, which is legal in an S3 bucket name and would otherwise make
  # this check match things it should not.
  bad=$(printf '%s\n' "$stripped" \
        | grep -nE "$TARGET_RE" \
        | grep -v -F -e "$BUCKET" \
        || true)
  if [ -n "$bad" ]; then
    printf '  WRONG BUCKET %s\n' "$f" >&2
    printf '%s\n' "$bad" | sed 's/^/               /' >&2
    problems=$((problems + 1))
    continue
  fi

  bad_ep=$(printf '%s\n' "$stripped" \
           | grep -nE "$ENDPOINT_RE" \
           | grep -v -F -e "$ENDPOINT_HOST" \
           || true)
  if [ -n "$bad_ep" ]; then
    printf '  WRONG ENDPOINT %s\n' "$f" >&2
    printf '%s\n' "$bad_ep" | sed 's/^/               /' >&2
    problems=$((problems + 1))
    continue
  fi

  printf '  ok           %s\n' "$f"
done

# --- C. is anything in $FILES no longer a target? --------------------------
# A stale list entry is not dangerous, but it is how the list stops describing
# reality -- and this script's whole value is that the list is trustworthy.
for g in $FILES; do
  if [ ! -f "$g" ]; then
    printf '  MISSING      %s  (in FILES, does not exist -- delete the line)\n' "$g" >&2
    problems=$((problems + 1))
    continue
  fi
  # `$real`, not `$discovered`: a file whose only mentions were in comments is
  # not a target and must not make its FILES entry look live.
  found=0
  for f in $real; do
    [ "$f" = "$g" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] || \
    printf '  STALE LIST   %s  (in FILES, names no bucket -- delete the line)\n' "$g"
done

if [ "$problems" -ne 0 ]; then
  echo >&2
  echo "$problems problem(s). The backup target is NOT consistently set." >&2
  echo >&2
  echo "This is the check the old version of this script claimed to do and did" >&2
  echo "not: it grepped for two hardcoded provider hostnames, so a forgotten" >&2
  echo "file carrying the old bucket -- or 'homelab-backups-REPLACE-ME' --" >&2
  echo "passed silently." >&2
  exit 1
fi
echo "  all clear"

# ---------------------------------------------------------------------------
# One thing this script cannot fix, stated rather than left to be discovered.
# ---------------------------------------------------------------------------
echo
echo "### manual follow-ups this script cannot do"
echo "  - AWS_DEFAULT_REGION in platform/secrets/s3-backup.sops.yaml is SEALED"
echo "    and cannot be rewritten here. restic derives its request signing"
echo "    region from it, so if the new bucket is not in the region already in"
echo "    that Secret, every restic operation fails with a SignatureDoesNotMatch"
echo "    that reads like a bad credential. Re-seal it if the region changed:"
echo "      task secrets:edit -- platform/secrets/s3-backup.sops.yaml"
echo "  - bootstrap/aws-backup/main.tf: local.restic_repos must list EVERY"
echo "    restic repository, or its pack files stay in S3 Standard at roughly"
echo "    6x the price and nothing warns you. Currently expected:"
echo "      immich/library  paperless/media  theater/configs  seafile/shared"
echo "      syncthing/data  mealie/data      grafana/data"

echo
echo "$changed file(s) updated. Now run:  task render"
