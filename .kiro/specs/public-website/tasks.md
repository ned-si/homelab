# Tasks: public-website

One PR per task, in order within a phase. Phase 1 (tasks 0-5 and 10) puts the
landing page live on `nedsi.io` and the blog on `blog.nedsi.io` with the
intro article; phase 2 (tasks 6-9) adds statistics, the dashboard, solar
and the republished articles.
No task writes to the cluster outside Argo CD. The defaults are in
[requirements.md](requirements.md#decided-defaults).

## Phase 1: the blog

- [x] 0. Operator console steps for `nedsi.io` (no PR). Defaults in
      brackets:
      1. Cloudflare, same account: Add a site `nedsi.io` [Free plan, skip
         the record import, DNS only, no proxy].
      2. Dynadot: set the `nedsi.io` nameservers to the two Cloudflare
         nameservers shown; wait until Cloudflare marks the zone Active.
      3. Cloudflare, API tokens: edit the cert-manager token and the
         external-dns token in place, adding `nedsi.io` to their zone
         resources [permissions unchanged: Zone Read, DNS Edit]. The token
         values stay the same, so no secret changes in git.
      4. Cloudflare, `nedsi.io` DNS: add CAA `0 issue "letsencrypt.org"`
         [yes]; enable DNSSEC and add the DS record at Dynadot [yes].
      Check: `dig NS nedsi.io` returns the Cloudflare nameservers.
- [x] 1. Site sources: `site/hugo.toml`, the layouts (canonical link,
      licence footer), `main.css`, `site/LICENSE` (CC BY 4.0), the About
      stub for the operator, the privacy page (phase 1 content: logs
      only), full-content RSS. `task site:serve`, `task site:build`,
      `task site:strip`; Hugo, htmltest and exiftool pinned in
      `scripts/ci/install-tool.sh`; `scripts/ci/site-check.sh` and the
      `site` job in `ci.yaml` with the `site-preview` artefact; the
      `site-denylist` pre-commit hook. Check: a draft, a future-dated page,
      a `<script>` and a GPS-tagged JPEG each fail the job in a throwaway
      commit; the clean tree passes. [1.2, 1.4-1.7, 2.1-2.3, 3.1, 4.2-4.4, 6.4]
      #1393
- [x] 2. Image and publishing: `site/Dockerfile`, `site/nginx.conf` (method
      limit, log format, cache headers; moved to `apps/website/` in task
      3), `.github/workflows/site-publish.yaml` with its ntfy failure step, the Renovate package rule. Check: the
      workflow pushes `ghcr.io/ned-si/homelab-site:main` with a
      `linux/arm64` manifest; the GHCR package is public; `docker run` of
      the image answers `200` on `/` and `405` on `POST`. [2.4, 3.3, 3.6, 6.3]
      #1398
- [x] 3. Domain, landing page and app (after task 0). First attempt #1399,
      reverted in #1401 (`www` over HTTPS answered `404`, the HTTP
      redirects sent `:443`); redone as designed in
      [Redirects](design.md#redirects):
      `nedsi.io` in the ClusterIssuers' `dnsZones`; the `nedsi-io`
      Certificate for `nedsi.io`, `www.nedsi.io`, `blog.nedsi.io`; the six
      Gateway listeners; `apps/website/` with `nginx.conf` and `landing/`
      as ConfigMaps, the HTTPRoutes `website` (headers) and
      `website-http`, Service ports 8080 and 8081; `site/` base URL
      `https://blog.nedsi.io/`, `site/nginx.conf` removed from the image;
      `scripts/ci/site-serve-check.sh` in the `site` job; the existing
      `website` Application and namespace re-adopted, the AppProject
      destination; the enforced network policies; the PostSync smoke; the
      blackbox probes `nedsi` and `blog` with their SLO rules; the pentest
      scope (and so the `dast` targets); `task render`. Operator first:
      delete the proxied `nedsi.io` and `www` records already in the zone
      (not external-dns's), so external-dns can create its own. Check:
      acceptance criteria 1, 2, 4, 9, 10; Kyverno reports no violation.
      [1.1, 1.8, 3.2-3.5, 3.7]
      Second attempt #1421, reverted in #1430: the proxied records were
      still in the zone, and the smoke's plain-HTTP checks got `403` from
      Cilium's Envoy, which also enforces the smoke pod's egress on the
      upstream leg (website `:8081` was not allowed). Re-landed with both
      fixed. #1434
- [ ] 4. Docs: `docs/website.md` (write, preview, publish with article PRs
      as drafts that only the operator marks ready, privacy rules, Why it
      is like this), the draft rule in the run-conventions skill, the
      README services table, the `site/` row in
      `.kiro/steering/structure.md`, the three `nedsi.io` names and the
      nginx redirects in `docs/networking.md`, the SLO app table (`nedsi`,
      `blog`) in `docs/sre.md`. Check: a newcomer can publish an
      article from the doc alone; links resolve. [2, 4.1]
- [ ] 5. Intro article: drafted with the `operator-voice` skill, a draft
      PR for the operator to edit and mark ready. Check: acceptance
      criteria 3 and 8. [1.3]
- [x] 10. About page and contact: `site/content/about.md`
      becomes the bundle `site/content/about/index.md` with the intro and
      the résumé (optional `photo.jpg`, stripped by `task site:strip`);
      the privacy page's e-mail section and contact `julien@nedsi.io`;
      `julien@nedsi.io` added to the allowed addresses in
      `scripts/ci/site-check.sh`; the landing page's About card. Texts
      validated by the operator in chat first; draft PR he marks ready.
      Starts once `julien@nedsi.io` receives mail. Check: the `site` job
      passes; a test mail to `julien@nedsi.io` arrives. [1.2, 1.8, 4.1-4.3, 6.4]
      With the landing page's homepage content, which replaces #1443.
      #1536

## Phase 2: statistics and the dashboard

- [ ] 6. Statistics: `apps/umami/` (Deployment, `umami-postgresql`, the
      oauth2-proxy route on `umami.lilalala.com`, retention CronJob,
      network policies), the `/stats/` routes on `blog.nedsi.io`, the tracker
      in `baseof`, `script-src`/`connect-src 'self'` in the CSP, the
      privacy page's statistics section. Check: acceptance criteria 5,
      13, 14; a visit shows in Umami with country, browser and device.
      [3.1, 3.8, 6.1, 6.2, 6.4]
- [x] 7. Dashboard: `apps/website/publisher/` (CronJob, `publisher.py`
      with the renderer, `schema.json`, `config.json` with the shown apps,
      Role), the `website-data` placeholder and its `ignoreDifferences`,
      the read-only mount, `location /homelab/ { ssi on; }` in the blog's
      server block, `site/content/homelab.md` and its `homelab` layout, the
      dashboard button on the landing page, the publisher's
      egress policy, `tests/website/test_publisher.py`, the CronJob lists.
      Check: acceptance criteria 11 and 12; one manual Job run on a
      weekday. [5.1-5.4]
      Publisher and data #1550, page #1552, site image #1555; apps with
      under 30 days of data show availability since their first day.
      Shared navigation bar on both sites: #1548, image #1549.
      Replaced by the Go app of spec homelab-dashboard at
      `https://homelab.nedsi.io/`; the publisher is deleted (its task 6).
- [ ] 8. Solar: to be done in the homelab-dashboard app (spec
      homelab-dashboard), not as a CronJob here. Was: the `website-solar`
      CronJob every 5 minutes and its
      ConfigMap, from the Home Assistant production sensors in Prometheus;
      production only. Starts once the home-automation spec records solar
      production; until then it is an issue labelled `blocked`. Check: the
      page shows current power and today's total, and no consumption
      figure. [5.5]
- [ ] 9. Republished articles: the two articles the operator wrote for
      another company's blog, with `canonical` and the "First published
      at" line. Blocked until the operator has checked he may reuse them
      and supplied the texts; draft PRs he marks ready. Check: each page
      has `<link rel="canonical">` to the original. [1.7]

## Amendment of 2026-11-25: the text and one layout

The operator's edits of 2026-11-24. Both tasks merge after their review
round, with no approval pause (operator, 2026-11-24), and are checked
live. Task 12 comes before the tech radar (spec tech-radar), which uses
the shared layout.

- [x] 11. Home and About text, as in
      [design.md, Home and About text](design.md#home-and-about-text-task-11):
      `apps/website/landing/index.html` (the line "Automate all the
      things.", "What this is" without "(I checked)", "What you can
      expect" with the overview list, no "Start here", the About card's
      text), `site/content/about/index.md` (the intro and the projects
      with links, no watches or photography, certifications newest
      first), the text rule in `scripts/ci/site_markup.py` and its test,
      `https://github.com/ned-si/` in its `LINKS`.
      Then the `homelab-site` digest bump for the About page (Renovate,
      or by hand as in #1549). Check: the `site` job; acceptance
      criterion 15 live on both pages. [1.8, 1.9, 4.2]
      Text and check #1684, image #1689. The account URL is an exact-match
      `ACCOUNT` entry, not a `LINKS` prefix, so repository links outside
      `<article>` stay forbidden.
- [x] 12. One layout and its check, as in
      [design.md, Shared layout](design.md#shared-layout-task-12):
      `site/assets/css/layout.css` and its copies in
      `apps/website/landing/` and `dashboard/internal/web/assets/`,
      each site's stylesheet without the rules it owns, the blog's
      `.prose` column, the landing page's nav inside `header.site`,
      `task site:layout-sync`, the copy check in
      `scripts/ci/site-check.sh`, the nav comparison in
      `scripts/ci/site_markup.py`, `scripts/ci/layout-check.sh` in the
      `site` job (with `setup-go`, chrome-headless-shell and the wider
      skip regex of the design), the dashboard's golden pages and screenshots updated;
      `docs/website.md` gets the layout rule. Then the `homelab-site`
      digest bump and the dashboard image deploy. Check: acceptance
      criterion 16; live, the nav and the content edge do not move
      between `nedsi.io`, `blog.nedsi.io` and `homelab.nedsi.io` at
      1920x1080 and 390x844 (the check's measurements on the live
      pages). [7.1-7.5]
      Layout and check #1704, images #1693 (`homelab-site`) and #1706
      (`homelab-dashboard`). `site-check.sh` also runs the markup check on
      the dashboard's golden pages, so its nav is compared with `NAV`.

The last task ticked sets `status: done`, `closed:`, and closes #971; the
public part of #817 is then done and #817 keeps the private homepage.
