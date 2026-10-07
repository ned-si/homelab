#!/bin/bash
# test_auto_rollback.sh -- scripts/ci/auto-rollback-decide.sh against a scratch
# repository, and scripts/ci/auto-rollback-act.sh against a stubbed `gh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
DECIDE="$REPO_ROOT/scripts/ci/auto-rollback-decide.sh"
ACT="$REPO_ROOT/scripts/ci/auto-rollback-act.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
cd "$repo"
git init -q -b main
git config user.email t@example.invalid
git config user.name t
git config commit.gpgsign false

# commit <epoch> <subject> <file>...: write each file and commit at <epoch>.
commit() {
  local when=$1 subject=$2
  shift 2
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    echo "$subject" >> "$f"
  done
  git add -A
  GIT_AUTHOR_DATE="@$when +0000" GIT_COMMITTER_DATE="@$when +0000" git commit -qm "$subject"
  git rev-parse HEAD
}

T0=1700000000
base=$(commit "$T0" "chore: init" README.md)
c_immich=$(commit $((T0 + 100)) "feat(immich): update chart to 0.10.0 (#12)" \
  clusters/homelab/apps/immich.yaml deploy/clusters/homelab/apps/application-immich.yaml)
git update-ref refs/remotes/origin/main HEAD

# run_decide <env...>: run the script, print its GITHUB_OUTPUT.
run_decide() {
  local out="$tmp/out.$RANDOM"
  : > "$out"
  env GITHUB_OUTPUT="$out" NOW=$((T0 + 700)) "$@" "$DECIDE" >/dev/null 2>"$tmp/err" || {
    echo "rc=$?"
    cat "$tmp/err"
  }
  cat "$out"
}
get() { sed -n "s/^$1=//p" <<<"$2"; }
# check <name> <command...>: ok when the command succeeds.
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

echo "decide"
o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="0.10.0 $c_immich $c_immich")
expect_eq "newest attributable commit is reverted" revert "$(get action "$o")"
expect_eq "chart versions in the revision list are skipped" "$c_immich" "$(get sha "$o")"
expect_eq "PR title" "revert: feat(immich): update chart to 0.10.0 (auto)" "$(get pr_title "$o")"
expect_eq "revert tree is the parent's tree" "$(git rev-parse "$base^{tree}")" "$(get revert_tree "$o")"
expect_eq "immich is stateful" true "$(get stateful "$o")"
expect_eq "dry_run defaults to false" false "$(get dry_run "$o")"
check "PR title passes check-title.sh" "$REPO_ROOT/scripts/ci/check-title.sh" "$(get pr_title "$o")"

o=$(run_decide APP=immich TRIGGER=on-sync-failed REVISION="$c_immich" DRY_RUN=true)
expect_eq "dry run is reported" true "$(get dry_run "$o")"
expect_eq "dry run still decides" revert "$(get action "$o")"

o=$(run_decide APP=mealie TRIGGER=on-health-degraded REVISION="$c_immich")
expect_eq "commit that does not touch the app: issue" issue "$(get action "$o")"
expect_contains "reason names the app" "changes no file of mealie" "$(get reason "$o")"

o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="$c_immich" NOW=$((T0 + 100 + 3600)))
expect_eq "older than 1 h: issue" issue "$(get action "$o")"

o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="1.2.3 0000000000000000000000000000000000000000")
expect_eq "no commit of main in the revision: issue" issue "$(get action "$o")"
expect_eq "no commit: empty sha" "" "$(get sha "$o")"

o=$(run_decide APP='bad;app' TRIGGER=on-health-degraded REVISION="$c_immich")
expect_contains "invalid app name is refused" "rc=1" "$o"
o=$(run_decide APP=immich TRIGGER=on-anything REVISION="$c_immich")
expect_contains "invalid trigger is refused" "rc=1" "$o"
o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="$c_immich
action=revert")
expect_eq "a newline in the revision cannot add an output" 1 "$(grep -c '^action=' <<<"$o")"

c_cilium=$(commit $((T0 + 200)) "feat(network): update Cilium to 1.18.0" \
  clusters/homelab/infrastructure/cilium.yaml infrastructure/cilium/values.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="$c_immich")
expect_eq "not the newest commit on main: issue" issue "$(get action "$o")"
o=$(run_decide APP=cilium TRIGGER=on-health-degraded REVISION="$c_cilium")
expect_eq "cilium is never reverted" issue "$(get action "$o")"
expect_contains "cilium reason" "never reverted automatically" "$(get reason "$o")"

c_dcsi=$(commit $((T0 + 250)) "feat(storage): update democratic-csi to 0.16.0" \
  deploy/clusters/homelab/infrastructure/application-democratic-csi.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=democratic-csi TRIGGER=on-sync-failed REVISION="$c_dcsi")
expect_eq "democratic-csi is never reverted" issue "$(get action "$o")"

c_rev=$(commit $((T0 + 300)) "revert: feat(storage): update democratic-csi to 0.16.0 (auto) (#20)" \
  deploy/clusters/homelab/infrastructure/application-democratic-csi.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=democratic-csi TRIGGER=on-sync-failed REVISION="$c_rev" NO_REVERT_APPS=cilium)
expect_eq "a revert is never reverted" issue "$(get action "$o")"

c_kps=$(commit $((T0 + 400)) "feat(monitoring): update kube-prometheus-stack" \
  platform/kube-prometheus-stack/values.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=kube-prometheus-stack TRIGGER=on-health-degraded REVISION="$c_kps")
expect_eq "right after an automatic revert: issue" issue "$(get action "$o")"
expect_contains "loop guard reason" "never two in a row" "$(get reason "$o")"
o=$(run_decide APP=kube-prometheus-stack TRIGGER=on-health-degraded REVISION="$c_kps" \
  LOOP_WINDOW=50)
expect_eq "an old automatic revert does not block" revert "$(get action "$o")"
expect_eq "kube-prometheus-stack is not stateful" false "$(get stateful "$o")"

c_sec=$(commit $((T0 + 500)) "feat(secrets): seal the notifications token" \
  platform/secrets/argocd-notifications.sops.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=secrets-platform TRIGGER=on-sync-failed REVISION="$c_sec")
expect_eq "secrets-<layer> maps to <layer>/secrets/" revert "$(get action "$o")"

long="feat(monitoring): update kube-prometheus-stack and every one of its CRDs (#30) (#31)"
c_long=$(commit $((T0 + 600)) "$long" deploy/platform/kube-prometheus-stack/routes/x.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=kube-prometheus-stack TRIGGER=on-health-degraded REVISION="$c_long")
t=$(get pr_title "$o")
expect_eq "long subject: still a revert" revert "$(get action "$o")"
check "long subject: title under 70 ($t)" [ "${#t}" -lt 70 ]
check "long title passes check-title.sh" "$REPO_ROOT/scripts/ci/check-title.sh" "$t"

echo "act"
install_fake_gh_act() {
  mkdir -p "$tmp/bin" "$tmp/log"
  cat > "$tmp/bin/gh" <<'EOF'
#!/bin/bash
n=$(( $(ls "$GH_LOG" | grep -c args) + 1 ))
printf '%s\n' "$*" > "$GH_LOG/$n.args"
printf '%s\n' "$GH_TOKEN" > "$GH_LOG/$n.token"
case " $* " in *" --input - "*) cat > "$GH_LOG/$n.stdin" ;; esac
case "$*" in
  "api repos/o/r/git/commits --input - --jq .sha") echo revertcommit ;;
  "api repos/o/r/git/refs --input -")
    [ "${REF_EXISTS:-}" = 1 ] && { echo "Reference already exists" >&2; exit 1; }
    echo '{}' ;;
  "api repos/o/r/pulls --input - --jq .number") echo 77 ;;
  "pr merge 77 --repo o/r --auto --squash") ;;
  "api repos/o/r/issues?state=open&per_page=100 --jq "*) echo "${OPEN_ISSUE:-}" ;;
  "api repos/o/r/issues --input - --jq .number") echo 88 ;;
  "api repos/o/r/issues/"*"/comments --input -") echo '{}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$tmp/bin/gh"
}
install_fake_gh_act
reset_log() { rm -rf "$tmp/log"; mkdir -p "$tmp/log"; }
call() { { grep -l -- "$1" "$tmp/log"/*.args 2>/dev/null || true; } | head -n 1 | sed 's/\.args$//'; }

export GH_LOG="$tmp/log"
act_env=(PATH="$tmp/bin:$PATH" REPO=o/r APP=immich TRIGGER=on-health-degraded
  SHA="$c_immich" SUBJECT="feat(immich): update chart to 0.10.0"
  PR_TITLE="revert: feat(immich): update chart to 0.10.0 (auto)"
  REVERT_TREE="$(git rev-parse "$base^{tree}")" REASON="newest commit" STATEFUL=true
  BOT_TOKEN=bot-token PR_TOKEN=owner-token RUN_URL=https://example.invalid/run/1)

reset_log
if out=$(env "${act_env[@]}" ACTION=revert "$ACT" 2>&1); then ok "revert run succeeds"; else bad "revert run failed: $out"; fi
c=$(call 'git/commits')
expect_eq "commit uses the bot token" bot-token "$(cat "$c.token")"
expect_eq "commit tree" "$(git rev-parse "$base^{tree}")" "$(jq -r .tree "$c.stdin")"
expect_eq "commit parent" "$c_immich" "$(jq -r '.parents | join(",")' "$c.stdin")"
expect_eq "commit has no author, so GitHub signs it" false "$(jq -r 'has("author") or has("committer")' "$c.stdin")"
r=$(call 'git/refs')
expect_eq "branch name" "refs/heads/auto-revert/${c_immich:0:12}" "$(jq -r .ref "$r.stdin")"
p=$(call 'repos/o/r/pulls')
expect_eq "pull request uses the owner token" owner-token "$(cat "$p.token")"
expect_eq "pull request title" "revert: feat(immich): update chart to 0.10.0 (auto)" "$(jq -r .title "$p.stdin")"
expect_eq "pull request base" main "$(jq -r .base "$p.stdin")"
m=$(call 'pr merge')
expect_eq "auto-merge uses the owner token" owner-token "$(cat "$m.token")"
i=$(call 'issues --input')
expect_eq "issue title" "Argo CD: immich failed after a deploy" "$(jq -r .title "$i.stdin")"
expect_contains "issue links the pull request" "#77" "$(jq -r .body "$i.stdin")"
expect_contains "issue has the migration note" "schema migration" "$(jq -r .body "$i.stdin")"

reset_log
out=$(env "${act_env[@]}" ACTION=revert REF_EXISTS=1 OPEN_ISSUE=5 "$ACT" 2>&1) || bad "existing branch run failed: $out"
check "existing branch: no second pull request" [ -z "$(call 'repos/o/r/pulls')" ]
c=$(call 'issues/5/comments')
check "open issue: commented instead" [ -n "$c" ]
expect_contains "comment says the branch existed" "already existed" "$(jq -r .body "$c.stdin")"

reset_log
out=$(env "${act_env[@]}" ACTION=issue STATEFUL=false "$ACT" 2>&1) || bad "issue run failed: $out"
check "issue only: no commit or branch" [ -z "$(call 'git/')" ]
i=$(call 'issues --input')
expect_contains "issue only: decision" "not reverted" "$(jq -r .body "$i.stdin")"

reset_log
if env "${act_env[@]}" ACTION=revert PR_TOKEN= "$ACT" >/dev/null 2>&1; then
  bad "missing AUTO_ROLLBACK_TOKEN was accepted"
else
  ok "missing AUTO_ROLLBACK_TOKEN fails"
fi
check "missing token: no API call" [ -z "$(ls "$tmp/log")" ]

finish
