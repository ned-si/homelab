# Tasks: merge-through-github-queue

One PR per task, in this order ([design, Cutover](design.md#cutover)).
Each PR body carries `Spec: merge-through-github-queue#<task>`. Tasks 1
and 2 merge in the live window (Monday to Friday, 08:00 to 21:00 UTC),
with the `scripts/pr-merge.sh` of `origin/main`. No task writes branch
protection, rulesets or repository settings. Before task 1 merges, run the
three commands of
[Protection and merge settings](design.md#protection-and-merge-settings)
and attach their output to the task 1 PR; any difference stops the
cutover.

Ticks: each task PR ticks the tasks merged before it (task 2 ticks 1,
task 4 ticks 2 and 3). Task 3 has no PR of its own. After task 5's checks
pass, a last PR `docs(spec): close merge-through-github-queue` ticks 4 and
5, sets `status: done` and `closed:`, updates the `.kiro/specs/README.md`
row, says `Closes #1832` and merges with the wrapper.

- [x] 1. Hold the Renovate train while a pull request is in flight:
      `scripts/ci/renovate-next.sh` (the hold right after the
      `auto-rollback` hold, its header comment) and the cases in
      `tests/bash/test_renovate_next.sh`
      ([design, The Renovate train](design.md#the-renovate-train)).
      Check: `ci` green; after the merge, the next `renovate-next` run
      prints a decision line and no error. [3.2; AC 4, AC 8 before] (#1870)
- [x] 2. `scripts/pr-merge.sh` merges through GitHub auto-merge: the
      wrapper, `scripts/lib/merge_lock.sh`, the comment in
      `scripts/ci/check-title.sh`, the `RENOVATE_TRAIN_PAUSED` comments in
      `scripts/ci/renovate-next.sh` and `.github/workflows/renovate-next.yaml`
      (a manual pause), `tests/bash/test_pr_merge.sh` rewritten,
      `tests/bash/test_pr_merge_lock.sh` on the REST routes, the fake `gh`
      in `tests/bash/lib.sh` ([design, The wrapper](design.md#the-wrapper)).
      The PR body says `Closes #1793`.
      Check: `ci` green; AC 1, 2, 3 and 5. [1, 2, 3.3; AC 1-3, 5, 10] (#1871)
- [x] 3. Skills and local notes, right after task 2 merges (local, no PR):
      a copy of each skill kept first, then the run-conventions and
      homelab-context skills and the handover notes as in
      [design, The skills and the local notes](design.md#the-skills-and-the-local-notes).
      No Claude Code link is added. Ticked with the date by the task 4
      PR. [5.1] (2026-11-27)
- [ ] 4. Docs: the files in
      [design, Documentation and the skills](design.md#documentation-and-the-skills),
      including the break-glass runbooks and the active netpol-default-deny
      spec (design D6, its break-glass acceptance criterion), merged with
      the new wrapper. This
      is the docs-only test PR. Procedure for AC 6:
      1. Branch from `origin/main~1`, not `origin/main`, so that the PR is
         behind when the wrapper starts (if `main~1..main` touches the same
         files, branch from the newest commit before `main` that does not).
      2. Run `scripts/pr-merge.sh <docs-pr>`. Once its log shows the push
         and auto-merge on, run
         `gh workflow run renovate-next.yaml -R ned-si/homelab`.
      3. Expected: that run's step summary is `held by #<docs-pr>
         (auto-merge on, up to date, ci running); nothing rebased`. If it
         prints `paused by pr-merge (...)`, an old-script run holds the
         train; dispatch again once that pause is gone, while the docs
         PR's `ci` still runs.
      4. After the merge: `gh run list -R ned-si/homelab --commit
         <merge-sha>` lists `ci` and `renovate-next`.
      Check: AC 6, and AC 9 (Scorecard Branch-Protection 4) once Scorecard
      has run after the merge. [4.3, 5.2, 5.3; AC 6, 9]
- [ ] 5. Verify a Renovate merge and the settings (no task PR): the
      first Renovate PR merged after task 4, with `ci` green on its head;
      the three settings commands print the expected lines. Ticked with
      that PR's number and merge SHA by the closing PR above, which sets
      this spec `done` and closes #1832. [3.1, 4.1, 4.2, 4.4; AC 7, 8 after]
