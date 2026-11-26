# Tasks: homelab-dashboard

One PR per task, in order. Tasks 1-3 add the app next to the publisher and
change nothing public; they start right after the amendment of
2026-11-20. Tasks 4 (the host `homelab.nedsi.io`) and 5 (the redirect and
the links) are the switch-over, in the next weekday daytime run with the
operator; task 6 deletes the publisher. No task writes to the cluster
outside Argo CD. Names and defaults:
[design.md, Overview](design.md#overview) and
[requirements.md](requirements.md#decided-defaults).

Tasks 8-15 are the redesign of 2026-11-23 (live availability, the
certificates, cluster and project cards). They run in order and do not
wait for tasks 4-6; task 7 comes after task 15 and documents the
result. Each says whether it is
**visible**: whether it changes what the web role renders at `/`, which
is what `https://homelab.nedsi.io/` shows once task 4 is live (until
then the page is only reachable through a port-forward). A visible task
merges only after the operator approves a preview: the page rendered
from the branch with live data, `/tmp/dashboard-redesign-preview.png`
and `.html`, with its figures listed in the request.

Task 16 is the Security card of 2026-11-24 and runs after task 15. It
is visible: it joins the preview of tasks 12-15 when that one has not
been shown yet, and gets its own preview and approval otherwise.

Where the checks of the look live: task 1 carries the golden HTML tests
(the page design, the status rules, the chart builders, the contrast
test and the markup check in `tests/test_site_markup.py`); task 2 carries
the rendered screenshot check.

- [x] 1. The Go module `dashboard/` with both roles: `cmd/homelab-dashboard`
      (`collect`, `collect --once --dry-run [--as-of]`, `web`, `version`),
      the `snapshot` package (embedded schema, `Validate`, the compiled
      shown apps, the hidden pattern, the rounding helpers), the
      `collector` (Prometheus, GitHub with the optional token, the `401`
      rule and the reset-aware refresh, the three cadences and the 03:45
      rule, the Ed25519 signer, the pusher over the headless Service), the
      `web` package (push receiver with its checks, the routes at `/` of
      [design.md, Routes](design.md#routes), readiness, headers, templates
      rendered per request, access log) with the dashboard of
      [design.md, The page](design.md#the-page): the navigation with
      absolute links, the app cards, stat tiles and "Coming later"
      panels, the status rules of
      [Status colours](design.md#status-colours), the SVG chart builders
      in `chart.go`, the dark responsive `dashboard.css`; the metrics,
      `slog` logs; the unit, golden and fuzz-seed tests of
      [design.md, Tests](design.md#tests), the contrast test, and in
      `tests/test_site_markup.py` the golden-page test against
      `Checker("homelab.nedsi.io", "https://homelab.nedsi.io/")` with
      `homelab.nedsi.io` in `SITE_HOSTS` and the per-host Homelab link of
      `scripts/ci/site_markup.py`; `dashboard/.golangci.yaml` and
      golangci-lint v2 pinned in `ci.yaml` and `scripts/ci/install-tool.sh`;
      `dashboard/Dockerfile`; `scripts/ci/dashboard-check.sh` and the
      `dashboard` job in `ci.yaml` (in the final job's `needs`); `go` in
      the CodeQL matrix (`matrix.include`, `build-mode: manual`); Renovate's
      `gomod` manager with `gomodTidy`, the module group and the toolchain
      group; the `dashboard/` row in `.kiro/steering/structure.md`, and in
      `.kiro/steering/tech.md` the first-party code row and "Go code:
      Google Go Style Guide, enforced by `dashboard/.golangci.yaml`".
      Check: `scripts/ci/dashboard-check.sh` passes locally and in `ci`; a
      throwaway commit with a `gofmt` error, a `revive` finding and
      `sonarr` in the shown apps each fail `ci`; acceptance criterion 6;
      `collect --once --dry-run` against Prometheus through a
      port-forward prints a snapshot that `Validate` accepts. [2.1-2.6,
      3.1-3.9, 4.1, 4.6, 5.1, 5.3]
      #1560
- [x] 2. Publishing and the screenshot check:
      `.github/workflows/dashboard-publish.yaml` (smoke with a signed test
      push by `internal/tools/pushfixture`, multi-arch build with SBOM and
      provenance, the arm64 `version` run under QEMU,
      `attest-build-provenance`, cosign sign and verify, tag `main`, ntfy
      on failure); `scripts/ci/dashboard-screenshots.sh` in the
      `dashboard` job with `chrome-headless-shell` pinned in `ci.yaml` and
      `scripts/ci/install-tool.sh`, and the `dashboard-screenshots`
      artefact ([design.md, Screenshot check](design.md#screenshot-check));
      the Renovate package rule for `ghcr.io/ned-si/homelab-dashboard`;
      the signer-list entry in `ci/image-signers.yaml`; one attestor and
      one validation per image in `verify-own-images.yaml`;
      `tests/test_security_controls.py` mapping every `ghcr.io/ned-si/*`
      entry to exactly one attestor and one validation. Operator, after
      the first push: set the GHCR package `homelab-dashboard` to public.
      Check: the workflow is green on `main`; `cosign verify` and
      `gh attestation verify` pass on `:main`; `docker buildx imagetools
      inspect` lists `linux/arm64` and `linux/amd64`; an anonymous `docker
      pull` works; `verify-own-images` still reports `pass` for the site's
      Pods; acceptance criterion 12, and a throwaway commit with a
      `style=` attribute in `page.html` fails the screenshot step on the
      CSP. [3.9, 4.2-4.5, 4.7]
      #1563
- [x] 3. Alongside, no public route. Operator first: a fine-grained GitHub
      token (public repositories, read-only, no expiry, reviewed yearly) and
      an Ed25519 key pair, in `secrets.local.env`. Then:
      `apps/homelab-dashboard/` (both Deployments with `maxSurge: 1`,
      `maxUnavailable: 0`, the web Service, the headless push Service, the
      ConfigMap `homelab-dashboard-push-pubkey`, PodMonitor, the PostSync
      smoke through the Service); `apps/secrets/homelab-dashboard-push.sops.yaml`
      and `apps/secrets/homelab-dashboard-github.sops.yaml` with their
      `.example`, their rows in `ci/secret-rotation.tsv` (both
      `credential`) and in the rotation table of `docs/secrets.md`; the
      namespace, the AppProject destination and
      `clusters/homelab/apps/homelab-dashboard.yaml`;
      `infrastructure/network-policies/56-homelab-dashboard.yaml`,
      enforced, and the collector's 9090 rule in the `prometheus` policy
      of `88-monitoring.yaml`; `HomelabDashboardSnapshotStale` in
      `platform/kube-prometheus-stack/routes/homelab-dashboard-alerts.yaml`
      with its promtool test; the web role in `ci/kind-workloads.txt`; the
      runbook `docs/runbooks/alerts/HomelabDashboardSnapshotStale.md` and
      the PAGE table row in `docs/sre.md`; `scripts/dashboard-compare.sh`;
      `task render`. Check: both pods Ready; `push_total{result="accepted"}`
      grows every minute; Kyverno reports no violation and
      `verify-own-images` is `pass`; acceptance criteria 1 and 2; the
      stale alert's rule is loaded; after the next night
      `scripts/dashboard-compare.sh` exits 0. [1.1-1.5, 5.1, 5.2, 6.1]
      #1566
- [x] 4. Switch-over, the host `homelab.nedsi.io` (weekday daytime, with
      the operator, after three equal comparisons). Operator first: no
      `homelab` record in the `nedsi.io` zone that external-dns does not
      own. Then, as in [design.md, Address](design.md#address): the
      Certificate `homelab-nedsi-io`; the Gateway listeners
      `https-nedsi-homelab` and `http-nedsi-homelab`; the HTTPRoute
      `homelab-dashboard` on `homelab.nedsi.io` with the response headers;
      `homelab.nedsi.io` on the `website-http` route and in nginx's
      `$https_host` map, with its case in `scripts/ci/site-serve-check.sh`;
      the web's ingress from the Gateway and the smoke's egress to it; the
      PostSync smoke through the Gateway; the test in
      `tests/test_security_controls.py` that `headers.golden` and the
      route carry the same CSP; the pentest scope (`docs/pentest/scope.yaml`,
      and so the `dast` targets); the blackbox probe
      `https://homelab.nedsi.io/` (app `homelab`) with its SLO rules and
      its row in the user-facing app table of `docs/sre.md`;
      `docs/threat-model.md` (the new public host, the push port and its
      key); `task render`. Check: acceptance criteria 3, 5, 11 and 13 on
      the public name; `blog.nedsi.io/homelab/` still served by nginx; the
      page matches the publisher's for the same `covers`. [3.3, 3.4, 6.2,
      7.1, 7.4]
      #1584; the three comparisons waived (operator, 2026-11-23).
- [x] 5. Switch-over, the redirect and the links (same run as task 4 once
      its checks pass): the `301` location for `/homelab` in the blog's
      server block of `apps/website/nginx.conf` replacing the SSI
      location, and its three forms in `scripts/ci/site-serve-check.sh`;
      the Homelab link `https://homelab.nedsi.io/` in
      `site/layouts/baseof.html`, in the landing page's navigation and
      "See the dashboard" button (`apps/website/landing/index.html`) and
      in `NAV` of `scripts/ci/site_markup.py`, the per-host difference of
      task 1 dropped; then the `homelab-site` digest bump so the blog's
      navigation follows. Check: acceptance criterion 14; the landing
      page and, after the bump, every blog page link the new host;
      `probe_success{app="blog"}` stays 1. [6.2, 6.3, 7.2, 7.3]
      #1587.
- [x] 6. Deletion (after one daily block served with the redirect live):
      `apps/website/publisher/`, its CronJob, ServiceAccount, Role,
      `website-data` and the Application's `ignoreDifferences`, the data
      mount in `apps/website/deployment.yaml`, the `/data/` location in
      `nginx.conf`, the `website-publisher` network policy and its 9090
      rule in `88-monitoring.yaml`, `site/content/homelab.md` and
      `site/layouts/homelab.html` (and the `homelab` case in `baseof`),
      `tests/website/`, the CronJob list entries, `^/homelab/` in
      `site/.htmltest.yml`'s `IgnoreURLs`; the public-website spec pointed
      here (task 7 replaced by this app, task 8 to be done in this app,
      acceptance criteria 11 and 12 on
      `https://homelab.nedsi.io/snapshot.json`). Closes #1551. Check:
      `https://homelab.nedsi.io/` still `200` with every header and
      `blog.nedsi.io/homelab/` still `301`; Argo CD `website` Synced and
      Healthy; no `website-publisher` object left. [6.4]
      #1588; the one-day wait waived (operator, 2026-11-23).
- [x] 7. Docs: `docs/homelab-dashboard.md` (how it works, operate, rotate
      the push key, release and verify a signature, the privacy rules, the
      status colours, Why it is like this), the README services table
      (`homelab.nedsi.io`), `docs/architecture.md` (first-party code),
      `docs/networking.md` (the fourth `nedsi.io` name and its redirects),
      `docs/testing.md` (the `dashboard` job with golangci-lint, the
      Google Go Style Guide and the screenshot step, `dashboard-publish`),
      `docs/observability.md` (the metrics), and from the redesign the
      cards, their sources, the DORA definitions and bands and the
      `fix-forward` label. Check: a newcomer can build, test, release and
      verify the image from the doc alone; links resolve.
      #1591 for the app as it runs; the redesign's parts (cards, DORA,
      `fix-forward`) by #1603 and #1624, the Security card by #1624.
- [x] 8. Probes and SLO rules (**not visible**). As in
      [design.md, Probes and SLO rules](design.md#probes-and-slo-rules-task-8):
      the probe `https://watch.lilalala.com/identity` in `public-https`
      (app `watch`); the Probe `internal-observability` on Prometheus
      `:9090/-/ready` and Alertmanager `:9093/-/ready` (apps
      `prometheus`, `alertmanager`); no rule in `88-monitoring.yaml`
      (its `monitoring` policy already admits the namespace both ways);
      in `slo.yaml` `watch`, `grafana` and `signoz` in the SLI
      matchers, `slo:app:info`, `SLOTargetProbeAbsent` and the latency
      threshold for `watch`, the groups `homelab.slo.observability` and
      `-long`; the promtool tests; Plex in the user-facing table of
      `docs/sre.md`; `task render`. Snapshot: no
      change. Check: acceptance criterion 15; `probe_success` is 1 for
      the three new targets an hour after the merge. [8.1-8.3]
      #1586
- [x] 9. NAS CPU, memory and load (**not visible**):
      `truenas_cpu_cores`, `truenas_load1`, `truenas_memory_total_bytes`
      from `system/info`, `truenas_cpu_utilisation_ratio` and
      `truenas_memory_used_bytes` from `reporting/get_data`, in
      `platform/truenas-exporter/exporter.py` with tests in
      `tests/test_truenas_exporter.py`
      ([design.md, NAS CPU, memory and load](design.md#nas-cpu-memory-and-load-task-9));
      each call checked against the NAS first, a missing one left out
      and named in the PR. Snapshot: no change. Check: the metrics in
      Prometheus; `NASExporterFailing` stays quiet. [11.1]
      #1600; used memory without the ZFS ARC in #1640.
- [x] 10. Sync statuses on GitHub (**not visible**). Operator first: the
      token in `argocd-notifications-github` gets "Commit statuses:
      write". Then the trigger `on-deployed`, the template
      `argocd-commit-status` and the subscription in
      `bootstrap/argocd-values.yaml`
      ([design.md, Sync statuses on GitHub](design.md#sync-statuses-on-github-task-10)),
      `tests/test_argocd_notifications.py`. Snapshot: no change. Check:
      the next merge that changes `deploy/` gets an `argocd/<app>`
      `success` status within 10 minutes; the two rollback triggers still
      pass `tests/bash/test_auto_rollback.sh`. [10.2]
      #1601
- [x] 11. Collector and snapshot version 2 (**not visible**: the page
      renders as before from version 2; `/snapshot.json` gains the new
      keys). Schema: every key of
      [design.md, Versions 2 and 3](design.md#versions-2-and-3-the-redesign)
      (`availability`, `certificates`, the new `cluster` keys, the new
      `project` keys) next to version 1's, `Validate` with its new
      checks, the shown certificates in `shown.go`. Collector: every
      query of
      [Cadence and sources of the redesign](design.md#cadence-and-sources-of-the-redesign),
      the midnight read of the finished days, the GraphQL query of the
      merged pull requests, the incidents (rollbacks and the `ALERTS`
      range query in slices), the `ci` runs; `block_age_seconds`. The
      label `fix-forward` and its rule in `docs/sre.md`;
      `scripts/dashboard-dora-check.sh` (recounts the four DORA figures
      with `gh` for a window). Check: `dashboard-check.sh` and the
      golden files unchanged; acceptance criteria 18 and 19;
      `collect --once --dry-run` through a port-forward prints a
      version 2 snapshot that `Validate` accepts; the `--as-of` output
      still equals the publisher's. [2.1-2.3, 2.6, 2.7, 10.1-10.4]
      #1603; rolled back in #1605, the project refresh's own deadline in
      #1606.
- [x] 12. Availability cards live (**visible**, preview and approval
      first). Schema version 3: `daily` dropped, the page reads
      `availability`; the 03:45 rule and `daily_age_seconds` removed;
      the shown apps of task 12 in `shown.go` (Plex for Jellyfin,
      Observability and Homelab dashboard added); the state word, the
      rolling 30 days ending now, today's bar (class `today`), the
      per-block staleness notices; golden pages updated. Snapshot keys
      read: `availability.*`. Queries: those of task 11. Probes: task 8,
      and task 4's for `homelab` ("No data" until then). Check:
      acceptance criteria 3 (on the port-forward until task 4), 6, 12
      and 16; the ten cards are on the grid at every width of the
      screenshot step.
      [2.2, 2.4, 3.5, 3.7, 3.8, 8.4]
      #1624
- [x] 13. Certificates card (**visible**, preview and approval first):
      the tiles, the rule of
      [design.md, Status colours](design.md#status-colours), golden
      pages. Snapshot keys read: `certificates.*`. Query:
      `probe_ssl_earliest_cert_expiry` per shown certificate. Probes:
      the existing public probes; `homelab.nedsi.io` from task 4.
      Check: acceptance criterion 17 for the certificate rule; the
      figures equal the Homelab / Security dashboard's. [9.1-9.3]
      #1624
- [x] 14. Cluster card, USE and RED (**visible**, preview and approval
      first): node and NAS rows, the Gateway's RED, Argo CD, restarts,
      volumes, versions; the rules of
      [Status colours](design.md#status-colours), with the Gateway p95
      thresholds checked against a day of live values first. Snapshot
      keys read: `cluster.*`. Queries: the cluster rows of task 11.
      Probes: none. Check: acceptance criteria 17 and 19; the figures
      equal Grafana's for the same instant within rounding. [2.7,
      11.1-11.4]
      #1624
- [x] 15. Project card, DORA and CI (**visible**, preview and approval
      first): the four DORA tiles with their bands, Renovate's share,
      the median `ci` run, the last five `ci` runs on `main`. Snapshot
      keys read: `project.*`. Queries: GitHub GraphQL and REST, the
      `ALERTS` range query of task 11. Probes: none. Check: acceptance
      criteria 17 and 18; each band word next to its colour in the
      golden pages. [10.1-10.6]
      #1624
- [x] 16. Security card (**visible**, in the preview of tasks 12-15 or
      its own, approval first). Schema version 4: the `security` block
      of [design.md, Version 4](design.md#version-4-task-16), `Validate`
      with its checks, the compiled signal list in `shown.go`. Collector:
      the queries of
      [Security signals](design.md#security-signals-task-16), with the
      count of a series born inside the window (no lockout signal: it
      would show which usernames exist). Web: the tiles,
      the sparkline builder in `chart.go` (class `spark`), the two rules
      in `status.go`, golden pages; the card in
      `docs/homelab-dashboard.md`. Snapshot keys read: `security.*`.
      Probes: none. Check: acceptance criteria 6, 19, 20 and 21; the 24 h
      counts equal the design's queries in Grafana for the same instant.
      [12.1-12.5]
      #1624
- [x] 17. DORA labels and overall level (**visible**, merges after its
      review round without a preview approval, operator 2026-11-24): the
      heading "DORA metrics", the two paragraphs and links of
      [design.md, The page](design.md#the-page) item 6, the overall level
      of [DORA bands](design.md#dora-bands) (`overallBand` in
      `status.go`), Renovate's share and the median `ci` run in their own
      group; `https://dora.dev/` in `LINKS` of
      `scripts/ci/site_markup.py`; the section order and every
      percentage with two decimals (operator, 2026-11-24). Snapshot keys
      read: `project.*`, unchanged. Probes: none.
      Check: acceptance criterion 17; the golden pages, a table test
      of the overall rule, `TestSectionOrder` and
      `TestPercentagesTwoDecimals`. Closes #1656. [7.10, 7.11, 10.7, 10.8]
      #1657

#1554 closed with task 17. The amendment of 2026-11-25 (#1670) reopens
the spec with tasks 18-21, in order, and the operator's Security-card
decisions of the same day add tasks 22 and 23; task 24 is the Scorecard
half of task 21. The same day's
rounding rule joins task 18 and the rolling-window fixes join task 19.
Each is **visible**
except tasks 20 and 22, merges after its review round with no preview approval (operator,
2026-11-24 and 2026-11-25), and is followed by the image deploy and a
live check.

- [x] 18. Stat tiles (**visible**): the `tile` template, `div.tiles`
      and the tile classes in `dashboard.css` as in
      [design.md, Stat tiles](design.md#stat-tiles-task-18), applied to
      every figure from the Cluster card down (Gateway, nodes, NAS,
      State, DORA, Renovate and CI, Security, Certificates);
      `--tile` and `TestContrast` on both backgrounds; the test that no
      label or value sits outside a tile and no label carries a status
      class; golden pages; the screenshots at the five widths in the PR.
      Every small text describing a time window says "rolling"
      ("rolling 24 h", "rolling 7 days", "rolling 30 days").
      Rounding (operator, 2026-11-25), as in
      [design.md, Rounding](design.md#rounding-task-18): snapshot
      version 5, every percentage and the error budget at full
      precision in the collector, `PercentDown`, `Percent`, `Budget`
      and `Share` deleted, one formatting function at two decimals,
      half to even, the status rules on the raw values; the tests of
      that section, 99.957 shown as "99.96%" among them.
      Snapshot keys read: unchanged. Probes: none. Check: acceptance
      criteria 6, 22 and 29. [3.11, 3.12, 3.13, 3.14]
      #1691
- [x] 19. Rework rate and "agents" (**visible**): snapshot version 6
      (`project.rework`, `ci_median_seconds_30d` nullable), the collector's count of
      [design.md, DORA bands](design.md#dora-bands), the tile without a
      band and its sentence, "a few agents" in the DORA paragraph, the
      recount in `scripts/dashboard-dora-check.sh`, a table test of the
      rework rule (a `fix` merge inside, at, and 1 s after the 24 h
      after an incident; a rollback counted once), golden pages; the
      metric in `docs/homelab-dashboard.md`. The rolling-window fixes
      of [design.md, Time windows](design.md#time-windows-2026-11-25)
      (operator, 2026-11-25): the median `ci` run over every successful
      run of the 30 days in 24-hour slices ending at the window's end,
      the incidents that started in the window and ended (Requirement
      10.4) with the same rule in the recount of
      `scripts/dashboard-dora-check.sh` (range and filter), the DORA
      figures and the CI median `null` 60 minutes after the last
      refresh with the token, the finished daily bars midnight to
      midnight; the window tests of
      acceptance criterion 30; Requirement 2.8 in
      `docs/homelab-dashboard.md`. Check: acceptance criteria 23 and
      30. [2.8, 10.4, 10.9, 10.10]
      #1703
- [x] 20. Provenance for both images and its verification (**not
      visible**): `actions/attest-build-provenance` in
      `site-publish.yaml` with its `gh attestation verify` step, the
      builder and workflow check in both publishing workflows, the
      attestation checks in `infrastructure/kyverno-policies/verify-own-images.yaml`
      (Audit), the `kyverno_policyreport_result` metric in the
      kube-state-metrics values, the SLSA badge in `README.md`, `task
      render`; the image-provenance spec's inventory notes the new
      attestation. Then one `homelab-site` image built by the new
      workflow and deployed. The PR body says `Closes #743` (signed
      provenance for the blog image on GHCR). Check: acceptance
      criteria 24 and 26. [13.3, 13.4, 13.7]
      #1714
- [x] 21. Supply chain section, SLSA panel (**visible**): snapshot
      version 7 (`supply_chain` without `scorecard`), the compiled image
      list, level and builder texts in `shown.go`, the Kyverno query in
      the collector, the panel between DORA metrics and Security, the
      status rule in `status.go`, `https://slsa.dev/` in `LINKS` of
      `scripts/ci/site_markup.py`, `TestSectionOrder` with Supply chain,
      golden pages, the section in `docs/homelab-dashboard.md`. Check:
      acceptance criterion 25 (SLSA part); live, both images "Build L2"
      and "Verified". [3.10, 13.1, 13.2]
      #1714
- [x] 22. Our own traffic out of the Security figures (**not
      visible**), as in
      [design.md, Security card figures](design.md#security-card-figures-tasks-22-and-23):
      the `theater` probe on a 2xx endpoint and its comment, `401`
      out of `http_gated`, the CI rule that a public probe expects only
      2xx or 3xx with its test, the smoke hooks' deliberate 4xx and
      405 requests against the Services, the list of own clients still
      crossing the Gateway and their exclusion where Envoy can
      attribute them, the Hubble drop metric with the source identity,
      `task render`. Check: acceptance criterion 27; live,
      `probe_success{app="theater"}` is 1 and the Gateway's 401 rate
      drops by the probe's 120 an hour. [12.6]
      #1691
- [x] 23. Security card figures (**visible**): snapshot version 5 with
      task 18 (tasks 18, 22 and 23 in one pull request, operator
      2026-11-25), the
      signal list, shares and unattributed line in `shown.go` and the
      collector, the plain names, no "observe mode", golden pages, the
      card in `docs/homelab-dashboard.md`. Check: acceptance criterion
      28. [12.6-12.11]
      #1691

- [x] 24. Supply chain section, Scorecard panel (**visible**): snapshot
      version 8 (`supply_chain.scorecard`), the Scorecard check list in
      `shown.go`, the Scorecard fetch in the collector, the panel after
      the SLSA one, the status rule in `status.go`,
      `https://scorecard.dev/` in `LINKS` of
      `scripts/ci/site_markup.py`, golden pages, the section in
      `docs/homelab-dashboard.md`. Split from task 21 on 2026-11-25: one
      pull request per operator item (SLSA, then Scorecard). Check:
      acceptance criterion 25 (Scorecard part); live, the Scorecard
      score equal to the API's. [13.5, 13.6]
      #1737
The last task ticked sets `status: done`, `closed:`, and closes #1670.

Task 27 is the operator's Scorecard decision of 2026-11-26 (#1756, a
`type/task` issue), numbered after tasks 25 and 26 of the Databases and
backups amendment (#1739).

- [x] 27. Every Scorecard check (**visible**), as in
      [design.md, Version 9](design.md#version-9-task-27): snapshot
      version 9 (`checks` for `lowest`), every check in name order in
      the collector, a `-1` as `null` and "Not applicable" on the page,
      `div.tiles.checks`, golden pages, the section in
      `docs/homelab-dashboard.md`. Check: acceptance criterion 25;
      live, the panel lists the API's checks with their scores.
      [13.5, 13.6]
      #1757

#1670 closed with tasks 24 and 27. The amendment of 2026-11-25 (#1739) reopens
the spec with tasks 25 and 26, the "Databases and backups" group of
the Cluster card, in order. Task 25 is **not visible**, task 26 is; each merges
after its review round with no preview approval (operator, 2026-11-24
and 2026-11-25) and is followed by a live check, task 26 by the image
deploy first.

- [x] 25. Database recording rules (**not visible**), as in
      [design.md, Recording rules](design.md#recording-rules-task-25):
      PrometheusRule `homelab-databases` in
      `platform/kube-prometheus-stack/routes/databases.yaml` with the
      groups `homelab.databases` (1 min) and
      `homelab.databases.restore` (2 min), its entry and comment in
      that directory's `kustomization.yaml`,
      `tests/prometheus/databases_test.yaml` with the cases of
      acceptance criterion 31, `task render`; one paragraph in
      `docs/backups.md`, Reading the results, naming the aggregates
      and what reads them. The PR body says `Spec:
      homelab-dashboard#25` and `Part of #1739`. Check: acceptance
      criterion 31; live, each aggregate in Grafana equal to the
      values of the design's table recomputed from the raw series at
      the same instant. [14.2, 14.3, 14.6]
      #1764
- [x] 26. Databases and backups group (**visible**), as in
      [design.md, Collector and page](design.md#collector-and-page-task-26):
      snapshot version 10 (`cluster.databases`, numbers only) in
      `snapshot.go`, `snapshot.schema.json` and `Validate`;
      `internal/collector/databases.go` with its queries and the
      clamp; `databaseTiles`, `durationText` and the five status
      functions; the group, its paragraph and tiles after State in
      `page.html`; the fixtures and golden pages (`full`, `alarms`,
      `since`); the screenshots at the five widths in the PR; the
      group, its figures and its rules in `docs/homelab-dashboard.md`
      (Cards, Privacy rules, Status colours). The PR body says
      `Closes #1739`. Check: acceptance criteria 32 and 33; live,
      after the digest bump, the card equal to the aggregates in
      Grafana at the same minute and no hidden name in
      `snapshot.json` or the page. Starts after task 27 is merged
      (snapshot version 9). [2.7, 3.12, 3.14, 14.1-14.6]
      #1766

The last task ticked sets `status: done`, `closed:`, and closes #1739.

#1739 closed with task 26. The operator's Scorecard decision of
2026-11-26 (#1775, a `type/task` issue) reopens the spec with task 28.
It is **visible**, merges after its review round with no preview
approval and after the French dashboard (site-theme-language task 5,
#1763), which changes the same lines, and is followed by the image
deploy and a live check.

- [x] 28. Scorecard check colours and notes (**visible**), as in
      [design.md, Scorecard](design.md#scorecard-task-24):
      `checkStatus` in `internal/web/status.go` with a table test on
      10, 7, 6, 4, 3, 0 and `nil`; in `checkTiles` the status and word
      from it and the compiled note by check name; the paragraph's
      sentence in `page.html`; the notes and the sentence as catalogue
      keys in English and French, the French as the operator corrected
      it; `TestScorecardTiles` with the coloured values, the four notes
      and no note elsewhere; golden pages; the screenshots at the five
      widths in the PR; the Scorecard row and Status colours in
      `docs/homelab-dashboard.md`. Snapshot keys read: unchanged
      (version 10). The PR body says `Closes #1775`. Check: acceptance
      criterion 25; live, after the digest bump, every check's value and
      class match the API's score, and the notes show on `/` and `/fr/`.
      [13.5]
      #1789

The last task ticked sets `status: done`, `closed:`, and closes #1775.
