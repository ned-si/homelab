#!/bin/bash
# scripts/pr-merge.sh --dry-run against fixture JSON (fake gh) and a local git origin.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install_fake_gh "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export PR_MERGE_REPO=ned-si/homelab
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# A local "origin" with main at A and a PR branch at B (child of A).
git init -q --bare "$tmp/origin.git"
git init -q "$tmp/work"
git -C "$tmp/work" -c commit.gpgsign=false commit -q --allow-empty -m "chore: a"
git -C "$tmp/work" branch -M main
git -C "$tmp/work" remote add origin "$tmp/origin.git"
git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q -b feature
git -C "$tmp/work" -c commit.gpgsign=false commit -q --allow-empty -m "ci: add b"
git -C "$tmp/work" push -q origin feature
HEAD_SHA=$(git -C "$tmp/work" rev-parse HEAD)

CHECKS="yamllint actionlint shellcheck render repo-policy kubeconform gitleaks trivy tofu pr-title commits ci"

setup() { # name
  export FAKE_GH_DIR="$tmp/$1"
  mkdir -p "$FAKE_GH_DIR"
  cat > "$FAKE_GH_DIR/pr-view.json" <<EOF
{"number":7,"title":"ci: add pinned CI gates for both repository layouts","state":"OPEN","isDraft":false,
 "baseRefName":"main","headRefName":"feature","headRefOid":"$HEAD_SHA","mergeable":"MERGEABLE"}
EOF
  local first=1 c
  {
    printf '['
    for c in $CHECKS; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"name":"%s","state":"SUCCESS","startedAt":"2026-10-04T07:00:00Z","link":"x"}' "$c"
    done
    printf ']\n'
  } > "$FAKE_GH_DIR/pr-checks.json"
  api_resp "repos/ned-si/homelab/pulls/7/commits" 200 \
    "[{\"sha\":\"$HEAD_SHA\",\"commit\":{\"message\":\"ci: add b\\n\\nbody\",\"verification\":{\"verified\":true,\"reason\":\"valid\"}}}]"
  api_resp 'repos/ned-si/homelab/actions/variables?per_page=1' 200 '{"total_count":0,"variables":[]}'
  api_resp 'repos/ned-si/homelab/actions/variables/MERGE_FREEZE' 404
  api_resp 'repos/ned-si/homelab/branches/main/protection' 403 '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature."}'
}

run_merge() { # args... -> sets rc and out
  rc=0
  out=$(cd "$tmp/work" && bash "$REPO_ROOT/scripts/pr-merge.sh" "$@" 2>&1) || rc=$?
}

setup good
run_merge --dry-run 7
expect_eq "all guards hold -> exit 0" 0 "$rc"
expect_contains "all guards hold -> would merge (squash)" "would merge (squash) PR #7 at $HEAD_SHA" "$out"
if grep -q '^pr merge' "$FAKE_GH_DIR/calls.log"; then bad "dry run must not merge"; else ok "dry run does not merge"; fi

setup freeze
api_resp 'repos/ned-si/homelab/actions/variables/MERGE_FREEZE' 200 '{"name":"MERGE_FREEZE","value":"history rewrite in progress"}'
run_merge --dry-run 7
expect_eq "MERGE_FREEZE present -> exit 2" 2 "$rc"
expect_contains "MERGE_FREEZE present -> reason printed" "refused: merge-freeze: MERGE_FREEZE is set: history rewrite in progress" "$out"

setup vars500
api_resp 'repos/ned-si/homelab/actions/variables?per_page=1' 500 '{"message":"Server Error"}'
run_merge --dry-run 7
expect_eq "variables API 500 -> exit 2" 2 "$rc"
expect_contains "variables API 500 -> fail closed" "refused: merge-freeze: variables API unavailable" "$out"

setup ffprot
api_resp 'repos/ned-si/homelab/branches/main/protection' 200 '{"enforce_admins":{"enabled":true}}'
run_merge --dry-run --ff 7
expect_eq "--ff with protection 200 -> exit 2" 2 "$rc"
expect_contains "--ff with protection 200 -> ff-protected" "refused: ff-protected" "$out"

setup ff403
run_merge --dry-run --ff 7
expect_eq "--ff with protection 403 -> exit 0" 0 "$rc"
expect_contains "--ff with protection 403 -> would merge (ff)" "would merge (ff) PR #7" "$out"

setup checkfail
sed -i.bak 's/"name":"kubeconform","state":"SUCCESS"/"name":"kubeconform","state":"FAILURE"/' "$FAKE_GH_DIR/pr-checks.json"
echo 1 > "$FAKE_GH_DIR/pr-checks.exit"
run_merge --dry-run 7
expect_eq "failing check -> exit 2" 2 "$rc"
expect_contains "failing check -> checks guard" "refused: checks: kubeconform is FAILURE" "$out"

setup missingcheck
sed -i.bak 's/{"name":"commits","state":"SUCCESS","startedAt":"2026-10-04T07:00:00Z","link":"x"},//' "$FAKE_GH_DIR/pr-checks.json"
run_merge --dry-run 7
expect_contains "missing check -> checks guard" "refused: checks: commits is MISSING" "$out"

setup rerun
# An older cancelled run of the same check is superseded by the newer success.
sed -i.bak 's/^\[/[{"name":"render","state":"CANCELLED","startedAt":"2026-10-04T06:00:00Z","link":"x"},/' "$FAKE_GH_DIR/pr-checks.json"
run_merge --dry-run 7
expect_eq "superseded cancelled run -> exit 0" 0 "$rc"

setup badtitle
sed -i.bak 's/"title":"ci: add pinned CI gates for both repository layouts"/"title":"Add CI."/' "$FAKE_GH_DIR/pr-view.json"
run_merge --dry-run 7
expect_eq "bad title -> exit 2" 2 "$rc"
expect_contains "bad title -> title guard" "refused: title" "$out"

setup unverified
api_resp "repos/ned-si/homelab/pulls/7/commits" 200 \
  "[{\"sha\":\"$HEAD_SHA\",\"commit\":{\"message\":\"wip\",\"verification\":{\"verified\":false,\"reason\":\"unsigned\"}}}]"
run_merge --dry-run 7
expect_contains "unsigned commit -> verified guard" "refused: verified" "$out"
expect_contains "bad subject -> subjects guard" "refused: subjects" "$out"

setup draft
sed -i.bak 's/"isDraft":false/"isDraft":true/; s/"mergeable":"MERGEABLE"/"mergeable":"CONFLICTING"/' "$FAKE_GH_DIR/pr-view.json"
run_merge --dry-run 7
expect_contains "draft -> mergeable guard" "refused: mergeable: PR is a draft" "$out"
expect_contains "conflicting -> mergeable guard" "refused: mergeable: GitHub reports CONFLICTING" "$out"

# main moves ahead: the PR head no longer contains origin/main.
git -C "$tmp/work" checkout -q main
git -C "$tmp/work" -c commit.gpgsign=false commit -q --allow-empty -m "chore: c"
git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q feature
setup behind
run_merge --dry-run 7
expect_eq "behind main -> exit 2" 2 "$rc"
expect_contains "behind main -> up-to-date guard" "refused: up-to-date" "$out"

run_merge --dry-run
expect_eq "no PR number -> usage" 64 "$rc"

finish
