# Design: tech-radar

## Overview

A Go generator in `techradar/` reads `techradar/entries.yaml`,
validates it, places the blips and renders one HTML page with an inline
SVG chart, plus its stylesheet and the shared layout's copy, into
`apps/website/techradar/`. That directory is committed (rendered output,
checked by CI like `deploy/`) and becomes the ConfigMap
`website-techradar`, which the `website` nginx pod serves on its own
server name, `techradar.nedsi.io`. Merging an entry change puts it live
through Argo CD; no image is built.

## Own app or a page of the site

Decided here, 2026-11-25: a page of the site, served by the `website`
app.

| Option | For | Against |
| --- | --- | --- |
| **The `website` nginx pod, a ConfigMap rendered in git** (chosen) | No new pod, namespace, image, signer identity, network policy or SLO plumbing beyond the host; live with the merge, like the landing page; the HTTPRoute already sets the headers; the PostSync smoke and `site-serve-check.sh` already test nginx | The rendered HTML is committed (as `deploy/` is), so CI must check it is current |
| Inside the `homelab-site` image | One artefact for the static sites | Go in the image pipeline; every entry change waits for a digest bump |
| Its own app (`techradar` namespace, image, Deployment) | Isolation | A second static web server with its own image, signature, Kyverno identity, policies and probe, for a page with no runtime logic |
| A Hugo page | Hugo already builds the blog | Another host's page in the blog's build (one base URL per build), and polar placement in Go templates without tests |

## Layout

| Path | Holds |
| --- | --- |
| `techradar/go.mod` | Module `github.com/ned-si/homelab/techradar`, the Go version of `dashboard/`, one dependency: `go.yaml.in/yaml/v3` (strict decoding, `KnownFields`) |
| `techradar/entries.yaml` | The entries ([Data](#data)) |
| `techradar/cmd/techradar/` | `main.go`: `techradar render -out <dir>` and `techradar check -out <dir>` (exit 1 when the files differ from a fresh render) |
| `techradar/internal/radar/` | `model.go` (types, validation), `place.go` (placement), `svg.go` (the chart), `page.go` (`html/template`), `testdata/` (golden page) |
| `techradar/internal/radar/assets/` | `page.html`, `techradar.css` (embedded) |
| `apps/website/techradar/` | Rendered: `index.html`, `techradar.css`, `layout.css` (the shared layout's copy, checked by public-website task 12's copy check) |
| `docs/techradar.md` | How to add or move an entry, what the rings mean, how it is served; Why it is like this |

Code style: Google's Go Style Guide, as the dashboard
(`dashboard/.golangci.yaml`); `go-cmp` for test diffs.

## Data

```yaml
updated: 2026-11-25          # required, YYYY-MM-DD, printed on the page
entries:
  - name: Talos Linux
    quadrant: infrastructure   # techniques, tools, platform, infrastructure
    ring: adopt                # adopt, trial, assess, hold
    reason: Immutable, API-only nodes with the machine config in git.
    link: docs/talos.md        # optional: #<issue> or a repository path
    moved: up                  # optional: up, down, new; absent in release 1
```

Validation (`model.go`), each a table-tested error naming the entry:

- `updated` missing or not a valid `YYYY-MM-DD` date;
- unknown key (strict decoding), quadrant, ring or `moved`;
- duplicate `name`, case-insensitive;
- `reason` empty, over 140 characters, with a newline, or with `—`
  (U+2014);
- `link` not `#<digits>` and not an existing repository path (the part
  before `#`, resolved from the repository root, which `render` finds
  with `git rev-parse --show-toplevel` or `-root`);
- a name or reason matching the compiled deny list: the download stack
  (`sonarr`, `radarr`, `lidarr`, `prowlarr`, `bazarr`, `recyclarr`,
  `qbittorrent`, `torrent`, `indexer`) and security devices (`camera`,
  `nvr`, `frigate`, `scrypted`, `doorbell`, `alarm`, `lock`), word
  boundaries, case-insensitive.

Links render as `https://github.com/ned-si/homelab/issues/<n>` and
`https://github.com/ned-si/homelab/blob/main/<path>` (`tree/main/` for a
directory), so every link is the repository (`REPO` in `LINKS` of
`scripts/ci/site_markup.py`).

## The chart

Zalando's look, without its JavaScript:

- An SVG `viewBox="0 0 800 800"`, centre (400, 400). Ring radii 170,
  255, 330, 400 (Adopt to Hold), wider at the centre than Zalando's
  130, 220, 310, 400: the inner disc has the least area per ring width,
  and Adopt holds the most entries (up to 28 in Platform). With the
  placement below, a simulation over 200 seeds fits at least 33, 39,
  48 and 56 blips per segment, Adopt to Hold. Quadrants: Techniques top
  left, Tools and languages top right, Platform bottom left,
  Infrastructure bottom right. Two axis lines, the four ring circles,
  ring names along the horizontal axis (a deliberate change from
  Zalando's vertical labels, readable on a phone), quadrant names as
  the legend headings (the corners of a phone-width SVG are too small
  for text).
- Placement (`place.go`): for each quadrant and ring, the entries in
  legend order; each blip (radius 8) gets candidate points from a
  PRNG seeded with the FNV-1a hash of `quadrant/ring/name`, uniform in
  the segment's area, with a margin of 10 from the ring lines and the
  vertical axis and of 16 from the horizontal axis, which carries the
  ring names; the first candidate at least 18 from every placed blip wins; 500
  candidates without a fit fail the build, naming the segment. Same
  input, same bytes.
- Blips: a circle, a triangle (`moved: up` points to the centre,
  `down` away) or a star (`new`), filled with the ring's colour, the
  number in the middle, a `<title>` "12. Cilium (Platform, Adopt):
  <reason>". Each blip is an `<a href="#entry-<slug>">` to its legend
  item (`<li id="entry-<slug>">`); the slug is the name in lower case,
  runs of other characters as `-` (`Gateway API`: `gateway-api`), and a
  slug shared by two entries fails the build like a duplicate name.
- Hover label: a `<g class="blip-label">` in each blip's `<a>`, one
  `<text>` "Cilium · Adopt" with a halo in the background colour, on
  the side facing the centre (`blip-label-start` or `blip-label-end`),
  `visibility: hidden` until `:focus-visible` or, inside `@media
  (hover: hover)`, `:hover`; the other blips dim to 0.3 meanwhile,
  because later blips paint over the label (SVG has no z-index). The
  hover rule stays out of touch screens, so a tap follows the link
  instead of showing the label first. The target legend item gets an
  outline in the link colour (`li:target`). No script, no inline style:
  the CSP is unchanged. Numbers run
  through the legend: Techniques, Tools and languages, Platform,
  Infrastructure; inside each, Adopt to Hold; inside a ring, by name.
- Classes only: `ring-adopt`, `ring-trial`, `ring-assess`, `ring-hold`,
  `axis`, `ring-line`, `ring-name`, `blip`, `blip-number`, `blip-label`,
  `blip-label-start`, `blip-label-end`. The SVG's builder is tested to
  emit only `svg`, `a`, `g`, `circle`, `path`, `line`, `text` and
  `title`, numeric attributes, classes from that set, `href` to
  `#entry-<slug>`, `role="group"` (the blips are links, which
  `role="img"` would hide from screen readers), `aria-label`,
  `aria-hidden="true"` (the number and the label, which repeat the
  `<title>`) and `focusable="false"`.
- Ring colours, Zalando's hues tuned for contrast, defined for the
  light and dark palettes in `techradar.css` and checked by the
  contrast test (Requirement 2.6): Adopt green, Trial teal, Assess
  amber, Hold red; the blip number in the page background colour on
  the fill (4.5:1).

## The page

`page.html`, rendered with `html/template`:

1. The shared `<header class="site">` and `nav.site` (current: "Tech
   radar"), the shared layout's container.
2. `<h1>Tech radar</h1>` and the intro (operator's voice): what the
   homelab uses, tries, looks at and decided against, and why; the
   rings in one line each; "In the spirit of Zalando's tech radar." with
   a link to `https://github.com/zalando/tech-radar` (in `LINKS`); the
   date of `updated` in `entries.yaml`, so render and check depend on
   no git metadata.
3. The chart, full container width up to `64rem` (the blip numbers
   stay readable on a desktop screen), centred in its column.
4. The legend: four sections (`h2` per quadrant), each with four `h3`
   rings and an ordered list (`<ol>` with explicit `value`) of `number,
   name, reason`. A grid of two columns from `60rem`, one below.
5. The site's footer.

`techradar.css` holds the palette (the site's light and dark values),
the ring colours and the legend grid; the layout comes from
`layout.css`. No rule there repeats a rule of `layout.css`.

## Serving

Set up like `homelab.nedsi.io` (homelab-dashboard design, Address):

- Certificate `techradar-nedsi-io` in namespace `gateway`
  (`infrastructure/gateway/certificate-techradar-nedsi.yaml`), one SAN,
  the `letsencrypt` ClusterIssuer, the settings of `nedsi-io`; its own,
  so the live certificates are not reissued.
- Gateway listeners `https-nedsi-techradar` (443,
  `techradar-nedsi-io-tls`) and `http-nedsi-techradar` (80).
- HTTPRoutes: `website` gains the hostname and the `https-nedsi-techradar`
  parent (so the same `ResponseHeaderModifier` headers), `website-http`
  the hostname and `http-nedsi-techradar`.
- `apps/website/nginx.conf`: a server block `server_name
  techradar.nedsi.io; root /usr/share/nginx/techradar;` with the method
  limit, `try_files $uri $uri/ =404`, `max-age=300` for HTML and CSS, and
  the log format of the other blocks; the `$https_host` map entry
  `techradar.nedsi.io techradar.nedsi.io` for the `301`.
- `apps/website/kustomization.yaml`: the `website-techradar`
  ConfigMap from `techradar/`, mounted read-only at
  `/usr/share/nginx/techradar/` by the Deployment (the name hash rolls
  the pod on a change).
- DNS: external-dns creates the A record from the HTTPRoute. Operator
  first: no `techradar` record in the `nedsi.io` zone that external-dns
  does not own.
- Lists: `docs/pentest/scope.yaml` `public_hostnames`;
  `https://techradar.nedsi.io/` in
  `platform/blackbox-exporter/probes/probes.yaml` (app `techradar`), its
  SLO rules and `tests/prometheus/slo_test.yaml` like `nedsi` and
  `blog`, its row in `docs/sre.md`.
- Checks: `scripts/ci/site-serve-check.sh` (`200`, `405`, `404`, the
  `301`), the PostSync smoke (headers on `/` and a `404`, the `405`).

## Navigation and landing page

- `NAV` in `scripts/ci/site_markup.py` gains "Tech radar"
  `https://techradar.nedsi.io/` after Homelab; the blog's `baseof.html`,
  the landing page and the dashboard's `layout.html` follow (the
  dashboard's golden pages and screenshots with it).
- The landing page: the overview line of public-website design, Home
  and About text ("[Tech radar](https://techradar.nedsi.io/): what the
  homelab uses, tries, assesses and holds, and why.") and a card in
  "Selected work".
- `scripts/ci/layout-check.sh` adds the radar page to its list.

The blog's nav changes with its next image and the dashboard's with its
next image deploy; both follow the PR.

## CI

A `techradar` job in `ci.yaml`, modelled on the `dashboard` job:
`actions/setup-go` with `go-version-file: techradar/go.mod`, the same
golangci-lint and govulncheck pins through `install-tool.sh`, and
`scripts/ci/techradar-check.sh`, which exits early unless the diff
against `HEAD^1` matches
`^(techradar/|apps/website/techradar/|docs/|\.kiro/specs/|scripts/ci/techradar)`
(a renamed doc or spec breaks a link). It runs
`golangci-lint run --config ../dashboard/.golangci.yaml` (one
configuration, no copy to drift), `go vet ./...`, `govulncheck ./...`,
`go mod verify`, `go test -race ./...`, `go run ./cmd/techradar check
-out ../apps/website/techradar`, and `site_markup.py` over the page.
The job joins the `ci` job's `needs:` list and its result loop.
`site_markup.py` gains `techradar.nedsi.io` in `SITE_HOSTS` (task 1),
so the radar page and the nav links to it pass the markup check.
Renovate's `gomod` manager
covers the new module (its package rule groups it with `dashboard/`).
The `site-denylist` pre-commit hook adds `techradar/entries.yaml` to its
paths.

## Inventory

The first release. The rings follow what the repository records; the
link is the record. Entries named for review without a decision on
record are `assess` with "not evaluated yet".

Left off on purpose: Frigate and Scrypted (they would say the house has
cameras: public-website Requirement 4.1), the download stack and
LazyLibrarian (never named on a public page), Vaultwarden (a
credential-tooling term the privacy audit keeps off public pages; back
when a decision is recorded in the repository), and Longhorn or any
other storage system (never discussed in the repository). The household
apps are entries as the README's Services table names them; their
internals are not.

### Techniques

| Name | Ring | Reason | Link |
| --- | --- | --- | --- |
| GitOps, main is production | adopt | Merging deploys and a revert rolls back; Argo CD tracks main | docs/decisions.md#main-is-production |
| Rendered manifests in git | adopt | Every object Argo CD applies is reviewed as a file in the pull request | docs/architecture.md |
| CI as the only gate | adopt | No human approval: green CI merges, a degraded app is reverted | docs/decisions.md#no-human-gates |
| Automatic rollback | adopt | A merge that degrades an app is reverted, with an outage guard | docs/decisions.md#automatic-rollback |
| Deterministic first | adopt | Scripts, checks and thresholds decide; AI writes and summarises | docs/decisions.md#deterministic-first |
| SLOs and error budgets | adopt | One number per app, 99.5% over 30 days, from public probes | docs/sre.md |
| Page only when urgent and actionable | adopt | Everything else is on a dashboard, never on the phone | docs/sre.md |
| Restore-tested backups | adopt | A backup counts once a scheduled restore of it has passed | docs/backups.md |
| Spec-driven development | adopt | Requirements, design and tasks merged before the code | docs/spec-driven-development.md |
| Agent-written pull requests | adopt | Agents implement through PRs; CI and the specs keep them honest | docs/spec-driven-development.md |
| Trunk-based with squash merges | adopt | One commit per pull request on a linear main | docs/decisions.md#squash-merge |
| Images pinned by digest | adopt | A tag can move; a digest cannot | docs/testing.md |
| Keyless signing and SLSA provenance | adopt | Own images signed by their workflow and checked by Kyverno | .kiro/specs/image-provenance/ |
| DORA metrics | adopt | Delivery measured from git, GitHub and alerts, live on the dashboard | .kiro/specs/homelab-dashboard/ |
| Database majors fix forward | adopt | A Postgres major is a one-way door: fresh backup, then forward | docs/decisions.md#database-majors-fix-forward |
| Scheduled pentests | adopt | A scoped run against our own names and addresses, findings as issues | docs/pentest/README.md |
| Default-deny network policies | trial | Enforced in a few namespaces; app allow-lists still in audit | #709 |
| Pod Security restricted | trial | Kyverno restricted policies in Audit until their reports are clean | #1021 |
| GitHub App instead of PATs | trial | Short-lived tokens for the pentest workflows; PATs remain elsewhere | docs/pentest/README.md |
| Chaos experiments tied to SLOs | assess | Break things on purpose, within the error budget | #733 |
| Wide events | assess | One rich event per request instead of three signals | #734 |
| Canary tokens | assess | Fake credentials that page when touched | #1618 |
| Weekly SBOM and CVE scan | assess | What runs, scanned weekly, not only at build time | #1507 |
| Disaster recovery site | assess | Where to rebuild if the house is gone, and how fast | #918 |
| Kubernetes OIDC through Keycloak | assess | Personal API credentials instead of a shared kubeconfig | #711 |
| ADR directory | hold | ADRs rot in a one-person repository; decisions live in the docs | docs/decisions.md |

### Tools and languages

| Name | Ring | Reason | Link |
| --- | --- | --- | --- |
| Go | adopt | The dashboard and this radar: one static binary, typed, tested | docs/decisions.md#the-public-dashboard-is-a-first-party-go-app |
| Python | adopt | CI scripts and checks, with pytest | docs/testing.md |
| Hugo | adopt | One pinned binary, no theme, no npm tree, strict CSP possible | .kiro/specs/public-website/design.md |
| OpenTofu | adopt | The cloud resources, applied by a workflow through GitHub OIDC | docs/bootstrap.md |
| SOPS with age | adopt | Secrets encrypted in git, decrypted by KSOPS in Argo CD | docs/secrets.md |
| Renovate | adopt | Every dependency pinned and updated, automerged on green CI | docs/testing.md |
| GitHub Actions | adopt | CI and publishing, every action pinned to a SHA | docs/testing.md |
| cosign | adopt | Keyless signatures with the workflow identity | .kiro/specs/image-provenance/ |
| GitHub artifact attestations | adopt | SLSA v1 provenance for the own images, SLSA Build L2 | .kiro/specs/homelab-dashboard/design.md |
| OpenSSF Scorecard | adopt | A weekly score of the repository's supply-chain practice | .kiro/specs/scorecard-hardening/ |
| talhelper | adopt | The Talos machine configs rendered from one file | docs/talos.md |
| Kustomize and Helm | adopt | Helm charts rendered through Kustomize into deploy/ | docs/architecture.md |
| kubeconform and kube-linter | adopt | Schema and practice checks on every rendered manifest | docs/testing.md |
| Trivy | adopt | The image and config gate in CI | docs/testing.md |
| gitleaks | adopt | No secret reaches a commit, public repository or not | docs/testing.md |
| pre-commit | adopt | The same checks locally on commit and push | docs/testing.md |
| kind | adopt | A throwaway cluster in CI for a server-side dry run and a real boot | docs/testing.md |
| chrome-headless-shell | adopt | Screenshot and layout checks without a pixel diff | .kiro/specs/homelab-dashboard/design.md |
| OWASP ZAP | adopt | The DAST scan of the public names | docs/pentest/README.md |
| Task | adopt | One Taskfile for render, checks and Talos operations | Taskfile.yml |
| Kiro | adopt | The agents that write most pull requests, held to the specs | docs/spec-driven-development.md |
| Lore | assess | Memory for coding agents; not evaluated yet, the exact project first | #1675 |
| Astro and Eleventy | hold | An npm dependency tree to patch for a static blog | .kiro/specs/public-website/design.md |
| Zola | hold | Fine, but a smaller ecosystem and nothing gained over Hugo | .kiro/specs/public-website/design.md |
| Ansible | hold | Node playbooks replaced by Talos machine configs | docs/decisions.md#talos-built-as-a-new-cluster |

### Platform

| Name | Ring | Reason | Link |
| --- | --- | --- | --- |
| Argo CD | adopt | Root, three layers, one Application per app, tracking main | docs/architecture.md |
| Kyverno | adopt | Baseline policies in Deny, in CI and in the cluster | docs/testing.md |
| CloudNativePG | adopt | Postgres with WAL and base backups to S3 through Barman Cloud | docs/backups.md |
| Keycloak | adopt | One sign-on for every app, access by group, TOTP for admins | docs/architecture.md |
| cert-manager | adopt | Let's Encrypt over DNS-01, renewed without anyone noticing | docs/networking.md#certificates |
| external-dns | adopt | DNS records from the routes, upsert only | docs/networking.md#dns |
| Prometheus | adopt | Metrics for 30 days, the SLOs as recording rules | docs/observability.md |
| Alertmanager | adopt | Pages through ntfy, quiet hours, only urgent alerts | docs/observability.md#notifications |
| Grafana | adopt | The dashboards, behind Keycloak | docs/observability.md#dashboards |
| Vector | adopt | Pod and Talos logs shipped as structured events | docs/observability.md#logs |
| Hubble | adopt | Network flows from Cilium, behind Keycloak | docs/networking.md |
| tuppr | adopt | Talos and Kubernetes upgrades rolled out node by node | docs/talos.md#upgrades |
| restic | adopt | File backups to S3 and the NAS, restore-tested weekly | docs/backups.md |
| Headlamp | adopt | A cluster UI behind Keycloak | docs/remote-access.md |
| ntfy | adopt | Push notifications for pages | docs/observability.md#notifications |
| PostgreSQL | adopt | The one database engine, run by CloudNativePG | docs/backups.md |
| Immich | adopt | The photo library, signed in through Keycloak | apps/immich/ |
| Plex | adopt | Films and series on the TVs, off SSO so the TV apps sign in | apps/theater/plex.yaml |
| Jellyfin | adopt | The open-source media server next to Plex, off SSO | apps/theater/jellyfin.yaml |
| Paperless-ngx | adopt | Scanned documents, searchable | apps/paperless/ |
| Mealie | adopt | The household's recipes | apps/mealie/ |
| Syncthing | adopt | Device sync without a cloud in the middle | apps/syncthing/ |
| Audiobookshelf | adopt | Audiobooks and podcasts | apps/books/audiobookshelf.yaml |
| Calibre-Web | adopt | The e-book library | apps/books/calibre-web.yaml |
| Home Assistant | adopt | Home automation, local first | apps/home/home-assistant.yaml |
| Mosquitto | adopt | The MQTT broker for the home devices | apps/home/mosquitto.yaml |
| Zigbee2MQTT | adopt | Zigbee devices on MQTT, no vendor hub | apps/home/zigbee2mqtt.yaml |
| healthchecks.io | adopt | The dead man's switch: pages when the cluster goes silent | docs/observability.md |
| Tetragon | trial | Runtime detection that pages on critical events; nothing is blocked yet | docs/observability.md#runtime-tetragon |
| SigNoz | trial | Logs on ClickHouse, on trial as the one place for signals | #801 |
| Umami | assess | Cookieless statistics, chosen and not deployed yet | .kiro/specs/public-website/ |
| OpenBao with External Secrets | assess | Cluster-owned secrets issued, not stored | #713 |
| KEDA | assess | Event-driven scaling, with the HA work | #917 |
| Shirudo | assess | eBPF shields for unpatched code paths, once arm64 and Talos fit | #1628 |
| Honeycomb and OBI | assess | Traces from eBPF instrumentation, compared with SigNoz | #734 |
| CrowdSec | assess | A shared blocklist at the Gateway; not evaluated yet | #1676 |
| Loki | hold | Indexes labels only; the fallback if the SigNoz trial fails | docs/observability.md#why-it-is-like-this |
| Service mesh | hold | Cilium already gives the policies and the flows, without sidecars | docs/decisions.md#no-service-mesh |
| Seafile | hold | Removed: Syncthing and Paperless-ngx cover its uses | docs/decisions.md#seafile-removed |
| Policy Reporter UI | hold | Grafana is the one view for policy reports | .kiro/specs/wave3-runtime-security/ |
| Dex in Argo CD | hold | Unused: Argo CD signs in with Keycloak directly | #969 |

### Infrastructure

| Name | Ring | Reason | Link |
| --- | --- | --- | --- |
| Kubernetes | adopt | One API for every workload, run on Talos | docs/architecture.md#cluster |
| Talos Linux | adopt | Immutable, API-only nodes with the machine config in git | docs/talos.md |
| Cilium | adopt | kube-proxy replacement, LB-IPAM, L2 announcements and the Gateway | docs/networking.md |
| Gateway API | adopt | One shared Gateway for every public name | docs/networking.md#gateway |
| TrueNAS SCALE | adopt | The NAS: ZFS, iSCSI and NFS, driven by its API | .kiro/specs/nas-on-truenas-scale/ |
| democratic-csi | adopt | iSCSI volumes from the NAS on demand, Retain for data | docs/architecture.md |
| Tailscale | adopt | kubectl and talosctl only over the tailnet | docs/remote-access.md |
| Cloudflare DNS | adopt | Free zones, DNS-01 for certificates, DNS only | docs/networking.md#dns |
| AWS S3 | adopt | Off-site backups with locked object versions | docs/backups.md#the-bucket |
| Turing Pi 2 with RK1 | trial | Four quiet arm64 nodes on one board, which is a single point of failure | #985 |
| NVMe per node | assess | Revisit from the eMMC wear trend | #738 |
| SELinux enforcing on the nodes | assess | Another layer under the pods | #737 |
| TrueNAS CORE | hold | Replaced by SCALE in November 2026 | #1305 |
| kube-vip | hold | Talos holds the API VIP itself | docs/networking.md#why-it-is-like-this |
| ingress-nginx | hold | Retired upstream; the Cilium Gateway replaced it | docs/networking.md#why-it-is-like-this |
| kubeadm | hold | The old cluster; rebuilt on Talos | docs/decisions.md#talos-built-as-a-new-cluster |
| GitHub Pages | hold | Cannot set a CSP header for the public site | .kiro/specs/public-website/design.md |
| Cloudflare proxy and Pages | hold | A token with account write access and data pushed out of the house | .kiro/specs/public-website/design.md |

## Testability

| What | How |
| --- | --- |
| Validation | Table tests in `model_test.go`, one per rule |
| Placement | No overlap, inside the segment, deterministic; the real file, a synthetic 30-entry Adopt segment and a 40-entry Hold segment |
| Page | Golden HTML; the SVG element and attribute set; every blip a link with a `<title>` to exactly one legend `id`; the contrast test over `techradar.css` |
| Rendered output | `techradar check` in CI |
| Serving | `site-serve-check.sh`, the PostSync smoke, the probe, `dast` |
| Layout | `layout-check.sh` with the radar page |

## Edge cases

- A segment too full to place: the build fails naming it; widen the
  ring radii or move an entry, both visible in review.
- A link to a renamed file: the generator fails in CI on the next
  change; `check` also runs when `docs/` or `.kiro/specs/` change.
- An anchor that no longer exists: not checked (headings change wording
  often); the file link still lands on the right page.

## Why it is like this

- Static and generated before deployment: the CSP stays `'self'` with no
  script, and there is nothing in the pod to exploit beyond nginx.
- A page of the site, not an app: see
  [Own app or a page of the site](#own-app-or-a-page-of-the-site).
- Rendered output in git: Argo CD applies what git holds, a reviewer
  sees the page change in the diff, and CI proves it is current.
  Rejected: rendering in an init container (a Go toolchain or binary in
  the pod).
- Go: the dashboard's language and CI; placement is geometry that needs
  tests. Rejected: Zalando's `radar.js` (D3 in the browser) and Hugo
  templates (no tests for the placement).
- Links only into the repository: the radar points at decisions, not
  at vendors' marketing pages.
