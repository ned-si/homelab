#!/bin/bash
# auto-rollback-keep.sh -- keep an automatic revert pull request mergeable
# until it merges.
#
# main requires an up-to-date `ci`, so a revert pull request falls BEHIND as
# soon as anything else merges, and GitHub auto-merge then waits forever
# (#989). The "update branch" API is no way out: it creates unsigned merge
# commits. auto-rollback-act.sh opens the pull request; this script runs right
# after it and checks the pull request every POLL seconds, at most MAX_POLLS
# times:
#
#   merged or closed     done.
#   head moved by
#   someone else         stop; never overwrite another push.
#   main moved           rebuild the revert on the new main:
#                          1. `git merge-tree` of main and SHA's parent with
#                             SHA as the merge base, which is `git revert SHA`
#                             applied to main, without a work tree;
#                          2. a conflict: stop and fail, the revert no longer
#                             applies; the same tree as main: main already
#                             undoes SHA, so the pull request is closed;
#                          3. otherwise the changed blobs, the tree and a
#                             commit with main as its parent go through the
#                             Git Data API with BOT_TOKEN and no author, so
#                             GitHub signs the commit; the tree GitHub builds
#                             must hash the same as the local one;
#                          4. auto-revert/<sha12> moves to that commit with
#                             PR_TOKEN: a push by GITHUB_TOKEN would not start
#                             CI. `ci` runs again and auto-merge (still on)
#                             merges.
#   otherwise            wait.
# Still open after MAX_POLLS checks: fail, so the run is red. The app's
# ArgoCDAppStillDegraded alert pages if it stays broken.
#
# Environment: REPO (owner/name), PR (number), SHA (the reverted commit),
# HEAD_SHA (the revert commit auto-rollback-act.sh created), BOT_TOKEN,
# PR_TOKEN, POLL (default 60), MAX_POLLS (default 60), REMOTE (default
# origin). Runs in a full clone of the repository (fetch-depth 0).
#
# The backticks in the printf formats below are Markdown code spans.
# shellcheck disable=SC2016
set -euo pipefail

: "${REPO:?}" "${PR:?}" "${BOT_TOKEN:?}" "${PR_TOKEN:?}"
POLL=${POLL:-60}
MAX_POLLS=${MAX_POLLS:-60}
REMOTE=${REMOTE:-origin}

say() { echo "auto-rollback-keep: $*"; }
warn() { echo "::warning::auto-rollback-keep: $*" >&2; }
die() { echo "::error::auto-rollback-keep: $*" >&2; exit 1; }

[[ "$PR" =~ ^[0-9]+$ ]] || die "bad PR"
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "bad SHA"
[[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "bad HEAD_SHA"
[[ "$POLL" =~ ^[0-9]+$ ]] || die "bad POLL"
[[ "$MAX_POLLS" =~ ^[0-9]+$ ]] || die "bad MAX_POLLS"

bot() { GH_TOKEN=$BOT_TOKEN gh "$@"; }
owner() { GH_TOKEN=$PR_TOKEN gh "$@"; }

branch="auto-revert/${SHA:0:12}"
parent=$(git rev-parse --verify "$SHA^^{commit}") || die "$SHA has no parent here; check out with fetch-depth 0"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The base the pull request's head is built on: the reverted commit itself.
head=$HEAD_SHA base=$SHA message=""

# rebuild <main>: point the branch at the revert of SHA on top of <main>.
# Sets closed=true when the pull request is closed instead; dies on a conflict.
closed=false
rebuild() {
  local main=$1 out tree main_tree meta path omode nmode nsha status type got e entries
  git merge-base --is-ancestor "$SHA" "$main" || die "${SHA:0:12} is no longer on main"
  out=$(git merge-tree --write-tree --no-messages --merge-base="$SHA" "$main" "$parent") ||
    die "the revert of ${SHA:0:12} no longer applies on main ${main:0:12} (conflict); #$PR left as is"
  tree=${out%%$'\n'*}
  main_tree=$(git rev-parse "$main^{tree}")
  if [ "$tree" = "$main_tree" ]; then
    say "main ${main:0:12} already undoes ${SHA:0:12}; closing #$PR"
    owner pr close "$PR" --repo "$REPO" \
      --comment "**[automation]** \`main\` (${main:0:12}) already undoes ${SHA:0:12}: nothing left to revert." >/dev/null
    closed=true
    return 0
  fi

  entries='[]'
  git diff-tree -r -z --no-renames "$main_tree" "$tree" > "$work/diff"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    # ":<old mode> <new mode> <old sha> <new sha> <status>"
    # shellcheck disable=SC2086
    set -- $meta
    omode=${1#:} nmode=$2 nsha=$4 status=$5
    if [ "$status" = D ]; then
      type=blob
      [ "$omode" = 160000 ] && type=commit
      e=$(jq -n --arg p "$path" --arg m "$omode" --arg t "$type" '{path: $p, mode: $m, type: $t, sha: null}')
    elif [ "$nmode" = 160000 ]; then
      e=$(jq -n --arg p "$path" --arg s "$nsha" '{path: $p, mode: "160000", type: "commit", sha: $s}')
    else
      git cat-file blob "$nsha" | base64 | tr -d '\n' > "$work/blob"
      got=$(jq -n --rawfile c "$work/blob" '{content: $c, encoding: "base64"}' |
        bot api "repos/$REPO/git/blobs" --input - --jq '.sha')
      [ "$got" = "$nsha" ] || die "GitHub stored $path as $got, expected $nsha"
      e=$(jq -n --arg p "$path" --arg m "$nmode" --arg s "$nsha" '{path: $p, mode: $m, type: "blob", sha: $s}')
    fi
    entries=$(jq -c --argjson e "$e" '. + [$e]' <<<"$entries")
  done < "$work/diff"

  got=$(jq -n --arg b "$main_tree" --argjson t "$entries" '{base_tree: $b, tree: $t}' |
    bot api "repos/$REPO/git/trees" --input - --jq '.sha')
  [ "$got" = "$tree" ] || die "GitHub built tree $got, expected $tree"

  [ -n "$message" ] || message=$(bot api "repos/$REPO/git/commits/$HEAD_SHA" --jq '.message')
  head=$(jq -n --arg m "$message" --arg t "$tree" --arg p "$main" \
      '{message: $m, tree: $t, parents: [$p]}' |
    bot api "repos/$REPO/git/commits" --input - --jq '.sha')
  jq -n --arg s "$head" '{sha: $s, force: true}' |
    owner api -X PATCH "repos/$REPO/git/refs/heads/$branch" --input - >/dev/null
  base=$main
  say "main moved to ${main:0:12}: #$PR rebuilt as ${head:0:12}; ci runs again"
}

polls=0
while :; do
  polls=$((polls + 1))
  if [ "$polls" -gt "$MAX_POLLS" ]; then
    die "#$PR is still open after $MAX_POLLS checks, $((MAX_POLLS * POLL))s; it merges on its own if ci passes and main stays put"
  fi
  [ "$POLL" -gt 0 ] && sleep "$POLL"

  if ! view=$(owner pr view "$PR" --repo "$REPO" --json state,headRefOid --jq '.state + " " + .headRefOid'); then
    warn "cannot read #$PR; next check in ${POLL}s"
    continue
  fi
  read -r state pr_head <<<"$view"
  case "$state" in
    MERGED) say "#$PR merged"; exit 0 ;;
    CLOSED) say "#$PR was closed; nothing to do"; exit 0 ;;
  esac
  if [ "$pr_head" != "$head" ]; then
    say "$branch was moved to ${pr_head:0:12} by someone else; left as is"
    exit 0
  fi

  if ! git fetch -q "$REMOTE" "+refs/heads/main:refs/remotes/$REMOTE/main"; then
    warn "cannot fetch main; next check in ${POLL}s"
    continue
  fi
  main=$(git rev-parse "refs/remotes/$REMOTE/main")
  [ "$main" = "$base" ] && continue
  rebuild "$main"
  [ "$closed" = true ] && exit 0
done
