# Design: drum-charts-per-song-releases

## Overview

The drum-charts `build` workflow gains a plan step. A new script,
`scripts/release-plan.py`, reads git and computes each chart's version
tag from the last commit that changed its release inputs; with the list
of published releases it marks the charts that have no song release yet.
The `charts` job builds only those, downloads the PDFs of the others
from their current releases, and runs `scripts/site-data.py` over all of
them, so every run validates the full site data. On `main`, the
`release` job publishes one release per chart built, and the
`site-data` job builds the data image from the same files, pushes it
only when its files differ from `:main`, and moves `:main` as today.
This repository's generator reads the new manifest (schema 2, a tag per
chart), the pin moves once by hand in that pull request, and Renovate
follows `:main` afterwards as it does now.

```
drum-charts push (any branch)
  -> charts: plan (git + release list) -> build the charts without a song release
             -> fetch the other charts' PDFs from their current releases
             -> site-data.py over all charts (manifest schema 2)
main only, head of main only
  -> release: one release <slug>-<date>-<sha7> per chart built (draft, upload, publish, Latest)
  -> site-data: PDFs equal the releases? files differ from :main?
                yes -> :<sha>, signed, attested, :main moved
                no  -> nothing pushed
homelab (unchanged path)
  -> Renovate pin pull request -> site-publish renders -> homelab-site digest -> Argo CD
```

## What publishes a release

A chart's release inputs are its own file and `lib/`:

| Chart | Release inputs |
| --- | --- |
| Song `<slug>` | `songs/<slug>.ly`, `lib/**` |
| Legend | `legend.ly`, `lib/**` |

Every song includes `lib/definitions.ly`, and `lib/audio.ly` shapes its
MP3, so a change under `lib/` changes every chart's output. Nothing else
does: the README, `archive/`, `drafts/`, `scripts/`, `tests/`, the
Dockerfile and the workflow change no PDF or MP3. The build recipe
(`Makefile`, the LilyPond image and soundfont pins in `build.yaml`)
could, but it changes rarely, and the LilyPond version is bumped with
the `\version` line of every song (the comment on `LILYPOND_IMAGE` says
so), which touches every release input anyway. A recipe change alone
publishes nothing; each chart picks it up at its next change. Branch
runs build every chart when the recipe changes, so it is tested before
`main` ([The plan](#the-plan)).

| Option | For | Against |
| --- | --- | --- |
| **Paths: the chart's file and `lib/`** (chosen) | Deterministic from git; one rule for branches and `main`; unit-testable on a temporary repository | A comment-only edit of a `.ly` publishes a release whose engraving did not change |
| Compare the new PDF with the released one | Publishes only real output changes | LilyPond's PDFs are not reproducible (drum-charts-site design, Workflow): every rebuild differs |
| Strip `%` comments before comparing the `.ly` | Comment-only edits publish nothing | A LilyPond lexer in Python (`%` inside strings, `%{ ... %}` blocks) for a rare case |

The `\header` fields are engraved at the top of the PDF, so a header
change is a chart change. The brief's "metadata-only change" is read as
a change outside the release inputs.

## The version tag

`<slug>-<yyyy-mm-dd>-<7 hex>` of the chart's version commit: the newest
commit in the first-parent history of the commit being built that
changed a release input, its committer date in UTC, its first 7 hex
digits.

```bash
c=$(git log -1 --first-parent --format=%H HEAD -- "songs/$slug.ly" lib)
d=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%d "$c")
tag="$slug-$d-${c:0:7}"
```

The tag depends on git only, so every run on the same commit computes
the same tags: a rerun the next day makes no second release (today's
`charts-$(date -u)` scheme does), and a run finds the releases it still
has to publish by name, without ordering releases by date. drum-charts
merges by squash, so each pull request is one first-parent commit; a
merge commit counts as the commit that brought the change to `main`.
Without `--follow`, a renamed file's history starts at the rename, which
is what [Renamed and removed songs](#renamed-and-removed-songs) needs.

Rejected: the run date (a rerun on another day gives a new tag for the
same files); the newest release per slug by creation date (needs
ordering rules for reruns and two releases a day, and the run that
creates a release cannot tell whether it is the newest).

## The plan

`python3 scripts/release-plan.py [--releases <file>] [--build-all]
<plan.json>`, Python 3 standard library, run from the repository root.

1. Fails with exit 1 and `release-plan: shallow clone; check out with
   fetch-depth: 0` when `git rev-parse --is-shallow-repository` prints
   `true`.
2. The charts: `legend`, then every `songs/*.ly` sorted by stem (the
   order of `site-data.py`). For each, the version commit and tag as
   above. A chart file with no commit in the history (`git log` prints
   nothing: the file is not committed) exits 1 with
   `<path>: not in the git history of HEAD`.
3. `--releases`: the output of `gh api --paginate --slurp
   repos/<repo>/releases`, a list of pages, each a list of releases. A
   chart is released when a release with its tag has `"draft": false`
   and an asset of each expected name in state `uploaded`. Releases
   whose tag is not a chart's version tag, the legacy `charts-*` ones
   included, are ignored. Not a list of lists of objects: exit 1
   `release-plan: <file> is not the GitHub releases list`. A release
   object without `tag_name`, `draft` or `assets` counts as not
   released.
4. `build` is true for a chart that is not released, or for every chart
   with `--build-all`. Without `--releases` (a local run), every chart
   is built.
5. Writes `plan.json` (keys sorted, two-space indent) and prints one line
   `<n> of <m> charts to build: <slugs>`.

```json
{
  "charts": [
    {"assets": ["legend.pdf"], "build": false, "commit": "fe3a366…", "date": "2026-11-20", "slug": "legend", "tag": "legend-2026-11-20-fe3a366"},
    {"assets": ["tool-schism.pdf", "tool-schism.mp3"], "build": true, "commit": "5387aa2…", "date": "2026-11-26", "slug": "tool-schism", "tag": "tool-schism-2026-11-26-5387aa2"}
  ],
  "head": "<40 hex of HEAD>"
}
```

(`…` stands for the rest of the 40 hex digits.)

## Where the data image comes from

| Option | For | Against |
| --- | --- | --- |
| **The current release of every chart, named by the plan** (chosen) | The PDFs are the release assets by construction; only changed charts are built; the same plan drives the releases and the data, so they cannot disagree | Each run downloads the other charts' PDFs (about 1.3 MiB) |
| Built from `main`: every chart engraved on every push | No downloads | Rebuilds everything, which is what the operator wants to stop; the PDFs differ from the song releases (not reproducible), so the site would serve files no release holds |
| The newest release per slug, found by listing | No git history needed | "Newest" needs ordering by date; a rerun of an older commit or two releases a day can pick the wrong one |

The `charts` job assembles `build/` from both sources before
`site-data.py` runs: the PDFs it built, and for each chart with
`build: false`, `gh release download "$tag" --pattern "$slug.pdf" --dir
build`. The manifest's artist and title come from the `.ly` headers at
the commit being built, as today.

## When a data image is published

The `site-data` job compares the new site data with the files under
`/charts/` of the current `:main`, as a sorted list of `sha256  path`
lines. Equal: `::notice::the site data equals :main; nothing published`
and the job ends. Different: build, push `:<sha>`, attest, sign, verify,
and move `:main` when this run is still for the head of `main` (the step
of today).

The comparison works because every file is deterministic for the same
releases: the PDFs are the release assets, `pdftocairo` gives the same
SVG for the same PDF (two renders of `tool-schism.pdf` page 1 with
poppler 26.11 on macOS were byte-identical while writing this design; a
unit test repeats this on the Ubuntu runner, [Tests](#tests)), and the
manifest has no field that changes per run (schema 2 drops the run's
tag and commit). A README push to `main` then publishes nothing, so no
Renovate pull request, no `site-publish` run and no website rollout. A
change to `site-data.py` that changes the page images publishes, since
the files differ.

## How the site and the pin pick up a change

Unchanged from drum-charts-site: Renovate follows the digest of `:main`
(rule "Deploy each new drum-charts data image at once" in
`.github/renovate.json5`), its pin pull request automerges, `site-publish`
verifies and renders, the `homelab-site` digest pull request deploys.
What changes is when `:main` moves: only when the site data changes.

Schema 2 needs a generator change here. Order:

1. drum-charts task 1 merges; its first run publishes the 15 song
   releases and a schema 2 data image, and moves `:main`.
2. Renovate's pin pull request for that digest fails `ci` (the
   `drumcharts` job: `charts.json: schema must be 1`) and stays
   unmerged. The site keeps the last schema 1 data, whose chart
   versions are the same.
3. Task 2 here sets `drumcharts/source.yaml` to the digest of `:main`
   and the generator to schema 2 in one pull request, so `ci` checks the
   new generator on the new data. After it merges, Renovate finds the
   pin current and closes its pull request.

Rejected: a generator that accepts schema 1 and 2, merged first. It
avoids the red Renovate pull request, but needs a third pull request to
remove schema 1, and the red one changes nothing live.

Nothing else here changes: not the Renovate rule, not `site-publish.yaml`,
not `scripts/ci/drumcharts-data.sh`, not the website manifests.

## Latest

Each song release is published with `gh release edit "$tag"
--draft=false --latest`, so Latest is the chart version published last.
When one run publishes several (a `lib/` change, the first run), it is
the last in plan order. Nothing depends on Latest: the README stops
linking `releases/latest/download/...`, and no step reads it.

Rejected: `--latest=false` on every song release. The last legacy
release would stay Latest, so the repository page and
every `releases/latest` link would point at stale files for good.

## Legacy releases

The legacy releases (every `charts-*` release the old workflow
published: 13 on 2026-11-27, from `charts-2026-11-20-fe3a366`, and one
or more from drum-charts-site task 9) and their tags stay as they are: not
deleted, not edited, not marked. Their asset URLs keep working for
anyone who saved one, and the tag prefix `charts-` tells them apart. No
step reads them: the plan ignores every tag that is not a chart's
version tag, and `site-data.py` refuses the slug `charts`, so no song
tag can ever start like one. Deleting them would break saved links for
no gain; editing their notes touches every one of them to say what the
tag name already says. The one way to change them after task 1 is a
rerun of a `main` run from before task 1, which runs the old workflow;
that is never done ([Edge cases](#edge-cases)).

## Renamed and removed songs

- Removed (`git rm songs/<slug>.ly`): the plan no longer lists it, so no
  release; its song releases stay. The run's site data lacks it, the
  files differ from `:main`, a new data image is published, and its page
  and PDF on charts.nedsi.io answer `404`.
- Renamed (`git mv songs/<old>.ly songs/<new>.ly`): `<new>` has no
  release, so the run builds and publishes `<new>-<date>-<sha7>` of the
  rename commit. `<old>`'s releases stay under `<old>`, findable with
  `releases?q=<old>`. The site drops `/<old>/` (`404`, no redirect, as
  drum-charts-site decided) and adds `/<new>/`.
- The README row changes in the same pull request (the drum-charts
  naming rule), as today.

## Technology stack

Locked with this design.

| Where | What |
| --- | --- |
| drum-charts | GitHub Actions on `ubuntu-24.04`; `gh` and `jq` from the runner image; Python 3 standard library (`argparse`, `json`, `re`, `subprocess`, `unittest`); git; `poppler-utils`, the pinned LilyPond image, FluidSynth, FFmpeg (as today); Docker Buildx, cosign and the action pins already in `build.yaml` |
| This repository | The Go generator in `drumcharts/` (standard library, as today); bash, `gh`, `jq`, `curl`, `pdfinfo` and `shasum` for `scripts/charts-check.sh` |

## drum-charts changes

### scripts/site-data.py

- Interface: `site-data.py --plan <plan.json> <pdf dir> <out dir>`;
  `--release` and `--commit` go.
- The plan must list `legend` and exactly the stems of `songs/*.ly`;
  each entry has `slug`, `commit` (40 lower-case hex), `date`
  (`yyyy-mm-dd`) and `tag` equal to `<slug>-<date>-<commit[:7]>`. A
  missing or extra song, or a malformed entry, prints `::error
  file=<plan>::<message>` and the script exits 1 after checking all.
- The slug `charts` joins the refused slugs, with its own message
  ("the prefix of the legacy release tags"). It is not added to
  `RESERVED`, which mirrors this repository's site paths.
- Writes `charts.json` schema 2 ([Manifest](#manifest-schema-2)).
- Every other rule (headers, page counts, the SVG allow-list) stays.

### Makefile

`TAG` goes. `site-data: pdf` runs `python3 scripts/release-plan.py
build/plan.json` (no `--releases`: every chart built locally) and then
`python3 scripts/site-data.py --plan build/plan.json build
build/site-data`.

### .github/workflows/build.yaml

`charts` job (every push):

1. `actions/checkout` with `fetch-depth: 0` and no credentials (the plan
   needs the full history; the branch runs need `origin/main`).
2. Install `poppler-utils` (needed by `site-data.py` on every run).
3. Unit tests: `python3 -m unittest discover -s tests -v`.
4. Plan. This step, the fetch step (6) and the `release` job's publish
   step carry `env: { GH_TOKEN: ${{ github.token }}, GH_REPO: ${{
   github.repository }} }`, so `gh release` needs no `--repo`:

   ```bash
   set -euo pipefail
   mkdir -p build
   gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases" > "$RUNNER_TEMP/releases.json"
   all=()
   if [ "$GITHUB_REF" != refs/heads/main ] &&
      ! git diff --quiet "$(git merge-base origin/main HEAD)" HEAD -- Makefile .github/workflows/build.yaml; then
     all=(--build-all)
   fi
   python3 scripts/release-plan.py --releases "$RUNNER_TEMP/releases.json" "${all[@]}" build/plan.json
   targets=$(jq -r '[.charts[] | select(.build) | .assets[] | "build/" + .] | join(" ")' build/plan.json)
   echo "targets=$targets" >> "$GITHUB_OUTPUT"
   echo "count=$(jq '[.charts[] | select(.build)] | length' build/plan.json)" >> "$GITHUB_OUTPUT"
   ```

   `count` is a job output.
5. When `count` is not `0`: install FluidSynth, the soundfont (checked
   against `SOUNDFONT_SHA256`), FFmpeg and the LilyPond image; `make
   -j"$(nproc)" $targets LILYPOND=...` (the targets are `build/<slug>.pdf`
   and `build/<slug>.mp3`, `build/legend.pdf`); the silence check over
   the MP3s the plan built, not a glob, so a legend-only build checks
   none and passes:

   ```bash
   set -euo pipefail
   for f in $(jq -r '.charts[] | select(.build) | .assets[] | select(endswith(".mp3")) | "build/" + .' build/plan.json); do
     max=$(ffmpeg -nostdin -i "$f" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB/\1/p')
     echo "$f max_volume ${max} dB"
     awk -v m="$max" 'BEGIN { exit !(m != "" && m > -40) }'
   done
   ```

   and the page-count check over `build/*.pdf`, as today (it now sees
   the built charts only); upload `build/*.pdf`, `build/*.mp3` and
   `build/plan.json` as `drum-charts-<sha>`, kept 7 days.
6. Fetch the other charts' PDFs, after the upload so the artifact holds
   only built files:

   ```bash
   set -euo pipefail
   while IFS=$'\t' read -r tag slug <&3; do
     gh release download "$tag" --pattern "$slug.pdf" --dir build
   done 3< <(jq -r '.charts[] | select(.build | not) | [.tag, .slug] | @tsv' build/plan.json)
   ```

   The loop reads from descriptor 3, so `gh` cannot consume the list on
   standard input, and a failed download fails the step (no pipeline
   subshell).
7. `python3 scripts/site-data.py --plan build/plan.json build
   build/site-data`; upload `build/site-data` as `site-data-<sha>`, as
   today.

`release` job: `if: github.ref == 'refs/heads/main' &&
needs.charts.outputs.count != '0'`; `contents: write`; `concurrency: {
group: release, cancel-in-progress: false }` as today.

1. Head check: `head=$(gh api repos/$GITHUB_REPOSITORY/commits/main
   --jq .sha)`; when it is not `$GITHUB_SHA`, `::notice::main is at
   <sha7>, not <sha7>; not the head of main; nothing published` and the
   remaining steps are skipped (a step output `head=false`).
2. Download `drum-charts-<sha>` to `charts/`.
3. For each chart with `build: true`, in plan order:

   ```bash
   set -euo pipefail
   run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
   while IFS=$'\t' read -r tag commit assets <&3; do
     files=(); for a in $assets; do files+=("charts/$a"); done
     if out=$(gh release view "$tag" --json isDraft 2>&1); then
       gh release upload "$tag" "${files[@]}" --clobber
     elif [[ $out == *"release not found"* ]]; then
       gh release create "$tag" "${files[@]}" --draft --target "$commit" \
         --title "$tag" --notes "Chart of $commit, built by $run."
     else
       echo "$out" >&2; exit 1
     fi
     gh release edit "$tag" --draft=false --latest
   done 3< <(jq -r '.charts[] | select(.build) | [.tag, .commit, (.assets | join(" "))] | @tsv' charts/plan.json)
   ```

   An existing release is a draft left by a failed run, or one this
   run's plan saw as incomplete; `--clobber` makes it hold this build's
   files, which the `site-data` job checks. Only "release not found"
   creates a release: any other `gh release view` error fails the step,
   so a transient error cannot leave a second draft with the same tag.
   The notes name the version
   commit and the run that built the files (in the first run, most
   charts' version commit is `fe3a366` but the build is task 1's run).
   They name no slug, so the release search for one slug finds no other
   song.

`site-data` job: `needs: [charts, release]`, `if: always() &&
github.ref == 'refs/heads/main' && needs.charts.result == 'success' &&
(needs.release.result == 'success' || needs.release.result ==
'skipped')`; permissions and concurrency group as today.

1. The head check of the `release` job, with the same notice.
2. Checkout, download `site-data-<sha>`.
3. Check the PDFs are the releases': one `gh api --paginate --slurp`
   of the releases; for each chart in `charts.json` (songs and legend),
   the SHA-256 of `build/site-data/<slug>.pdf` must equal the `digest`
   of asset `<slug>.pdf` of its `release`; else `::error::<slug>.pdf is
   <digest>, the release <tag> has <digest or no such asset>` and the
   job fails.
4. Compare with `:main`: `docker create --platform linux/amd64
   ghcr.io/ned-si/drum-charts:main /none`, `docker cp <id>:/charts/.
   "$RUNNER_TEMP/main"`, `docker rm` (in a trap); `(cd <dir> && find .
   -type f | LC_ALL=C sort | xargs sha256sum)` for both; equal gives the
   notice above and the output `publish=false`. No login: the package
   is public.
5. With `publish=true`: the existing steps (log in, builder, build and
   push `:<sha>`, attest, cosign sign and verify, move `:main` after the
   head check, log out).

### README

- The intro: every change to a song publishes a release of that song;
  it links `https://github.com/ned-si/drum-charts/releases`, not
  `releases/latest`.
- Layout: rows `scripts/release-plan.py` (the plan: version tags and
  what to build) and `tests/` (unit tests of both scripts).
- Songs table: columns Title, Artist, Chart, PDF, Releases. PDF links
  `https://charts.nedsi.io/pdf/<slug>.pdf`; Releases links
  `https://github.com/ned-si/drum-charts/releases?q=<slug>&expanded=true`
  (tested while writing this design: the search matches tag names and
  notes, not asset names, and `q=2026-11-25` lists exactly the 5
  releases of that day). Under the Songs heading, keep drum-charts-site
  task 9's charts.nedsi.io line, and replace the "latest release"
  sentence with one saying the Releases link lists every version of the
  song, newest first, with its PDF and MP3.
- Naming: the slug `charts` is refused.
- Notation: "The legend PDF (`legend.pdf` in each release)" becomes "in
  the legend's releases (`legend-<date>-<sha>`)".
- CI: the plan, what publishes a release (the inputs table), the tag,
  Latest, the legacy releases, when the data image is published.
- Build locally: `make site-data` needs every song committed (its
  version tag comes from git); `make pdf` does not.

### Tests

`tests/test_release_plan.py` and `tests/test_site_data.py`, `unittest`,
each test in a temporary git repository built with fixed
`GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`, run by step 3 of `charts`.
Each test copies `scripts/` into its temporary repository and runs the
copy with `cwd` set to that repository: `site-data.py` finds `songs/`
from its own path (`ROOT`), and `release-plan.py` runs from the
repository root, so both see the temporary tree and neither script
changes how it finds the tree. The cases are acceptance criterion 1.

The render case copies `archive/pdf-stems-down/legend.pdf` (committed, one
page) into a temporary directory, renders page 1 twice with the
`pdftocairo -svg -f 1 -l 1` call `site-data.py` uses, and asserts the two SVGs are
byte-identical. It runs in step 3, after step 2 installs
`poppler-utils`, so it checks the runner's poppler on task 1's branch,
before the comparison with `:main` depends on it.

## Manifest, schema 2

```json
{
  "legend": {"commit": "fe3a366…", "pages": 1, "release": "legend-2026-11-20-fe3a366"},
  "schema": 2,
  "songs": [
    {"artist": "Tool", "commit": "5387aa2…", "pages": 3, "release": "tool-schism-2026-11-26-5387aa2", "slug": "tool-schism", "title": "Schism"}
  ]
}
```

Top-level `release` and `commit` go: no single release describes the
data, and a per-run field would make every data image differ. Songs in
slug order, keys sorted, two-space indent, as in schema 1.

## This repository's changes

### Validation

The generator owns these rules, as in drum-charts-site (the data crosses
a repository boundary). Changed rows only; the others stay.

| Input | Rule |
| --- | --- |
| `schema` | Required integer, `2` (`charts.json: schema must be 2`) |
| Top-level `release`, `commit` | Unknown keys, refused by the strict decoding |
| `legend.release` | Required, `legend-` then `(\d{4}-\d{2}-\d{2})-([0-9a-f]{7})`, a valid date |
| `legend.commit` | Required, 40 lower-case hex, its first 7 equal the tag's hex |
| song `release` | Required, `<slug>-` then `(\d{4}-\d{2}-\d{2})-([0-9a-f]{7})`, a valid date |
| song `commit` | Required, 40 lower-case hex, its first 7 equal the tag's hex |

Each broken rule is one `charts.json: <rule>` line, as today. The check
is `strings.HasPrefix(release, slug+"-")` and the regexp
`^(\d{4}-\d{2}-\d{2})-([0-9a-f]{7})$` on the rest.

### Code

| File | Change |
| --- | --- |
| `drumcharts/internal/site/manifest.go` | `Schema = 2`; `Legend` and `Song` gain `Release`, `Commit`; `Manifest` loses them; `Chart` gains `Release string`, `Date time.Time`; `Data` loses `Release`, `Date`, gains `Updated` (the newest `Date` of the songs and the legend) |
| `drumcharts/internal/site/render.go` | `home.updated` takes `count` and `date` (of `Updated`); `songView` gains `Version template.HTML` from `song.version`, with `date` as the existing `<time>` markup and `release` as `link("https://github.com/ned-si/drum-charts/releases/tag/"+tag, tag)`; set for songs and the legend |
| `drumcharts/internal/site/assets/song.html` | `<p class="updated">{{.Version}}</p>` after the `links` paragraph; `charts.css` already styles `.updated` |
| `drumcharts/internal/site/i18n.go` | The strings below |
| `drumcharts/internal/site/testdata/data/charts.json` | Schema 2, a tag and commit per chart |
| `drumcharts/internal/site/testdata/golden/` | `go test -update` |
| `drumcharts/internal/site/*_test.go` | The cases of acceptance criterion 7; the `updated` expectations of `render_test.go` |
| `drumcharts/source.yaml` | The digest of `:main` after task 1 |
| `scripts/charts-check.sh` | [The live check](#the-live-check) |
| `docs/drum-charts.md` | The per-song releases, when `:main` moves, the check |

### Strings

| Key | English | French (proposed, for the operator to correct) |
| --- | --- | --- |
| `home.updated.one` | 1 song, last updated {date}. | 1 morceau, mis à jour le {date}. |
| `home.updated.other` | {count} songs, last updated {date}. | {count} morceaux, mis à jour le {date}. |
| `song.version` | Version of {date}, release {release}. | Version du {date}, *release* {release}. |

These rows replace drum-charts-site's `home.updated.*` rows, whose
French still carries `{release}`: `fill()` in `i18n.go` replaces only
the keys it is given, so that French would print `{release}` literally,
and `TestCatalogue` compares only key sets.

If the `fr` catalogue exists when task 2 starts (drum-charts-site task 7
merged), task 2 posts the three keys with the proposed French on its
pull request and waits for the operator's correction before merging,
the only wait in this spec; `TestCatalogue` keeps both languages' keys
equal. If it does not, task 2 comments the three keys, their English and
the proposed French above on the issue that carries drum-charts-site
task 7 (#1761, or its `blocked` issue if task 7 was deferred), so drum-charts-site task 7 takes them from this spec and
not from its own Strings table; its `TestCatalogue` fails until
`song.version` has French.

### The live check

`scripts/charts-check.sh` (from drum-charts-site task 5) keeps its
output and exit codes; its source of truth changes:

1. The charts: `gh api 'repos/ned-si/drum-charts/contents/songs?ref=main'`,
   the stems of the `.ly` names, and `legend`.
2. `gh api --paginate --slurp repos/ned-si/drum-charts/releases`; for
   each chart, the published releases whose tag matches
   `^<slug>-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7}$`, the newest by
   `created_at`. None: `FAIL <slug>: no song release`. Creation order is
   version order, because only runs for the head of `main` publish.
3. The song pages linked from `/` are exactly the songs; per chart, the
   PDF's SHA-256 equals its release's `<slug>.pdf` digest, one `<img>`
   per page answering `200 image/svg+xml`, the page links
   `releases/tag/<tag>`, and the release's MP3 answers `404` at
   `/pdf/<slug>.mp3` and `/<slug>.mp3`.
4. Prints `ok   /<slug>/ (<n> pages, <tag>)` per chart and ends with
   `charts-check: https://charts.nedsi.io matches the current release of
   each of <n> charts`.

## Error handling

| Operation | Failure | Recoverable | What the caller gets | Logged |
| --- | --- | --- | --- | --- |
| `release-plan.py` | Shallow clone; a chart file not in the history; the releases file malformed | Fatal; fix the workflow or commit the file | Exit 1, the message above | Job log |
| Plan step | `gh api` fails (network, rate limit) | Transient: "Re-run failed jobs" | Step fails, nothing built or published | Job log |
| Build, silence, page count | LilyPond error, silent MP3, more than 3 pages | Fatal; fixed by a commit | `charts` fails, nothing published; annotations as today | Job log, annotations |
| Fetch the other PDFs | Asset missing or download fails | Transient (rerun), or a race with another run (rerun) | Step fails, nothing published | `gh`'s message |
| `site-data.py` | Plan and `songs/` differ; slug `charts`; the existing rules | Fatal; fixed by a commit | Exit 1, one `::error file=...` per problem | Annotations |
| `release` job | Not the head of `main` | Not an error | Success, nothing published | `::notice::... not the head of main; nothing published` |
| `release` job | Create, upload or publish fails | Recoverable: "Re-run failed jobs"; the draft is reused | Job fails; drafts stay invisible; `site-data` does not run | Job log, GitHub's failed-run e-mail |
| `site-data` job | Not the head of `main` | Not an error | Success, nothing pushed | The same notice |
| `site-data` job | A PDF differs from its release asset | Fatal: a broken workflow change | Job fails, `:main` unchanged, the site keeps its data | `::error::<slug>.pdf is ...` |
| `site-data` job | `:main` cannot be pulled | Transient: rerun the job | Job fails, nothing pushed | docker's message |
| `release` job | Cancelled while pending, by a rerun of an older run in the `release` group | Recoverable: "Re-run failed jobs" of the newest run | `release` cancelled, `site-data` skipped, nothing published; the site lags | The run shows cancelled; `charts-check.sh` shows the lag |
| `site-data` job | Files equal `:main`'s | Not an error | Success, nothing pushed | `::notice::the site data equals :main; nothing published` |
| `site-data` job | Push, attest, sign or verify fails | As drum-charts-site: rerun | Job fails, `:main` unchanged | Job log |
| Generator (here) | Schema 1, or a tag rule broken | Fatal for the pull request | `drumcharts` job fails, `ci` red, nothing deployed | `charts.json: <rule>` lines |
| `charts-check.sh` | No song release for a chart; any difference | Shows a lag or a fault | Exit 1, `FAIL ...` | stdout |

## Validation of external inputs

| Input | Owner | Rules | On failure |
| --- | --- | --- | --- |
| Git history | `release-plan.py` | Full clone; each chart file has at least one commit | Exit 1 |
| GitHub releases list | `release-plan.py`, `site-data` job, `charts-check.sh` | A list of pages of releases; per release `tag_name` (string), `draft` (bool), `assets[].name`, `assets[].state`, `assets[].digest` | Malformed list: exit 1; a release missing a key counts as not released (it is rebuilt) |
| `plan.json` | `site-data.py` | Every `songs/*.ly` stem and `legend` once; `commit` 40 hex; `date` `yyyy-mm-dd`; `tag` = `<slug>-<date>-<commit[:7]>` | `::error`, exit 1 |
| `songs/*.ly` names and headers | `site-data.py` | The existing slug and header rules, and not `charts` | `::error`, exit 1 |
| `charts.json` | The generator | [Validation](#validation) | Exit 1 |

## Invariants

| Invariant | Owner | Why there |
| --- | --- | --- |
| A chart's song release holds the files of one build | The `release` job: draft, upload with `--clobber`, then publish | The only writer of song releases |
| The data image's PDFs are the release assets | The `site-data` job's digest check; `charts-check.sh` live | Both read the same artifact; the check catches a broken workflow change |
| Every song in the data image comes from its current release | `release-plan.py` (the tag from git) and `site-data.py` (the plan equals `songs/`) | The plan is the one place that names versions; the generator here checks only the tag's form |
| Only the head of `main` publishes | The head checks of the `release` and `site-data` jobs, and before `:main` moves | An older run finishing last must not publish older versions |
| `:main` changes only when the site data changes | The `site-data` job's comparison | Stops a site rebuild on every README push |
| Legacy releases are untouched | `release-plan.py` names only version tags; nothing else writes releases | One writer, by name |
| A song release and its data image come from one pull request | Task 1's scope | Requirement 3.5 |

## Testability

| What | How |
| --- | --- |
| Tags, inputs, release state, renames, removals, first-parent, UTC date, shallow clone | `tests/test_release_plan.py`, unit, temporary git repositories |
| Plan and `songs/` mismatch, slug `charts` | `tests/test_site_data.py`, unit |
| Only changed charts built; downloads; full validation | Branch runs of task 1 (all built) and task 3's PR A (none) and PR B (one) |
| Releases, Latest, legacy untouched, data image only on change, the `site-data` head check | The `main` runs of tasks 1 and 3 and the reruns of criterion 4 |
| The legend-only build (the silence check over no MP3) | Read in review |
| The `release` job's head check | Read in review; live only on a race ([Edge cases](#edge-cases)) |
| Render determinism on the runner | The render case of `tests/test_site_data.py` on task 1's branch |
| Schema 2 rules, strings, golden pages | `go test ./...` in `drumcharts/` |
| End to end | `charts-check.sh`, the PostSync smoke and Renovate's merges after PR B |

## Edge cases

- A `lib/` change: all 15 charts are built and published in one run;
  Latest is the last in plan order.
- A `legend.ly` change: the legend's release only; the songs keep
  theirs. It builds no MP3; the silence check loops over the plan's MP3
  assets, so it checks none and passes.
- Two songs in one pull request: two releases.
- A comment-only or `% chart: long` edit of a `.ly`: a release with the
  same engraving; accepted (path rule).
- Two merges minutes apart: the first run finds `main` moved and
  publishes nothing; the second run's plan includes the first merge's
  version commit for its song, so it publishes both.
- A release published by an older run while this run built the same
  chart: this run's `--clobber` replaces its assets with this build's,
  which the site data holds. For those seconds the public release is
  missing an asset; accepted, since it needs a merge during another
  run's `release` job.
- A run fails after some releases: the next run of the head (a rerun or
  the next push) publishes the missing ones; drafts are reused.
- The `site-data` job fails after the releases: the site keeps the
  previous data; "Re-run failed jobs" publishes it, or the next push
  does, since the files still differ from `:main`.
- A song release deleted by hand: the next `main` run rebuilds and
  republishes it under the same tag.
- A rerun on another day: the same tags; nothing new.
- More than 100 releases: `--paginate --slurp`.
- A slug that contains another (`korn-here-to-stay` and a later
  `korn-here-to-stay-live`): the README's search link for the shorter
  one also lists the longer one's releases; accepted.
- During the window between tasks 1 and 2: another song change publishes
  more schema 2 data; task 2 pins the digest `:main` points at when its
  pull request is last rebased (Requirement 7.3).
- Never rerun a `main` run from before task 1's merge. GitHub reruns
  with the workflow file of that run's commit: the old `release` job
  has no head check, so on the same UTC day it clobbers the assets of
  that legacy release, and on another day it creates a new `charts-*`
  release with every chart and makes it Latest. A failed old run is
  left as it is; the next push to `main` runs the new workflow.
- A rerun of an older run (after task 1) cancels the newest run's
  pending `release` job, since GitHub keeps one pending job per
  concurrency group; the newest run's `site-data` is then skipped.
  Rerun the newest run's failed jobs; `charts-check.sh` shows the lag
  until then.
- The `release` job's head check is reached only when an older run's
  plan still has charts to build, which needs a race (a second merge
  while the first run builds). The `site-data` job's head check, which
  stops `:main` moving backwards, is the one checked live
  (criterion 4 (b)).
- The first branch run of task 1: no chart has a song release, and
  `build.yaml` changed, so all are built and nothing is downloaded.

## Why it is like this

- Version tags from git: every run on a commit agrees on the names, so
  "what to publish" is "which names have no release", with no
  date ordering and no second release on a rerun.
- Data from the releases: the site serves exactly the files a release
  holds, and an unchanged song is never rebuilt.
- `:main` moves only when its files change: a README push publishes
  nothing anywhere, which is the point of the operator's request.
- Legacy releases kept as they are: old links keep working, and nothing
  reads them.
- Rejected: a separate release index file committed by CI (a bot commit
  to `main` per release), a rolling `<slug>-latest` release per song
  (15 more releases rewritten on every change).

## Review responses

First review, 12 findings, all addressed:

| # | Finding | Response |
| --- | --- | --- |
| 1 | Criterion 4 reruns a pre-change run | Criterion 4 split: (a) rerun of task 1's own run at task 1, (b) rerun of PR A's run after PR B at task 3; an edge case forbids rerunning any run from before task 1. Rerunning PR A's run skips `release` (0 charts), so the `release` head check is reachable only on a race; Testability says so |
| 2 | "13 legacy releases" goes stale | Defined as every `charts-*` release of the old workflow; criterion 3 and task 1 compare with the snapshot saved before the merge |
| 3 | 7.3 "first schema 2 data image" | 7.3 and task 2: the digest of `:main` at the pull request's last rebase |
| 4 | Supersedes misses Strings, 1.4, Checks, Metadata | Rows added; Strings explains the `{release}` problem; task 2 comments the keys on #1761 when drum-charts-site task 7 is still open |
| 5 | Loop and `gh` env not written out | Both loops written with `@tsv` on descriptor 3; `GH_TOKEN` and `GH_REPO` on the plan, fetch and publish steps |
| 6 | API budget | At most about 150 calls |
| 7 | Rerun cancels the newest pending `release` | Edge case and error row |
| 8 | Glossary example tag | `tool-schism-2026-11-26-5387aa2` |
| 9 | Tests and `ROOT` | Tests copy `scripts/` into the temporary repository and run with `cwd` there |
| 10 | README MP3 links | Decided defaults row |
| 11 | Release notes | `Chart of <commit>, built by <run URL>.` |
| 12 | Render determinism on the runner | Unit test rendering the committed legend PDF twice, criterion 1 |

Second review, 1 MEDIUM and 8 NITs, all addressed: the silence check
loops over the plan's MP3s (a legend-only build passes); `gh release
view` tells "not found" from other errors, and the clobber of a
just-published release is an edge case; the README list covers Layout,
the intro link, task 9's line and Build locally; task 2's French path
names the wait and the issue; criterion 3 reads the tags from
`plan.json`; task 3 explains PR B's comment; Supersedes gains
drum-charts-site criterion 3, and task 2 greps `docs/` and `README.md`.
