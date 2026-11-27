# Tasks: drum-charts-per-song-releases

One PR per task, in order; each names its repository. Task 1 starts once
[drum-charts-site](../drum-charts-site/tasks.md) task 9 has merged
(tasks 5, 6 and 8 come before it; task 7 may still be open): task 9's
end-to-end test needs a README push to publish a data image, which task 1
stops, and task 2 changes `scripts/charts-check.sh` and
`docs/drum-charts.md`, which drum-charts-site tasks 5 and 8 create. Task
2 follows task 1 at once. Each task merges after its review round and is
checked live where it changes a public page (operator, 2026-11-24: no
approval pauses). In this repository, merges go through
`scripts/pr-merge.sh`; in ned-si/drum-charts, a squash merge on a green
`build`, signed commits. No task writes to the cluster outside Argo CD.
Defaults: [requirements.md](requirements.md#decided-defaults).

- [ ] 1. Per-song releases and the data image (**ned-si/drum-charts**),
      one PR: `scripts/release-plan.py`, `tests/test_release_plan.py`,
      `tests/test_site_data.py`; `scripts/site-data.py` (`--plan`,
      schema 2, the slug `charts` refused); the `Makefile`
      `site-data` target; in `build.yaml` the full-history checkout, the
      unit tests, the plan, the conditional tool install and build, the
      artifact of the built charts, the download of the other PDFs, the
      `release` job (head check, draft, upload, publish as Latest) and
      the `site-data` job (head check, digest check against each
      chart's release, comparison with `:main`)
      ([design, drum-charts changes](design.md#drum-charts-changes));
      the README (intro, Songs table links, Naming, Notation, CI).
      Before the merge, save the tag, asset names and digests of every
      `charts-*` release (`gh release list` and `gh release view --json
      assets`) to compare after. Never rerun a `main` run from before
      the merge ([design, Edge cases](design.md#edge-cases)). Check:
      acceptance criteria 1 and 2 on the PR; after the merge, criterion
      3 and criterion 4 (a). [1, 2, 3, 4, 5, 6]
- [ ] 2. The generator reads schema 2 (**ned-si/homelab**, live):
      `drumcharts/internal/site/` (manifest, render, `song.html`,
      strings, fixture, golden tree, tests), `drumcharts/source.yaml` set
      to the digest of `:main` at the pull request's last rebase
      (`docker buildx imagetools inspect ghcr.io/ned-si/drum-charts:main`),
      `scripts/charts-check.sh`, `docs/drum-charts.md` ([design, This
      repository's changes](design.md#this-repositorys-changes)). The
      French of the new strings as the operator corrects it, if the `fr`
      catalogue exists by then; if drum-charts-site task 7 has not
      merged, a comment on #1761 with the three keys, their English and
      the proposed French ([design, Strings](design.md#strings)), so
      task 7 takes them from this spec. No change to the Renovate rule, `site-publish.yaml`,
      `scripts/ci/drumcharts-data.sh` or the website manifests. Check:
      `ci` green with the `drumcharts` job on the new pin; criterion 7;
      `site-publish` green; the `homelab-site` digest PR merges by
      itself; criterion 8; Renovate's red pin PR of the window closes by
      itself. [7]
- [ ] 3. Verification (**ned-si/drum-charts**, two PRs, live).
      PR A changes `README.md` only: the Next section lists PR B's
      change while it is open. PR B adds one comment line,
      `% Recording: Welcome Interstate Managers (2003).`, under the
      `\header` block of `songs/fountains-of-wayne-stacys-mom.ly` (its
      only change to a release input) and sets Next back to "none" in
      the README. Merge
      PR A, wait for its `main` run, then PR B. Check: criterion 5 for
      PR A; criteria 6, 8, 9 and 10 for PR B; after PR B's `main` run,
      criterion 4 (b) (rerun PR A's `main` run). [1, 2, 3, 4, 7]
- [ ] 4. Close-out (**ned-si/homelab**): tick the tasks with their PRs
      (`ned-si/drum-charts#<n>` for tasks 1 and 3), the header
      `status: done` and `closed:`, the index row moved to the done
      table in [README.md](../README.md), and close #1865.

The last task ticked sets `status: done`, `closed:`, and closes #1865.
