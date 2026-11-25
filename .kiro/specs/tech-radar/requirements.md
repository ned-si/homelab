---
kind: change
status: active
created: 2026-11-25
issue: 1671
---
# Requirements: tech-radar

## Introduction

The homelab runs on a few dozen technologies, and as many again were
considered, researched or rejected along the way. The reasons are spread
over `docs/decisions.md`, the "Why it is like this" sections, the specs
and the issues. A tech radar puts them on one page: what the homelab
uses, what it is trying, what it is looking at and what it decided
against, each with a one-line reason and a link to the decision.

This spec builds it at `https://techradar.nedsi.io/` in the look and
data model of [Zalando's tech radar](https://github.com/zalando/tech-radar):
four quadrants, four rings (Adopt, Trial, Assess, Hold), numbered blips
and a legend. It is rendered to static HTML and SVG at build time, with
no JavaScript in the browser, the CSP and headers of the public-website
spec and the shared layout and navigation bar of that spec's task 12.
The operator asked for it on 2026-11-24 ("we need a techradar
(zalando) at techradar.nedsi.io") and for its content on 2026-11-25:
everything the homelab uses, and everything considered, researched or
rejected.

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **Radar**: the page at `https://techradar.nedsi.io/`: the SVG chart and
  the legend.
- **Entry**: one technology or technique on the radar, one item of
  `techradar/entries.yaml`.
- **Quadrant**: one of four categories: `techniques`, `tools`
  (tools and languages), `platform` (services that run in the cluster),
  `infrastructure` (hardware, operating system, network, storage,
  cloud).
- **Ring**: how the homelab stands on an entry, from the centre out:
  - `adopt`: in use, and the homelab would choose it again;
  - `trial`: in use on trial, or in use with a known limit being worked
    on;
  - `assess`: researched or planned, not in use;
  - `hold`: decided against, removed or replaced; the reason says why.
- **Blip**: an entry's mark on the chart, numbered like its legend item.
- **Generator**: the Go program in `techradar/` that validates the
  entries and renders the page.
- **Public pages**, **shared layout**, **navigation bar**: as defined in
  the [public-website spec](../public-website/requirements.md#glossary).

## Requirement 1: The data

**User story:** As the operator, I want the radar's content in one file
in the repository, so a change of mind is a one-line pull request.

1. THE entries SHALL be one YAML file, `techradar/entries.yaml`, each
   with `name`, `quadrant`, `ring`, `reason` (one line) and optionally
   `link` and `moved`, the fields of Zalando's model.
2. `link`, when set, SHALL point to the decision: an issue (`#<n>`) or
   a file or directory of this repository, with an optional anchor
   (`docs/decisions.md#no-service-mesh`, `.kiro/specs/<name>/`); the
   generator SHALL fail on an issue number that is not a number or a
   path that does not exist.
3. `moved` SHALL be `up` (moved towards the centre), `down` (moved
   out) or `new`, and SHALL be absent in the first release.
4. THE generator SHALL fail on an unknown key, quadrant, ring or `moved`
   value, a duplicate name (case-insensitive), an empty reason, a reason
   over 140 characters, on two lines, or holding an em dash.
5. THE first release SHALL hold every entry of the
   [design's inventory](design.md#inventory), the rings following the
   recorded decisions; a `hold` entry's reason SHALL say why.

## Requirement 2: The page

**User story:** As a reader, I want to see at a glance what the homelab
is built with and why, on any screen.

1. THE page SHALL show the four quadrants and the four rings with their
   names, one blip per entry inside its quadrant and ring, numbered, in
   Zalando's layout: rings Adopt to Hold from the centre, quadrant names
   at the corners, ring names along the horizontal axis, a circle for an
   unchanged entry, a triangle up or down for `moved`, a star for `new`.
2. THE legend SHALL list every entry by quadrant, then ring, with its
   number, its name (a link when `link` is set), its ring and its
   reason; the numbering SHALL follow the legend's order.
3. NO two blips SHALL overlap, and every blip SHALL sit inside its
   quadrant and ring with a margin; the placement SHALL be
   deterministic, so the same entries render the same bytes.
4. THE chart SHALL be one inline SVG with a `viewBox`, styled by class
   only, `role="img"` and an `aria-label` that points to the legend;
   each blip SHALL carry a `<title>` with its number, name and ring.
5. THE page SHALL read without horizontal scrolling from 320 px wide up
   to a desktop screen; at 390 px the legend follows the chart in one
   column.
6. EVERY text, ring and blip colour SHALL have a contrast of at least
   4.5:1 against its background (3:1 for the blips and ring lines as
   graphics, WCAG 2.2 1.4.11), in the site's light and dark palettes,
   checked by a test.
7. THE page SHALL carry the shared layout, the navigation bar (with
   "Tech radar" marked current) and the site's footer, and a short
   intro: what the radar is, what the rings mean, that it follows
   Zalando's, and when it was last generated.

## Requirement 3: Static and hardened

**User story:** As the operator, I want the radar to add no attack
surface beyond a static page.

1. THE page SHALL contain no JavaScript, no inline style, no form, no
   iframe, no web font and no third-party resource; it SHALL be built
   before it is deployed, never in the browser or the pod.
2. EVERY response on `techradar.nedsi.io` SHALL carry the headers and
   CSP of public-website Requirement 3.2, and only `GET` and `HEAD`
   SHALL be answered (`405` otherwise); unknown paths answer `404` with
   the headers.
3. THE radar SHALL be served by the `website` app (the decision in
   [design, Own app or a page of the site](design.md#own-app-or-a-page-of-the-site)):
   no new pod, image or network policy.
4. THE radar text SHALL pass the site's content rules: public-website
   Requirement 4 (no household data, nothing about security devices),
   gitleaks, the local deny-list hook, and no entry from the download
   stack (the *arr apps, qBittorrent, indexers), which the public
   pages never name.

## Requirement 4: Its own address

**User story:** As a reader, I want the radar at one short address,
reachable from every public page.

1. THE radar SHALL be served at `https://techradar.nedsi.io/` through the
   shared Gateway, with its own certificate issued by cert-manager and
   an A record created by external-dns, DNS only.
   `http://techradar.nedsi.io/<path>` SHALL answer `301` to
   `https://techradar.nedsi.io/<path>`, with no port.
2. `techradar.nedsi.io` SHALL be in the pentest scope (and so the `dast`
   targets) and in the blackbox probe list as app `techradar`, with the
   99.5% SLO and a row in the user-facing app table of `docs/sre.md`.
3. THE navigation bar of every public page SHALL gain the link "Tech
   radar" to `https://techradar.nedsi.io/`, after Homelab, and the
   landing page SHALL introduce it in its overview and with a card.
4. THE radar page SHALL be in the layout check of public-website
   Requirement 7.4.

## Requirement 5: Built and tested like the dashboard

**User story:** As the operator, I want the generator held to the same
standard as the dashboard's Go code.

1. EVERY pull request touching `techradar/` or the rendered page SHALL
   run, inside `ci`: `golangci-lint run` (the dashboard's configuration,
   Google Go Style Guide), `go vet`, `govulncheck`, `go mod verify`,
   `go test -race` with the validation, placement and golden tests, and
   a check that the committed page equals the generator's output.
2. Renovate SHALL update the module's dependencies and Go toolchain.

## Non-functional requirements

- Cost: nothing paid.
- Size: the rendered page under 300 KiB, well inside a ConfigMap's
  1 MiB.
- Language: English, British spelling; the intro in the operator's
  voice, the reasons in plain reference text; no em dashes; "agents",
  never "bots".

## Acceptance criteria

1. `curl -sI https://techradar.nedsi.io/` returns `200` and every header
   of public-website Requirement 3.2; `curl -s -X POST -o /dev/null -w
   '%{http_code}' https://techradar.nedsi.io/` prints `405`;
   `/nope` returns `404` with the headers;
   `curl -sI http://techradar.nedsi.io/x` returns `301` with `Location:
   https://techradar.nedsi.io/x`. [3.2, 4.1]
2. The page contains no `<script`, `style=`, `<form` or `<iframe`, and
   no `src=` to another origin (`scripts/ci/site_markup.py`). [3.1]
3. Unit tests: an entry with an unknown ring, a duplicate name, a
   two-line reason, an em dash, a missing link path, or a name from the
   download stack each fail the generator; the clean file passes.
   [1.2-1.4, 3.4]
4. A placement test over the real entries and over 40 entries in one
   segment finds no overlap and every blip inside its segment; two runs
   give the same bytes; the golden page matches. [2.3]
5. The legend lists every entry of `entries.yaml` once, numbered as the
   chart; the contrast test passes in both palettes. [2.1, 2.2, 2.6]
6. `dig +short techradar.nedsi.io` returns the WAN address;
   `scripts/published-hostnames.sh` prints `techradar.nedsi.io` and
   `scripts/pentest-scope-check.sh` passes;
   `probe_success{app="techradar"}` is 1. [4.1, 4.2]
7. Every public page's navigation bar has "Tech radar" after Homelab
   (`site_markup.py`), the landing page links the radar twice (overview
   and card), and `scripts/ci/layout-check.sh` passes with the radar in
   its list. [4.3, 4.4]
8. `ci` runs the checks of 5.1 on a PR touching `techradar/`, and fails
   when the committed page is stale. [5.1]

## Out of scope

- A radar per area or several editions: one radar, history in git.
- JavaScript features of Zalando's radar (hover highlight, filters);
  `<title>` gives the hover text.
- A dashboard card or certificate tile for `techradar.nedsi.io`: the
  dashboard's allow-lists change in its own spec if wanted.
- Entries for the household apps' internals and anything under
  Requirement 3.4.

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Name | Spec and module `tech-radar` / `techradar/`, host `techradar.nedsi.io` (operator, 2026-11-24) | The operator's host name |
| Own app or page | A page of the site: rendered into the ConfigMap `website-techradar`, served by the `website` nginx pod under its own server name ([design](design.md#own-app-or-a-page-of-the-site)) | Static files need no pod, image or policy of their own; a ConfigMap is live with the merge, like the landing page |
| Generator | Go, `techradar/cmd/techradar`, standard library plus one YAML parser | The dashboard's language and tooling; placement and validation are tested code |
| Rendered output | Committed under `apps/website/techradar/`, checked in CI against the generator, like `deploy/` | Argo CD serves what git holds; a stale page fails CI |
| Quadrants | Techniques (top left), Tools and languages (top right), Platform (bottom left), Infrastructure (bottom right) | A homelab's choices split along these lines; Zalando's own quadrant names fit a company, not a homelab |
| Rings | Adopt, Trial, Assess, Hold, with the glossary's meanings | Zalando's rings; the meanings tied to what the repository records |
| Links | Repository paths and issues only | The reasons live in the repository; no third-party link to rot |
| Privacy | Nothing about security devices and nothing from the download stack, so Frigate and Scrypted (cameras) and the *arr stack are left off | public-website Requirement 4.1 and the dashboard's rule on the download stack |
| Merge | Each task merges after its review round and is checked live (operator, 2026-11-24: no approval pauses) | Same as the other website work |
