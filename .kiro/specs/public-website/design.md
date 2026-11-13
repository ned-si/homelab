# Design: public-website

## Overview

Hugo builds `site/` into static files. A COPY-only Dockerfile puts them on
an unprivileged nginx image, pushed to GHCR by a workflow on `main`.
Renovate sees the new digest and opens the usual digest PR, which merges on
green CI; Argo CD rolls out the `website` app at `https://nedsi.io`.

Phase 2 adds three things next to the static site, each in its own app:

- `umami`: cookieless statistics, its tracker and collect endpoint proxied
  under `nedsi.io/stats/`, its UI on `umami.lilalala.com` behind Keycloak.
- `isso`: moderated comments under `nedsi.io/comments/`, its admin on
  `comments.lilalala.com` behind Keycloak.
- The publisher CronJobs in `website`: they read Prometheus, validate a
  fixed set of figures, render the dashboard's HTML and SVG and write them
  to ConfigMaps the site pod mounts read-only. nginx includes them in
  `/homelab/` with a server-side include.

The site pod talks to nothing. Stack, locked: Hugo extended (pinned with
its checksum in `scripts/ci/install-tool.sh`), `nginxinc/nginx-unprivileged`
alpine by digest, Python 3 from the `python` alpine image by digest for the
publisher, Isso and Umami images by digest, GitHub Actions, GHCR, Renovate,
Argo CD, Kustomize, CloudNativePG for Umami's database.

## Domains

`nedsi.io` is the public identity: the blog and its dashboard, and
anything else public later. `lilalala.com` stays the household's domain
for private and semi-private services, including the admin UIs of this
spec. The naming rule in `.kiro/steering/structure.md` says so.

DNS and TLS for `nedsi.io`:

- A free Cloudflare zone `nedsi.io` in the same account as
  `lilalala.com`, DNS only (no Cloudflare proxy). Dynadot keeps the
  registration and points the nameservers at Cloudflare.
- The existing Cloudflare tokens of cert-manager and external-dns get the
  `nedsi.io` zone added to their zone resources, same permissions (Zone
  Read, DNS Edit). Edited in place, so the SOPS secrets do not change.
- cert-manager: the `letsencrypt` and staging ClusterIssuers add `nedsi.io`
  to the solver's `dnsZones`. A Certificate `nedsi-io` in the Gateway's
  namespace covers `nedsi.io` and `www.nedsi.io`.
- Gateway: two listeners, `https-nedsi` (443, hostnames `nedsi.io` and
  `www.nedsi.io`, certificate `nedsi-io`) and `http-nedsi` (80), next to
  the `*.lilalala.com` ones. The HTTP-to-HTTPS redirect route gets the two
  names; an HTTPRoute on `www.nedsi.io` redirects to `https://nedsi.io`
  with `301`.
- external-dns (upsert only, no domain filter today) creates the apex and
  `www` records from the HTTPRoutes once the token covers the zone; the
  apex is an A record to the WAN address like the other names.
- CAA records `0 issue "letsencrypt.org"` on `nedsi.io`, created in the
  console with the zone (external-dns does not manage CAA).

## Layout

| Path | Holds |
| --- | --- |
| `site/hugo.toml` | Base URL `https://nedsi.io/`, RSS, markup settings, `buildDrafts=false`, `buildFuture=false`, `params.comments` (on/off), `[minify.tdewolff.html] keepComments = true` |
| `site/layouts/` | Home-made templates: `baseof`, `list`, `single`, `index`, `404`, `rss` (full content), `homelab` |
| `site/assets/css/main.css` | The only stylesheet, fingerprinted by Hugo Pipes; Isso's stylesheet copied in |
| `site/content/` | `about.md`, `privacy.md`, `homelab.md` (phase 2), `posts/<yyyy-mm-dd>-<slug>/index.md` |
| `site/LICENSE` | CC BY 4.0 for the content under `site/content/` |
| `site/Dockerfile`, `site/nginx.conf` | The image |
| `apps/website/` | Namespace, Deployment, Service, HTTPRoutes, NetworkPolicy, PostSync smoke, publisher (phase 2) |
| `apps/umami/`, `apps/isso/` | Phase 2 apps |
| `clusters/homelab/apps/{website,umami,isso}.yaml` | The Applications |
| `.github/workflows/site-publish.yaml` | Build and push on `main` |
| `scripts/ci/site-check.sh` | The `site` job's checks |
| `docs/website.md` | How to write, preview and publish; the privacy rules; comments and statistics operations; Why it is like this |

`structure.md` gets the `site/` row. The name `website` is the app
directory, Application and namespace; `site/` holds sources, like
`talos/` holds the Talos sources.

## Generator

Hugo: one static binary for macOS and Linux, Markdown, page bundles, RSS
and syntax highlighting built in, deterministic output. Rejected: Astro and
Eleventy (an npm dependency tree to patch for a static blog), Zola (fine,
but a smaller ecosystem and nothing gained over Hugo). No third-party
theme: themes bring JavaScript, web fonts and inline styles that the CSP
would block. Syntax highlighting uses classes
(`markup.highlight.noClasses = false`) and a generated stylesheet, so no
inline style is needed.

The `single` layout adds `<link rel="canonical" href="{{ .Params.canonical }}">`
and a "First published at ..." line when `canonical` is set, otherwise
a canonical link to itself. The footer of `baseof` states CC BY 4.0 with a
link to the licence.

## Why in the cluster

Three options were weighed:

- **In the cluster, behind the shared Gateway** (chosen by the operator).
  Free; headers set at the HTTPRoute like every app; the same Kyverno,
  netpol, probe, SLO and pentest coverage; the blog runs on the homelab it
  describes; comments, statistics and the dashboard data stay in the
  house. Costs: the site is down when the house is (power cuts), and it
  adds public routes. The site serves static files from a pod with no
  token and no egress.
- **GitHub Pages**: free and independent of the house, but no CSP header,
  no `frame-ancestors`, no HSTS control, and comments and statistics would
  still need the cluster. Rejected for Requirement 3.2.
- **Cloudflare Pages**: free with a `_headers` file, but a new token with
  write access to the account, and the dashboard data would have to be
  pushed out of the house. The fallback if home outages hurt the blog.

## Publishing flow

1. The operator (or an agent, on his request) opens a draft PR with the
   article.
2. `ci` runs the `site` job (below) and uploads `site-preview.zip`.
3. Only the operator marks an article PR ready, and `scripts/pr-merge.sh`
   refuses drafts, so no agent can publish an article first. Then the PR
   merges with `scripts/pr-merge.sh`. `docs/website.md` and the
   run-conventions skill state the rule.
4. `site-publish.yaml` runs on `push` to `main` with `paths: [site/**]`:
   `hugo --minify --panicOnWarning`, then `docker buildx build
   --platform linux/arm64 --push` with tags `main` and `<git sha>`. The
   Dockerfile only `COPY`s, so the arm64 image builds on the amd64 runner
   without emulation. Permissions: `packages: write`, `contents: read`.
5. The manifest pins `ghcr.io/ned-si/homelab-site:main@sha256:<digest>`.
   A Renovate package rule for `ghcr.io/ned-si/homelab-site`: digest
   updates, `automerge: true`, `minimumReleaseAge: 0`, no schedule.
   `renovate-render` renders `deploy/`; the PR merges on green CI.
6. Argo CD syncs; the PostSync smoke Job checks `/`, `/index.xml`, a 404,
   the headers and the `405`.

Rejected: the publish workflow opening its own bump PR (a PR opened with
`GITHUB_TOKEN` triggers no `ci` run, so it would need a GitHub App token);
a mutable tag without digest (breaks the digest-pinning rule); Argo CD
Image Updater (a new component for one image).

Failures: a Hugo or push failure fails `site-publish`, whose own last step
posts to ntfy at low priority (a copy of the `renovate-render` "Notify
ntfy on failure" step with `ntfy-quiet-delay.sh`, title `site-publish
failed`); nothing is deployed, and the running site stays. A digest PR
with red `ci` stays open; the running site stays. A degraded sync is
reverted by auto-rollback.

## The `site` job

A job in `ci.yaml`, through `scripts/ci/site-check.sh`. `ci` is the
required check, so the job always runs and exits 0 early when
`git diff --name-only origin/main...HEAD` touches neither `site/` nor
`apps/website/`:

| Check | Fails when |
| --- | --- |
| `hugo --panicOnWarning --printPathWarnings` | Any template or content warning, a broken `ref`/`relref` (`refLinksErrorLevel = "ERROR"`) |
| `htmltest` offline on `public/` | A broken internal link, anchor or image |
| Markup check (grep on `public/`) | `<form`, `<iframe`, `style=`, an inline `<script>`, a `<script src=` other than `/stats/s.js` and `/comments/js/embed.min.js`, or a `src=`/`href=` to another origin outside `<article>` |
| `exiftool -if '$EXIF:all or $XMP:all or $IPTC:all or $GPS:all'` over `site/**/*.{jpg,jpeg,png,webp,heic}` | Any image carries metadata; the fix is `task site:strip` (`exiftool -all= -overwrite_original`) |
| Deny patterns | An e-mail address other than `nedsi@pm.me`; gitleaks already scans the tree |
| Local files | `git ls-files site \| grep -E '\.local\.'` is non-empty |
| Drafts | A `draft: true` or future-dated page in `public/` |

`htmltest` and `exiftool` are pinned with checksums like the other tools.
The built `public/` is uploaded as the artefact `site-preview` (7 days).

Local hook: a `pre-commit` hook `site-denylist` greps `site/` case
insensitively for every line of `site/denylist.local.txt`. The file is
git-ignored through `*.local.*`; the hook prints the file and line of a
match, never the deny term itself, and passes when the file is absent (CI
cannot know the terms without publishing them).

## Serving

`site/nginx.conf`, listening on 8080:

- `location / { limit_except GET HEAD { deny all; } error_page 403 =405; }`,
  so only the method refusal becomes a `405`.
- `server_tokens off`; `autoindex off`; `try_files $uri $uri/ =404`;
  `error_page 404 /404.html`.
- `Cache-Control: public, max-age=31536000, immutable` for fingerprinted
  assets under `/css/`, `max-age=300` for HTML and `/index.xml`,
  `no-cache` for `/data/`.
- `log_format site escape=json '{"time":"$time_iso8601","method":"$request_method","path":"$uri","status":$status,"bytes":$body_bytes_sent}'`;
  no address, user agent, referrer or query string. Vector already ships
  pod logs to SigNoz.
- Phase 2: `location /homelab/ { ssi on; }` (a prefix match, so it still
  applies after `try_files` serves `/homelab/index.html`).

Routes on `nedsi.io` (HTTPRoute `website`, listener `https-nedsi`):

| Path | Backend |
| --- | --- |
| `/` | `website` Service, 8080 |
| `/stats/s.js`, `/stats/api/send` (exact) | `umami` Service, rewritten to its tracker and collect paths (phase 2) |
| `/comments/admin` (prefix) | `website` Service, which answers `404` |
| `/comments/` (prefix) | `isso` Service, prefix stripped (phase 2) |

Gateway API picks the longest match, so the admin path never reaches
Isso and no other Umami path is public.

Response headers are set at the HTTPRoute with `ResponseHeaderModifier`,
as on `apps/mealie/httproute.yaml`:

```text
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
Cross-Origin-Opener-Policy: same-origin
```

Phase 1 ships without `script-src` and `connect-src` (both fall back to
`'none'`); phase 2 adds them with the first script. Isso's embed is loaded
with `data-isso-css="false"`, so it injects no inline style; its
stylesheet is part of `main.css`.

The PostSync smoke Job (`components/postsync-smoke`) asserts each header
on `/` and on a 404, the `405`, and the `www` redirect, so a header lost in
a refactor rolls the change back. Whether Cilium applies
`ResponseHeaderModifier` to error responses is checked in task 3; if it
does not, nginx sets the same headers with `add_header ... always`.

## The `website` app

- Namespace `website` in the apps AppProject destinations.
- Deployment `website`, one replica, image by digest, port 8080,
  `automountServiceAccountToken: false`, `runAsNonRoot`, `runAsUser: 101`,
  `readOnlyRootFilesystem`, capabilities drop `ALL`, `seccompProfile:
  RuntimeDefault`, `allowPrivilegeEscalation: false`; `emptyDir` for
  `/tmp` (nginx temp and pid paths point there); requests `10m`/`32Mi`,
  limit `64Mi`; readiness and liveness `GET /` on 8080.
- Service `website` on 8080; HTTPRoutes `website` and `website-www` as
  above.
- Network policies, enforced from the start in the format of
  `infrastructure/network-policies/`: ingress to the site pod from the
  Gateway only on 8080; no egress. Phase 2 adds the publishers' egress to
  the Prometheus Service in `monitoring` and to the API server.
- Lists: `ci/expected-ingresses.txt`, `ci/kind-workloads.txt` (it boots
  without data), the blackbox probe list with the public URL (99.5% SLO,
  the user-facing app table in `docs/sre.md`), the pentest scope file,
  the `dast` targets.

## Statistics: Umami

Umami (official multi-arch image, by digest), app `umami`, namespace
`umami`, database `umami-postgresql` on CloudNativePG with the usual WAL
and base backups.

Why Umami: no cookies, no stored IP; a session hash from IP, user agent,
site and a salt that rotates monthly, so a reader is not recognised across
months or sites; and it records pages, referrers, countries, browsers,
operating systems and devices. That fits the GDPR and the nFADP without a
consent banner. Rejected: GoatCounter (equally cookieless, but no
maintained arm64 image found); Plausible (ClickHouse, heavy for one blog);
server-side log analytics (it needs the IP and user agent in the logs,
which Requirement 6.3 forbids).

- Tracker served as `/stats/s.js` (`TRACKER_SCRIPT_NAME`), collect
  endpoint `/stats/api/send` (`COLLECT_API_ENDPOINT`), both same-origin,
  so the CSP needs only `'self'`. `DISABLE_TELEMETRY=1`,
  `DISABLE_UPDATES=1`.
- Country from Umami's bundled GeoIP database, computed at collect time;
  the IP is not stored.
- Respects `Do Not Track` (`data-do-not-track="true"`).
- UI at `umami.lilalala.com` behind the oauth2-proxy pattern
  (`platform/headlamp/resources/sso.yaml`), group `admins`; Umami's own
  login stays on behind it.
- Retention: events older than 13 months deleted by a monthly CronJob
  (SQL delete), stated on the privacy page.
- Network policies: ingress from the Gateway; egress to
  `umami-postgresql` only.

## Comments: Isso

Isso (`ghcr.io/isso-comments/isso` by digest, arm64 checked in task 7;
fallback Remark42), app `isso`, namespace `isso`, SQLite on an
`iscsi-retain` PVC with a restic CronJob like the other apps.

Why Isso: one small process, SQLite, a moderation queue, no account or
third party, and it runs under a path of the site, so the CSP stays
`'self'`. Remark42 is the fallback: richer, but it renders in an iframe
and pushes social logins.

- `isso.cfg`: `moderation.enabled = true`, `public-endpoint =
  https://nedsi.io/comments`, `gravatar = false`, admin on, notifications
  off (no SMTP); Isso stores client addresses truncated (IPv4 /24, IPv6
  /48).
- Client: `data-isso-require-email="false"`,
  `data-isso-require-author="false"`, `[guard] require-email = false`, the
  e-mail and website fields hidden with CSS and so left empty. Task 7
  checks the `comments` table after a test comment: empty `email` and
  `website`, truncated `remote_addr`.
- Moderation: `comments.lilalala.com` routes to Isso's `/admin` behind
  the oauth2-proxy pattern, group `admins`.
- Off switch: `params.comments = false` in `hugo.toml` removes the embed
  from every page; scaling `isso` to 0 stops the service. Existing
  comments stay in the database.
- Deletion on request: the operator deletes the comment in the admin; the
  privacy page gives `nedsi@pm.me`.
- Network policies: ingress from the Gateway (both routes); no egress.

## Public figures

Phase 2. The allow-list, in `apps/website/publisher/schema.json` (JSON
Schema, `additionalProperties: false`):

| Key | Value | Source |
| --- | --- | --- |
| `covers` | `YYYY-MM-DD`, yesterday in Europe/Zurich | Clock |
| `computed_at` | RFC 3339, minute precision | Clock |
| `availability_30d` | Per shown app: percent, 0 to 100, one decimal | `slo:availability:ratio_rate30d` at `covers` 24:00 |
| `availability_daily` | Per shown app: the last 30 daily values, for the sparklines | The same rule as a range query, step 1 d |
| `error_budget_remaining_30d` | Per shown app: percent, -100 to 100, whole number; clamped at -100 before validation, -100 rendered as "exhausted" | `slo:error_budget_remaining:ratio_rate30d` |
| `nodes` | Integer 1-10 | `count(kube_node_info)` |
| `apps` | Integer 1-200 | Argo CD Applications, `count(argocd_app_info)` |
| `talos_version`, `kubernetes_version` | Strings matching `^v\d+\.\d+\.\d+$`; the lowest when nodes disagree (mid-upgrade) | `max by (os_image) (kube_node_info)` and `max by (kubelet_version) (kube_node_info)`, version taken from the label with `re.search(r"v\d+\.\d+\.\d+", label)` |

Solar, in its own document `solar.json` (task 9):

| Key | Value | Source |
| --- | --- | --- |
| `at` | RFC 3339, minute precision | Clock |
| `solar_power_w` | Integer 0-20000 | The Home Assistant production sensor, scraped by Prometheus |
| `solar_today_kwh` | Number 0-200, one decimal | The daily production sensor |

Shown apps: an explicit allow-list in `apps/website/publisher/config.json`
(Immich, Mealie, Paperless-ngx, Audiobookshelf, Calibre-Web, Plex,
Jellyfin, Home Assistant, Syncthing, Keycloak, the website). An app not on
it is never queried. The *arr apps, qBittorrent, Prowlarr, Recyclarr,
Bazarr and LazyLibrarian are not on it, and the publisher tests fail if
one is added.

Why daily and delayed for availability: a live status page tells an
attacker when the house is down (a power cut is also the moment cameras
and alarm may be down). A daily figure for a finished day says neither.
Solar production is allowed live by the operator: it follows the sun, not
the household. Consumption, grid flows, battery and charging are never
published: they show when the house is empty. Why pushed: the site pod
has no credential and no route to anything; the publisher has read access
to Prometheus and write access to its ConfigMaps, and no public listener.
A reader can shape no query.

### Publisher

The dashboard is the project's own renderer: `publisher.py` turns the
figures into `figures.html` (a table per app with an inline SVG sparkline
of the 30 daily values, the budget, the platform facts) and `solar.html`
(the current power and today's total). Numbers and fixed strings only,
`html.escape` on all, SVG built from numbers, no script.

- CronJob `website-publisher` in `website`, `schedule: "30 3 * * *"`,
  `timeZone: Europe/Zurich`, writes `website-data`; CronJob
  `website-solar`, `schedule: "*/5 * * * *"`, writes `website-solar`
  (task 9). Both `concurrencyPolicy: Forbid`, `backoffLimit: 2`, in
  `ci/non-backup-cronjobs.txt` and `ci/active-cronjobs.txt`; same pod
  hardening as the site.
- `publisher.py` from a ConfigMap on the `python` alpine image, standard
  library only (the `platform/usage-exporter` pattern).
- ServiceAccount `website-publisher`, Role: `get`, `update`, `patch` on
  `configmaps` with `resourceNames: [website-data, website-solar]`. The
  ConfigMaps are in git as empty placeholders (`figures.json: "{}"`,
  `figures.html: ""`); the Application has `ignoreDifferences` on their
  `/data` with `RespectIgnoreDifferences=true`, so Argo CD creates them
  and never resets them.
- The site Deployment mounts both read-only under
  `/usr/share/nginx/html/data/` (`optional: true`).
- The include comes from a layout, not from Markdown (Goldmark drops raw
  HTML): `homelab.md` sets `layout: homelab`, and
  `layouts/_default/homelab.html` emits
  `{{ "<!--# include virtual=\"/data/figures.html\" -->" | safeHTML }}`
  and the same for `solar.html`. `keepComments = true` keeps the
  directives through `--minify`. The kind job checks that `/homelab/`
  contains no literal `<!--#`.

Steps and failures:

| Step | Failure | Result |
| --- | --- | --- |
| Query each figure (`/api/v1/query`, 10 s timeout, `time=` the end of `covers`) | Connection error, non-200, empty result | Exit 1, log `ERROR <figure>: <reason>`; ConfigMap untouched |
| Validate against the schema, the ranges and the shown apps | Missing key, extra key, extra app, out of range, bad version string | Exit 1, log the key and the rule, never write |
| Render the HTML | (numbers and fixed strings only) | — |
| Update the ConfigMap | API error | Exit 1, retried by `backoffLimit` |

A failed Job raises the existing `KubeJobFailed`, an INFO event, not a
page. The page cannot compute its own age without JavaScript, so each
fragment prints its period first, and the layout has a fixed line under
it: "Updated once a day (solar every 5 minutes). A date more than two
days old means the update is failing." A missing solar sensor leaves the
solar section out.

Tests: `tests/website/test_publisher.py` with a fake Prometheus (stdlib
`http.server`): valid figures, each failure row, an extra key, an app
outside the allow-list, a value out of range, a budget below -100, a
mid-upgrade version split, missing solar; the HTML contains no `<script`.

## Content plan

1. The intro article: the concept of the homelab (a family platform run
   like production, public as an example) and what the blog will cover.
   Drafted by an agent with the `operator-voice` skill, opened as a draft
   PR for the operator to edit.
2. The About page: short, written by the operator; the default is one
   line and a link to his LinkedIn. Agents leave it as a stub for him.
3. Two articles the operator wrote for another company's blog,
   republished with `canonical` set to the original URL. Before the PR,
   the operator checks that he may reuse them; he supplies the texts.
   Agents do not name the company in the repository; the canonical link
   and the "First published at" line come from the operator.
4. The privacy page: reference text, drafted by an agent.

## Privacy rules

In `docs/website.md`, checked by the operator before marking an article
ready, and the deterministic part by CI (Requirement 4.3, 4.4):

- No names of household members, friends or relatives. The author is
  `nedsi`; the operator's own name only where he writes it.
- No address, town, street, views from the house, photos of the house,
  rooms, garden or people; screenshots cropped to the subject.
- No user or account names (Keycloak, Plex, Immich), no library contents.
- No routines, holidays, absences or dates of power cuts while they matter.
- No security devices: brands, models, counts or placement of cameras,
  locks, the alarm.
- No WAN address, no secrets, no employer written by an agent. LAN
  addresses are fine (the repository already shows them).

The privacy page (`site/content/privacy.md`) lists:

- Access logs: time, method, path, status, bytes; kept for the SigNoz log
  retention; no address or user agent.
- Statistics (phase 2): page, referrer, country, browser, operating
  system, device type, screen size, language; no cookie, no stored IP, a
  monthly rotating hash; kept 13 months; `Do Not Track` respected.
- Comments (phase 2): the text, the optional name, the time, a truncated
  address for spam control; kept until deleted; deletion on request.
- Legal basis: legitimate interest (GDPR art. 6(1)(f); nFADP), no
  transfer to third parties, data stored in Switzerland on the operator's
  hardware; off-site backups in AWS eu-central-1. Contact `nedsi@pm.me`.

## Testability

| What | How |
| --- | --- |
| Templates, links, markup, metadata, drafts | `site` job on every PR (unit level) |
| Image and nginx config | kind boot in pre-production (`ci/kind-workloads.txt`), `curl` checks of method, headers and the SSI in the kind job |
| Headers, method, redirect live | PostSync smoke, blackbox probe, `dast` |
| Publisher | pytest with a fake Prometheus; one manual Job run in task 8 |
| Umami, Isso | PostSync smoke: tracker and collect answer on `nedsi.io/stats/`, admin paths `404` on `nedsi.io`; a test comment waits for moderation |
| Network policy | Hubble shows no denied flow from the Gateway; acceptance criterion 10 |

## Edge cases

- An article image above 1 MiB: the `site` job warns; Hugo image
  processing makes a resized copy.
- A renamed article URL: Hugo `aliases` in front matter keep the old one.
- A ConfigMap of the publisher deleted by hand: Argo CD recreates the
  placeholder; the page shows no figures until the next run.
- First deploy before the first image exists: task 2 pushes the image
  before task 3 references it.
- The zone not active yet: task 3 waits for task 0; cert-manager retries
  DNS-01 until the zone answers.
- DNS: external-dns is upsert only; removing the site later needs the
  records deleted by hand (as for every app).
- Comments switched off: Isso keeps running until scaled to 0; no page
  loads its script.

## Why it is like this

- `nedsi.io`: the public identity apart from the household's domain, so
  a reader of the blog is not pointed at the family's services.
- In the cluster: free and fully under the same checks; GitHub Pages
  cannot set the CSP header.
- Hugo with no theme; the dashboard rendered by the project's own code:
  the strictest CSP is possible and there is little to patch.
- Comments and statistics self-hosted under the site's own origin: no
  third party, no cookie, no consent banner, CSP `'self'` only.
- Renovate publishes: it already pins and automerges images; a second
  merge path would need a new token.
- Figures pushed into ConfigMaps: the public pod knows nothing and
  reaches nothing.
