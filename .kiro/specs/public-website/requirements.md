---
kind: change
status: active
created: 2026-11-13
issue: 971
---
# Requirements: public-website

## Introduction

The repository is public as an implementation example, but there is no
place to explain it. This spec builds a public website on a new public
domain, `nedsi.io`: a simple landing page at the apex with buttons to the
other pages; a blog at `blog.nedsi.io` about how the homelab is built and
run, written by the operator in Markdown; and a home-made dashboard at
`https://blog.nedsi.io/homelab/` with aggregated, delayed figures and live
solar production. It covers #971 and the public part of #817.

`nedsi.io` is the public identity; `lilalala.com` stays the household's
domain for private and semi-private services.

Phase 1 puts the landing page and the blog live with an intro article, RSS
and a privacy page.
Phase 2 adds statistics, the dashboard and the republished
articles. Each phase is useful on its own.

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **Site**: the static files Hugo builds from `site/`, served at
  `https://blog.nedsi.io`.
- **Landing page**: the one static page at `https://nedsi.io`, from
  `apps/website/landing/`, with buttons to the blog, the source repository
  and, from phase 2, the dashboard.
- **Article**: one Markdown file under `site/content/posts/`, with front
  matter `title`, `date`, `summary`, `tags`, `draft`, and optionally
  `canonical` (the original URL of a republished article).
- **Published**: the article is in the image the `website` Deployment runs.
- **Dashboard**: `/homelab/` on the site (`https://blog.nedsi.io/homelab/`),
  showing the public figures.
- **Public figures**: the allow-listed values in
  [design.md, Public figures](design.md#public-figures).
- **Shown apps**: the allow-list of household and platform apps whose
  availability the dashboard shows; the *arr apps, qBittorrent and the
  indexer and downloader tooling are never on it.
- **Publisher**: the CronJobs that compute the public figures and write
  them to the ConfigMaps the site mounts.
- **Personal data**: anything that identifies or locates the household or
  its members other than the operator: their names, faces, voices, the
  address, the town, photos of the house or its surroundings, image
  metadata (EXIF, GPS), account names, routines, absences, household
  consumption and other live house data. The operator's own name, his
  photo on the About page and his professional history are not secret.
- **Résumé**: the operator's professional history on the About page: his
  IT roles only, with employers, titles and periods; certifications
  ordered by the year earned, with that year only; talks and articles. No
  skills list, education, languages, phone, address or birth date.

## Requirement 1: The blog is live

**User story:** As the operator, I want a working blog soon, so I can start
writing articles.

1. THE site SHALL be served at `https://blog.nedsi.io` and the landing page
   at `https://nedsi.io`, with one Let's Encrypt certificate through the
   shared Gateway. `https://www.nedsi.io` and `http://www.nedsi.io` SHALL
   redirect permanently to `https://nedsi.io`, and `http://` on the other
   two names to their `https://` URL, keeping the path and query. No
   `Location` SHALL carry a port.
2. THE site SHALL have a home page listing articles newest first, one page
   per article, an About page holding the short intro and the résumé
   below it, a privacy page, a tag list and a 404 page. There SHALL be no
   separate résumé page and no résumé PDF.
3. THE first release SHALL contain an intro article explaining the
   concept of the homelab and the blog, drafted in the operator's voice
   for him to edit.
4. THE site SHALL publish a full-content RSS feed at `/index.xml`, linked
   from every page with `<link rel="alternate" type="application/rss+xml">`.
5. Articles with `draft: true` or a future `date` SHALL NOT be in the
   built site.
6. Articles SHALL be licensed CC BY 4.0 in `site/LICENSE`; the code
   keeps the repository licence. No page states the licence; a copyright
   page may come later.
7. A republished article SHALL carry `<link rel="canonical">` to its
   original and a visible line naming where it first appeared.
8. THE landing page SHALL be one HTML page and one stylesheet, with
   buttons to the blog and the source repository, a card linking to the
   About page, a dashboard button from phase 2, and the privacy link in
   its footer.

## Requirement 2: Writing and publishing is a pull request

**User story:** As the operator, I want to write an article in Markdown and
publish it by merging, without touching the cluster.

1. AN article SHALL be one Markdown file plus its images in a page bundle
   `site/content/posts/<yyyy-mm-dd>-<slug>/index.md`.
2. `task site:serve` SHALL serve the site with drafts on
   `http://localhost:1313` on the operator's Mac, with the pinned Hugo.
3. EVERY pull request SHALL run the `site` job inside the `ci` workflow;
   when `site/` changed, it runs a Hugo build that fails on warnings, an
   offline check of internal links and anchors, the markup check, the
   image-metadata check, the content check (Requirement 4.3), and uploads
   the built site as a downloadable artefact for preview.
4. A merge to `main` touching `site/` SHALL build and push a new image, and
   the new image SHALL be running within 6 hours without operator action.
5. AN article PR SHALL open as a draft, and only the operator SHALL mark it
   ready; `scripts/pr-merge.sh` refuses drafts (an exception to "no human
   gates": publishing words under his name is not an operations change).

## Requirement 3: The site is hardened

**User story:** As the operator, I want the public site to add as little
attack surface to the homelab as possible.

1. THE site SHALL load no third-party resource (fonts, scripts, images,
   embeds) and set no cookie. Its only JavaScript SHALL be the self-hosted
   statistics script, served from `blog.nedsi.io`; the landing page, the
   dashboard and every other page work without JavaScript.
2. EVERY HTTPS response on the three names SHALL carry: `Content-Security-Policy` with
   `default-src 'none'`, only `'self'` for scripts, styles, images, fonts
   and connections, no `'unsafe-inline'` or `'unsafe-eval'`,
   `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'none'`;
   `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`,
   `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options:
   DENY`, `Permissions-Policy` denying camera, microphone, geolocation,
   payment and usb, `Cross-Origin-Opener-Policy: same-origin`.
3. THE site server SHALL answer only `GET` and `HEAD`; any other method
   gets `405`. Only the statistics collect endpoint accepts `POST`.
4. EVERY pod SHALL run as non-root with a read-only root file system, no
   capabilities, the `RuntimeDefault` seccomp profile, no service account
   token unless it needs the API, requests and limits, and pass every
   Kyverno baseline policy with no PolicyException.
5. EACH namespace SHALL have enforced network policies: ingress from the
   shared Gateway only; no egress for the site and statistics pods
   except the statistics database.
6. THE site image SHALL be built in this repository's CI, pushed to
   `ghcr.io/ned-si/homelab-site`, and run by digest; every image SHALL
   publish `linux/arm64`.
7. `nedsi.io`, `www.nedsi.io` and `blog.nedsi.io` SHALL be in the pentest
   scope and the `dast` workflow's targets.
8. THE statistics UI SHALL NOT be reachable on any `nedsi.io` name; it is
   on `lilalala.com` behind Keycloak, group `admins`.

## Requirement 4: No household data, ever

**User story:** As the operator, I want nothing on the site to identify
the household or help anyone target the house.

1. THE site SHALL NOT show personal data (glossary), secrets, the WAN
   address, any employer outside the About page, or anything about
   security devices (cameras, locks, alarm) and their placement.
2. THE author SHALL be shown as `nedsi`. The About page MAY show the
   operator's name, an optional small photo of him, his résumé (glossary;
   employers and titles included, the current one too), links to his
   GitHub and LinkedIn, and `julien@nedsi.io`. Employers appear only on
   the About page.
   Agents MAY draft the page from his CV; no About or landing text is
   merged before the operator has validated it.
3. CI SHALL fail when an image under `site/` carries EXIF, XMP, IPTC or
   GPS metadata (the About photo included), or when a file under `site/`
   matches the public deny patterns (e-mail addresses other than
   `nedsi@pm.me` and `julien@nedsi.io`, secret patterns through gitleaks,
   tracked `*.local.*` files).
4. A local pre-commit hook SHALL check `site/` against the operator's
   git-ignored deny list `site/denylist.local.txt` (household names,
   address terms); the hook passes when the file is absent.

## Requirement 5: The dashboard

**User story:** As a reader, I want to see that the homelab runs, without
learning anything that helps an attacker or shows who is home.

1. THE dashboard SHALL show only the public figures, each with the period
   it covers and the time it was computed, rendered by the project's own
   code (no dashboard product, no JavaScript).
2. THE availability figures SHALL cover a full past day or the 30 days
   ending with it, never the current day, computed once a day after 03:00
   Zurich, and only for the shown apps, by name.
3. THE site pod SHALL NOT reach Prometheus, Home Assistant or any internal
   service; the publisher pushes the figures to the site.
4. WHEN a publisher run fails or a value is out of range, THE dashboard
   SHALL keep the last good figures, show the period they cover, and say
   when they are stale.
5. Solar production MAY be shown near real time (current power and
   today's total, refreshed every 5 minutes) once Home Assistant records
   it. Household consumption, grid import and export, battery and charging
   SHALL NEVER be shown, at any granularity.

## Requirement 6: Statistics without consent banner

**User story:** As the operator, I want to know what is read and where
readers come from, within the GDPR and the Swiss nFADP, with no consent
banner.

1. Statistics SHALL be self-hosted and cookieless, store no raw IP address,
   no persistent identifier and nothing that tracks a reader across sites
   or days.
2. THEY SHALL record pages, referrers, countries, browsers, operating
   systems and device types.
3. THE site's access logs SHALL keep `time`, `method`, `path`, `status`
   and `bytes`, and SHALL NOT keep the client address, the user agent or
   the referrer.
4. THE privacy page SHALL list exactly what is collected by the logs and
   the statistics, why, how long it is kept, who to contact
   and how to have data deleted.

## Non-functional requirements

- Cost: no paid service beyond the `nedsi.io` registration; Cloudflare on
  the free plan, same account.
- Platform: arm64, one replica, rendered `deploy/` like every app.
- Availability: the site is a user-facing app with the 99.5% probe SLO; a
  power cut at home takes it down like the rest, and that is accepted.
- Voice: articles, the About page and the home page intro follow the
  operator's writing voice; reference text (the dashboard, the privacy
  page, the docs) follows the documentation standard.
- Language: English, British spelling.

## Acceptance criteria

1. `curl -sI https://nedsi.io/` and `curl -sI https://blog.nedsi.io/`
   return `200` and every header of Requirement 3.2; the landing page links
   to `https://blog.nedsi.io/`. `curl -sI https://www.nedsi.io/` and
   `curl -sI http://www.nedsi.io/` return `301` with `Location:
   https://nedsi.io/`; `curl -sI http://nedsi.io/` and
   `curl -sI http://blog.nedsi.io/` return `301` to the same URL on
   `https://`, with no port. [1.1, 1.8, 3.2]
2. `curl -sI https://blog.nedsi.io/does-not-exist` returns `404` with every
   header of Requirement 3.2. [3.2]
3. `curl -s https://blog.nedsi.io/index.xml` is a valid RSS document
   containing the intro article. [1.3, 1.4]
4. `curl -s -X POST -o /dev/null -w '%{http_code}'` prints `405` on
   `https://nedsi.io/` and `https://blog.nedsi.io/`. [3.3]
5. The built site contains no `<form`, `<iframe`, inline `<script>` or
   `style=`, no `<script src=` other than the statistics script, and
   no `src=` or `href=` to another origin outside `<article>`, checked in
   the `site` job. [3.1]
6. A PR adding a JPEG with GPS EXIF under `site/` fails `ci`. [4.3]
7. A draft article and a future-dated article are absent from the build. [1.5]
8. Merging an article PR shows the article on the site within 6 hours. [2.4]
9. Every pod's security context matches Requirement 3.4 and Kyverno
   reports no violation. [3.4]
10. From a debug pod in `website` with the site's labels, a request to the
    Prometheus Service times out. [3.5, 5.3]
11. `https://blog.nedsi.io/data/figures.json` holds only the allow-listed keys,
    `covers` equal to yesterday's date, and no app outside the shown
    apps. [5.1, 5.2]
12. A publisher run against an unreachable Prometheus leaves the figures
    unchanged and the Job fails. [5.4]
13. The site's log lines in SigNoz contain no client address or user
    agent; the statistics database has no column holding a full IP
    address. [6.1, 6.3]
14. The statistics UI paths return `404` on `nedsi.io` and
    `blog.nedsi.io`. [3.8]

## Out of scope

- The private homepage behind Keycloak (#817's private part): it stays on
  #817.
- Comments (Hugo has none built in; readers can open a GitHub issue),
  newsletters, search, a second language.
- Household consumption, presence, cameras, doors, alarm, at any
  granularity (home-automation design, Public data).
- Hosting off the cluster and Cloudflare's proxy: rejected for now, see
  [design.md](design.md#why-in-the-cluster).
- Moving household services to `nedsi.io`.

## Decided defaults

Each default holds until the operator says otherwise. Rows marked
"operator" are his answers of 2026-11-13, or of 2026-11-16 where dated.

| Topic | Default | Reason |
| --- | --- | --- |
| Hosting | In the cluster, behind the shared Gateway (operator) | Free, full control of headers, same checks as every app |
| Domain | `nedsi.io` (operator) | Public identity apart from the household domain |
| Names | Landing page at the apex, blog at `blog.nedsi.io`, `www` redirects to the apex (operator, 2026-11-16) | The apex can point at more than the blog later |
| Dashboard location | `https://blog.nedsi.io/homelab/`, a button on the landing page | A Hugo page of the site, so the publisher design stays as it is; see [design.md](design.md#dashboard-location) |
| DNS and TLS | Free Cloudflare zone in the same account; DNS-01; external-dns upsert only | Same tooling as `lilalala.com` |
| Blog generator | Hugo, home-made layouts, no theme (operator) | One pinned binary, built-in RSS, no npm tree to keep patched |
| Dashboard | Home-made: the publisher renders HTML and SVG from the figures (operator) | Shows the project's own work; no JavaScript |
| Sources | `site/` in this repository (operator) | One CI, articles link to the code they describe |
| Comments | None; readers can open a GitHub issue (operator) | No moderation, no extra service, no personal data to hold |
| Statistics | Umami, self-hosted, cookieless, phase 2 (operator) | Every wanted dimension without cookies or stored IPs |
| Dashboard apps | Household and platform apps by name; no *arr, qBittorrent or indexers (operator) | Nothing about the download stack |
| Solar | Near real time, production only (operator) | Production says nothing about who is home |
| Author | `nedsi`; the About page is his (operator) | Public commit identity |
| About page | Short intro, optional photo, then the full résumé; drafted from his CV, validated by him before merge (operator, 2026-11-19) | One page instead of a résumé page or PDF; his words, nothing an agent invents |
| Contact | GitHub, LinkedIn and `julien@nedsi.io`, a Proton custom-domain address; no form (operator, 2026-11-19) | A readable address on the public domain, in a mailbox he already has |
| Résumé content | IT roles only, no skills, education or languages; employers named, the current one included (operator, 2026-11-19) | The About page stays short; the photography years are in the intro |
| Certifications | Name and year earned, ordered by year, never whether one is valid or lapsed (operator, 2026-11-19) | Nothing to keep up to date |
| Language | English, British spelling (operator) | Same as the repository |
| Content plan | Intro article first; then two republished articles with canonical links (operator) | Texts and reuse permission from the operator |
| Article licence | CC BY 4.0 in `site/LICENSE`, not stated on the pages; code under the repository licence (operator, 2026-11-16) | Reuse with credit; nobody reads a licence footer |
| Article merge | Draft PR until the operator marks it ready | His words, under his name |
