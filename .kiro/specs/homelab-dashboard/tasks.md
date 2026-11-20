# Tasks: homelab-dashboard

One PR per task, in order. Tasks 1-3 add the app next to the publisher and
change nothing public; task 4 switches the route and task 5 deletes the
publisher, both on a weekday in daytime with the operator. No task writes
to the cluster outside Argo CD. Names and defaults:
[design.md, Overview](design.md#overview) and
[requirements.md](requirements.md#decided-defaults).

- [ ] 1. The Go module `dashboard/` with both roles: `cmd/homelab-dashboard`
      (`collect`, `collect --once --dry-run [--as-of]`, `web`, `version`),
      the `snapshot` package (embedded schema, `Validate`, the compiled
      shown apps, the hidden pattern, the rounding helpers), the
      `collector` (Prometheus, GitHub with the optional token, the `401`
      rule and the reset-aware refresh, the three cadences and the 03:45
      rule, the Ed25519 signer, the pusher over the headless Service), the
      `web` package (push receiver with its checks, routes, readiness,
      headers, templates rendered per request, `dashboard.css`, access
      log), the metrics, `slog` logs; the unit, golden and fuzz-seed tests
      of [design.md, Tests](design.md#tests), and the golden-page test in
      `tests/test_site_markup.py`; `dashboard/.golangci.yaml` and
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
      `sonarr` in the shown apps each fail `ci`; `collect --once
      --dry-run` against Prometheus through a port-forward prints a
      snapshot that `Validate` accepts. [2.1-2.6, 3.1-3.6, 4.1, 4.6, 5.1,
      5.3]
- [ ] 2. Publishing: `.github/workflows/dashboard-publish.yaml` (smoke with
      a signed test push, multi-arch build with SBOM and provenance, the
      arm64 `version` run under QEMU, `attest-build-provenance`, cosign
      sign and verify, tag `main`, ntfy on failure); the Renovate package
      rule for `ghcr.io/ned-si/homelab-dashboard`; the signer-list entry
      in `ci/image-signers.yaml`; one attestor and one validation per
      image in `verify-own-images.yaml`; `tests/test_security_controls.py`
      mapping every `ghcr.io/ned-si/*` entry to exactly one attestor and
      one validation. Operator, after the first push: set the GHCR package
      `homelab-dashboard` to public. Check: the workflow is green on
      `main`; `cosign verify` and `gh attestation verify` pass on `:main`;
      `docker buildx imagetools inspect` lists `linux/arm64` and
      `linux/amd64`; an anonymous `docker pull` works;
      `verify-own-images` still reports `pass` for the site's Pods.
      [4.2-4.5]
- [ ] 3. Alongside, no public route. Operator first: a fine-grained GitHub
      token (public repositories, read-only, expiry at most 180 days) and
      an Ed25519 key pair, in `secrets.local.env`. Then:
      `apps/homelab-dashboard/` (both Deployments with `maxSurge: 1`,
      `maxUnavailable: 0`, the web Service, the headless push Service, the
      ConfigMap `homelab-dashboard-push-pubkey`, PodMonitor, the PostSync
      smoke through the Service); `apps/secrets/homelab-dashboard-push.sops.yaml`
      and `apps/secrets/homelab-dashboard-github.sops.yaml` with their
      `.example`, their rows in `ci/secret-rotation.tsv` (`credential`,
      `api-token`) and in the rotation table of `docs/secrets.md`; the
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
- [ ] 4. Switch-over (weekday daytime, with the operator, after three equal
      comparisons): HTTPRoute `homelab-dashboard` on `https-nedsi-blog`,
      `PathPrefix /homelab`, with the response headers; the web's ingress
      from the Gateway and the smoke's egress to it; the PostSync smoke
      through the Gateway; the test in `tests/test_security_controls.py`
      that `headers.golden` and the route carry the same CSP;
      `docs/threat-model.md` (the new public server, the push port and its
      key). Check: acceptance criteria 3, 5 and 11 on the public name;
      `/homelab/` served by the app and `/` by nginx; the page matches the
      publisher's for the same `covers`. [3.3, 3.4, 6.2, 6.3]
- [ ] 5. Deletion (after one daily block served by the app):
      `apps/website/publisher/`, its CronJob, ServiceAccount, Role,
      `website-data` and the Application's `ignoreDifferences`, the data
      mount in `apps/website/deployment.yaml`, the `/homelab/` SSI location
      in `nginx.conf`, the `website-publisher` network policy and its 9090
      rule in `88-monitoring.yaml`, `site/content/homelab.md` and
      `site/layouts/homelab.html`, `tests/website/`, the CronJob list
      entries; `^/homelab/` stays ignored in `site/.htmltest.yml`; the
      public-website spec pointed here (task 7 replaced by this app, task 8
      to be done in this app, acceptance criteria 11 and 12 on
      `/homelab/snapshot.json`). Closes #1551. Check: `/homelab/` still
      `200` with every header; Argo CD `website` Synced and Healthy; no
      `website-publisher` object left. [6.4]
- [ ] 6. Docs: `docs/homelab-dashboard.md` (how it works, operate, rotate
      the push key, release and verify a signature, the privacy rules, Why
      it is like this), the README services table, `docs/architecture.md`
      (first-party code), `docs/testing.md` (the `dashboard` job with
      golangci-lint and the Google Go Style Guide, `dashboard-publish`),
      `docs/observability.md` (the metrics). Check: a newcomer can build,
      test, release and verify the image from the doc alone; links
      resolve.

The last task ticked sets `status: done`, `closed:`, and closes #1554.
