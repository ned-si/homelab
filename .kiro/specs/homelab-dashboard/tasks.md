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
- [ ] 4. Switch-over, the host `homelab.nedsi.io` (weekday daytime, with
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
- [ ] 5. Switch-over, the redirect and the links (same run as task 4 once
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
- [ ] 6. Deletion (after one daily block served with the redirect live):
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
- [ ] 7. Docs: `docs/homelab-dashboard.md` (how it works, operate, rotate
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
- [ ] 9. NAS CPU, memory and load (**not visible**):
      `truenas_cpu_cores`, `truenas_load1`, `truenas_memory_total_bytes`
      from `system/info`, `truenas_cpu_utilisation_ratio` and
      `truenas_memory_used_bytes` from `reporting/get_data`, in
      `platform/truenas-exporter/exporter.py` with tests in
      `tests/test_truenas_exporter.py`
      ([design.md, NAS CPU, memory and load](design.md#nas-cpu-memory-and-load-task-9));
      each call checked against the NAS first, a missing one left out
      and named in the PR. Snapshot: no change. Check: the metrics in
      Prometheus; `NASExporterFailing` stays quiet. [11.1]
- [ ] 10. Sync statuses on GitHub (**not visible**). Operator first: the
      token in `argocd-notifications-github` gets "Commit statuses:
      write". Then the trigger `on-deployed`, the template
      `argocd-commit-status` and the subscription in
      `bootstrap/argocd-values.yaml`
      ([design.md, Sync statuses on GitHub](design.md#sync-statuses-on-github-task-10)),
      `tests/test_argocd_notifications.py`. Snapshot: no change. Check:
      the next merge that changes `deploy/` gets an `argocd/<app>`
      `success` status within 10 minutes; the two rollback triggers still
      pass `tests/bash/test_auto_rollback.sh`. [10.2]
- [ ] 11. Collector and snapshot version 2 (**not visible**: the page
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
- [ ] 12. Availability cards live (**visible**, preview and approval
      first). Schema version 3: `daily` dropped, the page reads
      `availability`; the 03:45 rule and `daily_age_seconds` removed;
      the shown apps of task 12 in `shown.go` (Plex for Jellyfin,
      Observability and Homelab dashboard added); the state word, the
      rolling 30 days ending now, today's bar (class `today`), the
      per-block staleness notices; golden pages updated. Snapshot keys
      read: `availability.*`. Queries: those of task 11. Probes: task 8,
      and task 4's for `homelab` ("No data" until then). Check:
      acceptance criteria 3 (on the port-forward until task 4), 6, 12
      and 16; the grid has no hole with ten cards at 390 and 1280 px.
      [2.2, 2.4, 3.5, 3.7, 3.8, 8.4]
- [ ] 13. Certificates card (**visible**, preview and approval first):
      the tiles, the rule of
      [design.md, Status colours](design.md#status-colours), golden
      pages. Snapshot keys read: `certificates.*`. Query:
      `probe_ssl_earliest_cert_expiry` per shown certificate. Probes:
      the existing public probes; `homelab.nedsi.io` from task 4.
      Check: acceptance criterion 17 for the certificate rule; the
      figures equal the Homelab / Security dashboard's. [9.1-9.3]
- [ ] 14. Cluster card, USE and RED (**visible**, preview and approval
      first): node and NAS rows, the Gateway's RED, Argo CD, restarts,
      volumes, versions; the rules of
      [Status colours](design.md#status-colours), with the Gateway p95
      thresholds checked against a day of live values first. Snapshot
      keys read: `cluster.*`. Queries: the cluster rows of task 11.
      Probes: none. Check: acceptance criteria 17 and 19; the figures
      equal Grafana's for the same instant within rounding. [2.7,
      11.1-11.4]
- [ ] 15. Project card, DORA and CI (**visible**, preview and approval
      first): the four DORA tiles with their bands, Renovate's share,
      the median `ci` run, the last five `ci` runs on `main`. Snapshot
      keys read: `project.*`. Queries: GitHub GraphQL and REST, the
      `ALERTS` range query of task 11. Probes: none. Check: acceptance
      criteria 17 and 18; each band word next to its colour in the
      golden pages. [10.1-10.6]

The last task ticked sets `status: done`, `closed:`, and closes #1554.
