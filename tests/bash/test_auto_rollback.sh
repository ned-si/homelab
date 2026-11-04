#!/bin/bash
# test_auto_rollback.sh -- scripts/ci/auto-rollback-decide.sh against a scratch
# repository, scripts/ci/auto-rollback-act.sh and scripts/ci/auto-rollback-guard.sh against
# a stubbed `gh` and `curl`, and scripts/ci/auto-rollback-keep.sh against a
# fake GitHub backed by a scratch repository.
#
# The keep hooks are commands for the hook's own shell: single quotes.
# shellcheck disable=SC2016
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
expect_eq "commit that does not touch the app: skip" skip "$(get action "$o")"
expect_contains "reason names the app" "changes no file of mealie" "$(get reason "$o")"

o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="$c_immich" NOW=$((T0 + 100 + 3600)))
expect_eq "older than 1 h: skip" skip "$(get action "$o")"

o=$(run_decide APP=immich TRIGGER=on-health-degraded REVISION="1.2.3 0000000000000000000000000000000000000000")
expect_eq "no commit of main in the revision: skip" skip "$(get action "$o")"
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
expect_eq "not the newest commit on main: skip" skip "$(get action "$o")"
o=$(run_decide APP=cilium TRIGGER=on-health-degraded REVISION="$c_cilium")
expect_eq "cilium is never reverted" skip "$(get action "$o")"
expect_contains "cilium reason" "never reverted automatically" "$(get reason "$o")"

c_dcsi=$(commit $((T0 + 250)) "feat(storage): update democratic-csi to 0.16.0" \
  deploy/clusters/homelab/infrastructure/application-democratic-csi.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=democratic-csi TRIGGER=on-sync-failed REVISION="$c_dcsi")
expect_eq "democratic-csi is never reverted" skip "$(get action "$o")"

c_rev=$(commit $((T0 + 300)) "revert: feat(storage): update democratic-csi to 0.16.0 (auto) (#20)" \
  deploy/clusters/homelab/infrastructure/application-democratic-csi.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=democratic-csi TRIGGER=on-sync-failed REVISION="$c_rev" NO_REVERT_APPS=cilium)
expect_eq "a revert is never reverted" skip "$(get action "$o")"

c_kps=$(commit $((T0 + 400)) "feat(monitoring): update kube-prometheus-stack" \
  platform/kube-prometheus-stack/values.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=kube-prometheus-stack TRIGGER=on-health-degraded REVISION="$c_kps")
expect_eq "right after an automatic revert: skip" skip "$(get action "$o")"
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

echo "decide: a cilium patch update is reverted, nothing else of cilium"
# pin <when> <subject> <version>: write the cilium chart pins, commit.
pin() {
  local when=$1 subject=$2 v=$3
  mkdir -p clusters/homelab/infrastructure deploy/clusters/homelab/infrastructure ci
  printf '      targetRevision: %s\n' "$v" > clusters/homelab/infrastructure/cilium.yaml
  printf '    targetRevision: %s\n' "$v" > deploy/clusters/homelab/infrastructure/application-cilium.yaml
  printf 'cilium:\n  version: %s\n' "$v" > ci/helm-releases.yaml
  git add -A
  GIT_AUTHOR_DATE="@$when +0000" GIT_COMMITTER_DATE="@$when +0000" git commit -qm "$subject"
  git rev-parse HEAD
}
pin $((T0 + 605)) "chore: cilium pins" 1.20.3 >/dev/null
c_cpatch=$(pin $((T0 + 610)) "chore(deps): update chart cilium to v1.20.4 (#654)" 1.20.4)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=cilium TRIGGER=on-sync-failed REVISION="$c_cpatch")
expect_eq "cilium patch update: revert" revert "$(get action "$o")"
c_cminor=$(pin $((T0 + 620)) "chore(deps): update chart cilium to v1.21.0 (#700)" 1.21.0)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=cilium TRIGGER=on-sync-failed REVISION="$c_cminor")
expect_eq "cilium minor update: skip" skip "$(get action "$o")"
c_cval=$(commit $((T0 + 630)) "feat(network): cilium values" infrastructure/cilium/values.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=cilium TRIGGER=on-sync-failed REVISION="$c_cval")
expect_eq "cilium values change: skip" skip "$(get action "$o")"

echo "decide: a failing PostSync smoke test (on-sync-failed)"
# The hook fails the sync of the merge that broke the app: that merge is
# reverted. The revert's sync runs the hook again; when it fails too, the
# answer is a skip, never a second revert.
c_bump=$(commit $((T0 + 650)) "chore(deps): update mealie to v3.29.0 (#40)" \
  apps/mealie/deployment.yaml deploy/apps/mealie/deployment-mealie.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_bump")
expect_eq "PostSync failure of the newest merge: revert" revert "$(get action "$o")"
expect_eq "revert title" "revert: chore(deps): update mealie to v3.29.0 (auto)" "$(get pr_title "$o")"
c_auto=$(commit $((T0 + 660)) "revert: chore(deps): update mealie to v3.29.0 (auto) (#41)" \
  apps/mealie/deployment.yaml deploy/apps/mealie/deployment-mealie.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_auto")
expect_eq "PostSync failure of the revert itself: skip" skip "$(get action "$o")"
expect_contains "no revert of a revert" "itself a revert" "$(get reason "$o")"
c_next=$(commit $((T0 + 670)) "fix(mealie): pin the old image tag (#42)" apps/mealie/deployment.yaml)
git update-ref refs/remotes/origin/main HEAD
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_next")
expect_eq "PostSync failure right after an automatic revert: skip" skip "$(get action "$o")"

echo "decide: outage guard"
# OUTAGE_CHECK is a command; its first line is the outage reason.
mkdir -p "$tmp/guards"
printf '#!/bin/bash\necho "3 apps failed within 10 minutes: a b c"\necho "action=revert"\n' > "$tmp/guards/outage"
printf '#!/bin/bash\nexit 0\n' > "$tmp/guards/calm"
printf '#!/bin/bash\necho "half a line"\nexit 1\n' > "$tmp/guards/broken"
chmod +x "$tmp/guards"/*
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_bump" MAIN_REF="$c_bump" OUTAGE_CHECK="$tmp/guards/outage")
expect_eq "outage: the revert is skipped" skip "$(get action "$o")"
expect_contains "outage: reason" "outage guard: 3 apps failed within 10 minutes" "$(get reason "$o")"
expect_eq "outage: no pull request title" "" "$(get pr_title "$o")"
expect_eq "outage: its second line cannot add an output" 1 "$(grep -c '^action=' <<<"$o")"
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_bump" MAIN_REF="$c_bump" OUTAGE_CHECK="$tmp/guards/calm")
expect_eq "no outage: revert" revert "$(get action "$o")"
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_bump" MAIN_REF="$c_bump" OUTAGE_CHECK="$tmp/guards/broken")
expect_eq "a failing guard holds nothing back" revert "$(get action "$o")"
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_auto" MAIN_REF="$c_auto" OUTAGE_CHECK="$tmp/guards/outage")
expect_contains "the guard runs only for a revert" "itself a revert" "$(get reason "$o")"
o=$(run_decide APP=mealie TRIGGER=on-sync-failed REVISION="$c_bump" GUARD_WAIT=soon)
expect_contains "invalid GUARD_WAIT is refused" "rc=1" "$o"

echo "guard"
# Fake gh (the run list) and curl (the ntfy topic) for auto-rollback-guard.sh.
GUARD="$REPO_ROOT/scripts/ci/auto-rollback-guard.sh"
mkdir -p "$tmp/gbin"
cat > "$tmp/gbin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GUARD_LOG"
[ "${RUNS_FAIL:-}" = 1 ] && exit 1
printf '%s' "${RUNS:-}"
EOF
cat > "$tmp/gbin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$GUARD_LOG"
[ "${NTFY_FAIL:-}" = 1 ] && exit 22
printf '%s' "${NTFY_MSGS:-}"
EOF
chmod +x "$tmp/gbin/gh" "$tmp/gbin/curl"
export GUARD_LOG="$tmp/guard.log"
guard() { env PATH="$tmp/gbin:$PATH" REPO=o/r NOW=1700000600 "$@" "$GUARD" 2>"$tmp/guard.err"; }
msg() { printf '{"event":"message","time":%s,"title":"%s"}\n' "$1" "$2"; }

: > "$GUARD_LOG"
out=$(guard RUNS=$'auto-rollback immich\nauto-rollback mealie\nauto-rollback immich\nauto-rollback syncthing' NTFY_TOPIC=t)
expect_eq "3 distinct apps: outage" "3 apps failed within 10 minutes: immich mealie syncthing" "$out"
expect_contains "runs since NOW - 10 minutes" "runs?created=%3E%3D2023-11-14T22:13:20Z" "$(cat "$GUARD_LOG")"
check "several apps: ntfy not read" [ -z "$(grep '^curl' "$GUARD_LOG")" ]

out=$(guard RUNS=$'auto-rollback immich\nauto-rollback immich\nauto-rollback mealie')
expect_eq "2 apps, no topic: no outage" "" "$out"
expect_contains "no topic: warned" "NTFY_TOPIC is not set" "$(cat "$tmp/guard.err")"

out=$(guard RUNS='auto-rollback immich' NTFY_TOPIC=t \
  NTFY_MSGS="$(msg 100 'CRITICAL: HomelabNodeNotReady'; msg 200 'Warning: SLOErrorBudgetBurnSlow')")
expect_eq "node alert firing: outage" "HomelabNodeNotReady is firing" "$out"

out=$(guard RUNS='auto-rollback immich' NTFY_TOPIC=t \
  NTFY_MSGS="$(msg 300 'Resolved: HomelabNASUnreachable'; msg 100 'CRITICAL: HomelabNASUnreachable')")
expect_eq "newest NAS message is Resolved: no outage" "" "$out"

out=$(guard RUNS='auto-rollback immich' NTFY_TOPIC=t \
  NTFY_MSGS="$(msg 100 'CRITICAL: HomelabNodeNotReadyish'; msg 100 'CRITICAL: ArgoCDAppDegraded')")
expect_eq "other alerts: no outage" "" "$out"

: > "$GUARD_LOG"
out=$(guard RUNS_FAIL=1 NTFY_TOPIC=t NTFY_FAIL=1)
expect_eq "both checks failing: no outage" "" "$out"
expect_contains "run list failure warned" "cannot list" "$(cat "$tmp/guard.err")"
expect_contains "ntfy failure warned" "cannot read the ntfy topic" "$(cat "$tmp/guard.err")"
expect_contains "guard topic read with poll and since" "t-guard/json?poll=1&since=12h" "$(cat "$GUARD_LOG")"

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
  "api repos/o/r/issues/77/labels --input -")
    [ "${LABEL_FAIL:-}" = 1 ] && exit 1
    echo '[]' ;;
  "pr merge 77 --repo o/r --auto --squash") ;;
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
expect_contains "pull request has the migration note" "schema migration" "$(jq -r .body "$p.stdin")"
expect_contains "pull request links the app" "applications/argo/immich" "$(jq -r .body "$p.stdin")"
l=$(call 'issues/77/labels')
expect_eq "label auto-rollback" auto-rollback "$(jq -r '.labels | join(",")' "$l.stdin")"
m=$(call 'pr merge')
expect_eq "auto-merge uses the owner token" owner-token "$(cat "$m.token")"
check "revert: no issue is opened" [ -z "$(grep -lE 'repos/o/r/issues --input|issues\?state|/comments' "$tmp/log"/*.args 2>/dev/null)" ]

reset_log
out=$(env "${act_env[@]}" ACTION=revert LABEL_FAIL=1 "$ACT" 2>&1) || bad "label failure stopped the revert: $out"
check "label failure: auto-merge still on" [ -n "$(call 'pr merge')" ]

reset_log
: > "$tmp/act.out"
out=$(env "${act_env[@]}" ACTION=revert GITHUB_OUTPUT="$tmp/act.out" "$ACT" 2>&1) || bad "revert run with outputs failed: $out"
expect_eq "outputs the pull request for keep" 77 "$(sed -n 's/^pr=//p' "$tmp/act.out")"
expect_eq "outputs the revert commit for keep" revertcommit "$(sed -n 's/^commit=//p' "$tmp/act.out")"

reset_log
out=$(env "${act_env[@]}" ACTION=revert REF_EXISTS=1 "$ACT" 2>&1) || bad "existing branch run failed: $out"
check "existing branch: no second pull request" [ -z "$(call 'repos/o/r/pulls')" ]
expect_contains "existing branch: said so" "already exists" "$out"

reset_log
out=$(env "${act_env[@]}" ACTION=skip STATEFUL=false "$ACT" 2>&1) || bad "skip run failed: $out"
check "skip: no API call at all" [ -z "$(ls "$tmp/log")" ]
expect_contains "skip: reason printed" "nothing to do (newest commit)" "$out"

reset_log
if env "${act_env[@]}" ACTION=revert PR_TOKEN= "$ACT" >/dev/null 2>&1; then
  bad "missing AUTO_ROLLBACK_TOKEN was accepted"
else
  ok "missing AUTO_ROLLBACK_TOKEN fails"
fi
check "missing token: no API call" [ -z "$(ls "$tmp/log")" ]

echo "keep"
# A fake GitHub: the repository $UP stands for the one on GitHub, the fake gh
# stores blobs, trees, commits and refs in it, and the pull request's head is
# its auto-revert/ branch. On the n-th `pr view`, $HOOKS/<n> runs first (it
# moves main, merges or closes the pull request).
KEEP="$REPO_ROOT/scripts/ci/auto-rollback-keep.sh"
mkdir -p "$tmp/kbin"
cat > "$tmp/kbin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
n=$(( $(ls "$KLOG" | grep -c args || true) + 1 ))
printf '%s\n' "$*" > "$KLOG/$n.args"
printf '%s\n' "$GH_TOKEN" > "$KLOG/$n.token"
in=""
case " $* " in *" --input - "*) in=$(cat); printf '%s' "$in" > "$KLOG/$n.stdin" ;; esac
up() { git -C "$UP" "$@"; }
case "$*" in
  "pr view 77 --repo o/r --json state,headRefOid --jq "*)
    v=$(( $(cat "$KLOG/views" 2>/dev/null || echo 0) + 1 ))
    echo "$v" > "$KLOG/views"
    if [ -x "$HOOKS/$v" ]; then "$HOOKS/$v" >/dev/null; fi
    echo "$(cat "$KLOG/state" 2>/dev/null || echo OPEN) $(up for-each-ref --format='%(objectname)' refs/heads/auto-revert/)" ;;
  "pr close 77 --repo o/r --comment "*) echo CLOSED > "$KLOG/state" ;;
  "api repos/o/r/git/blobs --input - --jq .sha")
    jq -r .content <<<"$in" | base64 --decode | up hash-object -w --stdin ;;
  "api repos/o/r/git/trees --input - --jq .sha")
    idx="$KLOG/index.$n"
    env GIT_INDEX_FILE="$idx" git -C "$UP" read-tree "$(jq -r .base_tree <<<"$in")"
    jq -r '.tree[] | if .sha == null then "0 0000000000000000000000000000000000000000\t\(.path)" else "\(.mode) \(.sha)\t\(.path)" end' <<<"$in" |
      env GIT_INDEX_FILE="$idx" git -C "$UP" update-index --index-info
    env GIT_INDEX_FILE="$idx" git -C "$UP" write-tree ;;
  "api repos/o/r/git/commits --input - --jq .sha")
    up commit-tree "$(jq -r .tree <<<"$in")" -p "$(jq -r '.parents[0]' <<<"$in")" -m "$(jq -r .message <<<"$in")" ;;
  "api repos/o/r/git/commits/"*" --jq .message")
    up log -1 --format=%B "${2##*/}" ;;
  "api -X PATCH repos/o/r/git/refs/heads/"*" --input -")
    up update-ref "refs/heads/${4#repos/o/r/git/refs/heads/}" "$(jq -r .sha <<<"$in")" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/kbin/gh"

# vals <line 2> <line 9>: a ten-line values file.
vals() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    case $i in 2) echo "k2: $1" ;; 9) echo "k9: $2" ;; *) echo "k$i: v$i" ;; esac
  done
}
vals v2 v9 > "$tmp/vals.base"
vals bad v9 > "$tmp/vals.bad"
vals bad new9 > "$tmp/vals.later"
vals other v9 > "$tmp/vals.conflict"

# keep_setup <name>: a fresh GitHub repository $K/up with main at the bad
# commit (line 2 changed, app/new.yaml added), the revert commit act made on
# branch auto-revert/<sha12>, and the runner's clone $K/work.
keep_setup() {
  K="$tmp/keep-$1"
  mkdir -p "$K/up/app" "$K/log" "$K/hooks"
  (
    cd "$K/up"
    git init -q -b main
    git config user.email t@example.invalid
    git config user.name t
    git config commit.gpgsign false
    cp "$tmp/vals.base" app/values.yaml
    echo one > other.txt
    git add -A && git commit -qm "chore: base"
    cp "$tmp/vals.bad" app/values.yaml
    echo new > app/new.yaml
    git add -A && git commit -qm "feat(app): break it (#5)"
  )
  k_bad=$(git -C "$K/up" rev-parse main)
  k_act=$(git -C "$K/up" commit-tree "$(git -C "$K/up" rev-parse "$k_bad^^{tree}")" -p "$k_bad" \
    -m "revert: feat(app): break it (auto)" -m "This reverts commit $k_bad.")
  git -C "$K/up" update-ref "refs/heads/auto-revert/${k_bad:0:12}" "$k_act"
  git clone -q "$K/up" "$K/work"
}
# hook <n> <commands>: run <commands> in $UP on the n-th check.
hook() { printf '#!/bin/bash\nset -e\ncd "$UP"\n%s\n' "$2" > "$K/hooks/$1"; chmod +x "$K/hooks/$1"; }
on_main() { printf 'cp %s app/values.yaml\n%s\ngit add -A\ngit commit -qm "%s"' "$1" "$2" "$3"; }
keep() {
  (cd "$K/work" && env PATH="$tmp/kbin:$PATH" UP="$K/up" KLOG="$K/log" HOOKS="$K/hooks" \
    REPO=o/r PR=77 SHA="$k_bad" HEAD_SHA="$k_act" BOT_TOKEN=bot-token PR_TOKEN=owner-token \
    POLL=0 MAX_POLLS=6 "$@" "$KEEP" 2>&1)
}
kcall() { { grep -l -- "$1" "$K/log"/*.args 2>/dev/null || true; } | sed 's/\.args$//'; }
head_of() { git -C "$K/up" rev-parse "refs/heads/auto-revert/${k_bad:0:12}"; }

keep_setup moved
hook 2 "$(on_main "$tmp/vals.later" "echo two > other.txt" "fix(other): unrelated (#6)")"
hook 4 "$(on_main "$tmp/vals.later" "echo three > other.txt" "fix(other): again (#7)")"
hook 6 'echo MERGED > "$KLOG/state"'
if out=$(keep); then ok "main moved twice: keep succeeds"; else bad "main moved twice: keep failed: $out"; fi
expect_contains "main moved: merged at the end" "#77 merged" "$out"
expect_eq "main moved: rebuilt once per move" 2 "$(grep -c 'rebuilt as' <<<"$out")"
h=$(head_of)
expect_eq "rebuilt revert sits on the newest main" "$(git -C "$K/up" rev-parse main)" "$(git -C "$K/up" rev-parse "$h^")"
expect_eq "rebuilt revert undoes the bad line, keeps the later one" "$(sed 's/k9: v9/k9: new9/' "$tmp/vals.base")" \
  "$(git -C "$K/up" show "$h:app/values.yaml")"
check "rebuilt revert deletes the added file" [ -z "$(git -C "$K/up" ls-tree "$h" app/new.yaml)" ]
expect_eq "rebuilt revert keeps later changes to other files" three "$(git -C "$K/up" show "$h:other.txt")"
expect_eq "rebuilt revert keeps the message" "$(git -C "$K/up" log -1 --format=%B "$k_act")" "$(git -C "$K/up" log -1 --format=%B "$h")"
expect_eq "rebuilt revert equals git revert on main" "$(git -C "$K/up" merge-tree --write-tree --merge-base="$k_bad" main "$k_bad^")" \
  "$(git -C "$K/up" rev-parse "$h^{tree}")"
c=$(kcall 'git/commits --input' | head -n 1)
expect_eq "rebuild: commit uses the bot token" bot-token "$(cat "$c.token")"
expect_eq "rebuild: commit has no author, so GitHub signs it" false "$(jq -r 'has("author") or has("committer")' "$c.stdin")"
p=$(kcall 'PATCH' | head -n 1)
expect_eq "rebuild: branch moved with the owner token, so ci runs" owner-token "$(cat "$p.token")"
expect_eq "rebuild: branch moved with force" true "$(jq -r .force "$p.stdin")"
expect_eq "rebuild: blobs use the bot token" bot-token "$(cat "$(kcall 'git/blobs' | head -n 1).token")"

keep_setup still
hook 3 'echo MERGED > "$KLOG/state"'
out=$(keep) || bad "main still: keep failed: $out"
check "main still: nothing rebuilt" [ -z "$(kcall 'git/')" ]
expect_eq "main still: head untouched" "$k_act" "$(head_of)"

keep_setup conflict
hook 1 "$(on_main "$tmp/vals.conflict" "rm app/new.yaml" "fix(app): another fix (#6)")"
if out=$(keep); then bad "conflict: keep succeeded"; else ok "conflict: keep fails"; fi
expect_contains "conflict: said so" "no longer applies" "$out"
check "conflict: branch not moved" [ -z "$(kcall 'PATCH')" ]
expect_eq "conflict: head untouched" "$k_act" "$(head_of)"

keep_setup undone
hook 1 "$(on_main "$tmp/vals.base" "rm app/new.yaml" "revert: feat(app): break it (#6)")"
out=$(keep) || bad "already undone: keep failed: $out"
expect_contains "already undone: said so" "already undoes" "$out"
c=$(kcall 'pr close')
check "already undone: pull request closed" [ -n "$c" ]
expect_eq "already undone: closed with the owner token" owner-token "$(cat "$c.token")"
expect_contains "already undone: automation comment" "**[automation]**" "$(cat "$c.args")"
check "already undone: branch not moved" [ -z "$(kcall 'PATCH')" ]

keep_setup closed
echo CLOSED > "$K/log/state"
out=$(keep) || bad "closed: keep failed: $out"
expect_contains "closed: said so" "was closed" "$out"
check "closed: one check only" [ "$(cat "$K/log/views")" = 1 ]

keep_setup pushed
hook 1 "$(on_main "$tmp/vals.later" "" "fix(other): unrelated (#6)")
git update-ref refs/heads/auto-revert/${k_bad:0:12} main"
out=$(keep) || bad "pushed by someone: keep failed: $out"
expect_contains "pushed by someone: left as is" "by someone else" "$out"
check "pushed by someone: branch not moved" [ -z "$(kcall 'PATCH')" ]

keep_setup timeout
if out=$(keep MAX_POLLS=2); then bad "timeout: keep succeeded"; else ok "timeout: keep fails"; fi
expect_contains "timeout: said so" "still open after 2 checks" "$out"

if keep SHA=nope >/dev/null; then bad "bad SHA accepted"; else ok "bad SHA refused"; fi

finish
