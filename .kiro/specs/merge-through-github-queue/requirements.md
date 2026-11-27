---
kind: change
status: active
created: 2026-11-27
issue: 1832
---

# Requirements: merge-through-github-queue

## Introduction

Every pull request in this repository lands on `main` through
`scripts/pr-merge.sh` (agents) or GitHub auto-merge (Renovate, automatic
reverts). The script has grown to 615 lines: guards that CI already runs, a
merge lock with a FIFO ticket queue in the git common dir, a local rebase,
a wait on `ci` that reads `gh pr view` and `gh pr checks`, the squash
merge, three retries when `main` moves, and a pause of the Renovate train
through the repository variable `RENOVATE_TRAIN_PAUSED`. Reading gh's
porcelain output has broken it before: the gh 2.105 stderr hint (#1480,
fixed in #1500). #1793 reports the same breakage with gh 2.106. Its cause
no longer exists on `main`: a dry run with gh 2.106.0 runs every guard,
because #1500 already keeps stderr out of `load_pr`. This change closes
#1793 because no gh porcelain parsing is left, and a test covers the hint.

The first plan was GitHub's native merge queue. It cannot be enabled here:
merge queues are only available in repositories owned by an organization,
and `ned-si/homelab` is owned by the user account `ned-si` (the API reports
`owner.type: User`; GraphQL `mergeQueue(branch: "main")` is `null`). The
operator rejected moving the repository to an organization on 2026-11-27,
as well as a custom merge server and a GitHub App for tokens. His
decision (2026-11-27): stay user-owned and merge through GitHub
auto-merge. Agents enable it with `gh pr merge --auto --squash`, the
strict "up to date before merging" protection keeps merges serialised,
`scripts/pr-merge.sh` shrinks to a thin compatible wrapper that parses no
gh porcelain output, Renovate automerge keeps working, and the automatic
rollback and its outage guard keep working.

The directory keeps the name `merge-through-github-queue`, which the
board, issue #1832 and this run's pipeline already use; the queue in
question is GitHub's auto-merge.

## Glossary

- **Auto-merge**: GitHub's pull request auto-merge. Once enabled, GitHub
  squash-merges the pull request as soon as the protection of `main` is
  met: `ci` green on the head, the head up to date with `main`, every
  commit verified. gh 2.106 `gh pr merge --auto` merges at once, without
  enabling auto-merge, when the merge state is already `CLEAN`,
  `HAS_HOOKS` or `UNSTABLE`.
- **Wrapper**: `scripts/pr-merge.sh` after this change.
- **Merge lock**: `pr-merge.lock` and the ticket queue `pr-merge.queue/` in
  `$(git rev-parse --git-common-dir)`, shared by every run on the operator's
  Mac.
- **Renovate train**: `.github/workflows/renovate-next.yaml` and
  `scripts/ci/renovate-next.sh`, which rebase one Renovate pull request at
  a time.
- **In flight**: an open, non-draft pull request not authored by Renovate,
  with auto-merge on, up to date with `main`, with at least one check run
  of the `ci` workflow on its head not completed. The `ci` workflow's jobs
  exist from the start of its run; the aggregate `ci` job exists only at
  its end, so it cannot be the signal.
- **Freeze**: the repository variable `MERGE_FREEZE`. Its value is a
  reason, optionally ending with `(allow #<n>)`, which lets pull request
  `<n>` through.
- **Stale revert**: an open pull request labelled `auto-rollback` opened
  more than 70 minutes ago. `auto-rollback-keep.sh` stops looking after
  60 minutes (60 polls of 60 s); the rest is margin.
- **Live window**: Monday to Friday, 08:00 to 21:00 UTC.

## Requirement 1: Agents merge through GitHub auto-merge

**User story:** As the operator, I want agent pull requests merged by
GitHub on a green `ci`, so that merging does not depend on parsing gh's
human output and a merge still happens if the run that asked for it dies.

1. THE wrapper SHALL request the merge with
   `gh pr merge <n> --auto --squash --match-head-commit <sha>` (gh merges
   at once when the pull request is already mergeable, and otherwise
   enables auto-merge) and SHALL NOT merge by any other path, except the
   direct squash merge of 1.6.
2. THE wrapper SHALL read GitHub state only through `gh api` (REST JSON
   with `--jq`), SHALL never capture gh's stderr into a value it parses,
   and SHALL validate every value it reads against its expected shape
   (40-hex SHA, integer, timestamp, enumerated state). A value that fails
   validation SHALL be a read error, never a decision. Error messages
   SHALL quote the last stderr line of the failing call that is not part
   of a gh hint.
3. WHEN the pull request is behind `main`, THE wrapper SHALL rebase it
   locally (signed by the operator's key) and push it with
   `--force-with-lease`, only for a branch of this repository authored by
   the gh user, as today. It SHALL never call the update-branch API. A
   rebase that fails because the signing agent refused SHALL say so.
4. THE wrapper SHALL keep the command line `pr-merge.sh [--dry-run] [--ff]
   <pr-number>`, the exit codes 0 (merged, would merge), 2 (refused), 1
   (operational error) and 64 (usage), and the `PR_MERGE_*` environment
   knobs it still uses.
5. THE wrapper SHALL refuse (exit 2) a closed, draft or non-`main` pull
   request, a set freeze unless its value ends with `(allow #<n>)` for
   this pull request, an unreadable freeze, a `ci` that completed without
   success on the head, and a rebase that fails. A `ci` run that is
   queued or running on the head (a rerun included) SHALL count as
   pending, whatever an earlier attempt concluded. `--ff` SHALL refuse,
   because `main` is protected.
6. WHEN requesting the merge fails, and a fresh read shows the pull request
   neither merged nor with auto-merge on at the run's head, and it is up
   to date with a green `ci`, THE wrapper SHALL squash-merge it directly
   with `--match-head-commit`.
7. THE wrapper SHALL enable auto-merge only when it is off, and SHALL
   return only once the pull request is merged (printing the merge commit
   SHA) or a refusal or error ends the run. It SHALL leave auto-merge on
   when it ends without a merge, and SHALL stop (exit 1) when someone else
   turns auto-merge off or moves the head, whether the pull request is
   behind or not, without rebasing or enabling auto-merge again. WHEN a
   freeze that does not allow this pull request is set, or the freeze
   cannot be read, while it waits, it SHALL turn its own auto-merge off
   and refuse. THE wrapper SHALL read the freeze again after any wait and
   right before it requests or performs a merge.
8. WHILE an open pull request labelled `auto-rollback`, other than its own
   and not a stale revert, exists, THE wrapper SHALL neither rebase nor
   enable auto-merge. A stale revert SHALL be logged and ignored.

## Requirement 2: Merges stay serialised

**User story:** As the operator, I want concurrent agent runs to merge one
after the other without rebasing against each other, so that CI is not
run several times for one merge.

1. THE wrapper SHALL keep the merge lock and its FIFO ticket queue with the
   same paths and file formats, so that runs of the old script and of the
   wrapper wait in the same queue during the cutover.
2. THE wrapper SHALL rebase and enable auto-merge only while it holds the
   merge lock.
3. THE branch protection of `main` SHALL keep requiring an up-to-date
   `ci`.

## Requirement 3: The Renovate train keeps working

**User story:** As the operator, I want Renovate updates to keep merging
on green CI with no human step, without moving `main` under an agent merge.

1. Renovate pull requests SHALL keep merging through auto-merge
   (`platformAutomerge: true`, `automergeType: 'pr'`), with no change to
   `.github/renovate.json5`.
2. THE Renovate train SHALL rebase nothing WHILE a pull request is in
   flight, and SHALL print which one holds it.
3. THE train SHALL keep honouring `RENOVATE_TRAIN_PAUSED` as a manual pause
   and its hold while an `auto-rollback` pull request is open. The wrapper
   SHALL no longer set the variable.

## Requirement 4: Protection, signatures and rollback stay as they are

**User story:** As the operator, I want this change to leave the security
settings of `main` and the automatic rollback exactly as they are.

1. THE branch protection of `main`, the rulesets and the repository merge
   settings SHALL equal the values recorded in
   [design.md](design.md#protection-and-merge-settings) before task 1
   merges and after task 5.
2. Every squash commit on `main` SHALL stay signed by GitHub, and every
   pull request commit verified (`pr-metadata`, required signatures).
3. THE OpenSSF Scorecard Branch-Protection score SHALL stay at 4.
4. THE automatic rollback (`auto-rollback.yaml`, its revert pull request
   with auto-merge, `auto-rollback-keep.sh`) and its outage guard SHALL work
   unchanged.

## Requirement 5: Documentation and agent rules

1. THE run-conventions and homelab-context skills (local operator files)
   SHALL describe the new merge path once the wrapper is on `main`, and
   the operator's local handover notes SHALL drop their stale line about
   the gh shim for `pr-merge.sh`.
2. README.md, docs/decisions.md, docs/dependencies.md, GOVERNANCE.md, the
   hold-every-merge and revert steps of docs/runbooks/netpol-enforcement.md
   and docs/runbooks/pod-security.md, the active netpol-default-deny spec
   (design D6, its break-glass acceptance criterion), and the
   gitops-delivery area spec
   SHALL describe the new merge path, and docs/decisions.md SHALL say why
   there is no native merge queue.
3. THE hold-every-merge steps SHALL set the freeze before they turn
   auto-merge off, and the revert step SHALL allow the revert pull request
   through the freeze before it merges it.
4. THE rollback of this change SHALL be written down in
   [design.md](design.md#rollback) before task 1 merges.

## Non-functional requirements

- The wrapper runs on the operator's Mac (bash 3.2, BSD tools) and in CI
  tests (bash 5); it passes shellcheck.
- API use: the lock holder makes at most 8 `gh api` calls per poll (30 s),
  at most 960 an hour, against the 5,000 an hour of the operator's token.
  A run waiting for `ci` outside the lock (flow step 4) makes at most 7
  calls per poll, about 16 polls for a 4 to 8 minute `ci`. Runs waiting
  for the lock poll only local files, as today.
- Unit tests run offline against a fake `gh` (`tests/bash/lib.sh`), in the
  `tests` job of `ci`.

## Acceptance criteria

1. `tests/bash/test_pr_merge.sh` passes and covers:
   1. merged after enabling auto-merge, with the log line `pr-merge:
      auto-merge on for PR #<n> at <sha7>`;
   2. merged at once by `--auto` on a mergeable pull request (the next read
      shows it merged);
   3. behind, rebased and merged, with the log lines `pr-merge: rebasing
      <branch> onto <remote>/main <sha7>`, `pr-merge: pushed <branch> at
      <sha>` and `pr-merge: auto-merge already on for PR #<n>`, and
      auto-merge not requested again when it is still on after the push;
   4. already merged;
   5. refusals for closed, draft, wrong base, freeze set, freeze unreadable,
      variables API error, `ci` failed, `--ff`;
   6. a freeze ending with `(allow #7)` lets PR 7 merge, and the same
      freeze refuses PR 8;
   7. a `ci` workflow run `in_progress` on the head, with the previous
      attempt's `ci` check run `failure`, counts as pending, not refused;
   8. `FAKE_MERGE_RC=1` with `pulls/7` then showing auto-merge on at the
      run's head, then merged: exit 0;
   9. `FAKE_MERGE_RC=1` on an up-to-date pull request with a green `ci` and
      auto-merge off: direct merge;
   10. auto-merge turned off by someone else (exit 1); auto-merge turned
       off by someone else on a behind pull request (exit 1, no push: the
       fake's calls.log has no `git push` and no second `pr merge
       --auto`); head moved by someone else (exit 1); a freeze set while
       waiting (auto-merge turned off, exit 2); the freeze unreadable while
       waiting (auto-merge turned off, exit 2); a freeze set while the run
       waits for a revert (no push, no `pr merge`, exit 2);
   11. an `auto-rollback` pull request opened 10 minutes ago holds the
       wrapper; one opened 80 minutes ago is logged as stale and ignored;
   12. a rebase whose stderr contains `agent refused operation` prints
       `signing failed (Bitwarden locked?)` and exits 2;
   13. `--dry-run` decisions.
2. The same test passes with a fake `gh` that prints a hint block on
   stderr before every call; with a malformed value on stdout (read error,
   exit 1 after the retries); and with the hint followed by
   `gh: Not Found (HTTP 404)` and exit 1, where the error message contains
   `HTTP 404`. These are the #1793 cases.
3. `tests/bash/test_pr_merge_lock.sh` passes with the same assertions for
   its lock, stale-break, bounded-wait, concurrency, FIFO and rebase cases
   (its fake `gh` answers the REST routes instead of `gh pr view`); its
   Renovate-pause cases are removed.
4. `tests/bash/test_renovate_next.sh` covers: held by an agent pull
   request with auto-merge on, up to date, whose `ci` workflow has `lint`
   `IN_PROGRESS` and no `ci` check run yet; not held when every check run
   of the `ci` workflow is `COMPLETED`; not held by a pull request that is
   behind, a draft, one without auto-merge, a Renovate pull request, or
   one whose only unfinished check run belongs to another workflow.
5. `grep -nE 'gh pr (view|checks)' scripts/pr-merge.sh scripts/lib/merge_lock.sh`
   prints nothing, and no line of either file captures `2>&1` from `gh`.
6. The docs pull request of task 4 merges through the wrapper with `ci`
   green, following the procedure in task 4: its wrapper log shows the
   rebase, auto-merge enabled and the merge commit SHA; a `renovate-next`
   run dispatched during its `ci` has the step summary
   `held by #<docs-pr> (auto-merge on, up to date, ci running); nothing rebased`;
   `gh run list --commit <merge-sha>` lists the push runs of `ci` and
   `renovate-next`.
7. A Renovate pull request merged by auto-merge after task 4, with `ci`
   green on its head.
8. The protection and merge settings commands of
   [design.md](design.md#protection-and-merge-settings) print the expected
   output before task 1 merges and after task 5.
9. The Scorecard API reports Branch-Protection 4 after task 4.
10. #1793 is closed by the task 2 pull request.

## Out of scope

- GitHub's native merge queue, a transfer of the repository to an
  organization, a merge server, a GitHub App or a new token.
- A server-side rebase of agent branches (it would replace the agents'
  signatures with GitHub's and widen `AUTO_ROLLBACK_TOKEN`).
- Changes to branch protection, rulesets, Renovate's configuration, the
  auto-rollback scripts or the outage guard.
- The train's existing hold on any open `auto-rollback` pull request,
  stale or not (#1003); it stays as it is.
- Retiring the wrapper: it stays, because GitHub cannot rebase a signed
  branch (design, [Why the wrapper stays](design.md#why-the-wrapper-stays)).
- Done specs that mention `scripts/pr-merge.sh`: they are history. The
  active netpol-default-deny spec is updated in task 4.
