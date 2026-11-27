---
kind: change
status: active
created: 2026-11-27
issue: 1865
---
# Requirements: drum-charts-per-song-releases

## Introduction

[ned-si/drum-charts](https://github.com/ned-si/drum-charts) rebuilds and
republishes every chart on each push to `main`: one release per push,
`charts-<date>-<short sha>`, with every PDF and MP3
(`charts-2026-11-27-dd3627f` holds 29 assets: 14 songs, their MP3s and
the legend). The same build fills the data image
`ghcr.io/ned-si/drum-charts:main`, which this repository pins in
`drumcharts/source.yaml` and renders at `https://charts.nedsi.io/`
([drum-charts-site](../drum-charts-site/requirements.md)).

Operator decision, 2026-11-27: one release per song. A change to one song
publishes a release of that song only, tagged with its slug, a date and a
short sha (`trivium-until-the-world-goes-cold-2026-11-27-<sha>`), so each
song has its own history and CI builds only what changed. The PDF and MP3
asset names stay as they are. The data image keeps holding every song,
now assembled from the current release of each.

The work spans both repositories: one pull request in drum-charts (the
releases and the data image together), then one here (the generator
reads the new manifest, the pin, the live check). Each task in
[tasks.md](tasks.md) names its repository.

## Glossary

- **Chart**: a song (`songs/<slug>.ly`) or the legend (`legend.ly`,
  slug `legend`).
- **Release inputs** of a song: `songs/<slug>.ly` and every file under
  `lib/`. Of the legend: `legend.ly` and every file under `lib/`.
- **Metadata-only change**: a change to no release input, for example
  `README.md`, `LICENSE`, `archive/`, `drafts/`, `scripts/`, `tests/`,
  `Makefile`, `site-data.Dockerfile` or `.github/`.
- **Version commit** of a chart: the newest commit in the first-parent
  history of the commit being built that changed one of its release
  inputs.
- **Version tag**: `<slug>-<yyyy-mm-dd>-<7 hex>`: the version commit's
  committer date in UTC and its first 7 hex digits
  (`tool-schism-2026-11-26-5387aa2`, `legend-2026-11-20-fe3a366`).
- **Song release**: the GitHub release named by a version tag, holding
  `<slug>.pdf` and `<slug>.mp3` (the legend: `legend.pdf`).
- **Current release** of a chart: the song release of its version tag
  at the head of `main`.
- **Legacy releases**: every release whose tag starts with `charts-`,
  published by the workflow before task 1, one per push, each with every
  chart. On 2026-11-27 there are 13, `charts-2026-11-20-fe3a366` to
  `charts-2026-11-27-478e181`; drum-charts-site task 9 adds at least one
  more before task 1.
- **Plan**: the list of charts, their version tags and whether this run
  builds them ([design, The plan](design.md#the-plan)).
- **Data image**, **manifest**, **pin**, **generator**, **site data**: as
  in [drum-charts-site](../drum-charts-site/requirements.md#glossary).

## Requirement 1: What publishes a release

**User story:** As the operator, I want a change to one song to publish
that song only, so each song has its own history.

1. A CHANGE to a chart's release inputs SHALL publish one song release
   for that chart, tagged with its version tag. A change to `lib/`
   publishes every chart. A metadata-only change SHALL publish no
   release. A change to a song's `\header` or a comment in its `.ly` is
   a change to a release input and publishes it.
2. ON a run for the head of `main`, THE workflow SHALL publish a song
   release for every chart whose version tag has no published release
   holding all of its assets, and for no other chart. The first run
   after this change publishes every chart once, since none has a song
   release yet.
3. A SONG release SHALL hold `<slug>.pdf` and `<slug>.mp3` of one build
   (the legend: `legend.pdf`), point its tag at the head of `main` that
   published it, name the version commit in its notes and be titled with
   its tag ([design, The tag's commit](design.md#the-tags-commit)). It SHALL become public only once every asset is
   uploaded.
4. A RUN that is not for the head of `main` (an older commit finishing
   last, a rerun of an older run) SHALL publish nothing: no release, no
   data image.
5. A RERUN of the newest run SHALL create no second release of a version:
   the version tag depends on git only, not on the day of the run.
6. THE slug `charts` SHALL be refused, so no song tag can look like a
   legacy release.

## Requirement 2: What CI builds

**User story:** As the operator, I want CI to build only what changed.

1. EVERY run, on any branch, SHALL build the PDF and MP3 of exactly the
   charts whose version tag has no published song release. On a branch
   whose diff against its merge base with `main` changes `Makefile` or
   `.github/workflows/build.yaml`, it SHALL build every chart, so a
   change to the build is tested before `main`.
2. THE silence and page-count checks SHALL run on the charts built.
3. EVERY run SHALL validate the site data of every song (the rules of
   drum-charts-site Requirement 1.3) from the PDFs it built and the
   current releases' PDFs of the others.
4. A RUN that builds no chart SHALL not install LilyPond, FluidSynth or
   FFmpeg.

## Requirement 3: The data image

**User story:** As the operator, I want charts.nedsi.io to keep showing
every song, each from its newest release.

1. THE data image SHALL be built from the current release of every
   chart: its PDFs SHALL be byte-identical to the release assets, its
   page images rendered from them, its manifest from the songs' headers
   at the head of `main`.
2. THE data image SHALL hold exactly the songs in `songs/` at the head
   of `main`, and the legend.
3. THE workflow SHALL push, sign and attest a new data image, and move
   `:main` to it, only when its files differ from those of the current
   `:main`. Otherwise it SHALL push nothing.
4. THE manifest SHALL carry each chart's version tag and version commit,
   and no single release for the whole build (schema 2,
   [design, Manifest](design.md#manifest-schema-2)).
5. THE per-song releases and the new data image SHALL land in one
   drum-charts pull request, so no push to `main` publishes song
   releases that the data image of the same run does not describe.
6. THE signing identity, platforms, labels, provenance and public
   package of drum-charts-site Requirement 1.4 SHALL stay as they are.

## Requirement 4: Latest and links

1. EVERY song release SHALL be published as GitHub's "Latest". Latest is
   then the most recently published chart version, not the full set.
2. THE drum-charts README SHALL not link `releases/latest/download/...`:
   each song's PDF links `https://charts.nedsi.io/pdf/<slug>.pdf` and its
   history links
   `https://github.com/ned-si/drum-charts/releases?q=<slug>&expanded=true`,
   where every version's PDF and MP3 are. The README's CI text describes
   the per-song releases.

## Requirement 5: Legacy releases

1. THE legacy releases and their tags SHALL stay as they are: not
   deleted, not edited, not marked. Their asset URLs keep working.
2. NO step SHALL read a legacy release after this change.

## Requirement 6: Renamed and removed songs

1. A REMOVED song SHALL publish no release. Its song releases stay. The
   next data image no longer holds it, so its page and PDF on
   charts.nedsi.io answer `404`.
2. A RENAMED song SHALL get its first song release under the new slug,
   from the rename commit. The old slug's releases stay under the old
   name. The site drops the old URL (`404`, no redirect) and adds the
   new one.

## Requirement 7: The site and the pin

**User story:** As the operator, I want charts.nedsi.io to follow the
per-song releases with no manual step.

1. THE generator SHALL accept manifest schema 2 only, with the rules of
   [design, Validation](design.md#validation), and refuse schema 1.
2. THE home page SHALL say how many songs there are and the date of the
   newest chart version; each song page and the legend page SHALL name
   the chart's version date and link its song release.
3. THE pin SHALL move, in the pull request that changes the generator,
   to the digest `:main` points at when that pull request is last
   rebased. After that, Renovate SHALL follow
   `:main` as today; the Renovate rule, `site-publish.yaml` and
   `scripts/ci/drumcharts-data.sh` SHALL not change.
4. `scripts/charts-check.sh` SHALL compare the site with the current
   release of each chart instead of one latest release.
5. `docs/drum-charts.md` SHALL describe the per-song releases, when a
   data image is published, and how to check the site is current.
6. NEW user-visible strings SHALL be in the generator's catalogue; their
   French SHALL be published only as the operator corrects it
   (drum-charts-site Requirement 7.3).

## Non-functional requirements

- Cost: nothing paid; GitHub Actions minutes go down (a song change
  builds one song).
- Freshness: a song change is on charts.nedsi.io within 24 hours,
  normally a few hours (drum-charts-site, unchanged).
- API use: a run makes at most about 150 GitHub API calls with its own
  `GITHUB_TOKEN` (the first run, which publishes 15 releases at about 7
  calls each, included), well under the token's 1,000 an hour per
  repository.

## Acceptance criteria

1. In drum-charts, `python3 -m unittest discover -s tests` passes in the
   `charts` job, with these cases for
   `scripts/release-plan.py`: a song changed in the last commit gets that
   commit's tag; a `lib/` change gives every chart the `lib/` commit; a
   later README commit changes no tag; a commit at
   `2026-11-27T00:30:00+01:00` gives the date `2026-11-26`; a published
   release with both assets means no build, a draft or a release missing
   its MP3 means a build; a legacy `charts-*` release is ignored;
   `--build-all` builds all; a renamed song's tag uses the rename commit;
   a removed song is not in the plan; on a merge commit whose second
   parent changed a song, the tag uses the merge commit; a shallow clone
   exits 1. And for `scripts/site-data.py`: a plan missing a song, a plan
   with a song not in `songs/`, and the slug `charts` each fail; two
   renders of `archive/pdf-stems-down/legend.pdf` give byte-identical
   SVGs (run on the Ubuntu runner, so the comparison of Requirement 3.3
   holds there). [1.1, 1.5, 1.6, 2.1, 3.3, 6]
2. On the pull request of task 1, the branch run builds all 15 charts
   (it changes `build.yaml`) and the site data holds 14 songs and the
   legend. [2.1, 2.3]
3. After task 1 merges, the `main` run publishes exactly 15 song
   releases, one per chart, with the tags in the `plan.json` that
   `python3 scripts/release-plan.py build/plan.json` writes locally on
   that commit (`jq -r '.charts[].tag' build/plan.json`); each holds exactly its assets and is
   not a draft; one of them is Latest. The legacy releases saved before
   task 1's merge still exist with the same asset names and digests, and
   no other `charts-*` release exists. `:main`'s
   `charts.json` has `"schema": 2`, 14 songs and the legend, each with
   its tag. [1.2, 1.3, 3.1, 3.2, 3.4, 4.1, 5]
4. (a) At task 1, "Re-run all jobs" of task 1's own `main` run, while it
   is still the head of `main`: the plan prints `0 of 15 charts to
   build`, no release is published, the `site-data` job logs `the site
   data equals :main; nothing published`, and the digest of `:main` is
   unchanged. (b) At task 3, after PR B's `main` run, "Re-run all jobs"
   of PR A's `main` run: the `site-data` job logs `not the head of main;
   nothing published`, no release is created, and the digest of `:main`
   is unchanged. No `main` run from before task 1's merge is ever rerun
   ([design, Edge cases](design.md#edge-cases)). [1.4, 1.5, 3.3]
5. A README-only pull request (task 3, PR A): its branch run builds 0
   charts, installs no LilyPond, and validates 14 songs. After its
   merge: no new release, the digest of `:main` unchanged, no Renovate
   pull request in this repository for `ghcr.io/ned-si/drum-charts`.
   [1.1, 2.1, 2.4, 3.3]
6. A pull request whose only change to a release input is one song's
   `.ly` (task 3, PR B; it also edits the README): its
   branch run builds that song only. After its merge: exactly one new
   release, `<slug>-<yyyy-mm-dd>-<sha7>` of the merge commit, holding
   `<slug>.pdf` and `<slug>.mp3`, marked Latest; `:main` moves; in its
   `charts.json` that song's `release` is the new tag and the 13 other
   songs and the legend keep theirs. [1.1, 1.2, 2.1, 3.1-3.3, 4.1]
7. In this repository, `go test ./...` in `drumcharts/` passes with
   failing cases for: schema 1, a top-level `release` key, a song tag
   with another slug, a song tag with an invalid date, a commit not
   starting with the tag's hex, a legend tag not starting with
   `legend-`; the golden home page says `3 songs, last updated` and each
   golden song page links its release. [7.1, 7.2]
8. After task 2, and again after PR B reaches the site: `curl -s
   https://charts.nedsi.io/` lists 14 songs; `scripts/charts-check.sh`
   passes and prints one `ok` line per chart with its current tag; the
   PR B song's page links its new tag; the Argo CD application
   `website` is Synced and Healthy and its PostSync smoke Job succeeded.
   [3.2, 7.2, 7.4]
9. PR B reaches the site with no manual step: Renovate's pin pull
   request and the `homelab-site` digest pull request merge by
   themselves. [7.3]
10. The README's Songs table of drum-charts has one row per file in
    `songs/`, no link containing `releases/latest`, and PR B's song's
    `releases?q=<slug>&expanded=true` link lists that song's releases,
    newest first, and no other song's. [4.2]

## Out of scope

- Deleting, editing or marking the legacy releases.
- Redirects from a renamed slug.
- A per-song history page on charts.nedsi.io: the song page links its
  release, the history stays on GitHub.
- Republishing on a change to the build alone (`Makefile`, the LilyPond
  or soundfont pins): each chart picks it up at its next change. A
  LilyPond version bump edits every song's `\version` line, which
  publishes every chart.
- Renovate in drum-charts (its own issue, from drum-charts-site task 2).
- Audio on charts.nedsi.io.

## Supersedes

[drum-charts-site](../drum-charts-site/) is active and built by another
run, so this spec does not edit it; these lines of it no longer hold
once task 1 of this spec merges, and `docs/drum-charts.md` (task 2)
records the current behaviour:

| drum-charts-site line | Becomes |
| --- | --- |
| Requirement 1.1, "from the same build as the release" | From the current release of each chart ([Requirement 3.1](#requirement-3-the-data-image)) |
| Requirement 1.2, "for the build its release tag and commit" | Each chart's version tag and version commit (3.4) |
| Requirement 1.4, "push the data image as `:<sha>` and `:main`" | Only when the files differ from `:main` (3.3); identity, platforms and provenance unchanged (3.6) |
| Requirement 1.5 | The PDFs equal each chart's current release (3.1) |
| Requirement 1.6 | Runs not for the head of `main` publish nothing (1.4); `:main` moves only when the files change (3.3) |
| Requirement 3.6, "the date of the release they come from" | The date of the newest chart version (7.2) |
| Acceptance criteria 2 and 15 | Criteria 4 and 8 of this spec |
| Acceptance criterion 3, "every MP3 of the release" | Every MP3 of each chart's current release ([The live check](design.md#the-live-check) step 3) |
| Design: Manifest, Workflow, Validation (`release`, `commit`), Edge cases on reruns and two releases a day | [design.md](design.md) of this spec |
| Design, Strings, `home.updated.one` and `home.updated.other` | This spec's [Strings](design.md#strings): no `{release}`; the French as the operator corrects it |
| Design, Strings (a new key) | `song.version`, this spec's [Strings](design.md#strings) |
| Design, Checks, `scripts/charts-check.sh` "against the latest release" | [The live check](design.md#the-live-check) (7.4) |
| Decided defaults, Metadata, "the release tag and date once on the home page" | The count and the newest version date on the home page, the version on each chart page (7.2) |

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Release trigger | A change to a chart's release inputs, by path ([design](design.md#what-publishes-a-release)) | Deterministic from git, testable; a comment-only change publishing one extra release is cheap. Rejected: comparing PDFs (not reproducible), stripping comments (a parser for LilyPond) |
| "Metadata-only" | Every path outside the release inputs, including `Makefile` and the workflow | The brief's example; `\header` fields are engraved into the PDF, so a header change is a chart change |
| Tag | `<slug>-<committer date UTC>-<sha7>` of the version commit | The operator's form; derived from git, so a rerun on another day makes no new tag |
| Data image source | The current release of every chart, chosen by the plan from git ([design](design.md#where-the-data-image-comes-from)) | Byte-identical PDFs by construction; builds nothing that did not change. Rejected: built from `main` (rebuilds everything, PDFs differ from the releases), newest release per slug by date (ordering breaks with reruns) |
| Site and pin | Unchanged path: `:main` digest, Renovate pin, `site-publish`; `:main` moves only when the data changes | No new mechanism; a README push no longer rebuilds the site |
| Legacy tags | Kept, unchanged | History and old links keep working; nothing reads them |
| Latest | Each song release published as Latest | Leaving a legacy release Latest would point at stale files forever |
| README MP3 links | Through the song's Releases link, which lists every version with its PDF and MP3 | GitHub's `releases/latest` covers the whole repository, so there is no stable per-song latest URL. Rejected: CI committing the current tag into the README (a bot commit per release) |
| Renamed or removed | Old releases kept, page `404`, no redirect | As drum-charts-site decided for renames; releases are the history |
| Order of the pull requests | drum-charts first, then this repository, after drum-charts-site task 9 | Task 9's end-to-end test needs a README push to publish data, which this change stops |
