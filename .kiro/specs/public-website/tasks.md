# Tasks: public-website

One PR per task, in order within a phase. Phase 1 (tasks 0-5) puts the
blog live on `nedsi.io` with the intro article; phase 2 (tasks 6-9) adds
statistics, the dashboard, solar and the republished articles.
No task writes to the cluster outside Argo CD. The defaults are in
[requirements.md](requirements.md#decided-defaults).

## Phase 1: the blog

- [ ] 0. Operator console steps for `nedsi.io` (no PR). Defaults in
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
- [ ] 1. Site sources: `site/hugo.toml`, the layouts (canonical link,
      licence footer), `main.css`, `site/LICENSE` (CC BY 4.0), the About
      stub for the operator, the privacy page (phase 1 content: logs
      only), full-content RSS. `task site:serve`, `task site:build`,
      `task site:strip`; Hugo, htmltest and exiftool pinned in
      `scripts/ci/install-tool.sh`; `scripts/ci/site-check.sh` and the
      `site` job in `ci.yaml` with the `site-preview` artefact; the
      `site-denylist` pre-commit hook. Check: a draft, a future-dated page,
      a `<script>` and a GPS-tagged JPEG each fail the job in a throwaway
      commit; the clean tree passes. [1.2, 1.4-1.7, 2.1-2.3, 3.1, 4.2-4.4, 6.4]
- [ ] 2. Image and publishing: `site/Dockerfile`, `site/nginx.conf` (method
      limit, log format, cache headers), `.github/workflows/site-publish.yaml`
      with its ntfy failure step, the Renovate package rule. Check: the
      workflow pushes `ghcr.io/ned-si/homelab-site:main` with a
      `linux/arm64` manifest; the GHCR package is public; `docker run` of
      the image answers `200` on `/` and `405` on `POST`. [2.4, 3.3, 3.6, 6.3]
- [ ] 3. Domain and app (after task 0): `nedsi.io` in the ClusterIssuers'
      `dnsZones`, the `nedsi-io` Certificate, the Gateway listeners, the
      HTTP redirect and `www` routes; `apps/website/`,
      `clusters/homelab/apps/website.yaml`, the AppProject destination,
      the HTTPRoute with the headers, the enforced network policies, the
      PostSync smoke, `ci/` lists, the blackbox probe, the pentest scope
      and `dast` targets; `task render`. Check: acceptance criteria 1, 2,
      4, 9, 10; Kyverno reports no violation. [1.1, 3.2-3.5, 3.7]
- [ ] 4. Docs: `docs/website.md` (write, preview, publish with article PRs
      as drafts that only the operator marks ready, privacy rules, Why it
      is like this), the draft rule in the run-conventions skill, the
      README services table, the `site/` row in
      `.kiro/steering/structure.md`, `nedsi.io` in `docs/networking.md`,
      the SLO app table in `docs/sre.md`. Check: a newcomer can publish an
      article from the doc alone; links resolve. [2, 4.1]
- [ ] 5. Intro article: drafted with the `operator-voice` skill, a draft
      PR for the operator to edit and mark ready. Check: acceptance
      criteria 3 and 8. [1.3]

## Phase 2: statistics and the dashboard

- [ ] 6. Statistics: `apps/umami/` (Deployment, `umami-postgresql`, the
      oauth2-proxy route on `umami.lilalala.com`, retention CronJob,
      network policies), the `/stats/` routes on `nedsi.io`, the tracker
      in `baseof`, `script-src`/`connect-src 'self'` in the CSP, the
      privacy page's statistics section. Check: acceptance criteria 5,
      13, 14; a visit shows in Umami with country, browser and device.
      [3.1, 3.8, 6.1, 6.2, 6.4]
- [ ] 7. Dashboard: `apps/website/publisher/` (CronJob, `publisher.py`
      with the renderer, `schema.json`, `config.json` with the shown apps,
      Role), the `website-data` placeholder and its `ignoreDifferences`,
      the read-only mount, `location /homelab/ { ssi on; }`,
      `site/content/homelab.md` and its `homelab` layout, the publisher's
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
