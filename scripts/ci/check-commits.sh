#!/bin/bash
# check-commits.sh <repo> <pr-number>
#
# The `commits` CI check: every commit of the PR has a subject that passes
# scripts/ci/check-title.sh, and GitHub reports it as verified (signed).
# Reads the commits through the REST API (GH_TOKEN with pull-requests: read).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=${1:?usage: check-commits.sh <owner/repo> <pr>}
pr=${2:?usage: check-commits.sh <owner/repo> <pr>}

json=$(gh api --paginate "repos/$repo/pulls/$pr/commits")
total=$(jq -s 'add | length' <<<"$json")
[ "$total" -gt 0 ] || { echo "check-commits: PR #$pr has no commits" >&2; exit 1; }

rc=0
while IFS=$'\t' read -r sha verified reason subject; do
  bad=0
  if ! "$HERE/check-title.sh" "$subject"; then
    echo "::error::${sha:0:7}: subject fails the Conventional Commits / length rule"
    bad=1
  fi
  if [ "$verified" != "true" ]; then
    echo "::error::${sha:0:7}: commit is not verified (reason: $reason)"
    bad=1
  fi
  if [ "$bad" -eq 0 ]; then echo "ok ${sha:0:7} verified: $subject"; else rc=1; fi
done < <(jq -rs 'add | .[] | [.sha, (.commit.verification.verified | tostring), .commit.verification.reason, (.commit.message | split("\n")[0])] | @tsv' <<<"$json")

echo "check-commits: $total commit(s) checked"
exit "$rc"
