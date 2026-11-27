# Design: merge-through-github-queue

## Overview

GitHub merges every pull request through auto-merge. Renovate and the
automatic revert already work this way, and agents switch to it now.
`scripts/pr-merge.sh` stays the one command agents run, as a thin wrapper.
It takes the merge lock, rebases the branch with the operator's signing
key when it is behind, runs `gh pr merge <n> --auto --squash
--match-head-commit <sha>`, and polls GitHub's REST API until the pull
request is merged. It drops the guards CI already runs, the parsing of
`gh pr view` and `gh pr checks`, its own merge call and retry loop, and the
Renovate pause variable. The Renovate train gets a stateless hold in its
place: it rebases nothing while another pull request is in flight. Branch
protection, rulesets, the repository merge settings and Renovate's
configuration stay unchanged. So do `ci.yaml`, the automatic rollback and
the outage guard. With no queue, `ci` needs no `merge_group` trigger.

## What pr-merge.sh does today, and what replaces it

| Today (615 lines) | After |
| --- | --- |
| Guards `checks`, `title`, `subjects`, `verified`: `gh pr checks`, `check-title.sh`, the commits API | Removed. `ci` (`pr-metadata`) and the required signatures enforce them, and auto-merge waits for `ci` |
| Guards `mergeable`, `up-to-date` | Open, not draft and base `main` are read from REST; up to date comes from `compare` |
| Guard `merge-freeze` (`MERGE_FREEZE`, fail closed) | Kept, checked on every poll, with a per-PR exemption `(allow #<n>)` for the break-glass revert |
| `--ff` and its protection probe | `--ff` always refuses: `main` is protected |
| Merge lock and FIFO tickets in the git common dir | Kept unchanged, moved to `scripts/lib/merge_lock.sh` |
| Local rebase in a throwaway worktree, push with lease | Kept |
| `wait_for_ci` reading `gh pr view` and check runs | A poll of `pulls/<n>`, the `ci` workflow run, check runs and `compare`, all through `gh api` |
| `gh pr merge --squash --match-head-commit`, 3 retries when `main` moves | `gh pr merge --auto --squash --match-head-commit`, and GitHub merges; a behind head is rebased again (3 times at most) |
| `RENOVATE_TRAIN_PAUSED` set, refreshed, deleted; `renovate-next` dispatched | Removed. The train holds by itself (see [The Renovate train](#the-renovate-train)) |

#1793 (gh 2.106 hint) does not reproduce on `main`: #1500 already keeps
stderr out of `load_pr`, and a dry run with gh 2.106.0 runs every guard.
Task 2 closes it anyway, because no gh porcelain parsing is left and a
test feeds the hint to every call.

## Why there is no native merge queue

GitHub offers merge queues only in repositories owned by an organization.
`ned-si/homelab` belongs to the user account `ned-si`. The operator
rejected moving it to an organization on 2026-11-27. The move would also
have moved the published images to a new `ghcr.io` owner and changed the
OIDC trust of `bootstrap/github-oidc`, 74 Argo CD `repoURL` values and the
Scorecard and Best Practices entries.

## Why the wrapper stays

When `main` moves, an agent's pull request falls behind, and GitHub
auto-merge waits until someone updates the branch. The update must produce
signed commits, which leaves three options:

- **Local rebase with the operator's key, in the wrapper (chosen).** The
  commits stay the agent's own and signed, and no new token is needed.
- **The update-branch API (rejected).** Its merge-commit form creates a
  `Merge branch 'main'` commit that fails `pr-metadata`. Its rebase form
  creates unsigned commits: GitHub cannot sign a rebased commit for its
  author.
- **A workflow that rebuilds the branch through the Git Data API, as
  `auto-rollback-keep.sh` does for reverts (rejected).** GitHub would sign
  the commits in place of the agent. The push needs a token other than
  `GITHUB_TOKEN`, otherwise `ci` does not start. That would mean either
  widening `AUTO_ROLLBACK_TOKEN` to every pull request, or adding the
  GitHub App the operator rejected.

So the brief's "deprecate pr-merge.sh" becomes "shrink it": rebasing stays
on the Mac.

## Why the merge lock stays

Strict protection means only one pull request can merge per move of
`main`, but nothing stops several runs from rebasing and running `ci` at
the same time. The `ci` workflow has 16 jobs, and GitHub runs at most 20
jobs at once for a Free account (40 on Pro). Without the lock, N
concurrent runs cost N + (N-1) + ... + 1 `ci` runs instead of N. For the
6 runs open on 2026-11-27 that is 21 runs instead of 6, about 340 jobs
queued behind that limit, Renovate's included. The lock already exists,
is tested, and is shared with the old script during the cutover.
Rejected: ordering the runs through GitHub state (the oldest PR with
auto-merge on goes first). It has no heartbeat, so a run that dies leaves
its PR at the head of the order unless a new staleness rule is invented,
and it replaces tested code with new code for no gain on a single Mac.

## Technology stack

bash (3.2 on the Mac, 5 in CI), `gh` (2.106.0 on the Mac today; only
`gh api`, `gh pr merge` and `gh api user`), `jq`, `git`. GitHub auto-merge
and the classic branch protection of `main`. No new tool, token, workflow
or setting.

## The wrapper

### Files

- `scripts/pr-merge.sh`: the flow below, about 250 lines.
- `scripts/lib/merge_lock.sh`: `lock_acquire <branch>`, `lock_refresh`,
  `lock_release`, `ticket_drop`, moved from today's script minus the three
  `train_*` calls and the `paused`/`PAUSE_REFRESH` lines in
  `lock_refresh`; everything else verbatim. The caller provides `pr`,
  `POLL`, `LOCK_WAIT`, `LOCK_STALE_MIN`, `log`, `nap` and `now`, and the
  `lock_held`, `LOCK_DIR`, `QUEUE_DIR` and `ticket` globals. Lock and ticket paths,
  the `owner` and ticket file formats, and the stale rules stay as they
  are, so an old run and a new run see each other's lock and tickets.
- `scripts/lib/gh_var.sh`: unchanged. `gh_var_state MERGE_FREEZE` makes
  two calls and reads only the HTTP status line, from stdout.
- `scripts/ci/check-title.sh`: comment only (the wrapper no longer calls
  it).

### Command line and environment

`pr-merge.sh [--dry-run] [--ff] <pr-number>`. Anything else, or a number
that does not match `^[0-9]+$`, exits 64.

| Variable | Default | Validation |
| --- | --- | --- |
| `PR_MERGE_REPO` / `GH_VAR_REPO` | `ned-si/homelab` | `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, else exit 64 |
| `PR_MERGE_REMOTE` | `origin` | must be a git remote, else exit 1 |
| `PR_MERGE_POLL` | 30 | integer 0-600 |
| `PR_MERGE_LOCK_WAIT` | 3600 | integer >= 0 |
| `PR_MERGE_LOCK_STALE_MIN` | 30 | integer >= 1 |
| `PR_MERGE_CI_TIMEOUT` | 2700 | integer >= 0; the wait for one head, and for an open revert |
| `PR_MERGE_READ_RETRIES` | 5 | integer >= 1; consecutive read errors before exit 1 |
| `PR_MERGE_REVERT_STALE_MIN` | 70 | integer >= 1; age after which an open revert is stale |
| `PR_MERGE_NOW_EPOCH` | unset (`date +%s` at each read) | integer when set; for tests only |

A variable that fails its rule exits 64. `PR_MERGE_PAUSE_REFRESH` is
accepted and ignored, for callers that still set it. The wrapper exports
`GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`.

### Reading GitHub (the #1793 fix)

Every value comes from `gh api ... --jq`. Its stdout goes into a variable.
Its stderr goes to a temporary file, `$errlog`, truncated before each
call, so the file only ever holds the current call's stderr. No capture
uses `2>&1`, and no `gh pr view` or `gh pr checks` remains:

```sh
: > "$errlog"
rc=0
out=$(gh api "$route" --jq "$expr" 2>"$errlog") || rc=$?
why=$(grep -v -e '^hint:' -e '^[[:space:]]' "$errlog" | tail -n 1 | cut -c1-200)
```

`why` drops gh 2.106's hint block (lines starting with `hint:` and its
indented continuation lines), so an error message names the real error,
for example `gh: Not Found (HTTP 404)`. Each reader checks `rc` and
validates `out`:

| Reader | Call | Fields and validation |
| --- | --- | --- |
| `read_pr` | `repos/$REPO/pulls/$pr`, one `@tsv` line | `state` `open`/`closed`; `merged`, `draft` `true`/`false`; `base.ref`, `head.ref` `^[A-Za-z0-9._/-]+$`; `head.sha` 40-hex; `head.repo.full_name` repo pattern or empty; `user.login` `^[A-Za-z0-9-]+(\[bot\])?$`; auto-merge `on`/`off`; `merge_commit_sha` 40-hex when merged |
| `ci_state <sha>` | see [The `ci` state](#the-ci-state) | `missing`, `pending`, or a conclusion |
| `behind_by <sha>` | `repos/$REPO/compare/main...<sha>` `.behind_by` | `^[0-9]+$` |
| `open_reverts` | `repos/$REPO/issues?state=open&labels=auto-rollback&per_page=20`, pull requests only, `"\(.number)\t\(.created_at)"` per line | number `^[0-9]+$`, `created_at` `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`; its own number removed |
| `freeze` | `gh_var_state MERGE_FREEZE` (2 calls); when `present`, `repos/$REPO/actions/variables/MERGE_FREEZE` `.value` | `absent`, `present` with any value, or `error`; a failed value read is `error` |
| `me` | `user` `.login` | login pattern |

A failed call or a value that fails validation is a read error. The run
logs it, sleeps one poll and tries again. After `PR_MERGE_READ_RETRIES`
read errors in a row it exits 1 with `pr-merge: cannot read <what>:
<why>`. A hint gh prints on stderr therefore never reaches a decision. A
hint printed on stdout fails validation and becomes a read error, which is
visible and bounded.

### The `ci` state

The aggregate `ci` job `needs:` every other job, so GitHub creates its
check run only when they finish (4 to 8 minutes after the run starts). On
a rerun, the check-runs API keeps returning the previous attempt's `ci`
until the new `ci` job starts. So the wrapper decides "pending" from the
workflow run, and reads the conclusion from the check run only once the
run has completed:

1. `repos/$REPO/actions/workflows/ci.yaml/runs?head_sha=<sha>&event=pull_request&per_page=1`
   with `--jq '.workflow_runs[0] | if . == null then "missing" else "\(.status)\t\(.conclusion // "")" end'`.
   The newest run for the head comes first, and its `status` reflects its
   latest attempt. `status` must be one of `queued in_progress waiting
   requested pending completed`; `missing` is also valid. Anything other
   than `completed` gives `missing` or `pending`.
2. When `completed`: `repos/$REPO/commits/<sha>/check-runs?check_name=ci&per_page=100`,
   the latest run by `started_at`, its `conclusion`. With no `ci` check run
   (the run failed before its last job), the workflow run's `conclusion`.
   Either must be one of `success failure cancelled timed_out
   action_required neutral skipped stale startup_failure`.

### The freeze and its exemption

`freeze` decides, in this order: `error` refuses (`MERGE_FREEZE
unreadable`, fail closed); `absent` passes; `present` with a value ending
in `(allow #<pr>)` for this pull request passes and logs `MERGE_FREEZE is
set (<value>); PR #<pr> is allowed`; any other `present` refuses with
`MERGE_FREEZE is set: <first 200 characters>`. The match is portable to
bash 3.2:

```sh
re='\(allow #([0-9]+)\)$'
if [[ $val =~ $re ]] && [ "${BASH_REMATCH[1]}" = "$pr" ]; then allowed=1; fi
```

### Flow

1. Parse the arguments. `--ff` prints `refused: ff-protected: main is
   protected; squash only` and exits 2.
2. `read_pr`. If the PR is merged, print `pr-merge: PR #<n> already merged
   as <sha>` and exit 0. Refuse if it is closed, a draft, or based on a
   branch other than `main`. Apply the freeze rule. Then read `ci_state
   <head>` and `behind_by <head>`. Refuse if `ci` completed without
   success. Each refusal prints `refused: <guard>: <reason>`, then
   `pr-merge: REFUSED PR #<n> (<k> guard failure(s)); nothing merged`, and
   exits 2. The format is today's.
3. `--dry-run` also refuses a pending or missing `ci` and a behind head
   (`head does not contain main <sha7>; rebase first`), as today.
   Otherwise it prints `would merge (squash) PR #<n> at <sha>` and exits
   0. It takes no lock and changes nothing.
4. If the PR is up to date and `ci` is pending, wait outside the lock
   (step 7's poll without enabling anything), as today, so that a failing
   `ci` refuses before the run queues.
5. `lock_acquire <head.ref>`.
6. Inside the lock, loop:
   1. `read_pr` and the step 2 guards. A merged PR exits 0.
   2. `open_reverts`. A revert whose age (now minus `created_at`, through
      `jq -rn --arg t "$t" '$t | fromdateiso8601'`) is at least
      `PR_MERGE_REVERT_STALE_MIN` minutes is logged once per run as
      `ignoring stale revert #<m> (opened <created_at>)`. While a younger
      one is open, log `waiting for the revert #<m>` once a minute and
      call `lock_refresh`. After any wait, go back to step 6.1, so the
      guards and the freeze are read again. Give up after
      `PR_MERGE_CI_TIMEOUT` with exit 1.
   3. If `behind_by > 0`, refuse when the branch is not ours to rebase
      (`head.repo.full_name` differs from `$REPO`, or the author is not
      `me`), the same rule as today. Then run `git fetch --quiet "$REMOTE"
      main "$head"` (a failed fetch exits 1 with `cannot fetch $REMOTE main
      and the head commit`), set `main_sha=$(git rev-parse
      "refs/remotes/$REMOTE/main")`, log `pr-merge: rebasing <branch> onto
      <remote>/main <sha7>`, rebase onto `main_sha` in a throwaway
      worktree, with the rebase's stderr in a temporary file, push with
      `--force-with-lease=refs/heads/<ref>:<old>` and log `pr-merge:
      pushed <branch> at <sha>` (today's lines). A failed
      rebase is refused (exit 2) with `refused: up-to-date: signing failed
      (Bitwarden locked?)` when that stderr contains `agent refused
      operation`, and `refused: up-to-date: rebase onto main failed;
      rebase it by hand` otherwise. A failed push exits 1. After the 4th
      rebase in one run (3 retries, today's limit) it exits 1 with `main
      kept moving`.
   4. `read_pr`. If auto-merge is `on`, set `am_seen=1`, log `pr-merge:
      auto-merge already on for PR #<n>` and go to step 7: a push by a
      user with write access leaves it on, as `auto-rollback-keep.sh`
      relies on. If it is `off` and `am_seen=1`, someone else turned it
      off: exit 1 with `auto-merge was turned off on PR #<n>; nothing
      merged`, without requesting it again. If it is `off` and `am_seen`
      is unset, apply the freeze rule again (a freeze that does not allow
      this PR refuses with exit 2 and nothing is requested), then run `gh
      pr merge <n> --repo $REPO --auto --squash --match-head-commit
      <head>`, with stdout to `/dev/null` and stderr to the truncated
      `$errlog`. Only its exit code is used. On exit 0, set `am_seen=1`,
      log `pr-merge: auto-merge on for PR #<n> at <sha7>` and go to step 7
      (gh may already have merged it; the poll sees that). On a non-zero
      exit, `read_pr` again: merged exits 0; auto-merge `on` with
      `head.sha` equal to this run's head sets `am_seen=1` and goes to
      step 7; up to date with a green `ci` is merged directly with `gh pr
      merge <n> --repo $REPO --squash --match-head-commit <head>`
      (requirement 1.6), after the freeze rule is applied once more, and
      read again; anything else exits 1 with `cannot enable auto-merge:
      <why>`.
7. Poll every `PR_MERGE_POLL` seconds for at most `PR_MERGE_CI_TIMEOUT`
   per head, calling `lock_refresh` each time. The checks run in this
   order:
   1. merged: print `pr-merge: merged PR #<n> as <merge_commit_sha>` and
      exit 0;
   2. closed: refuse;
   3. `head.sha` is not this run's head: exit 1, `head moved to <sha7> by
      someone else`;
   4. the freeze refuses, or cannot be read (fail closed): `gh pr merge
      <n> --repo $REPO --disable-auto`, then refuse;
   5. `ci` completed without success: refuse, `ci is <conclusion> on
      <sha7>`, with auto-merge left on, so that a rerun that passes still
      merges;
   6. auto-merge off (`am_seen=1` by now): exit 1, `auto-merge was turned
      off on PR #<n>; nothing merged`, whether the PR is behind or not;
   7. `behind_by > 0`: back to step 6.1;
   8. otherwise keep waiting.
   At the deadline the run exits 1 with `timed out after <m> min waiting
   for ci on <sha7>; auto-merge stays on`.
8. The traps on EXIT, INT and TERM remove the rebase worktree and the
   temporary files, drop the ticket and release the lock (only the lock
   this run owns, as today). Auto-merge is left as it is.

The freeze check (7.4) and the auto-merge-off check (7.6) come before the
behind check (7.7), so a wrapper never rebases and turns auto-merge on
again once a freeze is set or someone else turned auto-merge off.

The squash commit is GitHub's, built as it is today: the title follows
`COMMIT_OR_PR_TITLE` plus ` (#<n>)`, the body `COMMIT_MESSAGES`, and
GitHub's key signs it. The merge is attributed to the user who enabled
auto-merge, the operator's gh account. The push to `main` therefore starts
the push workflows (`ci`, `renovate-next`, `scorecard`, the publish
workflows), as a merge by `gh pr merge --squash` does today.

### How agents merge

`scripts/pr-merge.sh <n>`, once, and let it run, as before. When the
wrapper cannot run (it is broken, or the brief asks for a merge from
outside the repository), the fallback is `gh pr merge <n> --repo
ned-si/homelab --auto --squash`, after rebasing by hand with
`--force-with-lease` whenever the PR falls behind. Never use the
update-branch button or API.

## The Renovate train

The train (`renovate-next`) stays. Renovate rebases only on conflicts
(`rebaseWhen: conflicted`), so without the train no Renovate pull request
would get back up to date after a merge. Rebasing them all on every merge
(`behind-base-branch`) would start one `ci` run per open Renovate PR for
each merge, against the 20-job limit. `.github/renovate.json5` keeps
`automerge: true`, `automergeType: 'pr'` and `platformAutomerge: true`:
Renovate turns GitHub auto-merge on, and the train turns it on where
Renovate did not (#837).

One change in `scripts/ci/renovate-next.sh`: a hold, placed right after
the `auto-rollback` hold and before the release-age comments, so nothing
is commented, ticked or turned on during it. It lists every open pull
request:

```sh
inflight=$($GH pr list --repo "$REPO" --state open --limit 100 \
  --json number,author,isDraft,autoMergeRequest,headRefOid,statusCheckRollup \
  --jq '.[] | select(.author.login != "app/renovate" and (.isDraft | not) and .autoMergeRequest != null)
    | select([.statusCheckRollup[]? | select(.__typename == "CheckRun" and .workflowName == "ci" and .status != "COMPLETED")] | length > 0)
    | "\(.number)\t\(.headRefOid)"')
```

For each line, `behind "$sha"` (the existing compare call) is checked; the
first one at `0` stops the run with `held by #<n> (auto-merge on, up to
date, ci running); nothing rebased` and exit 0. The workflow already
writes that line to the step summary.

The jobs of the `ci` workflow are created when its run starts, so the
hold covers the whole run, not only the last seconds when the aggregate
`ci` job exists. A rerun counts too: its rerun jobs are not completed. The
hold clears itself: the candidate's `ci` finishes within the `ci`
workflow's job timeouts, and the PR then either merges, which moves
`main` and starts `renovate-next` on push, or fails, which leaves the
train to its 30-minute schedule. A PR with no `ci` check run yet (the few
seconds between a push and the run's start) does not hold. Check runs of
other workflows do not hold. The hold replaces the pause variable, and it
also covers a PR merged with the direct `gh pr merge --auto` fallback.
`RENOVATE_TRAIN_PAUSED` stays as a manual pause; nothing sets it once the
old script is gone. A Renovate PR that was already rebased can still merge
during a hold. That is #960, unchanged: the wrapper rebases again.

## CI

No change to `.github/workflows/ci.yaml`. `ci` stays the only required
check, on `pull_request` (the PR head) and on `push` to `main`. A
`merge_group` trigger is needed only for a merge queue, which this
repository cannot have.

## Protection and merge settings

Nothing changes them. These commands record them before task 1 merges and
after task 5 (acceptance criterion 8). The values match the settings
saved by this run on 2026-11-27, read again the same day.

```sh
gh api repos/ned-si/homelab/branches/main/protection | jq -cS '{strict: .required_status_checks.strict, checks: [.required_status_checks.checks[] | "\(.context)/\(.app_id)"], reviews: .required_pull_request_reviews.required_approving_review_count, dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews, code_owners: .required_pull_request_reviews.require_code_owner_reviews, last_push: .required_pull_request_reviews.require_last_push_approval, signatures: .required_signatures.enabled, admins: .enforce_admins.enabled, linear: .required_linear_history.enabled, force_pushes: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled, creations: .block_creations.enabled, conversations: .required_conversation_resolution.enabled, lock: .lock_branch.enabled, fork_sync: .allow_fork_syncing.enabled}'
gh api repos/ned-si/homelab/rulesets | jq -c length
gh api repos/ned-si/homelab | jq -cS '{allow_auto_merge, allow_merge_commit, allow_rebase_merge, allow_squash_merge, allow_update_branch, delete_branch_on_merge, merge_commit_message, merge_commit_title, squash_merge_commit_message, squash_merge_commit_title, web_commit_signoff_required}'
```

Expected output, three lines:

```text
{"admins":true,"checks":["ci/15368"],"code_owners":false,"conversations":false,"creations":false,"deletions":false,"dismiss_stale":true,"force_pushes":false,"fork_sync":false,"last_push":false,"linear":true,"lock":false,"reviews":0,"signatures":true,"strict":true}
0
{"allow_auto_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"allow_squash_merge":true,"allow_update_branch":false,"delete_branch_on_merge":true,"merge_commit_message":"PR_TITLE","merge_commit_title":"MERGE_MESSAGE","squash_merge_commit_message":"COMMIT_MESSAGES","squash_merge_commit_title":"COMMIT_OR_PR_TITLE","web_commit_signoff_required":false}
```

`15368` is the GitHub Actions app. Strict `ci` keeps merges serialised,
signed commits stay required (GitHub signs its squash commits),
`dismiss_stale_reviews` stays on, and no approvals are required. Renovate
automerge and "no human gates" therefore work as today. If any line
differs, stop the cutover and restore it with
[Restoring the settings](#restoring-the-settings).

### OpenSSF Scorecard

Branch-Protection reads the classic protection of `main`, which does not
change, so it stays at 4. That is the accepted gap of no required
approvals, in docs/decisions.md under "No human gates". The Scorecard API
read 4 on 2026-11-27 (overall 8.4). Check after task 4:

```sh
curl -sS -m 10 https://api.securityscorecards.dev/projects/github.com/ned-si/homelab | jq -c '{date, bp: [.checks[] | select(.name == "Branch-Protection") | .score]}'
```

Expected: a `date` after the task 4 merge and `"bp":[4]`.

## Automatic rollback and the outage guard

`auto-rollback.yaml`, `auto-rollback-decide.sh`, `-guard.sh`, `-act.sh`
and `-keep.sh` do not change. The revert PR already merges through
auto-merge enabled with `AUTO_ROLLBACK_TOKEN`, and `-keep.sh` already
rebuilds it whenever `main` moves. The change protects it in two ways.
The train keeps its hold while an `auto-rollback` PR is open (#1516). The
wrapper no longer rebases or turns on auto-merge while a revert younger
than 70 minutes is open (step 6.2), so agent merges do not keep moving
`main` under the revert during the hour `-keep.sh` waits. A revert that
`-keep.sh` has given up on (as #989 once was) is ignored, so it cannot
stall every agent merge. The outage guard reads only workflow runs and the
ntfy guard topic, and nothing here touches either.

## Documentation and the skills

| File | Change |
| --- | --- |
| `README.md` | "How changes reach the cluster" step 3 rewritten for the wrapper (lock, rebase, auto-merge, poll); the `ci` sentence and the `scripts/` row keep naming `pr-merge.sh` |
| `docs/decisions.md` | "Squash merge": GitHub squash-merges through auto-merge, requested by `pr-merge.sh`; `--ff` removed; new paragraphs on why there is no merge queue (user-owned repository), why the rebase stays local (signatures) and why the lock stays (`ci` cost). "main is production": the gate sentence names `ci` and auto-merge |
| `docs/dependencies.md` | "How updates merge": the train holds while another PR is in flight |
| `GOVERNANCE.md` | The AI agents row: "merge only through `scripts/pr-merge.sh` (GitHub auto-merge), only on a green `ci`" |
| `docs/runbooks/netpol-enforcement.md`, `docs/runbooks/pod-security.md` | See [The break-glass runbooks](#the-break-glass-runbooks) |
| `.kiro/specs/netpol-default-deny/` (active, #709) | design D6 steps 2 and 3, its merges row in the failure table, and requirements acceptance criterion 1 of the break-glass requirement: "set `MERGE_FREEZE`, wait 60 s, then turn auto-merge off on every open PR; the revert is allowed with `(allow #<n>)`" instead of telling every other runner to stop |
| `.kiro/specs/gitops-delivery/` | The `pr-merge.sh` row and requirement 3: "auto-merge on a green `ci`, requested inside the merge lock"; the flowchart label |
| `scripts/ci/renovate-next.sh`, `.github/workflows/renovate-next.yaml` | Task 1: the hold in the header comment. Task 2: `RENOVATE_TRAIN_PAUSED` described as a manual pause (no longer "set by scripts/pr-merge.sh"), and the workflow comment that says `pr-merge.sh` pauses and dispatches the train |

`docs/testing.md` does not describe merging and stays as it is. So does
`SECURITY.md`, which still says "merged by `scripts/pr-merge.sh`". Done
specs are history and stay as they are; active specs that describe the
hold are updated.

### The break-glass runbooks

Both runbooks have "Hold every merge", "Revert" and "Release the hold".
The new steps, in this order:

Hold every merge:

1. Stop the Renovate train, unchanged
   (`gh workflow disable renovate-next.yaml -R ned-si/homelab`).
2. New. Set the freeze, then wait for running wrappers to see it:

   ```sh
   gh variable set MERGE_FREEZE -R ned-si/homelab --body "<reason>"
   sleep 60
   ```

   Expected: no output, exit 0. A wrapper sees the freeze at its next
   poll (30 s), turns its own auto-merge off and stops; 60 s covers one
   poll and its calls.
3. Today's step 2, unchanged: the `--disable-auto` loop over every open PR
   with auto-merge on, and the `held:` list.

Today's step 3 ("tell every other runner to stop merging") is removed: the
freeze does it.

Revert, step 1: after `gh pr create`, and before `bash scripts/pr-merge.sh
<pr>`:

```sh
gh variable set MERGE_FREEZE -R ned-si/homelab --body "<reason> (allow #<revert-pr>)"
```

Expected: no output, exit 0. The wrapper merges the revert; every other
PR is still refused.

Release the hold: `gh variable delete MERGE_FREEZE -R ned-si/homelab`
first (expected: `✓ Deleted variable MERGE_FREEZE from ned-si/homelab`),
then today's two lines.

The freeze must come before the `--disable-auto` loop. In the other order,
a wrapper polling a behind PR between the two steps rebases it and turns
its auto-merge on again, and the `held:` list is wrong.

### The skills and the local notes

The run-conventions and homelab-context skills are local operator files,
not in git. There is no Claude Code link for either, and none is added.
Before editing, a copy of each is kept in this run's local task
directory. The run-conventions merge bullet becomes: merge with
`scripts/pr-merge.sh <n>`, once; it takes the merge lock, rebases when
behind, turns on GitHub auto-merge (`gh pr merge --auto --squash`) and
returns when GitHub has merged; a refusal leaves auto-merge on, so a
passing rerun of a transient failure still merges; a rerun is pending, not
failed, while it runs; `signing failed (Bitwarden locked?)` means pause
and ask the operator to unlock it; the fallback is `gh pr merge <n> --auto
--squash` with a manual rebase; never use update-branch. The
homelab-context skill's "Merge only with `scripts/pr-merge.sh <n>`" line
and its Renovate line ("the `renovate-next` train ... held while another
PR is in flight") change the same way. The operator's local handover
notes drop the line saying `pr-merge.sh` still needs a `gh` shim.

## Cutover

Order (each step one PR, tasks.md):

1. Train hold (task 1), merged in the live window, after the settings
   check. It is additive. While old runs still set
   `RENOVATE_TRAIN_PAUSED`, both holds apply.
2. Wrapper (task 2), merged in the live window. Merge it with the
   `scripts/pr-merge.sh` of `origin/main` (run from a worktree at
   `origin/main`), not with the branch's own copy, so that a bug in the
   new wrapper cannot block its own merge.
3. Skills and local notes (task 3), right after task 2 merges.
4. Docs (task 4), merged with the new wrapper. It is the docs-only test
   PR.
5. A Renovate PR merged through the train after task 4, then the settings
   and Scorecard checks (task 5).

Runs that are merging now are not disturbed:

- Branch protection is never written, so no merge can see it change.
- A run that started before task 2 keeps executing the script file of its
  own worktree. The rebase happens in a throwaway worktree, so that file
  does not change under the running bash.
- Old and new runs take tickets in the same queue and the same lock, in
  FIFO order.
- Old runs still pause the train through the variable, which the train
  still honours.
- A run that starts after its worktree has `main` with task 2 uses the
  wrapper.

Before task 2 merges, the lock is held by its own run, which has the oldest
ticket, so no other merge is in progress inside the lock.

## Rollback

Each task reverts on its own: a `git revert` of its squash commit on a
branch from `origin/main`, a PR, and a merge with `scripts/pr-merge.sh`.
If the wrapper is what broke, use the fallback (`gh pr merge <n> --repo
ned-si/homelab --auto --squash`, with a manual rebase when behind).

| What | Symptom | Rollback |
| --- | --- | --- |
| Task 1, train hold | `renovate-next` prints `held by #<n>` for over an hour while #<n> is not merging | At once: `gh pr merge <n> -R ned-si/homelab --disable-auto` ends the hold. Then revert task 1 |
| Task 2, wrapper | A merge fails in a way the old script did not | Revert task 2. The old script comes back with its lock (same files) and the train pause; reopen #1793 if its hint returns |
| Task 3, skills | Agents follow the wrong rule | Restore the saved copies |
| Task 4, docs | Wrong text | Revert task 4 |

### Restoring the settings

Only needed if the check under
[Protection and merge settings](#protection-and-merge-settings) shows a
difference. It restores exactly the values saved on 2026-11-27: the
classic protection, no rulesets, and the merge settings. Admin token, live
window:

```sh
gh api -X PUT repos/ned-si/homelab/branches/main/protection --input - >/dev/null <<'EOF'
{"required_status_checks":{"strict":true,"checks":[{"context":"ci","app_id":15368}]},
 "enforce_admins":true,
 "required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":false,"require_last_push_approval":false,"required_approving_review_count":0},
 "restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false,
 "block_creations":false,"required_conversation_resolution":false,"lock_branch":false,"allow_fork_syncing":false}
EOF
gh api -X POST repos/ned-si/homelab/branches/main/protection/required_signatures >/dev/null
gh api repos/ned-si/homelab/rulesets --jq '.[].id' | while read -r id; do
  gh api -X DELETE "repos/ned-si/homelab/rulesets/$id"
done
gh api -X PATCH repos/ned-si/homelab -F allow_merge_commit=false -F allow_squash_merge=true \
  -F allow_rebase_merge=false -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_update_branch=false -F web_commit_signoff_required=false \
  -f squash_merge_commit_title=COMMIT_OR_PR_TITLE -f squash_merge_commit_message=COMMIT_MESSAGES \
  -f merge_commit_title=MERGE_MESSAGE -f merge_commit_message=PR_TITLE >/dev/null
```

Expected: no output, exit 0. Then the three check commands print the
expected lines. `use_squash_pr_title_as_default` (saved as `false`) is
not set: GitHub derives it from `squash_merge_commit_title`.

## Error handling

| Operation | Failure | Kind | Caller gets | Logged |
| --- | --- | --- | --- | --- |
| Arguments, environment | bad flag, number, knob | fatal | exit 64, usage on stderr | stderr |
| `read_pr`, `ci_state`, `behind_by`, `open_reverts`, `me` | gh exit != 0, or a value fails validation | recoverable up to `READ_RETRIES` in a row | then exit 1, `cannot read <what>: <why>` | each retry on stdout, the error on stderr |
| `freeze` | `gh_var_state` prints `error`, or the value read fails | fatal (fail closed) | exit 2, `MERGE_FREEZE unreadable` | stdout |
| Guards | closed, draft, base, freeze, `ci` failed, not ours to rebase, `--ff` | fatal | exit 2, `refused:` lines and the summary | stdout |
| Lock | wait over `LOCK_WAIT`; not inside a repository | fatal | exit 1, nothing merged | stderr; waits once a minute on stdout |
| Revert wait | a revert younger than the stale bound still open after `CI_TIMEOUT` | fatal | exit 1 | stderr; waits once a minute on stdout |
| Rebase | signing agent refused | fatal | exit 2, `signing failed (Bitwarden locked?)`; the agent pauses and asks the operator | stdout |
| Rebase | conflict or other failure | fatal | exit 2, `rebase it by hand` | stdout |
| Push | lease rejected, network | fatal | exit 1 | stderr |
| Request the merge | gh exit != 0, then not merged, auto-merge not on at the head, not directly mergeable | fatal | exit 1, `cannot enable auto-merge: <why>` | stderr |
| Direct merge (1.6) | gh exit != 0 and not merged after | fatal | exit 1 | stderr |
| Poll | head moved, auto-merge off, timeout, `main kept moving` | fatal | exit 1, auto-merge left as it is | stderr |
| Poll | `ci` failed, closed, freeze set or unreadable | fatal | exit 2; auto-merge turned off on a freeze or an unreadable freeze, else left on | stdout |
| Train hold | `gh pr list` or `compare` fails | fatal for the run (`set -e`), as the train's other calls are | a red `renovate-next` run; the next trigger retries | the Actions log |

The wrapper never prints a token. gh's error lines contain no token.

## Invariants and who enforces them

| Invariant | Owner | Why there |
| --- | --- | --- |
| Only a green, up-to-date, signed PR reaches `main` | Branch protection (strict `ci`, signatures, enforce admins) | It holds for every merge path: wrapper, Renovate, revert, a person |
| Titles and commit subjects pass, every commit is verified | `ci` / `pr-metadata` | CI is the only gate; the wrapper no longer repeats it |
| One rebase-and-CI round at a time on the Mac | The merge lock | Local, already shared by every run |
| The train does not move `main` under an agent merge | `renovate-next.sh` hold | It is the one that would move it; it reads GitHub state, so nothing can go stale |
| No merge during a hold except the revert | The freeze in the wrapper, with its `(allow #<n>)` exemption; auto-merge off in the runbook | The runbook turns auto-merge off; the freeze keeps running wrappers from turning it on again and lets only the named revert through |
| Reverts first, without stalling forever | The train's hold and the wrapper's revert wait with its 70-minute bound | The two automatic movers of `main`; the bound matches `-keep.sh`'s lifetime |

## Testing

All unit tests run offline in the `tests` job (`tests/run-bash-tests.sh`)
with the fake `gh` of `tests/bash/lib.sh`, extended so that `pr merge`
records its flags and exits with `FAKE_MERGE_RC`, so that a sequence file
serves successive answers to one REST route (`pulls/7` open, then merged),
and so that a route can print a body on stderr and exit 1 (the
`HTTP 404` case). The fake already prints `stderr-hint` before every call
and applies `--jq` with jq.

- `tests/bash/test_pr_merge.sh`, rewritten: every case of acceptance
  criterion 1, and the #1793 cases of criterion 2, with `PR_MERGE_POLL=0`.
  The revert age cases set `PR_MERGE_NOW_EPOCH`; the rebase-signing case
  uses a git `gpg.ssh.program` stub that prints `agent refused operation`
  and exits 1.
- `tests/bash/test_pr_merge_lock.sh`: the routes move to REST, the
  assertions stay, and the train-pause cases are removed.
- `tests/bash/test_renovate_next.sh`: the hold cases of criterion 4, with
  the fake answering the all-authors `gh pr list` call.
- shellcheck through `lint`.

The integration checks are live, in tasks 4 and 5: the docs PR through the
wrapper, the train's `held by` line during its `ci`, the push runs on its
merge SHA, a Renovate merge, the settings, and Scorecard.

## Edge cases

- **Already merged when the wrapper starts, or merged between two polls**:
  exit 0 with the merge SHA.
- **Mergeable already when the wrapper requests the merge**: gh merges at
  once; the next poll sees it merged.
- **Auto-merge already on (a rerun of the wrapper, or after its own
  push)**: it is not requested again.
- **GitHub refuses to turn on auto-merge**: the fresh read decides (merged,
  on at the head, or the direct merge of 1.6).
- **`ci` missing right after a push**: counted as pending until
  `PR_MERGE_CI_TIMEOUT`.
- **A transient `ci` failure**: exit 2 with auto-merge left on. The agent
  runs `gh run rerun --failed` once and calls the wrapper again; the rerun
  counts as pending while it runs. The passing rerun merges on its own if
  `main` has not moved.
- **Renovate merges during the wait**: the head falls behind; rebase,
  push, wait (at most 3 retries).
- **The wrapper is killed after enabling auto-merge**: GitHub still merges
  on green if `main` has not moved. Otherwise the PR waits with auto-merge
  on, and the next call rebases it.
- **An old-script run holds the lock**: the wrapper waits in FIFO order;
  the old run's pause is honoured by the train.
- **A fork PR, or another author's**: refused when behind, as today.
- **A freeze set while waiting**: auto-merge off, exit 2, unless it allows
  this PR.
- **A stale revert left open**: ignored by the wrapper and logged; the
  train still holds on it, as today (#1003).
- **Bitwarden locked**: the rebase cannot sign; `signing failed (Bitwarden
  locked?)`, exit 2, nothing pushed.
- **The operator's Mac is asleep while a run waits**: the lock goes stale
  after 30 minutes, as today. Auto-merge, once on, does not depend on the
  Mac.

## Responses to the review of 2026-11-27

| Finding | Response |
| --- | --- |
| 1. The train hold keyed on the aggregate `ci` check run | Addressed: in flight is any unfinished check run of the `ci` workflow, plus up to date; glossary, 3.2, AC 4 and [The Renovate train](#the-renovate-train) |
| 2. The freeze blocks the runbook's revert | Addressed: the `(allow #<n>)` exemption ([The freeze and its exemption](#the-freeze-and-its-exemption)), the revert step that sets it, AC 1.6 |
| 3. `ci_state` reads the old failed `ci` during a rerun | Addressed: pending from the workflow run, conclusion from the check run ([The `ci` state](#the-ci-state)); NFR call count; AC 1.7 |
| 4. Enabling auto-merge again after a push | Addressed: step 6.4 requests it only when off and re-reads on failure; requirement 1.7; AC 1.3 and 1.8 |
| 5. The error message showed a hint line | Addressed: `$errlog` truncated per call, hint lines filtered; AC 2 |
| 6. Auto-merge off before the freeze in the runbooks | Addressed: the freeze first, a 60 s wait, then the loop ([The break-glass runbooks](#the-break-glass-runbooks)); 60 s instead of 30 s to cover the calls of one poll |
| 7. A stale revert stalls every agent merge | Addressed: the 70-minute bound, `PR_MERGE_REVERT_STALE_MIN`; AC 1.11. The train's own hold on a stale revert is unchanged and out of scope |
| 8. AC 6 by chance | Addressed: the procedure in task 4 (a behind docs PR, then a dispatched `renovate-next`) |
| 9. Issue and spec name | Issue title and body edited to the auto-merge plan. The directory keeps its name, because the board, the issue and this run's pipeline use it; the introduction says so |
| 10. #1793 does not reproduce | Addressed: the introduction and [What pr-merge.sh does today](#what-pr-mergesh-does-today-and-what-replaces-it) say so; task 2 still closes it |
| 11. gh merges at once on `--auto` | Addressed: glossary, requirement 1.1, step 6.4, AC 1.2 |
| 12. Before which task | Addressed: "before task 1 merges and after task 5" in 4.1, 5.4, AC 8, the settings section and tasks |
| 13. The restore omitted fields and rulesets | Addressed: the PATCH sets every saved field but the derived `use_squash_pr_title_as_default`, a rulesets delete loop, and the third check command now prints those fields |
| 14. Skill paths, the `.claude` link, the handover notes | Partly: the spec says there is no Claude Code link and none is added, that copies are kept first, and that the handover notes drop the shim line. The exact local paths stay out of this public spec (local-only paths are never written into committed files); the run's local task notes carry them |
| 15. Task 1 in the live window | Addressed in tasks.md |
| 16. Precision gaps | Addressed: the step-4 cost in the NFR, `--repo` on `--disable-auto`, the hold placement with `$GH` and `.author.login != "app/renovate"`, the signing-failure message |
