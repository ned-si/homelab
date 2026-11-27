# Drum charts

`https://charts.nedsi.io/` shows every drum chart of
[`ned-si/drum-charts`](https://github.com/ned-si/drum-charts): one page per
song with its PDF pages as SVG images, and a link that downloads the PDF.
No MP3 is served. The pages are static HTML rendered by the Go generator in
[`drumcharts/`](../drumcharts/) into the `homelab-site` image, and served by
the `website` nginx pod like the tech radar. The design and its decisions
are in [spec drum-charts-site](../.kiro/specs/drum-charts-site/design.md);
the per-song releases in
[spec drum-charts-per-song-releases](../.kiro/specs/drum-charts-per-song-releases/design.md).

The French pages are the same tree under `/fr/`, sharing the page images
and PDFs, with their words in the `fr` catalogue of
[`drumcharts/internal/site/i18n.go`](../drumcharts/internal/site/i18n.go).
A new French string goes to the operator before it is published, and
follows the
[translation conventions](website.md#translation-conventions).

## How a chart reaches the site

Each chart (every song and the legend) has its own releases,
`<slug>-<yyyy-mm-dd>-<sha7>`, named after its version commit: the newest
commit on `main` that changed `songs/<slug>.ly` (or `legend.ly`) or
`lib/`. A merge that changes one song publishes one release; a `lib/`
change publishes all of them. The `charts-<date>-<sha7>` releases are the
legacy ones from before per-song releases; nothing reads them.

A merge to `main` in drum-charts that changes the site data reaches the
site in two automerged Renovate hops, within hours. No step waits for a
person and no token crosses the repositories.

| Step | Where | What happens |
| --- | --- | --- |
| 1 | drum-charts, `build` workflow, `charts` job | `scripts/release-plan.py` computes each chart's version tag from git and lists the charts with no release under it; only those are engraved. The other charts' PDFs are downloaded from their current releases, and `scripts/site-data.py` writes the site data (a manifest, schema 2, with each chart's tag and commit; the PDFs; one SVG per PDF page) |
| 2 | `release` job, `main` only | Publishes one release per chart built, with its PDF and MP3, each marked Latest |
| 3 | `site-data` job, `main` only | Checks each PDF against its release's asset. When the files equal those of `:main` it pushes nothing (`the site data equals :main; nothing published`), so a README-only merge stops here. Otherwise it pushes `ghcr.io/ned-si/drum-charts:<sha>`, signs it with cosign, then moves `:main` to it if the run is for the head of `main` |
| 4 | homelab, Renovate | Opens the `drum-charts` digest pull request on [`drumcharts/source.yaml`](../drumcharts/source.yaml) (`chore(deps): update ned-si/drum-charts to <sha7>`); the `drumcharts` CI job verifies, extracts and renders the new data; automerge on green `ci` |
| 5 | `site-publish` workflow | `scripts/ci/drumcharts-data.sh` verifies the signature and extracts the data, `drumcharts render` writes `site/charts-public/`, the `homelab-site` image is built, signed and smoke-tested |
| 6 | Renovate | The `homelab-site` digest pull request on `apps/website/deployment.yaml`, automerged on green `ci` |
| 7 | Argo CD | The `website` app rolls; its PostSync smoke checks `charts.nedsi.io` through the Gateway, and a failure reverts the merge |

The blackbox probe `https://charts.nedsi.io/` feeds the `charts` SLO
([sre.md](sre.md)). The host, certificate and listeners are in
[networking.md](networking.md#nedsiio); the layout and palette copies in
website.md ([Shared layout](website.md#shared-layout),
[Palette](website.md#palette)).

## See that the site is current

```sh
scripts/charts-check.sh
```

Needs `gh`, `jq`, `curl`, `pdfinfo` and `shasum`. It compares the site
with the current release of each chart, the newest published
`<slug>-<date>-<sha7>` release: the song pages linked from `/` are the
`songs/*.ly` on `main`; per chart, one page image per PDF page, the page
links its release, `/pdf/<slug>.pdf` has the SHA-256 of the release's
asset, and the release's MP3 answers `404`. Expected: `ok   /legend/ (<n>
pages, <tag>)`, one `ok   /<slug>/ (<n> pages, <tag>)` line per song, then
`charts-check: https://charts.nedsi.io matches the current release of each
of <n> charts`, exit 0. A `FAIL` line names the first difference, such as
`FAIL <slug>: no song release`. Shortly after a drum-charts merge a
difference is normal: the site lags until both Renovate pull requests have
deployed.

To see where it is stuck, compare the pin with `:main`:

```sh
git fetch origin && git show origin/main:drumcharts/source.yaml | grep '^image:'
docker buildx imagetools inspect ghcr.io/ned-si/drum-charts:main | grep '^Digest'
```

Same digest: the pin is current, so look at `site-publish` and the
`homelab-site` pull request. Different: look at the drum-charts pull
request below.

## When it lags

- `:main` did not move (the `release` or `site-data` job failed, or a
  rerun of an older run cancelled the newest run's pending `release` job).
  Rerun the failed jobs of the newest `main` run; it is idempotent: the
  version tags come from git, so it publishes only the releases still
  missing (reusing a draft a failed run left), and pushes and moves `:main`
  only when the site data differs from it.

  ```sh
  gh run list --repo ned-si/drum-charts --workflow build.yaml --branch main --limit 1 \
    --json databaseId,headSha,conclusion
  gh run rerun <databaseId> --repo ned-si/drum-charts
  ```

  A run that is not for the head of `main` succeeds with the notice
  `not the head of main; nothing published`; a run whose site data equals
  `:main` with `the site data equals :main; nothing published`. Neither is
  an error. Never rerun a `main` run from before the per-song releases: it
  runs the old workflow, which publishes a `charts-*` release.
- The pin pull request is red. Read the failing `drumcharts` step: a
  network error in `drumcharts-data.sh` gets one `gh run rerun --failed`;
  a signature, validation or render error is fixed in drum-charts, and its
  next merge updates the same pull request. The site keeps the previous
  data meanwhile.
- `drumcharts-data.sh` fails with `unauthorized`: the GHCR package
  `ghcr.io/ned-si/drum-charts` is private. Set it to public once in the
  package settings on GitHub; the REST API cannot change it.
- `site-publish` failed or the `homelab-site` pull request is red: as for
  any blog change ([website.md](website.md)).

## Why it is like this

- A signed data image, not release assets: Renovate can follow a digest,
  but it cannot gather the current release of every chart. The image is
  pinned in git and verified before use. Rejected: a pod that downloads the release
  (egress from the website pod, a site that changes without a commit).
- Rendered into the `homelab-site` image, not a ConfigMap or an app of its
  own: the PDFs exceed a ConfigMap's 1 MiB, and a second web server would
  bring its own image, signer identity and policies.
- PDF pages as SVG through `<img>`: the only way to show a page on every
  phone without JavaScript, a frame or a CSP change. drum-charts renders
  them, because its CI already has poppler.
- Rendered output not committed, unlike the radar: it follows binary data
  that changes with every release; CI renders the pinned data on every pull
  request that can change it.
- White sheets in both themes: the screen matches the PDF a reader
  downloads.
- One release per chart, tagged from git: a song change rebuilds and
  publishes that song only, and every run on a commit agrees on the tags,
  so a rerun publishes nothing twice.
- `:main` moves only for the head of `main`, and only when the site data
  changes: an older run finishing last cannot take the site back, and a
  README push rebuilds nothing.
