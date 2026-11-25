# Design: public-website

## Overview

Hugo builds `site/` into static files. A COPY-only Dockerfile puts them on
an unprivileged nginx image, pushed to GHCR by a workflow on `main`.
Renovate sees the new digest and opens the usual digest PR, which merges on
green CI; Argo CD rolls out the `website` app. One nginx pod serves three
names: the blog at `https://blog.nedsi.io`, the landing page at
`https://nedsi.io`, and the redirects of `www.nedsi.io` and plain HTTP.
The nginx config and the landing page are ConfigMaps from
`apps/website/`, so they change without a new image.

Phase 2 adds two things next to the static site:

- `umami`: cookieless statistics, its tracker and collect endpoint proxied
  under `blog.nedsi.io/stats/`, its UI on `umami.lilalala.com` behind
  Keycloak.
- The publisher CronJobs in `website`: they read Prometheus, validate a
  fixed set of figures, render the dashboard's HTML and SVG and write them
  to ConfigMaps the site pod mounts read-only. nginx includes them in
  `/homelab/` with a server-side include.

The site pod talks to nothing. Stack, locked: Hugo extended (pinned with
its checksum in `scripts/ci/install-tool.sh`), `nginxinc/nginx-unprivileged`
alpine by digest, Python 3 from the `python` alpine image by digest for the
publisher, the Umami image by digest, GitHub Actions, GHCR, Renovate,
Argo CD, Kustomize, CloudNativePG for Umami's database.

## Domains

`nedsi.io` is the public identity: the landing page at the apex, the blog
and its dashboard on `blog.nedsi.io`, and anything else public later.

| Name | Serves |
| --- | --- |
| `nedsi.io` | The landing page, the operator's homepage: cards to his projects (the source repository among them), the blog, the About page, his contact links and, from phase 2, the dashboard |
| `blog.nedsi.io` | The blog (Hugo), its RSS feed, the dashboard at `/homelab/` (phase 2) until it moves, then a `301` to `homelab.nedsi.io`, the statistics script under `/stats/` (phase 2) |
| `homelab.nedsi.io` | The dashboard, app `homelab-dashboard` ([spec homelab-dashboard](../homelab-dashboard/design.md#address), from its task 4) |
| `www.nedsi.io` | `301` to `https://nedsi.io`, path and query kept |
| `http://` on all three | `301` to the `https://` URL, `www` folded into the apex |

`lilalala.com` stays the household's domain for private and semi-private services, including the admin UIs of this
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
  namespace covers `nedsi.io`, `www.nedsi.io` and `blog.nedsi.io`: three
  SANs, three TXT names, no wildcard.
- Gateway: six listeners next to the `*.lilalala.com` ones, one hostname
  each: `https-nedsi`, `https-nedsi-www`, `https-nedsi-blog` (443,
  certificate `nedsi-io`) and `http-nedsi`, `http-nedsi-www`,
  `http-nedsi-blog` (80). The `*.lilalala.com` redirect route
  (`infrastructure/gateway/http-redirect.yaml`) does not cover them.
- Two HTTPRoutes in `website`, both on the three names: `website` on the
  443 listeners to Service port 8080 with the response headers, and
  `website-http` on the 80 listeners to port 8081, where nginx answers
  every request with the redirect. No route uses `RequestRedirect`, see
  [Redirects](#redirects).
- external-dns (upsert only, TXT registry, no domain filter today) creates
  the three A records from the HTTPRoutes, to the WAN address like the
  other names. It does not take over records it does not own: the
  proxied apex and `www` records that were in the zone before task 3 must
  be deleted in the console first.
- CAA records `0 issue "letsencrypt.org"` on `nedsi.io`, created in the
  console with the zone (external-dns does not manage CAA).

### Dashboard location

Decided 2026-11-20, with the dashboard's move to its own Go app
(spec homelab-dashboard): the dashboard gets its own host,
`https://homelab.nedsi.io/`. `blog.nedsi.io/homelab/` answers a
permanent redirect there, and the Homelab link of the navigation bar
and the landing page's dashboard button point there. The certificate,
listeners, route, DNS record, redirect, pentest scope and probe are
[that spec's Address section](../homelab-dashboard/design.md#address).

- For: the app is its own origin with its own route, certificate and
  CSP, serves from `/`, and shares no path space with nginx or the Hugo
  build. Nothing in [Public figures](#public-figures) changes.
- Rejected, the blog page of 2026-11-16 (`blog.nedsi.io/homelab/`): a
  path-prefix split of the blog's host between nginx and the app.
- Rejected, `nedsi.io/homelab/`: the same split on the landing page's
  host, with the app's assets under a prefix.

### Redirects

The redirects are answered by nginx, not by the Gateway. Task 3's first
attempt (#1399, reverted in #1401) used Gateway API `RequestRedirect`
filters and failed its PostSync smoke on two points, both Cilium 1.20
behaviour:

- `scheme: https` without a port gives `Location: https://nedsi.io:443/`
  (the existing `*.lilalala.com` redirect does the same).
- The `RequestRedirect` route on the `https-nedsi-www` listener was
  accepted but answered `404`, while the same route on `http-nedsi-www`
  answered `301`.

nginx returns `301 https://<name>$request_uri` with no port, the
behaviour is tested in CI before a merge (`scripts/ci/site-serve-check.sh`),
and the routes are plain backend routes like every other app's.

## Layout

| Path | Holds |
| --- | --- |
| `site/hugo.toml` | Base URL `https://blog.nedsi.io/`, RSS, markup settings, `buildDrafts=false`, `buildFuture=false`, `[minify.tdewolff.html] keepComments = true` |
| `site/layouts/` | Home-made templates: `baseof`, `list`, `single`, `index`, `404`, `rss` (full content), `homelab` |
| `site/assets/css/main.css` | The only stylesheet, fingerprinted by Hugo Pipes |
| `site/content/` | `about/index.md` (and its optional photo), `privacy.md`, `homelab.md` (phase 2), `posts/<yyyy-mm-dd>-<slug>/index.md` |
| `site/LICENSE` | CC BY 4.0 for the content under `site/content/` |
| `site/Dockerfile` | The image: the nginx base and the Hugo output |
| `apps/website/` | Deployment, Service, HTTPRoutes, PostSync smoke, publisher (phase 2) |
| `apps/website/nginx.conf` | The nginx config, a ConfigMap: the three names, the redirects, the method limit, the log format |
| `apps/website/landing/` | The landing page (`index.html`, `landing.css`), a ConfigMap |
| `apps/umami/` | Phase 2 statistics |
| `clusters/homelab/apps/{website,umami}.yaml` | The Applications |
| `.github/workflows/site-publish.yaml` | Build and push on `main` |
| `scripts/ci/site-check.sh`, `scripts/ci/site-serve-check.sh` | The `site` job's checks |
| `docs/website.md` | How to write, preview and publish; the privacy rules; statistics operations; Why it is like this |

`structure.md` gets the `site/` row. The name `website` is the app
directory, Application and namespace; `site/` holds sources, like
`talos/` holds the Talos sources.

From task 12: `site/assets/css/layout.css` (the shared layout, the one
definition), its copies `apps/website/landing/layout.css` and
`dashboard/internal/web/assets/layout.css`, and
`scripts/ci/layout-check.sh` (the layout check).

## Home and About text (task 11)

The operator's edits of 2026-11-24, as text. The landing page is
`apps/website/landing/index.html` (a ConfigMap, live with the merge);
the About page is `site/content/about/index.md` (in the site image, live
with the next `homelab-site` digest bump). Voice: the `operator-voice`
skill; no em dashes; "agents", never "bots".

Landing page, from the top:

- `<h1>Security and reliability engineer</h1>`, then
  `<p class="lead">Automate all the things.</p>`.
- **What this is**: "My corner of the web: the projects I work on and
  what I write about them. No newsletter, no cookies, no tracking."
- **What you can expect**: today's first paragraph (security,
  reliability and platform engineering, the soft spot for developer
  experience, "not every week"), then "What is here so far:" and a list,
  one line and one link each:
  - [Blog](https://blog.nedsi.io/): how the homelab is built and run,
    the trade-offs behind it, and what I learn on the way.
  - [Homelab dashboard](https://homelab.nedsi.io/): the homelab in
    numbers, live: availability, the cluster, DORA metrics, security.
  - [About](https://blog.nedsi.io/about/): who I am, what I have done so
    far, certifications and talks.
  - [Projects on GitHub](https://github.com/ned-si/): the homelab, the
    keyboard firmware and the drum charts, all in the open. This link
    sits outside any `<article>`, so task 11 adds
    `"https://github.com/ned-si/"` (the operator's own account, trailing
    slash) to `LINKS` in `scripts/ci/site_markup.py`.
  - Tech radar: added by spec tech-radar once `techradar.nedsi.io` is
    live, "what the homelab uses, tries, assesses and holds, and why".
- No "Start here" block. Its homelab paragraph moves into the About
  intro (below), where the projects are introduced.
- The cards stay. The About card's text becomes "Who I am, what I have
  done so far in IT, my certifications and talks." (no watches).

About page intro (`site/content/about/index.md`, above "Résumé"):

1. "Hi, I'm Julien Sudan, nedsi on most of the internet." unchanged.
2. Who he is and what he has done so far in IT: the current-role
   sentence as it is on the page today, then "A security engineer who
   never quite stopped being an SRE, in other words. Before that, I ran
   a public cloud as an SRE, built cloud native platforms as a
   consultant and, before that, designed and ran observability and SIEM
   platforms." and the thread sentence ("make the secure and reliable
   path the easy one, then automate it so nobody has to think about
   it"). The watch-industry and photography clause is removed.
3. "What I work on when I am not at work:" with the three projects, a
   link each:
   - [the homelab](https://github.com/ned-si/homelab) and its
     [dashboard](https://homelab.nedsi.io/): today's "Why the homelab?"
     paragraph, shortened to two sentences (built to solve my own
     problems and to test things properly; a fairly complex platform
     run by very few people, here one and a handful of agents);
   - [ergonomic keyboards](https://github.com/ned-si/scylla) and their
     QMK and ZMK firmware, built and released by CI;
   - [drum charts as code](https://github.com/ned-si/drum-charts), in
     LilyPond, because away from the keyboards I play the drums.
4. The contact sentence, unchanged.

Certifications, newest first, years only, the names as on the page
today:

| Year | Certifications |
| --- | --- |
| 2024 | KCNA, KCSA, Kubestronaut (CNCF) |
| 2023 | CISSP |
| 2022 | HashiCorp Vault Operations Professional, HashiCorp Terraform Associate, AWS Solutions Architect Associate, Google Cloud Associate Cloud Engineer, Microsoft Azure Administrator Associate |
| 2021 | CKAD, CKS |
| 2020 | CKA, Elastic Certified Analyst |
| 2019 | CompTIA Security+, Elastic Certified Engineer |

`scripts/ci/site_markup.py` gains a text rule over the built About page
and the landing page: no `watch`, `photograph` or `(I checked)`
(case-insensitive), no "Start here" on the landing page, and the
About page's certification years in strictly decreasing order.

## Shared layout (task 12)

Today each public page sizes its own `body`: the blog `44rem`, the
landing page `60rem` with a `3rem` top padding and its nav outside
`header.site`, the dashboard `72rem`. Switching pages moves the nav and
the content edge.

One container for every public page:

- `body { margin: 0 auto; max-width: 72rem; padding: 1.5rem 1.25rem 3rem; }`,
  `* { box-sizing: border-box; }`, the font shorthand
  `1.0625rem/1.6 system-ui, -apple-system, "Segoe UI", sans-serif`
  (font size and line height decide the nav's height, so they are part
  of the layout).
- `header.site` (`padding-bottom: 0.75rem`, a `1px` bottom rule in
  `var(--rule)`), `nav.site` (flex, wrap, gap `0.5rem 1.5rem`, the link
  states), `main { padding-top: 1.5rem; }`, and `footer.site`'s margin,
  padding and rule.
- `72rem` because the dashboard's grid needs it (three `17rem` tracks
  and their gaps); the blog's text keeps its reading measure in a column
  `main > .prose { max-width: 44rem; }` that starts at the container's
  left edge, so the left content edge is the same everywhere. The
  landing page's hero, blocks and cards use the full `72rem`.

These rules live in `site/assets/css/layout.css` and nowhere else; the
per-site stylesheets keep colours and their own components and drop
every rule the shared file owns.

| Page | How it gets `layout.css` |
| --- | --- |
| Blog | Hugo Pipes concatenates `layout.css`, `main.css` and `syntax.css` into the one fingerprinted stylesheet |
| Landing page | `apps/website/landing/layout.css`, a copy, a third file of the `website-landing` ConfigMap, linked before `landing.css` |
| Dashboard | `dashboard/internal/web/assets/layout.css`, a copy, embedded and served first in its one stylesheet (the integrity hash covers both) |

`task site:layout-sync` copies the canonical file over the copies;
`scripts/ci/site-check.sh` fails when a copy differs byte for byte. It
and `layout-check.sh` run when the diff against `HEAD^1` matches
`^(site/|apps/website/|dashboard/internal/web/|scripts/ci/(site[-_]|layout-check))`,
so a dashboard-only change to its copy or its nav is checked too (Go
`embed` cannot read outside its module and a ConfigMap generator outside
its kustomization, so a checked copy is the one definition both can
use).

The same navigation bar everywhere: `<header class="site"><nav
class="site" aria-label="Site">` with the links of `NAV`; the landing
page moves its nav into `header.site` and drops its negative margin.
`scripts/ci/site_markup.py` compares each rendered page's
`header.site > nav.site` with `NAV` (tags, classes, order, text,
`href`); only `aria-current` may differ. The dashboard's golden pages
are rendered pages, so its nav is checked too.

The layout check, `scripts/ci/layout-check.sh`, a step of the `site`
job, runs on the regex above. The `site` job gains what the check
needs and the `dashboard` job already has: `actions/setup-go` with
`go-version-file: dashboard/go.mod` (the web role and `pushfixture`)
and `install-tool.sh chrome-headless-shell`, its tool-cache key adding
`CHROME_HEADLESS_SHELL_VERSION`. Steps:

1. Builds the blog, takes the landing page from its ConfigMap sources
   and renders the dashboard's full fixture page (the web role and
   `pushfixture`, as in `dashboard-screenshots.sh`).
2. Writes a static copy of each page (landing, blog home, one article,
   About, dashboard) with its stylesheet into a temporary directory,
   each with one added `<script src="/measure.js">` that writes the
   measurements into the DOM. The copies are test fixtures served by
   `python3 -m http.server` on `127.0.0.1`, never deployed; the real
   pages stay script-free. Layout depends only on HTML and CSS, so the
   copy lays out like the page.
3. Runs the pinned `chrome-headless-shell --dump-dom` at
   `--window-size=1920,1080` and `390,844` and reads, for each page:
   the left edge and width of `body`'s content box, the `x`, `y`,
   width and height of `nav.site`, and the `x` and width of each nav
   link (`getBoundingClientRect`, scrollbars hidden).
4. Fails when any value differs by more than 1 px from the landing
   page's at the same viewport, naming the page, the value and both
   numbers. The current page's bold link can be wider, so the link
   widths are compared with every page's links in normal weight: the
   copy removes `aria-current` before measuring.

Later public pages (the tech radar) add their page to the list.

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
a canonical link to itself. The footer of `baseof` names the author and
links the privacy page; it states no licence.

## Why in the cluster

Three options were weighed:

- **In the cluster, behind the shared Gateway** (chosen by the operator).
  Free; headers set at the HTTPRoute like every app; the same Kyverno,
  netpol, probe, SLO and pentest coverage; the blog runs on the homelab it
  describes; statistics and the dashboard data stay in the house. Costs: the site is down when the house is (power cuts), and it
  adds public routes. The site serves static files from a pod with no
  token and no egress.
- **GitHub Pages**: free and independent of the house, but no CSP header,
  no `frame-ancestors`, no HSTS control, and statistics would still need the
  cluster. Rejected for Requirement 3.2.
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
| Markup check (grep on `public/`) | `<form`, `<iframe`, `style=`, an inline `<script>`, a `<script src=` other than `/stats/s.js`, or a `src=`/`href=` to another origin outside `<article>` |
| `exiftool -if '$EXIF:all or $XMP:all or $IPTC:all or $GPS:all'` over `site/**/*.{jpg,jpeg,png,webp,heic}` | Any image carries metadata; the fix is `task site:strip` (`exiftool -all= -overwrite_original`) |
| Deny patterns | An e-mail address other than `nedsi@pm.me` and `julien@nedsi.io`; gitleaks already scans the tree |
| Local files | `git ls-files site \| grep -E '\.local\.'` is non-empty |
| Drafts | A `draft: true` or future-dated page in `public/` |
| `site-serve-check.sh`: the base image with `public/`, `apps/website/nginx.conf` and the landing page mounted | A wrong status or `Location` for a name, a missing `405`, no blog link on the landing page |

`htmltest` and `exiftool` are pinned with checksums like the other tools.
The built `public/` is uploaded as the artefact `site-preview` (7 days).

Local hook: a `pre-commit` hook `site-denylist` greps `site/` case
insensitively for every line of `site/denylist.local.txt`. The file is
git-ignored through `*.local.*`; the hook prints the file and line of a
match, never the deny term itself, and passes when the file is absent (CI
cannot know the terms without publishing them).

## Serving

`apps/website/nginx.conf`, a ConfigMap mounted at `/etc/nginx-site/` and
started with `nginx -c`. The landing page is a second ConfigMap mounted at
`/usr/share/nginx/landing/`; the image holds only the blog. A change to
either rolls the Deployment through the name hash, with no new image.

| Port, `server_name` | Answers |
| --- | --- |
| 8080 `blog.nedsi.io` (default server, so the kubelet probes land here) | The blog from `/usr/share/nginx/html` |
| 8080 `nedsi.io` | The landing page |
| 8080 `www.nedsi.io` | `301 https://nedsi.io$request_uri` |
| 8081, any name | `301 https://<blog.nedsi.io or nedsi.io>$request_uri`, from a `map` on `$host` |

Every server block:

- `if ($request_method !~ ^(GET|HEAD)$) { return 405; }`, so no other
  error can turn into a `405`.
- `server_tokens off`; `autoindex off`; `absolute_redirect off`;
  `try_files $uri $uri/ =404`; `error_page 404 /404.html` on the blog.
- `Cache-Control: public, max-age=31536000, immutable` for fingerprinted
  assets under `/css/`, `max-age=300` for HTML and `/index.xml`,
  `no-cache` for `/data/`.
- `log_format site escape=json '{"time":"$time_iso8601","method":"$request_method","path":"$uri","status":$status,"bytes":$body_bytes_sent}'`;
  no address, user agent, referrer or query string. Vector already ships
  pod logs to SigNoz.
- Phase 2: `location /homelab/ { ssi on; }` (a prefix match, so it still
  applies after `try_files` serves `/homelab/index.html`).

Routes (HTTPRoute `website` on the three 443 listeners, `website-http` on
the three 80 listeners):

| Route, path | Backend |
| --- | --- |
| `website` `/` | `website` Service, 8080 |
| `website-http` `/` | `website` Service, 8081 |
| `/stats/s.js`, `/stats/api/send` (exact) on `blog.nedsi.io` | `umami` Service, rewritten to its tracker and collect paths (phase 2) |

Exact matches only, so no other Umami path is public.

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
`'none'`); phase 2 adds them with the statistics script.

The PostSync smoke Job (`components/postsync-smoke`) asserts each header
on both `/` and on a blog 404, the `405`, and the status and `Location`
of every redirect, so a header lost in a refactor rolls the change back.
Cilium applies `ResponseHeaderModifier` to the `404` (checked live in
#1399).

## The `website` app

- Namespace `website` in the apps AppProject destinations.
- Deployment `website`, one replica, image by digest, port 8080,
  `automountServiceAccountToken: false`, `runAsNonRoot`, `runAsUser: 101`,
  `readOnlyRootFilesystem`, capabilities drop `ALL`, `seccompProfile:
  RuntimeDefault`, `allowPrivilegeEscalation: false`; `emptyDir` for
  `/tmp` (nginx temp and pid paths point there); the ConfigMaps
  `website-nginx` and `website-landing` read-only; requests `10m`/`32Mi`,
  limit `64Mi`; readiness and liveness `GET /` on 8080.
- Service `website` on 8080 (`http`) and 8081 (`http-redirect`);
  HTTPRoutes `website` and `website-http` as above.
- Network policies, enforced from the start in the format of
  `infrastructure/network-policies/`: ingress to the site pod from the
  Gateway only on 8080 and 8081; no egress. Phase 2 adds the publishers' egress to
  the Prometheus Service in `monitoring` and to the API server.
- Lists: the blackbox probe list with `https://nedsi.io/` (app `nedsi`)
  and `https://blog.nedsi.io/` (app `blog`), both with the 99.5% SLO and
  in the user-facing app table in `docs/sre.md`; the pentest scope file
  (the `dast` targets come from it). Not in `ci/kind-workloads.txt`: the
  image is `linux/arm64` only and the kind runner is amd64; the `site`
  job's serve check covers the nginx config instead. No entry in
  `ci/expected-ingresses.txt`, which lists Ingresses, not HTTPRoutes.
- The namespace and the Application survived the revert of #1399 (the
  namespace has `Prune=false`, the Application lost its project
  destination); task 3 re-adopts both under the same names.

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

## Public figures

Phase 2. The allow-list, in `apps/website/publisher/schema.json` (JSON
Schema, `additionalProperties: false`):

| Key | Value | Source |
| --- | --- | --- |
| `covers` | `YYYY-MM-DD`, yesterday in Europe/Zurich | Clock |
| `computed_at` | RFC 3339, minute precision | Clock |
| `project_as_of` | Optional, RFC 3339: when the kept project figures were computed (GitHub rate-limited) | The last good document |
| `availability_30d` | Per shown app: percent, 0 to 100, one decimal | `slo:availability:ratio_rate30d` at `covers` 24:00 |
| `availability_daily` | Per shown app: the last 30 daily values, for the sparklines | The same rule as a range query, step 1 d |
| `error_budget_remaining_30d` | Per shown app: percent, -100 to 100, whole number; clamped at -100 before validation, -100 rendered as "exhausted" | `slo:error_budget_remaining:ratio_rate30d` |
| `nodes` | Integer 1-10 | `count(kube_node_info)` |
| `apps` | Integer 1-200 | Argo CD Applications, `count(argocd_app_info)` |
| `talos_version`, `kubernetes_version` | Strings matching `^v\d+\.\d+\.\d+$`; the lowest when nodes disagree (mid-upgrade) | `max by (os_image) (kube_node_info)` and `max by (kubelet_version) (kube_node_info)`, version taken from the label with `re.search(r"v\d+\.\d+\.\d+", label)` |

Solar, in its own document `solar.json` (task 8):

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
  (task 8). Both `concurrencyPolicy: Forbid`, `backoffLimit: 2`, in
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
| Query GitHub | 403 or 429 (the IP's unauthenticated quota, #1551) | Keep `project` of the last good document and its date in `project_as_of`; the page says so. Exit 1 when there is none |
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
2. The About page (`site/content/about/index.md`, a page bundle): a short
   intro in the operator's voice, then the résumé (glossary) as plain
   Markdown sections, and links to GitHub, LinkedIn and
   `julien@nedsi.io`. An optional small photo of the operator,
   `about/photo.jpg`, goes through `task site:strip` and the image-metadata
   check like any image. An agent drafts it from his CV; the operator
   validates the text in chat before the PR. The landing page's About card
   links to it. No separate résumé page and no résumé PDF.
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
- No WAN address, no secrets. Employers, the current one included, only
  on the About page, as the operator validated it. LAN addresses are fine
  (the repository already shows them).

The privacy page (`site/content/privacy.md`) lists:

- Access logs: time, method, path, status, bytes; kept for the SigNoz log
  retention; no address or user agent.
- Statistics (phase 2): page, referrer, country, browser, operating
  system, device type, screen size, language; no cookie, no stored IP, a
  monthly rotating hash; kept 13 months; `Do Not Track` respected.
- Legal basis: legitimate interest (GDPR art. 6(1)(f); nFADP), no
  transfer to third parties, data stored in Switzerland on the operator's
  hardware; off-site backups in AWS eu-central-1.
- E-mail: a message to `julien@nedsi.io` stays in the operator's Proton
  mailbox (Switzerland), is not passed on, and is deleted on request.
- Contact `julien@nedsi.io`.

## Testability

| What | How |
| --- | --- |
| Templates, links, markup, metadata, drafts | `site` job on every PR (unit level) |
| Image and nginx config | `site-serve-check.sh` in the `site` job: names, `405`, redirects (and the SSI from phase 2); the `site-publish` smoke before a push |
| Headers, method, redirects live | PostSync smoke, blackbox probes, `dast` |
| Publisher | pytest with a fake Prometheus; one manual Job run in task 7 |
| Umami | PostSync smoke: tracker and collect answer on `blog.nedsi.io/stats/`, UI paths `404` on `nedsi.io` and `blog.nedsi.io` |
| Network policy | Hubble shows no denied flow from the Gateway; acceptance criterion 10 |

## Edge cases

- An article image above 1 MiB: the `site` job warns; Hugo image
  processing makes a resized copy.
- A renamed article URL: Hugo `aliases` in front matter keep the old one.
- A ConfigMap of the publisher deleted by hand: Argo CD recreates the
  placeholder; the page shows no figures until the next run.
- First deploy before the first image exists: task 2 pushes the image
  before task 3 references it.
- The task 3 merge changes `site/` (base URL `https://blog.nedsi.io/`)
  and deploys the image of task 2 at the same time: until the Renovate
  digest PR lands (6 hours at most), the blog's canonical and feed links
  still name `https://nedsi.io/`. Phase 1 has no published article, so
  nothing links there yet.
- The zone not active yet: task 3 waits for task 0; cert-manager retries
  DNS-01 until the zone answers.
- DNS: external-dns is upsert only; removing the site later needs the
  records deleted by hand (as for every app).

## Why it is like this

- `nedsi.io`: the public identity apart from the household's domain, so
  a reader of the blog is not pointed at the family's services. The blog
  on `blog.nedsi.io` and a landing page at the apex (operator): the apex
  can link to more than the blog later.
- Redirects in nginx: Cilium's `RequestRedirect` adds `:443` and did not
  serve the HTTPS `www` redirect; nginx's are tested before a merge.
- nginx config and landing page as ConfigMaps: a change to either needs
  no image build, so a routing fix and its smoke land in one PR.
- In the cluster: free and fully under the same checks; GitHub Pages
  cannot set the CSP header.
- Hugo with no theme; the dashboard rendered by the project's own code:
  the strictest CSP is possible and there is little to patch.
- No comments: no moderation, no extra service, no reader data to hold;
  readers can open a GitHub issue.
- One layout file with checked copies: the three pages are built by
  three tools (Hugo, a ConfigMap, a Go binary), so they cannot import
  one stylesheet, and a stylesheet served from one origin to the others
  would break the `'self'`-only CSP. Rejected: three hand-kept copies
  (how the widths drifted apart), and a pixel diff (breaks on every
  browser update; geometry is what has to match).
- Statistics self-hosted under the site's own origin: no
  third party, no cookie, no consent banner, CSP `'self'` only.
- Renovate publishes: it already pins and automerges images; a second
  merge path would need a new token.
- Figures pushed into ConfigMaps: the public pod knows nothing and
  reaches nothing.
