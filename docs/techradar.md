# Tech radar

`https://techradar.nedsi.io/` lists what the homelab uses, tries, assesses
and decided against, each with a one-line reason and a link to the decision.
It follows [Zalando's tech radar](https://github.com/zalando/tech-radar):
four quadrants, four rings, numbered blips and a legend. The page is static
HTML and SVG rendered from [`techradar/entries.yaml`](../techradar/entries.yaml)
by the Go generator in [`techradar/`](../techradar/), and served by the
`website` nginx pod, in English at `/` and in French at `/fr/`. The theme
and the language toggle work as on the other public pages
([website.md](website.md#theme)). The design and its decisions are in
[spec tech-radar](../.kiro/specs/tech-radar/design.md).

## Rings and quadrants

| Ring | Meaning |
| --- | --- |
| `adopt` | In use, and the homelab would choose it again |
| `trial` | In use on trial, or in use with a known limit being worked on |
| `assess` | Researched or planned, not in use |
| `hold` | Decided against, removed or replaced; the reason says why |

| Quadrant | Holds |
| --- | --- |
| `techniques` | Practices: GitOps, SLOs, spec-driven development |
| `tools` | Tools and languages used to build and check the repository |
| `platform` | Services that run in the cluster, household apps included |
| `infrastructure` | Hardware, operating system, network, storage, cloud |

## Add or move an entry

1. Edit `techradar/entries.yaml`. An entry:

   ```yaml
   - name: Talos Linux
     quadrant: infrastructure
     ring: adopt
     reason: "Immutable, API-only nodes with the machine config in git."
     reason_fr: "Des *nodes* immuables, pilotés par API, avec la config machine dans git."
     link: "docs/talos.md"
   ```

   - `reason`: one line, at most 140 characters, no em dash.
   - `reason_fr` (required): the reason in Swiss French, with the same
     rules and the [translation conventions](website.md#translation-conventions).
     An English expression in italics is written `*nodes*`; the page
     sets it in `<em>`.
   - `link` (optional): `"#<issue>"` or a repository path with an optional
     anchor (`"docs/decisions.md#no-service-mesh"`, `".kiro/specs/<name>/"`).
     Quote it: a bare `#` starts a YAML comment.
   - `moved` (optional): `up` (towards the centre), `down` or `new`. The
     blip becomes a triangle or a star.
   - Set the top-level `updated` to today's date; the page prints it.

2. Render the page into `apps/website/techradar/`:

   ```sh
   task techradar:render
   ```

   Expected: task prints the `go run` line, exits 0, and
   `apps/website/techradar/index.html` and `index-fr.html` change. Both
   come from one placement, so the blips sit in the same place in both
   languages.
   An error names the entry and the rule it breaks, for example
   `"Sonarr": names "Sonarr", which the public pages never name`.

3. Commit `entries.yaml` and the rendered files in one pull request. Merging
   puts the change live: the ConfigMap `website-techradar` gets a new name
   hash and the `website` Deployment rolls.

The generator refuses an unknown key, quadrant, ring or `moved` value, a
duplicate name, a missing `reason_fr`, a link to a path that does not
exist, and any name or reason from the download stack or about security
devices (public-website Requirement 4.1).

The page's other strings (title, intro, legend, quadrant and ring names,
footer) are the message catalogue `catalogue` in
`techradar/internal/radar/i18n.go`, one map per language under the same
keys. A new string goes in both maps; `TestCatalogue` fails on a key in
one language only, an empty value, an em dash or "bot".

## How it is built and checked

| Piece | Where |
| --- | --- |
| Generator | `techradar/cmd/techradar`: `render -out <dir>` writes the page, `check -out <dir>` fails when the directory differs from a fresh render |
| Validation, placement, SVG, page | `techradar/internal/radar/`; the stylesheets and template in `assets/` |
| Strings | `techradar/internal/radar/i18n.go`: the catalogue, the languages (`Langs`) and the French dates |
| Rendered page | `apps/website/techradar/` (`index.html`, `index-fr.html`, `techradar.css`, `layout.css`, `theme-dark.css`, `theme-light.css`) |
| CI | the `techradar` job, `scripts/ci/techradar-check.sh`: golangci-lint with `dashboard/.golangci.yaml`, `go vet`, `govulncheck`, `go test -race` (with `TestCatalogue` and `TestContrast` on both palettes), `techradar check`, `site_markup.py` |

The job runs when a change touches `techradar/`, the rendered page, `docs/`,
`.kiro/specs/` or its scripts: entries link into `docs/` and the specs, so a
renamed file fails the check. Placement is seeded from each entry's quadrant,
ring and name, so the same entries render the same bytes. A segment too full
to place a blip fails the build and names the segment; widen the ring radii in
`place.go` or move an entry.

## How it is served

| Piece | Object |
| --- | --- |
| Name | `techradar.nedsi.io`, A record by external-dns from the `website` HTTPRoute |
| Certificate | `gateway/techradar-nedsi-io`, Secret `techradar-nedsi-io-tls` |
| Listeners | `https-nedsi-techradar` (443) on route `website`, with the site's security headers; `http-nedsi-techradar` (80) on route `website-http`, nginx port 8081 answers `301` |
| nginx | `apps/website/nginx.conf`, server `techradar.nedsi.io`, root `/usr/share/nginx/techradar` (the ConfigMap), `GET` and `HEAD` only; `location = /fr/` serves `index-fr.html`, `theme.conf` the theme |
| Probe and SLO | `https://techradar.nedsi.io/`, app `techradar`, 99.5% over 30 days ([sre.md](sre.md)) |

Check it live:

```sh
curl -sI https://techradar.nedsi.io/ | head -1
curl -s https://techradar.nedsi.io/fr/ | grep -o '<html lang="fr-CH">'
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://techradar.nedsi.io/
```

Expected: `HTTP/1.1 200 OK`, then `<html lang="fr-CH">`, then `405`.

## Why it is like this

- A page of the site, not its own app: static files need no pod, image,
  signature or network policy of their own, and a ConfigMap is live with the
  merge. Rejected: an image of its own, and the page inside the
  `homelab-site` image (every entry change would wait for a digest bump).
- Rendered at build time with no JavaScript: the CSP stays without
  `script-src`. Rejected: Zalando's `radar.js`, which draws the chart with D3
  in the browser.
- Rendered output in git: Argo CD serves what git holds, the reviewer sees
  the page change in the diff, and CI proves it is current. Rejected:
  rendering in an init container, which puts a Go toolchain in the pod.
- Links only into the repository: the radar points at decisions, not at
  vendors' pages.
