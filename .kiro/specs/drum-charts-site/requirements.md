---
kind: change
status: active
created: 2026-11-26
issue: 1761
---
# Requirements: drum-charts-site

## Introduction

The operator writes his drum charts in LilyPond in
[ned-si/drum-charts](https://github.com/ned-si/drum-charts) (public,
CC BY 4.0). Its CI engraves each song to a PDF, renders an MP3 and
publishes both in a GitHub release on every push to `main`
(`charts-<date>-<short sha>`; the latest when this spec was written is
`charts-2026-11-26-5387aa2`, 14 songs and the legend).

This spec puts the charts on a public page at `https://charts.nedsi.io/`,
under the public `nedsi.io` identity like the tech radar (operator,
2026-11-26: "charts: no mp3, just the charts, and on nedsi.io, maybe
charts.nedsi.io? If so, don't forget to add it to the navigation bar.
And let's have not only a possibility to dl the charts, but also display
them directly."). Each song can be read in the browser and downloaded
as a PDF. No audio is published. The pages follow the other public
sites: no JavaScript, the shared layout and navigation bar, the theme
endpoint and the English and French structure of
[site-theme-language](../site-theme-language/requirements.md), the CSP
and headers of [public-website](../public-website/requirements.md)
Requirement 3.2, served by the cluster behind the shared Gateway.

The work spans two repositories: ned-si/drum-charts publishes the data,
this repository renders and serves it. Each task in
[tasks.md](tasks.md) names its repository.

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **Charts site**: the pages at `https://charts.nedsi.io/`.
- **Song**: one finished song of drum-charts, `songs/<slug>.ly`, and its
  PDF `<slug>.pdf` in a release.
- **Slug**: the song's file name without `.ly`
  (`tool-schism`), the drum-charts naming rule `<artist>-<title>`. It
  becomes a public URL (`/<slug>/`) and the download name
  (`<slug>.pdf`). `bloodhound-gang-fuck` is renamed
  `bloodhound-gang-foxtrot-uniform-charlie-kilo` in task 1, before any
  slug is published ([Decided defaults](#decided-defaults)).
- **Legend**: `legend.ly`, built to `legend.pdf`, which explains the note
  heads.
- **Page image**: one page of a PDF as an SVG file, `<slug>-<n>.svg`.
- **Manifest**: `charts.json`, the list of songs with their metadata
  ([design, Manifest](design.md#manifest)).
- **Site data**: the manifest, the PDFs and the page images of one build.
- **Data image**: `ghcr.io/ned-si/drum-charts`, an OCI image holding the
  site data under `/charts/` and nothing else, built and signed by the
  drum-charts workflow.
- **Pin**: the data image reference by digest in
  `drumcharts/source.yaml` of this repository.
- **Generator**: the Go program in `drumcharts/` that validates the site
  data and renders the charts site.
- **Public pages**, **shared layout**, **navigation bar**: as defined in
  the [public-website spec](../public-website/requirements.md#glossary).
- **Preferences**, **theme endpoint**, **message catalogue**: as defined
  in the [site-theme-language spec](../site-theme-language/requirements.md#glossary).

## Requirement 1: The site data, from drum-charts

**User story:** As the operator, I want the charts site to show exactly
what a drum-charts release holds, without copying files by hand.

1. THE drum-charts `build` workflow SHALL produce the site data on every
   push, from the same build as the release: the manifest, each song's
   PDF, one page image per PDF page, and the legend's PDF and page
   images. It SHALL contain no audio file.
2. THE manifest SHALL hold, for each song, its slug, its artist (the
   `title` of the song's `\header`), its title (the `subtitle`) and its
   page count (from the PDF), and for the build its release tag and
   commit ([design, Manifest](design.md#manifest)).
3. THE workflow SHALL fail when a song has not exactly one `title` and
   one `subtitle`, a header string holds a `\` or a `"`, a slug breaks
   the naming rule or is reserved, a song's page images do not match its
   page count, or a page image fails the allow-list of
   [design, Page images](design.md#page-images).
4. ON `main`, after the release, THE workflow SHALL push the data image
   as `:<sha>` and `:main` for `linux/amd64` and `linux/arm64`, signed
   keyless by its own workflow identity and with a signed SLSA
   provenance. The package SHALL be public.
5. THE PDFs in the data image SHALL be byte-identical to the release's
   PDFs of the same commit, also after a rerun of the workflow (the PDFs
   are not reproducible between builds, so a rerun replaces the
   release's assets).
6. `:main` SHALL move only to the data image of the current head of
   drum-charts' `main`: a run that finishes after a newer one, or a
   rerun of an older commit, SHALL leave it where it is.

## Requirement 2: From a release to the live site, with no manual step

**User story:** As the operator, I want a new chart on the site soon
after I merge it, and nothing to do for it.

1. THIS repository SHALL pin the data image by digest in
   `drumcharts/source.yaml`. Renovate SHALL follow the digest of `:main`
   and open its update as its own pull request, automerged on green CI
   with no release age.
2. BEFORE the site data is used, CI and `site-publish` SHALL verify the
   data image's signature against the identity
   `https://github.com/ned-si/drum-charts/.github/workflows/build.yaml@refs/heads/main`
   and fail when it does not match. Nothing is deployed then.
3. A merge that changes the pin SHALL rebuild the `homelab-site` image
   with the rendered charts site; its digest pull request deploys it, as
   for any blog change.
4. THE generator SHALL validate the site data before rendering (the
   rules of [design, Validation](design.md#validation)). When any file
   breaks a rule it SHALL exit non-zero, list every broken rule with its
   file, and leave no output.

## Requirement 3: The pages

**User story:** As a drummer, I want to find a song, read it on my phone
or my screen, and download it to print or keep.

1. THE home page `/` SHALL list every song of the manifest once, ordered
   by artist, then title, both compared case-insensitively. Each row
   SHALL show the title (a link to the song's page), the artist, the
   page count and a link to its PDF.
2. EACH song SHALL have a page `/<slug>/` with its title, artist and page
   count, a link to download its PDF, and every page image in order as
   an `<img>` with a text alternative. From `60rem` wide two pages sit
   side by side, the way the chart lies on a music stand; below that,
   one column.
3. THE legend SHALL have a page `/legend/` built the same way, linked from
   the home page and from every song page.
4. EVERY PDF SHALL be served at `/pdf/<slug>.pdf` (`/pdf/legend.pdf` for
   the legend) as `application/pdf` with `Content-Disposition:
   attachment`, and every link to it SHALL carry the `download`
   attribute.
5. THE page images SHALL show a white sheet with black notation in both
   themes, as the PDF prints, with a border in the theme's rule colour.
6. THE home page SHALL carry a short intro in the operator's voice, the
   number of songs and the date of the release they come from, the
   licence (CC BY 4.0 with its link), the attribution ("the songs belong
   to their authors") and a link to the source repository.
7. EVERY page SHALL carry the shared layout, the navigation bar with
   "Charts" marked current, the preferences and the site's footer.
8. THE pages SHALL read without horizontal scrolling from 320 px wide up
   to a desktop screen, and SHALL allow zooming (no `maximum-scale` or
   `user-scalable` in the viewport).
9. NO page of the charts site SHALL contain an `<audio>`, `<video>`,
   `<source>`, `<embed>` or `<object>` element or a link to an audio
   file, and the charts site SHALL serve no audio file. The rule covers
   `charts.nedsi.io` only; the other hosts keep their own markup rules.
10. EVERY user-visible string SHALL come from the generator's message
    catalogue. Song titles and artists come from the manifest and are
    never translated.
11. THE Bloodhound Gang chart SHALL be published under the slug
    `bloodhound-gang-foxtrot-uniform-charlie-kilo`, its title, renamed in
    drum-charts before the first slug goes public.

## Requirement 4: Static and hardened

**User story:** As the operator, I want the charts site to add no attack
surface beyond static files.

1. THE pages SHALL contain no JavaScript, no inline style, no form, no
   iframe, no web font and no third-party resource; they SHALL be
   rendered before deployment, never in the browser or the pod.
2. EVERY response on `charts.nedsi.io`, the PDFs and page images
   included, SHALL carry the headers and CSP of public-website
   Requirement 3.2. Only `GET` and `HEAD` SHALL be answered (`405`
   otherwise); unknown paths answer `404` with the headers.
3. THE charts site SHALL be served by the `website` app from the
   `homelab-site` image ([design, Serving](design.md#serving)): no new
   pod, namespace, image in the cluster or network policy.
4. A page image SHALL hold only the elements and attributes of the
   allow-list, and only references inside itself (`#id`). The generator
   SHALL refuse any other file.
5. THE charts site SHALL show no personal data (public-website
   Requirement 4): song titles, artists and the author name `nedsi`
   only.

## Requirement 5: Its own address

**User story:** As a reader, I want the charts at one short address,
reachable from every public page.

1. THE charts site SHALL be served at `https://charts.nedsi.io/` through
   the shared Gateway, with its own certificate from cert-manager and an
   A record created by external-dns, DNS only.
   `http://charts.nedsi.io/<path>` SHALL answer `301` to
   `https://charts.nedsi.io/<path>`.
2. `charts.nedsi.io` SHALL be in the pentest scope and in the blackbox
   probe list as app `charts`, with the 99.5% SLO and a row in the
   user-facing app table of `docs/sre.md`.
3. THE website PostSync smoke, `scripts/ci/site-serve-check.sh` and the
   `site-publish` image smoke test SHALL cover the host
   ([design, Checks](design.md#checks)).

## Requirement 6: Navigation and links

**User story:** As a reader of any public page, I want to find the
charts from it.

1. THE navigation bar of every public page SHALL gain the link "Charts"
   to `https://charts.nedsi.io/`, after "Tech radar": on `nedsi.io`,
   `blog.nedsi.io`, `homelab.nedsi.io`, `techradar.nedsi.io` and the
   charts site. `NAV` in `scripts/ci/site_markup.py` SHALL list it, so
   the nav check stays green on every host.
2. THE landing page SHALL list the charts in its overview, after the
   tech radar, and its "Drum charts" card SHALL link the charts site.
3. THE privacy page's cookie table SHALL name the drum charts among the
   hosts the theme cookie is sent to.
4. `scripts/ci/layout-check.sh` SHALL measure the charts home page and a
   song page with the other public pages.
5. THE README (Services table, the public pages line, the repository
   layout) and the website docs SHALL list the charts site where they
   list the tech radar.

## Requirement 7: English and French

**User story:** As a French-speaking reader, I want the charts site in
French, like the other public pages.

1. ENGLISH SHALL be served at `/`, `/<slug>/` and `/legend/`; French at
   the same paths under `/fr/`, with the language toggle, `lang`,
   canonical and `hreflang` of site-theme-language Requirement 4. The
   French pages ship after site-theme-language task 4, which defines the
   toggle and the per-language `NAV`.
2. THE catalogue SHALL hold every string of
   [design, Strings](design.md#strings) in English and French, with the
   catalogue test of site-theme-language Requirement 4.9; dates SHALL
   follow `fr-CH` on French pages.
3. EVERY French string SHALL be proposed to the operator next to its
   English original and published only with his corrections. Until then
   every string in the design's table is marked "awaiting the operator's
   review".

## Requirement 8: Built and tested like the radar

**User story:** As the operator, I want the generator held to the same
standard as the tech radar's Go code.

1. EVERY pull request touching `drumcharts/` or the scripts that use it
   SHALL run, inside `ci`: `golangci-lint run` (the dashboard's
   configuration), `go vet`, `govulncheck`, `go mod verify`,
   `go test -race` with the validation, allow-list and golden tests, the
   signature check and render of the pinned data image, and
   `site_markup.py` over the rendered pages.
2. Renovate SHALL update the module's Go toolchain with the dashboard's
   and the tech radar's.

## Non-functional requirements

- Cost: nothing paid. GitHub Actions and GHCR on public repositories.
- Size: a page image at most 4 MiB as a file (the largest today is
  about 0.6 MiB) and served gzipped (about 70 KiB); the site data at
  most 64 MiB.
- Freshness: a drum-charts merge is live within 24 hours, normally
  within a few hours (Renovate's polling of GHCR sets the pace).
- Language: English, British spelling; the intro in the operator's
  voice; no em dashes.

## Acceptance criteria

1. On `https://charts.nedsi.io/`, `/tool-schism/`, `/pdf/legend.pdf` and
   `/pages/legend-1.svg`, `curl -sI` returns `200` and every header of
   public-website Requirement 3.2; `/pdf/legend.pdf` has `Content-Type:
   application/pdf` and `Content-Disposition: attachment`;
   `/pages/legend-1.svg` with `Accept-Encoding: gzip` has
   `Content-Type: image/svg+xml` and `Content-Encoding: gzip`;
   `curl -s -X POST -o /dev/null -w '%{http_code}'
   https://charts.nedsi.io/` prints `405`; `/nope` returns `404` with
   the headers; `curl -sI http://charts.nedsi.io/x` returns `301` with
   `Location: https://charts.nedsi.io/x`. [3.4, 4.2, 5.1]
2. `scripts/charts-check.sh` passes live: the song pages linked from `/`
   are exactly the PDFs of the latest drum-charts release minus
   `legend.pdf`; each song page has one `<img>` per PDF page, each
   answering `200` as `image/svg+xml`; each `/pdf/<slug>.pdf` has the
   SHA-256 of the release asset; the same for the legend. It prints the
   release tag. [1.5, 2.3, 3.1-3.4]
3. `/pdf/<slug>.mp3` and `/<slug>.mp3` answer `404` for every MP3 of the
   release; `site_markup.py` fails a `charts.nedsi.io` page with an
   `<audio>` element or a link to an `.mp3`, passes the rendered charts
   site, and passes a `blog.nedsi.io` page with `<picture><source>`.
   [3.9]
4. Unit tests: each rule of [design, Validation](design.md#validation)
   has a failing case (unknown schema, unknown key, duplicate or
   reserved slug, missing file, extra file such as an `.mp3`, page count
   0 or 4, empty artist, bad release tag); the clean fixture renders.
   [2.4]
5. Allow-list tests: a page image with `<script>`, an `onload`
   attribute, `<foreignObject>`, `<image>`, a `style` attribute, an
   `href` to `https:`, or a `<!DOCTYPE>` each fails; the 25 page images
   of `charts-2026-11-26-5387aa2` pass. [4.4]
6. A golden tree for the fixture, the whole render (home, a 1-page and
   a 2-page song, the legend, page images, PDFs, stylesheets): the
   render equals it file by file, two renders give the same bytes, the
   `.svg.gz` files included, and every directory is 0755 and every file
   0644. The `site` job runs on a change under `drumcharts/`.
   [3.1-3.3, 3.6]
7. `ci` runs the checks of 8.1 on a pull request touching `drumcharts/`.
   `scripts/ci/drumcharts-data.sh` fails on the pinned image when
   `DRUMCHARTS_IDENTITY` is set to the `site-publish` identity (the
   expected identity of another workflow, so no signature matches), and
   on a pin that is not
   `ghcr.io/ned-si/drum-charts:main@sha256:<64 hex>`. [2.2, 8.1]
8. `dig +short charts.nedsi.io` returns the WAN address;
   `scripts/published-hostnames.sh` prints `charts.nedsi.io`;
   `scripts/pentest-scope-check.sh` passes; `probe_success{app="charts"}`
   is 1; the Argo CD application `website` is Synced and Healthy. [5.1,
   5.2]
9. Every public page's navigation bar has "Charts" after "Tech radar":
   `site_markup.py` over the blog, the landing page, the dashboard's
   golden pages, the tech radar and the charts site in `ci`, and
   `curl -s` of `https://nedsi.io/`, `https://blog.nedsi.io/`,
   `https://homelab.nedsi.io/`, `https://techradar.nedsi.io/` and
   `https://charts.nedsi.io/` live. The landing page links
   `https://charts.nedsi.io/` in its overview and its card. [6.1, 6.2]
10. `scripts/ci/layout-check.sh` passes with the golden tree's charts
    home page and two-page song page in its list, and
    `scripts/ci/site-serve-check.sh` passes with the golden tree mounted
    at `/usr/share/nginx/charts`. [3.8, 5.3, 6.4]
11. Screenshots at 1920x1080 and 390x844, in the dark and the light
    theme (the light one set through `/set-theme/light/` in the same
    browser profile), of the charts home page, `/tool-schism/` and the
    four other hosts' home pages show "Charts" in the nav, the song list
    and the two sheets (side by side at 1920, stacked at 390) on white,
    with no horizontal scrollbar. [3.2, 3.5, 3.8, 6.1]
12. The drum-charts merge of task 9 reaches the live site with no manual
    step: Renovate's pin pull request and the `homelab-site` digest pull
    request merge by themselves, and `scripts/charts-check.sh` then
    prints the new release tag. [2.1, 2.3]
13. In drum-charts, a throwaway branch with a song whose `\header` has no
    `subtitle` fails `build` with an annotation on that file. [1.3]
14. `curl -s https://charts.nedsi.io/fr/` has `<html lang="fr-CH">`, the
    three `hreflang` links, the toggle to `/`, and only strings the
    operator corrected; `go test ./...` passes the catalogue test. [7]
15. In drum-charts, "Re-run all jobs" of the newest `main` run passes;
    afterwards the release's PDF digests equal the PDFs under `/charts/`
    in `:main`. "Re-run all jobs" of an older `main` run passes with the
    notice `:main not moved`, and the digest of `:main` is unchanged.
    [1.5, 1.6]
16. `https://charts.nedsi.io/bloodhound-gang-foxtrot-uniform-charlie-kilo/`
    answers `200`; no path on the charts site and no file name in the
    data image contains `bloodhound-gang-fuck`. [3.11]

## Out of scope

- Audio of any kind, and the drum-charts `drafts/` and `archive/`.
- Search, filters, tags or a per-song history: one list, history in the
  drum-charts releases.
- A print stylesheet: the PDF is the printable form.
- Translating song titles and artists.
- A dashboard card or certificate tile for `charts.nedsi.io`: the
  dashboard's allow-lists change in its own spec if wanted.
- An alert for a site that lags the latest release: the release and the
  data image come from one workflow run, and `scripts/charts-check.sh`
  shows the lag on demand.

## Supersedes

These lines of other specs change when the task named here merges, and
that task edits them to point here:

| Spec and line | Becomes | Task |
| --- | --- | --- |
| site-theme-language requirements, Glossary, **Host** | Adds `charts.nedsi.io`, static files served by the `website` nginx pod like the tech radar | 3 |
| site-theme-language requirements, Requirement 4.3, the French nav link texts | Adds the French label for Charts, after the operator's review | 6, or 7 if site-theme-language task 4 merges after task 6 |
| site-theme-language design, Privacy page, the cookie table's "Sent to" row | Names the drum charts with the blog, the dashboard and the tech radar | 6 |
| site-theme-language design, Language, Navigation table | Gains the row Charts, its French label (after the operator's review), `https://charts.nedsi.io/fr/` from task 7 of this spec, `https://charts.nedsi.io/` before | 6 |

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Spec | A change spec of its own, `drum-charts-site`, not an amendment of public-website | public-website is a change spec with its own open tasks (11, 12); this is a new host with a data flow across two repositories, which is how tech-radar got its own spec |
| Host | `charts.nedsi.io` (operator, 2026-11-26) | The operator's choice, under the public identity |
| Data flow | drum-charts publishes a signed data image; this repository pins it by digest, Renovate follows `:main`, `site-publish` renders it into `homelab-site` ([design](design.md#how-the-charts-reach-the-site)) | No cross-repository token, the exact files pinned in git, the update path Renovate already runs for the site and the dashboard |
| Display | Each PDF page as an SVG `<img>`, rendered by `pdftocairo` in drum-charts CI ([design](design.md#how-a-chart-is-displayed)) | Works on every browser and phone with the CSP unchanged; sharp at any zoom |
| Download | `/pdf/<slug>.pdf` with `Content-Disposition: attachment` and the `download` attribute | The file of the release, saved, not opened in a viewer |
| Order | Artist, then title, case-insensitive, from the header fields (never the slug) | The charts are filed by artist, and the chart header puts the artist on top |
| Slugs | Public as they are, except `bloodhound-gang-fuck`, renamed `bloodhound-gang-foxtrot-uniform-charlie-kilo` in drum-charts (task 1) | The slug becomes a URL and a download name on the public identity the operator plans to present; the new name is the song's title, so it follows the naming rule `<artist>-<title>` better than the old one. A rename is cheap only before the URL is published. Rejected: keeping it (a profanity in a public URL), a slug map in the manifest (a second name to keep in sync) |
| Metadata | Title, artist, page count; the release tag and date once on the home page | What a drummer picks a chart by; the page count says whether it needs a stand for two |
| Paper | White sheets in both themes | Notation reads as printed; an inverted chart reads as a negative |
| Generator | Go, `drumcharts/`, standard library only | The tech radar's language and tooling; validation and the allow-list are tested code |
| Navigation | "Charts" after "Tech radar" (operator, 2026-11-26: "Charts") | The operator's label; the newest site last before About |
| Merge | Each task merges after its review round and is checked live (operator, 2026-11-24: no approval pauses); French strings wait for the operator's corrections | Same as the other website work; the operator's rule for French text |
