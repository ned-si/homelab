#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Every restic repository in the manifests must appear in `local.restic_repos`
# in bootstrap/aws-backup/main.tf, and vice versa.
#
# WHY THIS NEEDS A CHECK
#
# `local.restic_repos` drives the S3 lifecycle rules that move pack files to
# Glacier Instant Retrieval. A repository missing from that list is NOT an error
# anywhere: the backup runs, the restore works, the verification passes. The only
# symptom is that its data sits in S3 Standard at roughly six times the price,
# indefinitely, and nothing ever says so.
#
# This is exactly the class of mistake that a comment saying "remember to update
# this" does not prevent -- and it already happened once: five of seven
# repositories were missing while every file involved claimed the list mattered.
#
# It also catches the reverse (a lifecycle rule for a repository that no longer
# exists), which is harmless but means the list has stopped describing reality.
#
# Usage:  scripts/check-restic-repos.sh
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TF=bootstrap/aws-backup/main.tf
[ -f "$TF" ] || { echo "cannot find $TF" >&2; exit 1; }

# --- what the manifests actually use ---------------------------------------
# RESTIC_REPOSITORY values look like:
#   s3:https://s3.<region>.amazonaws.com/<bucket>/<owner>/<name>
# Take the last two path segments. Excludes deploy/ -- it is generated from
# these same sources, so counting it would double every entry.
manifest_repos=$(grep -rho 'RESTIC_REPOSITORY' -A2 --include='*.yaml' apps platform 2>/dev/null \
  | grep -o 's3:https://[^[:space:]]*' \
  | sed -E 's|^s3:https://[^/]+/[^/]+/||' \
  | grep -E '^[a-z0-9-]+/[a-z0-9-]+$' \
  | sort -u)

# Local filesystem repositories (the NFS copies) have no lifecycle rules to miss,
# so they are deliberately out of scope.

# --- what the lifecycle rules cover ----------------------------------------
tf_repos=$(sed -n '/restic_repos *= *\[/,/^  \]/p' "$TF" \
  | grep -oE '"[a-z0-9-]+/[a-z0-9-]+"' \
  | tr -d '"' \
  | sort -u)

if [ -z "$manifest_repos" ]; then
  echo "found no RESTIC_REPOSITORY values in apps/ or platform/ -- has the layout changed?" >&2
  exit 1
fi
if [ -z "$tf_repos" ]; then
  echo "could not parse local.restic_repos out of $TF" >&2
  exit 1
fi

missing=$(comm -23 <(printf '%s\n' "$manifest_repos") <(printf '%s\n' "$tf_repos"))
extra=$(comm -13 <(printf '%s\n' "$manifest_repos") <(printf '%s\n' "$tf_repos"))

printf 'restic repositories in manifests: %s\n' "$(printf '%s\n' "$manifest_repos" | wc -l | tr -d ' ')"
printf 'covered by lifecycle rules:       %s\n' "$(printf '%s\n' "$tf_repos" | wc -l | tr -d ' ')"
echo

rc=0
if [ -n "$missing" ]; then
  echo "NOT COVERED by a Glacier IR lifecycle rule -- these will sit in S3 Standard:" >&2
  printf '%s\n' "$missing" | sed 's/^/  /' >&2
  echo >&2
  echo "Add them to local.restic_repos in $TF." >&2
  rc=1
fi

if [ -n "$extra" ]; then
  echo "Lifecycle rule for a repository no NOTHING writes to:" >&2
  printf '%s\n' "$extra" | sed 's/^/  /' >&2
  echo "  (harmless, but the list no longer matches the manifests)" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "every restic repository is covered"
exit $rc
