# Tasks: public-website

One PR per task, in order within a phase. Phase 1 (tasks 0-5) puts the
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

## Phase 2: statistics and the dashboard

- [ ] 6. Statistics: `apps/umami/` (Deployment, `umami-postgresql`, the
      oauth2-proxy route on `umami.lilalala.com`, retention CronJob,
      network policies), the `/stats/` routes on `blog.nedsi.io`, the tracker
      in `baseof`, `script-src`/`connect-src 'self'` in the CSP, the
      privacy page's statistics section. Check: acceptance criteria 5,
      13, 14; a visit shows in Umami with country, browser and device.
      [3.1, 3.8, 6.1, 6.2, 6.4]
- [ ] 7. Dashboard: `apps/website/publisher/` (CronJob, `publisher.py`
      with the renderer, `schema.json`, `config.json` with the shown apps,
      Role), the `website-data` placeholder and its `ignoreDifferences`,
      the read-only mount, `location /homelab/ { ssi on; }` in the blog's
      server block, `site/content/homelab.md` and its `homelab` layout, the
      dashboard button on the landing page, the publisher's
      egress policy, `tests/website/test_publisher.py`, the CronJob lists.
      Check: acceptance criteria 11 and 12; one manual Job run on a
      weekday. [5.1-5.4]
- [ ] 8. Solar: the `website-solar` CronJob every 5 minutes and its
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

The last task ticked sets `status: done`, `closed:`, and closes #971; the
public part of #817 is then done and #817 keeps the private homepage.
