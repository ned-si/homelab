# Tasks: homelab-dashboard

One PR per task, in order. Tasks 1-3 add the app next to the publisher and
change nothing public; task 4 switches the route and task 5 deletes the
publisher, both on a weekday in daytime with the operator. No task writes
to the cluster outside Argo CD. Names and defaults:
[design.md, Overview](design.md#overview) and
[requirements.md](requirements.md#decided-defaults).

- [ ] 1. The Go module `dashboard/` with both roles: `cmd/homelab-dashboard`
      (`collect`, `collect --once [--dry-run]`, `web`, `version`), the
      `snapshot` package (embedded schema, `Validate`, the compiled shown
      apps and the hidden pattern), the `collector` (Prometheus, GitHub with
      the optional token and the reset-aware retry, the schedule, the
      ConfigMap patch), the `web` package (loader, routes, headers,
      templates, `dashboard.css`, access log), the metrics, `slog` logs;
      the unit, golden and fuzz-seed tests of
      [design.md, Tests](design.md#tests); `dashboard/Dockerfile`;
      `scripts/ci/dashboard-check.sh` and the `dashboard` job in `ci.yaml`
      (in the final job's `needs`); `go` in the CodeQL matrix; Renovate's
      `gomod` manager with `gomodTidy` and the Go group; the `dashboard/`
      row in `.kiro/steering/structure.md` and the first-party code row in
      `.kiro/steering/tech.md`. Check: `scripts/ci/dashboard-check.sh`
      passes locally and in `ci`; a throwaway commit with a `gofmt` error,
      a `staticcheck` finding and `sonarr` in the shown apps each fail the
      job; `collect --once --dry-run` against Prometheus through a
      port-forward prints a snapshot that `Validate` accepts. [2.1-2.6,
      3.1-3.6, 4.1, 4.6, 5.1, 5.3]
- [ ] 2. Publishing: `.github/workflows/dashboard-publish.yaml` (smoke,
      multi-arch build with SBOM and provenance, `attest-build-provenance`,
      cosign sign and verify, tag `main`, ntfy on failure); the Renovate
      package rule for `ghcr.io/ned-si/homelab-dashboard`; the signer-list
      entry in `ci/image-signers.yaml`; the `dashboard-publish` identity
      in `verify-own-images.yaml`; `tests/test_security_controls.py` over
      every `ghcr.io/ned-si/*` entry. Operator, after the first push: set
      the GHCR package `homelab-dashboard` to public. Check: the workflow
      is green on `main`; `cosign verify` and `gh attestation verify` pass
      on `:main`; `docker buildx imagetools inspect` lists `linux/arm64`
      and `linux/amd64`; an anonymous `docker pull` works. [4.2-4.5]
- [ ] 3. Alongside, no public route: `apps/homelab-dashboard/` (both
      Deployments, the web Service, ServiceAccount, Role and RoleBinding,
      the snapshot placeholder, PodMonitor, PrometheusRule with
      `HomelabDashboardSnapshotStale` and its promtool test, the PostSync
      smoke through the Service); the namespace, the AppProject
      destination and `clusters/homelab/apps/homelab-dashboard.yaml` with
      its `ignoreDifferences`; `infrastructure/network-policies/56-homelab-dashboard.yaml`,
      enforced; the web role in `ci/kind-workloads.txt`; the runbook
      `docs/runbooks/alerts/HomelabDashboardSnapshotStale.md` and the PAGE
      table row in `docs/sre.md`; `scripts/dashboard-compare.sh`;
      `task render`. Check: both pods Ready; Kyverno reports no violation
      and `verify-own-images` is `pass`; acceptance criteria 1 and 2; the
      stale alert's rule is loaded; after the next night
      `scripts/dashboard-compare.sh` exits 0. [1.1-1.5, 5.1, 5.2, 6.1]
- [ ] 4. Switch-over (weekday daytime, with the operator, after three equal
      comparisons): HTTPRoute `homelab-dashboard` on `https-nedsi-blog`,
      `PathPrefix /homelab`, with the response headers; the web's ingress
      from the Gateway and the smoke's egress to it; the PostSync smoke
      through the Gateway; the test in `tests/test_security_controls.py`
      that `headers.golden` and the route carry the same CSP. Operator first, optional: a fine-grained GitHub token
      (public repositories, read-only) in `secrets.local.env`, sealed as
      `apps/secrets/homelab-dashboard-github.sops.yaml` with its
      `.example`. Check: acceptance criteria 3, 5 and 11 on the public
      name; the page matches the publisher's for the same `covers`.
      [3.3, 3.4, 6.2, 6.3]
- [ ] 5. Deletion (after one nightly update served by the app):
      `apps/website/publisher/`, its CronJob, ServiceAccount, Role,
      `website-data` and the Application's `ignoreDifferences`, the data
      mount in `apps/website/deployment.yaml`, the `/homelab/` SSI location
      in `nginx.conf`, the `website-publisher` network policy,
      `site/content/homelab.md` and `site/layouts/homelab.html`,
      `tests/website/`, the CronJob list entries; `^/homelab/` ignored in
      `site/.htmltest.yml` and the navigation check in the `site` job; the
      public-website spec pointed here (task 7 ticked with #1550, #1552 and
      this PR; task 8 to be done in this app; acceptance criteria 11 and 12
      on `/homelab/snapshot.json`); `docs/threat-model.md`. Closes #1551.
      Check: `/homelab/` still `200` with every header; Argo CD `website`
      Synced and Healthy; no `website-publisher` object left. [6.4]
- [ ] 6. Docs: `docs/homelab-dashboard.md` (how it works, operate, release
      and verify a signature, the privacy rules, Why it is like this), the
      README services table, `docs/architecture.md` (first-party code),
      `docs/testing.md` (the `dashboard` job, `dashboard-publish`),
      `docs/observability.md` (the metrics). Check: a newcomer can build,
      test, release and verify the image from the doc alone; links
      resolve.

The last task ticked sets `status: done`, `closed:`, and closes #1554.
