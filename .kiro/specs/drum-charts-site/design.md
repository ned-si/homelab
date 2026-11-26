# Design: drum-charts-site

## Overview

ned-si/drum-charts already engraves every song to a PDF in its `build`
workflow. This change adds one step there: from the same build it writes
the site data (a manifest, the PDFs and one SVG per PDF page) and, on
`main`, publishes it as a small signed OCI image,
`ghcr.io/ned-si/drum-charts:main`. This repository pins that image by
digest in `drumcharts/source.yaml`. Renovate follows `:main` and opens a
pull request when it moves. On merge, `site-publish` verifies the
image's signature, extracts the data, runs the Go generator in
`drumcharts/` and copies the rendered pages into the `homelab-site`
image. The `website` nginx pod already runs that image and serves the
charts on a new server name, `charts.nedsi.io`, behind the shared
Gateway, like the tech radar. The site is static HTML: each song has a
page showing its PDF pages as SVG images, and a link that downloads the
PDF.

```
drum-charts push to main
  -> build: PDFs, MP3s, site data       (one run, one build artifact)
  -> release charts-<date>-<sha>         (unchanged: PDFs and MP3s)
  -> site-data: ghcr.io/ned-si/drum-charts:<sha> and :main, signed
homelab
  -> Renovate: pin pull request (drumcharts/source.yaml), automerge on green ci
  -> site-publish: verify, extract, render, build homelab-site, sign
  -> Renovate: homelab-site digest pull request, automerge
  -> Argo CD: website rolls, PostSync smoke checks charts.nedsi.io
```

## Own spec or an amendment of public-website

Decided here: a change spec of its own. public-website is an active
change spec whose open tasks (11, 12) are the Home text and the shared
layout; adding a host, a second repository and a data pipeline to it
would keep it open for unrelated work. tech-radar set the precedent: a
new `nedsi.io` host with its own generator got its own spec and reused
public-website's requirements by reference. This spec does the same.

## How the charts reach the site

| Option | For | Against |
| --- | --- | --- |
| **A signed data image from drum-charts, pinned by digest here, followed by Renovate** (chosen) | Uses only each repository's own `GITHUB_TOKEN`; git pins the exact files; Renovate already follows `:main` digests for `homelab-site` and `homelab-dashboard`, so updates need no new mechanism; the signature is checked before use | drum-charts gains a publish job, a GHCR package and a signing step |
| Release assets fetched at build time, the tag pinned in a file | No new artefact in drum-charts | Renovate cannot order the tags: `charts-<date>-<sha>` has a hex suffix that no versioning scheme compares, and two releases on one day (`charts-2026-11-26-8dd16c2`, `charts-2026-11-26-5387aa2`) share a date; an unpinned "latest" fetch makes the image build unreproducible |
| drum-charts dispatches a workflow or opens a pull request here | Immediate | A token in drum-charts with write access to this repository; a GITHUB_TOKEN-made pull request triggers no CI |
| A ConfigMap rendered in git, like the tech radar | Live with the merge | The PDFs alone are 1.3 MiB, over a ConfigMap's 1 MiB; binaries in git on every release |
| An init container that downloads the release in the pod | No build step | Egress from the website pod to GitHub, a network policy hole, rendering in the pod, and a site that changes without a commit |

Two Renovate hops (pin, then `homelab-site` digest) set the pace: within
hours, under 24 hours. Both are automerged on green CI, so no step waits
for a person.

## How a chart is displayed

| Option | For | Against |
| --- | --- | --- |
| **Each PDF page as an SVG, rendered by `pdftocairo -svg` in drum-charts CI, shown with `<img>`** (chosen) | Every browser and phone shows it, with `img-src 'self'` already in the CSP; vector, so sharp at any zoom on a phone; an SVG loaded by `<img>` runs no script and loads nothing; 25 pages today, 0.6 MiB at most per file, about 70 KiB gzipped | 8.3 MiB of SVG in the image (about 1.7 MiB gzipped); an allow-list check on every file |
| The PDF in `<object>`, `<embed>` or `<iframe>` | No rendering | The CSP gets `object-src` or `frame-src` (today `'none'`), `frame-ancestors 'none'` and `X-Frame-Options: DENY` block it even from the same origin, and mobile browsers show nothing or the first page only |
| A link that opens the PDF in the browser's viewer | Nothing to build | Not "displayed on the site": no nav, no theme; some mobile browsers download the file instead of showing it; the viewer's behaviour under the strict CSP varies by browser |
| PNG per page | Small decoder cost | Blurry when zoomed on a phone, or large at the resolution a 3x screen needs (126 KiB at 110 dpi, still under a phone's pixel width) |
| LilyPond's own SVG backend | No poppler | Its text uses fonts by name, so it needs a web font (forbidden) or renders differently per device |

Rendering in drum-charts CI, where poppler is already installed for
`pdfinfo`, keeps this repository free of an apt-installed tool (every tool
here is pinned by version and checksum) and renders each release once.

The SVG from `pdftocairo` has a transparent background. The site-data
step adds a white `<rect>` as its first child, so the sheet is white
paper in both themes, as it prints. An inverted chart in the dark theme
was rejected: notation reads as a negative, and the PDF download would
not match what was on screen. The sheet's border uses `--rule`, so the
palette needs no new property.

## Order and metadata

- Order: artist, then title, compared in lower case; ties by slug. The
  charts are filed by artist (`<artist>-<title>.ly`), and the chart
  header puts the artist on top. The file-name order differs in places
  (`soad-` sorts before `sum41-`, `ratm-` files under "Rage Against The
  Machine"), so the sort uses the artist from the header, never the
  slug. Rejected: by title
  (the charts are filed by artist), newest first (the release carries no
  per-song date; git history would have to enter the data).
- Shown per song: title, artist, page count. The page count tells a
  drummer whether the chart fits one stand; the README's rule is two A4
  pages, three for a long song. Shown once: the number of songs, the
  release tag (a link to the GitHub release) and its date.
- Source of each field: artist is the `title` of the song's `\header`,
  title is its `subtitle` (the convention of every song in `songs/`;
  `title = "Tool"`, `subtitle = "Schism"`), pages from `pdfinfo`.

## Technology stack

Locked with this design.

| Where | What |
| --- | --- |
| drum-charts | GitHub Actions on `ubuntu-24.04` (the existing jobs); `pdfinfo` and `pdftocairo` from the apt `poppler-utils` the workflow already installs; Python 3 standard library (the runner's `python3`) for `scripts/site-data.py`; Docker Buildx with a `docker-container` builder; cosign (`COSIGN_VERSION`, `COSIGN_SHA256`) and the SHAs of `docker/setup-buildx-action`, `docker/login-action` and `actions/attest-build-provenance`, copied into `build.yaml` from this repository's `ci.yaml` and `site-publish.yaml` at task 2 and updated by hand when those pins move (the signature format is fixed by the cosign flags, not the version); GHCR. drum-charts has no Renovate; adding it is a separate issue in ned-si/drum-charts, opened with task 2, not part of this spec |
| This repository | Go at the version of `dashboard/go.mod`, `GOTOOLCHAIN=local`, standard library only at run time (`encoding/json`, `encoding/xml`, `html/template`, `compress/gzip`, `embed`), `govulncheck` as a `tool` directive run with `go tool govulncheck`, like the radar (so the module has a `go.sum`); bash for the scripts; `scripts/ci/site_markup.py` (Python); nginx of the `homelab-site` base image; the shared Gateway (Cilium), cert-manager, external-dns, Renovate (hosted app), Argo CD |

## drum-charts: the site data

### One slug renamed first

The slug is the public URL and the download name. Task 1, its own pull
request in drum-charts, runs `git mv songs/bloodhound-gang-fuck.ly
songs/bloodhound-gang-foxtrot-uniform-charlie-kilo.ly` and changes that
row of the README's Songs table (file name, PDF and MP3 links). The
`\header` stays (`title = "Bloodhound Gang"`, `subtitle = "Foxtrot
Uniform Charlie Kilo"`). `archive/pdf-stems-down/bloodhound-gang-fuck.pdf`
stays: the archive is kept as it was and never reaches the site. The
old file name keeps working in the releases made before the rename;
`releases/latest/download/bloodhound-gang-fuck.pdf` answers `404` from
the next release, and the README links the new name. Done before task 2,
so no published URL ever changes.

### Manifest

`charts.json`, written by `scripts/site-data.py`:

```json
{
  "schema": 1,
  "release": "charts-2026-11-26-5387aa2",
  "commit": "5387aa2358e4fe55993320dccb60947f21bc1028",
  "legend": {"pages": 1},
  "songs": [
    {"slug": "tool-schism", "artist": "Tool", "title": "Schism", "pages": 2}
  ]
}
```

Songs in slug order, keys sorted, two-space indent. `schema` changes only
with a change of this contract, in both repositories.

### Page images

For each PDF (songs and legend), `pdftocairo -svg -f <n> -l <n>
build/<slug>.pdf <out>/<slug>-<n>.svg` for `n` from 1 to the page count,
then the white background
`<rect width="100%" height="100%" fill="#ffffff"/>` inserted right after
the `<svg ...>` start tag. Each file is then checked against the
allow-list, the same list the generator applies here
([Validation](#validation)):

- Elements, in the SVG namespace: `svg`, `defs`, `g`, `path`, `use`,
  `rect`, `clipPath`.
- Attributes: `xmlns`, `xmlns:xlink`, `version`, `width`, `height`,
  `viewBox`, `id`, `d`, `x`, `y`, `transform`, `fill`, `fill-opacity`,
  `fill-rule`, `stroke`, `stroke-width`, `stroke-linecap`,
  `stroke-linejoin`, `stroke-miterlimit`, `stroke-opacity`,
  `stroke-dasharray`, `stroke-dashoffset`, `opacity`, `clip-path`,
  `clip-rule`, `href`, `xlink:href`.
- `href` and `xlink:href` match `^#[A-Za-z0-9_.:-]+$`; a value holding
  `url(` must be exactly `url(#<id>)`.
- No `<!DOCTYPE>`, no processing instruction but the XML declaration,
  no character data but whitespace.

The 25 pages of `charts-2026-11-26-5387aa2`, rendered with poppler
26.11 while writing this design, hold only `svg`, `defs`, `g`, `path` and
`use`, presentation attributes and internal `xlink:href`; no `style`
attribute.

### scripts/site-data.py

`python3 scripts/site-data.py --release <tag> --commit <sha> <build dir>
<out dir>`, Python 3 standard library, run after the page-count check.

1. For each `songs/*.ly`, sorted: the slug must match
   `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 80 characters, and not be `fr`,
   `pdf`, `pages`, `legend` or `set-theme` (paths of the site).
2. Inside its `\header { ... }` block (from `\header {` to the first line
   that is only `}`), the lines matching
   `^\s*(title|subtitle)\s*=\s*"([^"\\]*)"\s*$` (multiline mode) give
   the fields: exactly one `title` and one `subtitle`, each 1 to 100
   characters after trimming. Any other line of the block that matches
   `\b(title|subtitle)\s*=` (a `\markup` value, an escaped quote, a
   second assignment on one line) is an error, so `subtitle =` is never
   counted as a `title`.
3. `pdfinfo <build>/<slug>.pdf`: `Pages` between 1 and 3.
4. The page images as above, and a copy of the PDF.
5. The legend: `legend.pdf`, its pages, `legend-<n>.svg`.
6. `charts.json`.

Every failure prints `::error file=<path>::<message>` (the song's `.ly`,
or `legend.ly`) and the script exits 1 after checking all songs. `make
site-data` runs it locally with `TAG ?= charts-$(date -u +%F)-$(git
rev-parse --short=7 HEAD)`.

### Workflow

Changes to `.github/workflows/build.yaml`:

- `charts` job: a first step computes
  `tag=charts-$(date -u +%Y-%m-%d)-${GITHUB_SHA::7}` into its outputs.
  After "Check the page count", "Build the site data" runs
  `site-data.py` into `build/site-data`. A second
  `upload-artifact` (the same pinned SHA) uploads it as
  `site-data-<sha>`, kept 7 days. It runs on every branch, so a pull
  request with a bad header fails before `main`.
- `release` job: takes the tag from `needs.charts.outputs.tag` instead of
  recomputing it, so the release and the manifest always agree. The PDFs
  are not reproducible (the digest of every unchanged song's PDF differs
  between `charts-2026-11-26-8dd16c2` and `charts-2026-11-26-5387aa2`,
  the MP3s do not), so a rerun must not keep the first assets: when the
  tag exists, the job runs `gh release upload "$tag" charts/*.pdf
  charts/*.mp3 --clobber` instead of `exit 0`; otherwise `gh release
  create` as today. The release then always holds the files of the build
  that produced the data image. `concurrency: { group: release,
  cancel-in-progress: false }`, so two runs never write one release at
  once. The drum-charts README's CI text says so.
- New `site-data` job, `main` only, `needs: [charts, release]`,
  `timeout-minutes: 10`, `concurrency: { group: site-data,
  cancel-in-progress: false }`, permissions `contents: read`,
  `packages: write`, `id-token: write`, `attestations: write`:
  1. checkout (no credentials), download `site-data-<sha>`;
  2. compare the SHA-256 of each PDF with the `digest` of the release
     asset of the same name (`gh release view <tag> --json assets`); a
     difference fails the job (Requirement 1.5);
  3. log in to GHCR with `GITHUB_TOKEN`, create a `docker-container`
     builder, and
     `docker buildx build --platform linux/amd64,linux/arm64 --push
     --provenance=mode=max -f site-data.Dockerfile` with the labels
     `org.opencontainers.image.source=https://github.com/ned-si/drum-charts`,
     `org.opencontainers.image.revision=<sha>` and
     `org.opencontainers.image.licenses=CC-BY-4.0`, tag `:<sha>`;
  4. `actions/attest-build-provenance` on the index digest, pushed to the
     registry;
  5. cosign: download the pinned release, check its SHA-256, then
     `cosign sign --yes --new-bundle-format=false
     --use-signing-config=false <image>@<digest>` and `cosign verify`
     with the identity
     `https://github.com/ned-si/drum-charts/.github/workflows/build.yaml@refs/heads/main`
     (the flags of `site-publish`, one signature format for both
     repositories);
  6. move `:main` only when this run is for the head of `main`, so an
     older run that finishes last, or a rerun of an older commit, never
     takes the site back:

     ```bash
     head=$(gh api repos/ned-si/drum-charts/commits/main --jq .sha)
     if [ "$head" != "$GITHUB_SHA" ]; then
       echo "::notice::main is at ${head::7}, not ${GITHUB_SHA::7}; :main not moved"
       exit 0
     fi
     docker buildx imagetools create -t "$image:main" "$image@$digest"
     ```

     then log out. `:<sha>` is pushed and signed in every case.

  A rerun of the newest `main` commit is idempotent: the release job
  replaces the assets with that build's, step 2 compares against them,
  `:<sha>` is pushed and signed again and `:main` moves to it. A rerun of
  an older commit pushes its `:<sha>` and leaves `:main` alone. The
  concurrency group runs the jobs one at a time. GitHub keeps at most one
  pending job per group and cancels the older pending one when another
  queues: if a rerun of an older commit cancels the newest commit's
  pending job, `:main` stays where it was until the newest run's
  `site-data` job is rerun by hand (`charts-check.sh` shows the lag).
  Step 6 reads `main` with `GH_TOKEN: ${{ github.token }}`, which
  `contents: read` covers.

### Data image

`site-data.Dockerfile` at the root of drum-charts, built with
`build/site-data` as context:

```dockerfile
# The site data of https://charts.nedsi.io (ned-si/homelab,
# .kiro/specs/drum-charts-site/). Data only: never run.
FROM scratch
COPY . /charts/
```

Two platforms so any build platform can read it with `docker create
--platform`; the layers are the same files. No SBOM: the image holds no
software.

The package `ghcr.io/ned-si/drum-charts` must be public, so Renovate and
the runners here pull it without credentials. GHCR creates it private on
the first push and its REST API offers no way to change that, so the
operator sets it once in the package settings (task 2), as for
`homelab-dashboard`.

## This repository

### Layout

| Path | Holds |
| --- | --- |
| `drumcharts/go.mod` | Module `github.com/ned-si/homelab/drumcharts`, the Go version of `dashboard/`, `tool golang.org/x/vuln/cmd/govulncheck` |
| `drumcharts/source.yaml` | The pin ([The pin](#the-pin)) |
| `drumcharts/cmd/drumcharts/main.go` | `drumcharts render -data <dir> -out <dir>` |
| `drumcharts/internal/site/manifest.go` | Types, strict decoding, [Validation](#validation) |
| `drumcharts/internal/site/svg.go` | The page-image allow-list |
| `drumcharts/internal/site/render.go` | Sorting, templates, output, gzip |
| `drumcharts/internal/site/i18n.go` | The message catalogue (`en`; `fr` from task 7) and date formatting |
| `drumcharts/internal/site/assets/` | `home.html`, `song.html` (songs and the legend), `charts.css`, and the embedded copies `layout.css`, `theme-dark.css`, `theme-light.css` |
| `drumcharts/internal/site/testdata/` | `data/`: a fixture of three songs (one page, two pages, and one with the longest real artist word, `Underschool`, for the narrow-screen check) and the legend, tiny PDFs and allow-listed SVGs; `golden/`: the complete output of `drumcharts render` over `data/` (the HTML pages, `pages/*.svg` and `.svg.gz`, `pdf/`, the four stylesheets), which the golden test compares file by file and the `site` job serves without Go ([Checks](#checks)) |
| `scripts/ci/drumcharts-data.sh` | Verify the pinned image and extract its data |
| `scripts/ci/drumcharts-check.sh` | The `drumcharts` CI job |
| `scripts/charts-check.sh` | The live check of acceptance criterion 2 |
| `docs/drum-charts.md` | How the charts reach the site, how to check it is current, what to do when it is not; Why it is like this |

Code style: Google's Go Style Guide, as the dashboard and the radar
(`dashboard/.golangci.yaml`).

### The pin

```yaml
# The site data of charts.nedsi.io, built and signed by ned-si/drum-charts
# (.kiro/specs/drum-charts-site/design.md#the-pin). Renovate bumps the digest.
# renovate: datasource=docker depName=ghcr.io/ned-si/drum-charts
image: ghcr.io/ned-si/drum-charts:main@sha256:<index digest>
```

The existing `image:` regex manager reads it; no new manager.

`scripts/ci/drumcharts-data.sh <out dir>`:

1. Reads the `image:` line of `drumcharts/source.yaml`; it must match
   `^ghcr\.io/ned-si/drum-charts:main@sha256:[0-9a-f]{64}$`, else exit 1
   "drumcharts/source.yaml: not a pinned drum-charts image".
2. `cosign verify --certificate-oidc-issuer
   https://token.actions.githubusercontent.com --certificate-identity
   "$DRUMCHARTS_IDENTITY" <ref>`, the identity defaulting to
   `https://github.com/ned-si/drum-charts/.github/workflows/build.yaml@refs/heads/main`
   (the variable exists for the negative test only). A failure exits 1
   with cosign's message.
3. `docker create --platform linux/amd64 <ref> /none`, `docker cp
   <id>:/charts/. <out dir>`, `docker rm <id>` (in a trap). No container
   runs. A missing `/charts` exits 1.

Needs docker and cosign (installed by `scripts/ci/install-tool.sh cosign`
with the pins of `ci.yaml`).

### Validation

The generator owns these rules: it is the last step before the files are
published, and the data comes from another repository. drum-charts
checks the same SVG allow-list and header rules earlier, so a mistake
shows on its own pull request first.

| Input | Rule |
| --- | --- |
| `charts.json` | Required; a regular file of at most 1 MiB; one JSON object, strict (`DisallowUnknownFields`, nothing after it) |
| `schema` | Required integer, `1` |
| `release` | Required, `^charts-(\d{4}-\d{2}-\d{2})-([0-9a-f]{7})$`, a valid date |
| `commit` | Required, 40 lower-case hex; its first 7 characters equal the release's suffix |
| `legend.pages` | Required integer, 1 to 3 |
| `songs` | Required array of 1 to 200 |
| `slug` | Required, `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 80 characters, unique, not `fr`, `pdf`, `pages`, `legend`, `set-theme` |
| `artist`, `title` | Required, valid UTF-8, 1 to 100 characters, no leading or trailing space, no control character (Unicode `Cc`), no U+2028 or U+2029 |
| `pages` | Required integer, 1 to 3 (the drum-charts limit) |
| The directory | Regular files only, no subdirectory or link; exactly `charts.json`, `legend.pdf`, `legend-<1..n>.svg`, and per song `<slug>.pdf` and `<slug>-<1..pages>.svg`. Anything else (an `.mp3`, a stray file) is an error |
| A PDF | Starts with `%PDF-`; at most 4 MiB |
| A page image | At most 4 MiB; the [allow-list](#page-images), read with `encoding/xml` in strict mode (it expands no entity but the five predefined, so no external entity can load); root `svg` with a `viewBox` matching `^0 0 ([0-9]+(\.[0-9]+)?) ([0-9]+(\.[0-9]+)?)$`, both values above 0 and at most 10000. `pdftocairo` writes `viewBox="0 0 595.28 841.89"` for A4; the `<img>` gets `width` and `height` as `int(math.Round(v))` (595 and 842), because HTML wants integers |
| All files | At most 64 MiB together |

Every broken rule becomes one line `<file>: <rule>`. The generator
renders into a temporary directory next to `-out` and renames it to
`-out` only when validation and rendering succeed; `-out` must not exist.
On any error it removes the temporary directory and exits 1.

`os.MkdirTemp` creates mode 0700, and nginx runs as uid 101 over
root-owned files in the image. Before the rename, the generator sets the
output root and every directory to 0755 and writes every file as 0644,
whatever the umask; a golden test asserts the modes.

### Output

What `drumcharts render` writes, copied to `/usr/share/nginx/charts/` in
the image:

| Path | What |
| --- | --- |
| `index.html` | The home page |
| `<slug>/index.html` | A song page |
| `legend/index.html` | The legend page |
| `pages/<slug>-<n>.svg`, `.svg.gz` | Page images, copied as validated, and gzipped (level 9, no name, no time), so the bytes are deterministic |
| `pdf/<slug>.pdf`, `pdf/legend.pdf` | The PDFs, copied |
| `charts.css`, `layout.css`, `theme-dark.css`, `theme-light.css` | Stylesheets; nginx serves one palette as `/theme.css` |
| `fr/...` | The French pages, from task 7 |

### The pages

Rendered with `html/template`; every string from the catalogue
([Strings](#strings)). Common to all pages: `<html lang="en-GB">`, the
viewport `width=device-width, initial-scale=1`, `<link
rel="canonical">` to the page's own URL, the stylesheets `/layout.css`,
`/charts.css`, `/theme.css` (last), `header.site` with `nav.site` and the
preferences markup of site-theme-language (the theme links to
`/set-theme/<theme><path>` with the page's own path), the footer with the
privacy link.

The home page:

```html
<main>
<h1>Drum charts</h1>
<p class="lead">The songs I play, charted by section.</p>
<p>... the intro, with a link to <a href="/legend/">legend</a> ...</p>
<h2 id="songs">Songs</h2>
<table class="songs" aria-labelledby="songs">
<thead><tr><th scope="col">Song</th><th scope="col">Artist</th><th scope="col" class="num">Pages</th><th scope="col">PDF</th></tr></thead>
<tbody>
<tr><td><a href="/tool-schism/">Schism</a></td><td>Tool</td><td class="num">2</td>
<td><a href="/pdf/tool-schism.pdf" download aria-label="Download the PDF of Schism">PDF</a></td></tr>
</tbody>
</table>
<p class="updated">14 songs, from the release <a href="https://github.com/ned-si/drum-charts/releases/tag/charts-2026-11-26-5387aa2">charts-2026-11-26-5387aa2</a> of <time datetime="2026-11-26">26 November 2026</time>.</p>
<p class="credits">... the attribution, the source link ...</p>
</main>
```

A song page (the legend page is the same template with the legend's
strings and no artist):

```html
<main>
<h1>Schism</h1>
<p class="lead">Tool · 2 pages</p>
<p class="links"><a class="button" href="/pdf/tool-schism.pdf" download>Download the PDF</a> · <a href="/">All charts</a> · <a href="/legend/">Legend</a></p>
<div class="sheets">
<img src="/pages/tool-schism-1.svg" width="595" height="842" alt="Schism by Tool, page 1 of 2">
<img src="/pages/tool-schism-2.svg" width="595" height="842" alt="Schism by Tool, page 2 of 2" loading="lazy">
</div>
</main>
```

The navigation bar renders `NAV` as it is when the task merges: until
task 6 it has no "Charts" link and marks nothing on the charts site;
from task 6 the charts site's nav marks "Charts" (`href="/"
aria-current="page"` on the home page, as the radar does; on song and
legend pages the parent-path form `site_markup.py` allows).

`charts.css`, with no colour literal (`site_markup.py --css`):

- `.songs`: full width, `border-collapse: collapse`, a bottom border
  `var(--rule)` per row, `.num` right-aligned, cells padded
  `0.4rem 0.75rem 0.4rem 0`, titles allowed to wrap.
- `.sheets`: a grid, one column; from `60rem`,
  `grid-template-columns: 1fr 1fr` and a `1rem` gap, so two pages sit
  side by side and a third wraps to the left.
- `.sheets img`: `display: block; width: 100%; height: auto;
  border: 1px solid var(--rule)`.

### Serving

Set up like `techradar.nedsi.io` (tech-radar design, Serving), except
that the files come from the image instead of a ConfigMap.

- `site/Dockerfile`: `COPY charts-public/ /usr/share/nginx/charts/` after
  the blog's `COPY`. `/site/charts-public/` joins `.gitignore`.
- `site-publish.yaml`: `paths` gains `drumcharts/**` and
  `scripts/ci/drumcharts-data.sh`; before the image build, `setup-go`
  (`go-version-file: drumcharts/go.mod`), cosign (the install step moves
  up), `scripts/ci/drumcharts-data.sh "$RUNNER_TEMP/charts-data"` and
  `go run ./cmd/drumcharts render -data "$RUNNER_TEMP/charts-data" -out
  "$GITHUB_WORKSPACE/site/charts-public"` (in `drumcharts/`).
- `apps/website/nginx.conf`, a server block after the tech radar's, and
  `charts.nedsi.io charts.nedsi.io;` in the `$https_host` map:

  ```nginx
  # The drum charts, rendered by drumcharts/ into the image (spec drum-charts-site).
  server {
      listen 8080;
      server_name charts.nedsi.io;
      root /usr/share/nginx/charts;

      if ($request_method !~ ^(GET|HEAD)$) {
          return 405;
      }

      include /etc/nginx-site/theme.conf;

      location / {
          try_files $uri $uri/ =404;
          add_header Cache-Control "public, max-age=300";
      }
      # About 70 KiB gzipped instead of 0.6 MiB; the .gz is written by the generator.
      location /pages/ {
          gzip_static on;
          gzip_vary on;
          try_files $uri =404;
          add_header Cache-Control "public, max-age=300";
      }
      location /pdf/ {
          try_files $uri =404;
          add_header Content-Disposition "attachment";
          add_header Cache-Control "public, max-age=300";
      }
  }
  ```

  The official nginx builds, which `nginx-unprivileged` packages,
  include `ngx_http_gzip_static_module`; the serve check's
  `Content-Encoding: gzip` case fails if it is ever missing.
  `add_header` in these locations replaces only nginx's own headers; the
  security headers come from the HTTPRoute.
- Certificate `charts-nedsi-io` in namespace `gateway`
  (`infrastructure/gateway/certificate-charts-nedsi.yaml`, in the
  kustomization), one SAN, the `letsencrypt` ClusterIssuer and the
  settings of `techradar-nedsi-io`, secret `charts-nedsi-io-tls`.
- Gateway listeners `https-nedsi-charts` (443, `charts-nedsi-io-tls`)
  and `http-nedsi-charts` (80) in `infrastructure/gateway/gateway.yaml`.
- HTTPRoutes: `website` gains the hostname and the `https-nedsi-charts`
  parent (so the same `ResponseHeaderModifier` headers and CSP, which
  already allow `img-src 'self'`), `website-http` the hostname and
  `http-nedsi-charts`.
- DNS: external-dns creates the A record from the HTTPRoute (upsert
  only). Operator first: no `charts` record in the `nedsi.io` zone that
  external-dns does not own.
- Lists: `docs/pentest/scope.yaml` `public_hostnames`;
  `https://charts.nedsi.io/` in
  `platform/blackbox-exporter/probes/probes.yaml` (app `charts` from the
  relabeling), its SLO rules in
  `platform/kube-prometheus-stack/routes/slo.yaml` and
  `tests/prometheus/slo_test.yaml` like `techradar`, its row in
  `docs/sre.md` (tier 2, like the radar).
- No change to the Deployment, its resources or the network policies:
  the files are in the image the pod already runs.

### Checks

| Check | Where | Cases |
| --- | --- | --- |
| `site-publish` image smoke | Before the push | The image holds `/usr/share/nginx/charts/index.html`; from task 5, with `Host: charts.nedsi.io`: `/` and `/legend/` `200`, `/pdf/legend.pdf` `200` with `Content-Disposition: attachment`, `/pages/legend-1.svg` with `Accept-Encoding: gzip` gives `Content-Encoding: gzip`, `POST /` `405` |
| `scripts/ci/site-serve-check.sh` | `site` job | The committed golden tree mounted with `-v "$root/drumcharts/internal/site/testdata/golden:/usr/share/nginx/charts:ro"` (no Go needed, so the step order of the `site` job stays): `/`, a song page, `/legend/`, `/charts.css` `200`; the PDF's `Content-Type` and `Content-Disposition`; the SVG's `Content-Type`, `Content-Encoding: gzip` and `Vary: Accept-Encoding`; `/does-not-exist` `404`; `POST /` `405`; port 8081 `301` to `https://charts.nedsi.io/x`; the theme cases (`theme charts.nedsi.io`) |
| PostSync smoke (`apps/website/kustomization.yaml`) | After every sync | Wait for the certificate as for the radar; `https://charts.nedsi.io/` `200` with the headers; `/pdf/legend.pdf` `200` with `Content-Disposition: attachment`; `/pages/legend-1.svg` `200`; `404` and `405` through the Service with `Host: charts.nedsi.io`; `http://charts.nedsi.io/x` `301`; the host in the theme loop |
| `scripts/charts-check.sh` | By hand, and in the report of tasks 5, 6 and 9 | Acceptance criterion 2 against the latest release (`gh release view --repo ned-si/drum-charts --json tagName,assets`); exits 1 on the first difference, printing it |
| Blackbox probe | Always | `probe_success{app="charts"}`, the SLO rules |

The legend is the fixed sample in the smoke tests because every release
has it; a song can be renamed or removed.

### Navigation and links

- `NAV` in `scripts/ci/site_markup.py` gains `("Charts",
  "https://charts.nedsi.io/")` after "Tech radar"; `tests/test_site_markup.py`
  follows. The same pull request changes every nav: the blog
  (`site/layouts/baseof.html`), the landing page
  (`apps/website/landing/index.html`), the dashboard
  (`dashboard/internal/web/templates/layout.html`, its golden pages and
  screenshots), the tech radar (`techradar/internal/radar/assets/page.html`
  and the rendered `apps/website/techradar/index.html`) and the charts
  generator. The blog and the dashboard change with their next image
  deploys, which follow the merge through Renovate.
- `SITE_HOSTS` and `THEMED` gain `charts.nedsi.io` (task 3), `LINKS`
  gains `https://github.com/ned-si/drum-charts` (the release and source
  links).
- `site_markup.py` gains a media rule for the charts site only (when
  `self.host == "charts.nedsi.io"`, said in its docstring): no `<audio>`,
  `<video>`, `<source>`, `<embed>` or `<object>`, and no `href` or `src`
  whose path ends in `.mp3`, `.wav`, `.ogg`, `.oga`, `.flac`, `.m4a`,
  `.aac`, `.opus`, `.mid` or `.midi`. Other hosts keep their markup
  rules as they are, so a blog article with `<picture><source>` or a
  `<video>` still passes. `tests/test_site_markup.py`: a charts page with
  `<audio>` fails, a charts page with a link to an `.mp3` fails, a blog
  page with `<picture><source>` passes.
- The landing page: in "What is here so far", after the tech radar,
  `<li><a href="https://charts.nedsi.io/">Drum charts</a>: the songs I
  play, to read in the browser or download as PDF.</li>`; the "Drum
  charts" card's link line becomes `<p class="links"><a class="button"
  href="https://charts.nedsi.io/">See the charts</a> · <a
  href="https://github.com/ned-si/drum-charts">Source on GitHub</a></p>`,
  the form of the Homelab card.
- The privacy page (`site/content/privacy.md`): the cookie table's "Sent
  to" row becomes "`nedsi.io` and its subdomains: this blog, the homelab
  dashboard, the tech radar and the drum charts"; the site-theme-language
  design's copy of the table follows. If `privacy.fr.md` exists by then,
  its row changes too, with the French text reviewed by the operator.
- `scripts/ci/layout-check.sh`: copies `golden/index.html` to
  `$work/charts.html` and the golden two-page song page to
  `$work/charts-song.html`, and `golden/charts.css` and `golden/pages/`
  into `$www`; `charts` and `charts-song` join `pages` and `themed`.
  The pages' `/layout.css` and `/theme.css` are already in `$www`.
- `site-check.sh`: its change filter gains `drumcharts/`
  (`'^(site/|apps/website/|dashboard/internal/web/|drumcharts/|scripts/ci/(site[-_]|layout-check))'`),
  so a change to the templates, `charts.css` or the golden tree runs the
  serve, layout and copy checks; `drumcharts/internal/site/assets/layout.css`
  joins the layout copies, `drumcharts/internal/site/assets` the palette
  copies, `charts.css` the `--css` list; `task site:layout-sync` copies
  to them.

### Language

From task 7, after site-theme-language task 4 has merged (the language
toggle markup, the per-language `NAV` and the `hreflang` checks):

- The generator renders the French tree under `fr/` from the same data:
  `/fr/`, `/fr/<slug>/`, `/fr/legend/`. The pages and the PDF are shared;
  only the HTML differs. nginx needs nothing new: the tree is a real
  directory in the image, so `location /` serves it.
- `<html lang="fr-CH">`, the toggle, `hreflang` (`en`, `fr`,
  `x-default`), the canonical to itself, the French `NAV` and its
  "Charts" label, all per site-theme-language Requirement 4.
- `i18n.go` gains `fr`; `TestCatalogue` (both languages have the same
  keys, none empty, no U+2014, no "bot"); dates `26 novembre 2026`.
- The French strings are proposed to the operator next to the English
  ones (the table below, in two columns) and go into the catalogue only
  as he corrects them.

### CI

A `drumcharts` job in `ci.yaml`, modelled on `techradar`, with
`GOTOOLCHAIN: local` in its `env`: `setup-go` with
`go-version-file: drumcharts/go.mod` and
`cache-dependency-path: drumcharts/go.sum`; golangci-lint and cosign
through `install-tool.sh` with the existing pins (govulncheck comes from
the module's `tool` directive, not from `install-tool.sh`); then
`scripts/ci/drumcharts-check.sh`. That script exits early unless the
diff against `HEAD^1` matches
`^(drumcharts/|dashboard/go\.mod$|site/assets/css/|scripts/ci/(drumcharts|site_markup)|\.github/workflows/(ci|site-publish)\.yaml$)`,
then runs, in `drumcharts/` and in the `step` form of
`techradar-check.sh`: `go mod verify`, `go mod tidy -diff`,
`golangci-lint run --config ../dashboard/.golangci.yaml ./...`,
`go vet ./...`, `go tool govulncheck ./...`, `go test -race -count=1
./...`, `drumcharts-data.sh` into a temporary directory, `drumcharts
render` of it, and `site_markup.py <out> charts.nedsi.io`.
`site-publish` sets `GOTOOLCHAIN: local` for its Go steps too. It also fails
when the `go` line of `drumcharts/go.mod` differs from `dashboard/go.mod`.
The job joins the `ci` job's `needs:` list and its result loop.

### Renovate

- A package rule after "Group image digest refreshes":
  `matchPackageNames: ['ghcr.io/ned-si/drum-charts']`,
  `matchUpdateTypes: ['digest']`, `groupName: 'drum-charts'`,
  `automerge: true`, `minimumReleaseAge: '0 days'`, the form of the
  `homelab-site` rule: its own pull request at once.
- The Go module rules' descriptions name `drumcharts/`; their matchers
  (by manager and datasource) already cover it.

### Strings

Every new user-visible string. The French column is the operator's
corrected text (2026-11-26); the catalogue and the pages use it as is,
from task 7 (or task 6 for the landing page, the privacy row and the
French nav label, if site-theme-language task 4 merged first). English
words kept in French text are in italics (`<em>` in the catalogue).

| Key or place | English | French |
| --- | --- | --- |
| `NAV`, every public page | Charts | Partitions |
| `home.title` | Drum charts · nedsi | Partitions de batterie · nedsi |
| `home.description` | nedsi's drum charts, to read in the browser or download as PDF. | Les partitions de batterie de nedsi, à lire dans le navigateur ou à télécharger en PDF. |
| `home.heading` | Drum charts | Partitions de batterie |
| `home.lead` | The songs I play, charted by section. | Les morceaux que je joue, découpés par section. |
| `home.intro` | Each chart follows the structure of the song rather than every note: one staff per section, repeat counts above, and a line of text where a part comes back. A chart fits on two A4 pages, side by side on a music stand; a long song takes three. The note heads are explained in the {legend}. | Chaque partition suit la structure du morceau plutôt que chaque note : une portée par section, le nombre de répétitions au-dessus, et une ligne de texte quand une partie revient. Une partition tient sur deux pages A4, côte à côte sur un pupitre ; un long morceau en prend trois. Les têtes de notes sont expliquées dans la {legend}. |
| `home.legend_link` | legend | légende |
| `home.songs` | Songs | Morceaux |
| `home.col_song`, `home.col_artist`, `home.col_pages`, `home.col_pdf` | Song, Artist, Pages, PDF | Morceau, Artiste, Pages, PDF |
| `home.pdf` | PDF | PDF |
| `home.pdf_label` | Download the PDF of {title} | Télécharger le PDF de {title} |
| `home.updated.one`, `home.updated.other` | 1 song, from the release {release} of {date}. / {count} songs, from the release {release} of {date}. | 1 morceau, de la *release* {release} du {date}. / {count} morceaux, de la *release* {release} du {date}. |
| `home.credits` | The charts are my transcriptions of the drum parts; the songs belong to their authors. The source is on {github}. | Les partitions sont mes transcriptions des parties de batterie ; les morceaux appartiennent à leurs auteurs. Le code source est sur {github}. |
| `home.github_link` | GitHub | GitHub |
| `song.title` | {title}, {artist} · Drum charts · nedsi | {title}, {artist} · Partitions de batterie · nedsi |
| `song.description` | Drum chart of {title} by {artist}, to read in the browser or download as PDF. | Partition de batterie de {title} par {artist}, à lire dans le navigateur ou à télécharger en PDF. |
| `song.lead` | {artist} · {pages} | {artist} · {pages} |
| `pages.one`, `pages.other` | 1 page, {n} pages | 1 page, {n} pages |
| `song.download` | Download the PDF | Télécharger le PDF |
| `song.all` | All charts | Toutes les partitions |
| `song.legend` | Legend | Légende |
| `song.page_alt` | {title} by {artist}, page {n} of {total} | {title} par {artist}, page {n} sur {total} |
| `legend.title` | Legend · Drum charts · nedsi | Légende · Partitions de batterie · nedsi |
| `legend.description` | What each note head on the drum charts means. | Ce que signifie chaque tête de note sur les partitions de batterie. |
| `legend.heading` | Legend | Légende |
| `legend.lead` | What each note head on the charts means. | Ce que signifie chaque tête de note sur les partitions. |
| `legend.page_alt` | The legend of the drum charts, page {n} of {total} | La légende des partitions de batterie, page {n} sur {total} |
| Landing page, overview item | Drum charts: the songs I play, to read in the browser or download as PDF. | Partitions de batterie : les morceaux que je joue, à lire dans le navigateur ou à télécharger en PDF. |
| Landing page, "Drum charts" card | See the charts | Voir les partitions |
| Privacy page, cookie table, "Sent to" | `nedsi.io` and its subdomains: this blog, the homelab dashboard, the tech radar and the drum charts | `nedsi.io` et ses sous-domaines : ce blog, le tableau de bord du homelab, le tech radar et les partitions de batterie |

The page carries no licence; it stays in the drum-charts repository.
The footer's "Privacy" and the preferences' strings are the existing
ones of site-theme-language. Dates print as `26 November 2026` (en-GB).
Song titles and artists come from the manifest, untranslated.

## Error handling

| Operation | Failure | Recoverable | What the caller gets | Logged |
| --- | --- | --- | --- | --- |
| `site-data.py` (drum-charts) | A header, slug, page count or SVG rule broken | Fatal for the run; fixed by a commit | `build` fails; one `::error file=...` annotation per problem | Job log and annotations |
| `site-data` job (drum-charts) | PDF digest differs from the release, push, attest, sign or verify fails | Recoverable on the newest `main` commit: "Re-run all jobs" rebuilds, replaces the release assets and moves `:main` (idempotent); a rerun of an older commit pushes its `:<sha>` and leaves `:main` | Job fails; the release exists, `:main` stays on the previous data, the site keeps it | Job log; GitHub's failed-run e-mail |
| `site-data` job (drum-charts) | This run is not for the head of `main` | Not an error | Job succeeds without moving `:main` | `::notice::main is at <sha>, not <sha>; :main not moved` |
| `drumcharts-data.sh` | Pin malformed | Fatal; fix the file | Exit 1, "drumcharts/source.yaml: not a pinned drum-charts image" | stderr in the job log |
| `drumcharts-data.sh` | Pull or Sigstore lookup fails (network) | Transient: one `gh run rerun --failed` | Exit 1 with docker's or cosign's message | stderr |
| `drumcharts-data.sh` | Signature missing or another identity | Fatal; the pin pull request stays red and unmerged | Exit 1 with cosign's message | stderr |
| `drumcharts render` | Any validation rule, or a write error | Fatal; no output left | Exit 1, one `<file>: <rule>` line per problem, sorted | stderr |
| `site-publish` | Any step | Nothing is pushed; the running site stays | Workflow fails | The existing ntfy notification (priority low, quiet hours) and the job log |
| nginx | Unknown path; method other than `GET`/`HEAD` | Not an error of the site | `404` or `405` with the Gateway's headers | The access log line (`time`, `method`, `path`, `status`, `bytes`) |
| PostSync smoke | Any case | Argo CD marks the sync failed; the automatic rollback reverts the merge, within its outage guard | Sync failed | The Job's log, the Argo CD event |
| Blackbox probe | `charts.nedsi.io` down | The SLO's burn-rate alerts, as for the radar | An alert by the paging policy | Prometheus |

## Invariants

| Invariant | Owner | Why there |
| --- | --- | --- |
| No audio on the charts site | The generator's file allow-list; `site_markup.py`'s media rule as the second check | The generator is the last step before publishing; drum-charts never puts audio in the data, but this repository does not rely on it |
| No active content in a page image | The generator's SVG allow-list; drum-charts checks the same list first | The data crosses a repository boundary; the CSP (`default-src 'none'`) is the defence behind it |
| The data comes from drum-charts' `main` | `drumcharts-data.sh` (cosign identity), before any use | Verification before extraction; Kyverno does not see the data image, which never runs |
| The site's PDFs are the release's | drum-charts' `site-data` job (digest comparison); `charts-check.sh` live | Both are built from one artifact; the comparison catches a broken workflow change |
| Every song in the data has a page and a PDF | The generator (one page per manifest entry, the exact file set) | One place that knows both the data and the pages |
| One nav on every host | `NAV` in `site_markup.py` | The existing owner of the shared nav |

## Testability

| What | How |
| --- | --- |
| Validation | Table tests in `manifest_test.go`, one per rule, on copies of the fixture changed by the test |
| SVG allow-list | `svg_test.go`: each forbidden construct of acceptance criterion 5 fails; a test over the 25 real page images, read from `$DRUMCHARTS_DATA` when set (the CI job sets it), skipped otherwise |
| Pages | The golden tree of the fixture; order by artist then title with a tie, and with an artist whose slug sorts differently (`soad-` against `sum41-`); plural forms; every `<img>` with integer `width` and `height` rounded from a decimal viewBox, and `alt`; two renders byte-identical |
| Output | The exact file set; the `.svg.gz` decompress to the `.svg`; directories 0755 and files 0644 under a `0077` umask |
| drum-charts header rule | `site-data.py` over a header with `subtitle` only, two `title` lines, a `title = \markup ...` line and an escaped quote: each fails; the 14 songs and `legend.ly` pass (checked while writing this revision) |
| Signature check | `drumcharts-check.sh` runs `drumcharts-data.sh` on the pin, and once with `DRUMCHARTS_IDENTITY` set to the `site-publish` identity, which must fail |
| Markup | `site_markup.py` over the real render in CI; `tests/test_site_markup.py` for `NAV` and the media rule |
| Serving | `site-serve-check.sh` (fixture), the `site-publish` smoke (real data), the PostSync smoke, the probe, `dast` |
| Layout | `layout-check.sh` with the golden home and two-page song pages |
| drum-charts | `site-data.py` runs on every push over the real songs; criterion 13 on a throwaway branch |
| End to end | `scripts/charts-check.sh` live; criterion 12 on the merge of task 9 |

## Edge cases

- A song removed or renamed in drum-charts: its page and PDF disappear
  with the next deploy and the old URLs answer `404`. No redirects: the
  drum-charts README says a correction is an edit, not a new file, so
  renames are rare.
- Two releases on one day: the data images differ by digest; Renovate
  follows `:main`, not tag names.
- A release whose `site-data` job failed: the site stays on the previous
  data; rerun the job. `charts-check.sh` reports the lag.
- A pin pull request that fails validation or the signature check: it
  stays open and red; the site is unchanged; the next drum-charts merge
  moves `:main` and Renovate updates the same pull request.
- A pin merged while `site-publish` runs: its concurrency group runs them
  one after the other, each on its own commit.
- A rerun of the drum-charts workflow on the same UTC day: the release
  job replaces that tag's assets with the new build (`--clobber`), so
  step 2 matches. On another day: a second release for the same commit
  (the existing tag scheme); the manifest carries the tag of the run
  that moved `:main` last.
- Two merges minutes apart, or a rerun of an older commit: only the run
  for the head of `main` moves `:main` (step 6), so Renovate never
  proposes older data.
- A three-page chart: the third page wraps below the first on wide
  screens; the page count on the home page says so before it is opened.
- Titles with `&`, `<` or quotes: `html/template` escapes them; the
  header rule refuses `"` and `\`, which LilyPond would need escaped.
- The legend has no artist: the song template takes an empty artist and
  prints the legend's own lead instead.
- A phone at 390 px: an A4 page is about 350 px wide; the notation is
  small but sharp, pinch zoom works, and the PDF is one tap away.
- The GHCR package left private: the first pull in task 3 fails with
  `unauthorized`; the operator sets it public (task 2).
- `pdftocairo` on the runner (Ubuntu 24.04, cairo 1.18) writes
  presentation attributes, as the 26.11 build checked here does. A later
  cairo that writes `style` attributes fails the allow-list on the
  drum-charts pull request, before anything is published.

## Why it is like this

- A data image, not release assets: Renovate can follow a digest, and it
  cannot order `charts-<date>-<sha>` tags. The image is the release's
  files and a manifest, signed by the workflow that built them, pinned
  in git, and verified before use. No token crosses the repositories.
- Rendered in the `homelab-site` image, not a ConfigMap and not its own
  app: the PDFs exceed a ConfigMap, and a second web server would bring
  an image, a signer identity, Kyverno exceptions and policies for static
  files. Rejected: a pod that downloads the release (egress, a site that
  changes without a commit).
- SVG pages through `<img>`: the only way to show a PDF page on every
  phone without JavaScript, a frame or a CSP change. Rendered in
  drum-charts, which already has poppler, so this repository keeps its
  rule that every tool is pinned by version and checksum.
- Rendered output not committed (unlike the radar): it depends on the
  pinned data, which is binary and changes with every release; CI renders
  the pinned data on every pull request that can change it, so the pin
  and the generator are always checked together.
- White sheets in both themes: notation is black on paper, and the
  screen matches the PDF a reader downloads.
- `:main` moves only for the head of `main`, and a rerun replaces the
  release's assets: the PDFs are not reproducible between builds, so
  without both a rerun could break the digest check for good or take
  the site back to older data through Renovate.

## Review responses

Review of the first draft (14 findings), all addressed:

| # | Finding | Response |
| --- | --- | --- |
| 1 | The `site` job never renders or serves the charts | `testdata/golden/` is the full render tree; `site-serve-check.sh` mounts it, `layout-check.sh` copies from it, `site-check.sh`'s filter gains `drumcharts/` ([Navigation and links](#navigation-and-links), [Checks](#checks)) |
| 2 | Same-day rerun fails for good; `:main` can go back | `release` uploads with `--clobber` on an existing tag; `site-data` has a concurrency group and moves `:main` only for the head of `main`; error table and edge cases corrected; Requirement 1.6 and criterion 15 added |
| 3 | Media rule on every host | Charts host only; a blog page with `<picture><source>` passes (Requirement 3.9, criterion 3) |
| 4 | Task 9 (was 8) could drop the song list | Keeps the Songs table and Next section, adds one line, checks one row per song |
| 5 | Non-integer viewBox | Decimal viewBox regex, bounds, `int(math.Round(v))` |
| 6 | Go tooling details | `go tool govulncheck`, `go.sum` cache path, `go mod tidy -diff`, `GOTOOLCHAIN: local` in the job and `site-publish` |
| 7 | Order rationale wrong | Filed by artist, header puts the artist on top; sort from the header, never the slug |
| 8 | No header regex | Regex inside the `\header` block; other `title =`/`subtitle =` lines are errors; checked on the 14 songs and the legend |
| 9 | File modes | 0755 directories, 0644 files, asserted by a golden test |
| 10 | Task 7 (was 6) if site-theme-language task 4 is open | Moves to a `blocked` issue linked to #1662 and the spec closes |
| 11 | Supersedes rows missing | Host glossary (task 3) and Requirement 4.3 (task 6 or 7) added |
| 12 | drum-charts pins have no updater | Copied at task 2, updated by hand; Renovate for drum-charts is its own issue, opened with task 2 |
| 13 | `bloodhound-gang-fuck` as a public URL | Decided, not asked (the brief leaves open decisions to the spec): renamed to `bloodhound-gang-foxtrot-uniform-charlie-kilo` in a new task 1 before any slug is published; later tasks renumbered |
| 14 | Criterion 7 wording | Reworded |
