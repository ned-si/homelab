# Design: homelab-dashboard

## Overview

One Go module in `dashboard/` builds one binary, `homelab-dashboard`, with
two roles:

- `homelab-dashboard collect`: a Deployment in namespace
  `homelab-dashboard`. Once a night it reads Prometheus and the public
  GitHub API, builds the snapshot, validates it against the embedded JSON
  Schema and the compiled allow-list of shown apps, and merge-patches it
  into the ConfigMap `homelab-dashboard-snapshot`.
- `homelab-dashboard web`: a second Deployment in the same namespace. It
  mounts that ConfigMap read-only, re-validates what it reads, renders the
  page with `html/template` and serves `blog.nedsi.io/homelab/`, the
  snapshot as JSON and its embedded assets.

```text
Prometheus ──┐                         ┌── ConfigMap (read-only mount) ──> web ──> Gateway ──> reader
GitHub API ──┼──> collector ── patch ──┤
             │    (token, egress)      └── nothing else
Kubernetes API (patch one ConfigMap)        (no token, no egress)
```

The image is built by `.github/workflows/dashboard-publish.yaml` for
`linux/arm64` and `linux/amd64` on a distroless base, carries an SBOM and
SLSA provenance, is signed keyless with cosign, and reaches the cluster
through a Renovate digest pull request, as the site image does. Kyverno's
`verify-own-images` checks the signature.

Names, fixed:

| What | Name |
| --- | --- |
| App, Application, namespace | `homelab-dashboard` |
| Go module | `dashboard/`, module path `github.com/ned-si/homelab/dashboard` |
| Binary | `homelab-dashboard` (`cmd/homelab-dashboard`) |
| Image | `ghcr.io/ned-si/homelab-dashboard`, tags `<git sha>` and `main` |
| Workflow | `.github/workflows/dashboard-publish.yaml` |
| Deployments | `homelab-dashboard-collector`, `homelab-dashboard-web` |
| ConfigMap | `homelab-dashboard-snapshot`, key `snapshot.json` |
| ServiceAccount | `homelab-dashboard-collector` (the web role uses none) |
| Labels | `app.kubernetes.io/name: homelab-dashboard`, `app.kubernetes.io/component: collector` or `web` |
| Ports | web `http` 8080 (public), both roles `metrics` 9464 (`/metrics`, `/healthz`, `/readyz`) |

Stack, locked: Go (the version in `go.mod`'s `go` and `toolchain` lines),
the standard library first; `github.com/prometheus/client_golang` for the
metrics and the Prometheus HTTP API client;
`github.com/santhosh-tekuri/jsonschema/v6` for validation; `log/slog` for
logs; `staticcheck` and `govulncheck` as `tool` directives in `go.mod`;
`gcr.io/distroless/static-debian13:nonroot` and the `golang` builder image
by digest; Docker BuildKit, cosign, GitHub Actions, GHCR, Renovate,
Argo CD, Kustomize.

## Module layout

| Path | Holds |
| --- | --- |
| `dashboard/go.mod`, `go.sum` | The module, its two libraries and the two tools |
| `dashboard/cmd/homelab-dashboard/main.go` | Flags, the subcommands `collect`, `web`, `version`, signal handling |
| `dashboard/internal/snapshot/` | The snapshot types, `snapshot.schema.json` (embedded), `Validate`, the shown apps (`shown.go`) and the hidden-tooling pattern |
| `dashboard/internal/collector/` | Prometheus queries, the GitHub client, the ConfigMap writer, the schedule and retries |
| `dashboard/internal/web/` | The HTTP server, headers, the loader that watches the mount, the renderer |
| `dashboard/internal/web/templates/` | `page.html`, `notfound.html` (embedded) |
| `dashboard/internal/web/assets/` | `dashboard.css` (embedded, served with its content hash in the name) |
| `dashboard/internal/web/testdata/` | Snapshot fixtures and the golden HTML files |
| `dashboard/internal/metrics/` | The metric definitions and the metrics server |
| `dashboard/Dockerfile` | Builder and runtime stages |

Kubernetes access is two plain HTTPS calls with the projected token (`GET`
and merge `PATCH` of one ConfigMap), like `publisher.py`, so there is no
`client-go` and its forty modules. GitHub is plain `net/http` too.

## The snapshot

`snapshot.json` has the keys of today's `figures.json`
([public-website design, Public figures](../public-website/design.md#public-figures)
and `apps/website/publisher/schema.json`) plus `schema_version: 1`. The
same keys keep the comparison of task 3 a plain diff.

| Key | Value |
| --- | --- |
| `schema_version` | `1` |
| `covers` | `YYYY-MM-DD`, yesterday in Europe/Zurich |
| `computed_at` | RFC 3339, minute precision, Zurich offset |
| `apps[]` | `id`, `name`, `availability_30d` (0-100, one decimal, rounded down), `error_budget_remaining_30d` (-100 to 100, integer, clamped), `availability_daily` (30 values, `null` for a day without probes) |
| `cluster` | `nodes` (1-10), `apps` (1-200), `talos_version`, `kubernetes_version` (`^v\d+\.\d+\.\d+$`, the lowest when nodes disagree) |
| `project` | `prs_merged_30d`, `renovate_share_30d` (0-100), `ci_median_seconds_30d` (1-21600) |

`snapshot.schema.json` (JSON Schema 2020-12, `additionalProperties: false`
at every level) is embedded in the binary. `snapshot.Validate` runs the
schema, then the checks a schema cannot express: `apps` equals the compiled
allow-list, in order, by `id` and `name`; no `id` matches the hidden
pattern; `covers` is not after the day of `computed_at`. The collector
runs it before every write; the web role on every load.

Shown apps, `internal/snapshot/shown.go`: the list of today's
`config.json` (Immich, Mealie, Paperless-ngx, Jellyfin, Syncthing,
Keycloak, the landing page, the blog), each with its `slo_app` label. The
hidden pattern is the one of `publisher.py`
(`sonarr|radarr|lidarr|readarr|prowlarr|bazarr|recyclarr|lazylibrarian|qbittorrent|torrent|jackett|flaresolverr|theater|arr$`);
a test fails when an entry of the list matches it. The list is compiled
in, not configuration: adding an app is a reviewed, signed release, and
the web role can refuse a snapshot that names any other app.

Solar (public-website task 8) will be a separate key with its own schema
version; nothing in version 1 reserves it.

## Collector

### Schedule

- A loop in one goroutine. The target time is 03:45 Europe/Zurich, 15
  minutes after the publisher's 03:30, so the two do not call GitHub in
  the same minute while both run.
- At start-up it reads the ConfigMap; when the stored snapshot does not
  cover yesterday, it collects at once.
- A failed run is retried after 5, 10, 20 and 40 minutes, then every 60
  minutes, until one succeeds or the Zurich day changes (then `covers`
  moves on). A GitHub `403` or `429` with `X-RateLimit-Remaining: 0`
  moves the next attempt to `X-RateLimit-Reset` plus 30 s, if that is
  later.
- Each run has a 5-minute deadline (`context.WithTimeout`), each HTTP call
  10 s.
- `homelab-dashboard collect --once [--dry-run]` runs one collection and
  exits; `--dry-run` prints the snapshot instead of writing it. Used
  locally (with a port-forward to Prometheus) and in tests.

### Sources

Prometheus, `PROM_URL` (default
`http://kube-prometheus-stack-prometheus.monitoring.svc:9090`), instant
queries at the end of `covers` (Zurich midnight), the queries of
`publisher.py`:

| Figure | Query |
| --- | --- |
| `availability_30d` | `slo:availability:ratio_rate30d{app=~"<shown>"}` |
| `error_budget_remaining_30d` | `slo:error_budget_remaining:ratio_rate30d{app=~"<shown>"}` |
| `availability_daily` | `1 - slo:probe_error:ratio_rate1d{app=~"<shown>"}` at each of the 30 Zurich midnights (instant queries, not a range with a 86400 s step, so the DST days stay right) |
| `nodes` | `count(kube_node_info)` |
| `apps` | `count(argocd_app_info)` |
| `talos_version`, `kubernetes_version` | `count by (os_image) (kube_node_info)`, `count by (kubelet_version) (kube_node_info)`; version taken with `v\d+\.\d+\.\d+`, the lowest kept |

The cluster figures come from Prometheus, not from the Kubernetes API:
the values at the end of `covers` from the same source as the
availability, no ClusterRole on nodes and no read of Argo CD's
Applications, and an exact match with the publisher during the
comparison.

GitHub, `https://api.github.com`, repository `ned-si/homelab`, the calls of
`publisher.py`: the search API for merged pull requests in the 30 days and
those by `app/renovate`; the `ci.yaml` workflow runs (`status=success`,
created in the window, up to 3 pages of 100) for the median wall time. The
token is read from `/var/run/secrets/github/token` when the file exists (a
fine-grained token with read-only access to public repositories, Secret
`homelab-dashboard-github`, mounted `optional: true`), so the collector
works before the operator has created it. `User-Agent:
homelab-dashboard/<version>`.

### Writing

1. Validate (above). A failure logs every error, counts
   `source="validation"` and writes nothing.
2. `PATCH /api/v1/namespaces/homelab-dashboard/configmaps/homelab-dashboard-snapshot`,
   `application/merge-patch+json`, `{"data":{"snapshot.json": "<compact JSON>"}}`.
3. Record `homelab_dashboard_snapshot_written_timestamp_seconds`.

A failed run never touches the ConfigMap, so the web role keeps serving
the last good snapshot.

## Web

### Loading

The ConfigMap is mounted at `/var/lib/homelab-dashboard/` (`optional:
true`). Every 30 s the loader reads `snapshot.json` when its modification
time or size changed (kubelet swaps the `..data` symlink), validates it,
and on success renders the page into memory and swaps it in atomically
(`atomic.Pointer`). An invalid document is logged, counted in
`homelab_dashboard_snapshot_load_errors_total`, and the last good page
stays. No document at all: the page shows "No figures yet".

### Routes

The public port 8080 serves only these paths. Anything else is the `404`
page, any method other than `GET` or `HEAD` is `405` with `Allow: GET,
HEAD`.

| Path | Answer | `Cache-Control` |
| --- | --- | --- |
| `/homelab` | `301`, `Location: /homelab/` | none |
| `/homelab/` | The page | `public, max-age=300` |
| `/homelab/snapshot.json` | The validated snapshot as served, `application/json` | `no-cache` |
| `/homelab/assets/dashboard.<sha256-8>.css` | The stylesheet | `public, max-age=31536000, immutable` |

The metrics port 9464 serves `/metrics`, `/healthz` (the process runs) and
`/readyz` (the listener is up; a missing snapshot does not make the pod
unready, the page says so). It is not in any HTTPRoute.

`http.Server` with `ReadHeaderTimeout` 5 s, `ReadTimeout` 10 s,
`WriteTimeout` 10 s, `IdleTimeout` 60 s, `MaxHeaderBytes` 8 KiB; graceful
shutdown on `SIGTERM` within 10 s. Responses carry an `ETag` (the content
hash) and answer `If-None-Match` with `304`.

### Headers

Set by a middleware on every response of port 8080, the values of
`apps/website/httproute.yaml`:

```text
Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
Cross-Origin-Opener-Policy: same-origin
```

The HTTPRoute of task 4 sets the same values with
`ResponseHeaderModifier`: the route is the public contract every app
follows and the PostSync smoke checks; the server's copy is unit-tested
and holds when the route's filter is lost. When public-website task 6 adds
`script-src` and `connect-src` for the statistics script, both copies
change in the same PR (a test compares them, see [Tests](#tests)).

### The page

`page.html` reproduces the blog's `baseof` (`site/layouts/baseof.html`):
the same header, the navigation bar (Home `https://nedsi.io/`, Blog `/`,
Homelab `/homelab/` with `aria-current="page"`, About `/about/`) and the
footer (author, RSS, privacy). Then the content of today's
`site/content/homelab.md` (intro, the figures, "Coming later" for solar and
home automation), carried over as template text. The figure sections are
those of `publisher.py`'s `render`:

- Availability: one row per shown app, the 30-day figure, the error budget
  left (or "exhausted" at -100), the sparkline; "since <date>" and no
  budget when the first daily value is `null`.
- Cluster: nodes, Argo CD applications, Talos, Kubernetes.
- Project, last 30 days: pull requests merged, Renovate's share, median
  `ci` run.
- "Last updated <date>, <time> (Zurich time)".

The sparkline is inline SVG, built by a Go function from numbers only
(coordinates formatted with `strconv`), passed to the template as
`template.HTML` after a test proves it contains only `svg`, `line`,
`polyline` and `circle` elements with numeric attributes. Everything else
goes through `html/template`'s contextual escaping. Styling is by class
only; the stylesheet is `dashboard.css`, written from the blog's
`main.css` variables (colours, fonts, widths).

Staleness: the web role knows the time, so the page says it. When
`covers` is more than two days before today (Zurich), a line under the
title reads "These figures are from <date>: the nightly update is
failing." The rendered page is cached per snapshot and per day; the clock
is injected for the tests.

### Logs and privacy

`log/slog` JSON handler on stdout. One line per request: `time`, `level`,
`msg: request`, `method`, `path`, `status`, `bytes`, `duration_ms`. The
path is `r.URL.Path` (no query string). No client address, user agent,
referrer or header value is ever logged (public-website Requirement 6.3).

## Metrics

Prefix `homelab_dashboard_`, both roles on port 9464, scraped by one
`PodMonitor` (label `release: kube-prometheus-stack`, repo-policy
`monitor-selected`).

| Metric | Role | Type | Labels |
| --- | --- | --- | --- |
| `build_info` | both | gauge 1 | `version`, `goversion`, `role` |
| `collect_runs_total` | collector | counter | `result` = `success`, `failure` |
| `collect_errors_total` | collector | counter | `source` = `prometheus`, `github`, `kubernetes`, `validation` |
| `collect_duration_seconds` | collector | histogram | none |
| `snapshot_written_timestamp_seconds` | collector | gauge | none |
| `github_ratelimit_remaining` | collector | gauge | none |
| `snapshot_age_seconds` | web | gauge, computed at scrape: now minus `computed_at`; without a snapshot, now minus the process start | none |
| `snapshot_load_errors_total` | web | counter | none |
| `http_requests_total` | web | counter | `code`, `method` (`GET`, `HEAD`, `other`) |
| `http_request_duration_seconds` | web | histogram | none |

Labels never carry a path, so a scanner cannot grow the series count.

Alert, in a PrometheusRule `homelab-dashboard` in `apps/homelab-dashboard/`:

```yaml
- alert: HomelabDashboardSnapshotStale
  expr: max(homelab_dashboard_snapshot_age_seconds) > 48 * 3600
  for: 30m
  labels:
    action: human
    severity: warning
  annotations:
    summary: The public dashboard has served the same figures for over 48 h.
    runbook_url: https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/HomelabDashboardSnapshotStale.md
```

A person has to act: the collector has retried for a day and a half. It
goes in the "Automation gave up or failed" row of `docs/sre.md`. A failed
run on its own is INFO (the metrics and the Automation dashboard); there is
no alert for it. With no snapshot at all, the age counts from the web
pod's start, so a fresh deployment does not page at once and one that
never gets a snapshot pages after 48 h. A promtool unit test in
`tests/prometheus/` covers both.

## Build and release

### CI on pull requests

A `dashboard` job in `ci.yaml`, through `scripts/ci/dashboard-check.sh`,
in the `needs` of the final `ci` job. Like the `site` job it always runs
and exits 0 early when `git diff --name-only origin/main...HEAD` touches
neither `dashboard/` nor `.github/workflows/dashboard-publish.yaml`.

| Step | Fails when |
| --- | --- |
| `actions/setup-go` (SHA-pinned), `go-version-file: dashboard/go.mod`, module cache on `go.sum` | — |
| `go mod verify`; `go mod tidy -diff` | A module does not match `go.sum`; `go.mod` is not tidy |
| `gofmt -l .` | Any file listed |
| `go vet ./...` | Any finding |
| `go tool staticcheck ./...` | Any finding |
| `go tool govulncheck ./...` | A known vulnerability in reachable code |
| `go test -race -count=1 ./...` | Any test, the golden files included |
| `go build ./cmd/homelab-dashboard` | It does not build |
| The builder image's Go version equals `go.mod`'s `toolchain` | Renovate bumped one without the other |

`go` joins the CodeQL matrix in `codeql.yaml` with build mode `manual`
(`go build ./...` in `dashboard/`).

Tools: `staticcheck` and `govulncheck` are `tool` directives in `go.mod`,
so their versions and checksums are in `go.mod` and `go.sum` and Renovate's
`gomod` manager updates them. They are not linked into the binary, so the
image SBOM does not list them.

### Tests

| Package | Covers |
| --- | --- |
| `snapshot` | Schema and `Validate`: a valid fixture; a missing key, an extra key at each level, an out-of-range value, a bad version string, an app outside the allow-list, apps out of order; the allow-list against the hidden pattern; a fuzz target `FuzzValidate` with the fixtures as seed corpus |
| `collector` | A fake Prometheus and a fake GitHub (`httptest`): the full snapshot; each source failing; an empty result; a budget below -100; the version split mid-upgrade; a day without probes (`null`, "since"); DST: `covers` on the last Sunday of March and of October; the rate-limit reset moving the retry; the schedule with an injected clock; `--dry-run`; a fake API server for the merge patch and its body |
| `web` | Golden HTML of the page for a full snapshot, a snapshot with a new app ("since"), a stale snapshot and no snapshot (`-update` rewrites them); every header on `200`, `301`, `304`, `404` and `405`; `/homelab` redirect with a relative `Location`; an invalid snapshot after a valid one keeps the first; the markup rules (no `<script`, `style=`, `<form`, `<iframe`, no `src`/`href` to another origin outside the nav's `https://nedsi.io/`); the access log line has no address, user agent or query |
| `metrics` | The names and labels, and that no label value comes from the request path |

The web tests write the response headers they assert to
`internal/web/testdata/headers.golden`. From task 4, a test in
`tests/test_security_controls.py` compares that file's CSP with the
HTTPRoute's, so the two copies cannot drift apart.

### Image

`dashboard/Dockerfile`:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:<version>-trixie@sha256:<digest> AS build
ARG TARGETOS TARGETARCH VERSION
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/homelab-dashboard ./cmd/homelab-dashboard

FROM gcr.io/distroless/static-debian13:nonroot@sha256:<digest>
COPY --from=build /out/homelab-dashboard /homelab-dashboard
USER 65532:65532
ENTRYPOINT ["/homelab-dashboard"]
```

Go cross-compiles, so both platforms build on the amd64 runner without
emulation. No shell, no package manager, a static binary and the CA
bundle of the base image (for `api.github.com`).

### Publishing

`.github/workflows/dashboard-publish.yaml`, a copy of `site-publish.yaml`
with these changes:

- Triggers: `push` to `main` with `paths: [dashboard/**,
  .github/workflows/dashboard-publish.yaml]`, and `workflow_dispatch`.
- Permissions on the job: `contents: read`, `packages: write`,
  `id-token: write` (cosign and the attestation), `attestations: write`.
- Smoke before any push: build for `linux/amd64` with `--load`, run `web`
  read-only with a fixture snapshot mounted, check `200` on `/homelab/`
  with every header, `405` on `POST`, `404`, the `301`, `/readyz`; run
  `version` and check it prints the commit.
- `docker buildx build --builder attest --platform
  linux/arm64,linux/amd64 --sbom=true --provenance=mode=max --build-arg
  VERSION=$SHA --push -t $IMAGE:$SHA dashboard`, then read the index
  digest.
- Check the index lists `linux/arm64` and `linux/amd64`.
- `actions/attest-build-provenance` (SHA-pinned) on the index digest with
  `push-to-registry: true`: a signed SLSA v1 provenance statement next to
  BuildKit's unsigned one, verifiable with `gh attestation verify
  oci://ghcr.io/ned-si/homelab-dashboard@<digest> --owner ned-si`.
- `cosign sign` and `cosign verify` with the identity
  `https://github.com/ned-si/homelab/.github/workflows/dashboard-publish.yaml@refs/heads/main`,
  in the classic signature format, flags as in `site-publish`.
- Tag the signed digest `main`; log out; ntfy at low priority on failure.

The GHCR package must be public so the cluster pulls without a
credential. GitHub has no API for a user package's visibility, so the
operator sets it once in the package settings after the first push.

### Renovate

- `gomod` joins `enabledManagers`, with `postUpdateOptions: ['gomodTidy']`
  and a package rule grouping `dashboard/go.mod` updates (minor and patch
  automerge on green CI; a Go toolchain bump and the `golang` builder image
  in one group, so the version check above passes).
- The `dockerfile` manager already reads `site/Dockerfile`; it also picks
  up `dashboard/Dockerfile` (both `FROM` lines are `repo:tag@digest`).
- A package rule for `ghcr.io/ned-si/homelab-dashboard`, the copy of the
  `homelab-site` one: digest updates, `automerge: true`,
  `minimumReleaseAge: '0 days'`, group `homelab-dashboard`.

### Signature verification in the cluster

- `ci/image-signers.yaml`: an entry for
  `ghcr.io/ned-si/homelab-dashboard` with the `dashboard-publish` identity.
- `infrastructure/kyverno-policies/verify-own-images.yaml`: the attestor's
  `identities` gain the `dashboard-publish` subject. The policy stays
  Audit, as for the site; #1506 decides enforcement for both.
- `tests/test_security_controls.py`: the identity check compares every
  `ghcr.io/ned-si/*` signer-list entry with the policy, not only
  `homelab-site`.
- The image-provenance CI gate (its task 3), once merged, verifies new
  digests of this image in pull requests like the site's.

## Kubernetes

`apps/homelab-dashboard/`, rendered to `deploy/apps/homelab-dashboard/`:

- Namespace `homelab-dashboard` in `infrastructure/namespaces/namespaces.yaml`,
  Pod Security `restricted`, `Prune=false`; destination in the `apps`
  AppProject; `clusters/homelab/apps/homelab-dashboard.yaml` with
  `ignoreDifferences` on the ConfigMap's `/data` and
  `RespectIgnoreDifferences=true` (the `website-data` pattern).
- ConfigMap `homelab-dashboard-snapshot` in git as a placeholder
  (`snapshot.json: ""`).
- Both Deployments: one replica, image by digest, `runAsNonRoot`,
  `runAsUser: 65532`, `readOnlyRootFilesystem`, capabilities drop `ALL`,
  `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`,
  requests `10m`/`16Mi`, limit `64Mi`, liveness `/healthz` and readiness
  `/readyz` on 9464, `GOMEMLIMIT` at 80 % of the limit. Web:
  `automountServiceAccountToken: false`, the ConfigMap read-only at
  `/var/lib/homelab-dashboard`. Collector: ServiceAccount
  `homelab-dashboard-collector` with the token, the optional GitHub Secret
  at `/var/run/secrets/github`.
- Role and RoleBinding: `get`, `patch` on `configmaps`, `resourceNames:
  [homelab-dashboard-snapshot]`.
- Service `homelab-dashboard-web` (8080 `http`, 9464 `metrics`); no Service
  for the collector (the PodMonitor scrapes Pods).
- PodMonitor and PrometheusRule (above); the runbook
  `docs/runbooks/alerts/HomelabDashboardSnapshotStale.md`.
- PostSync smoke (`components/postsync-smoke`, own script like
  `apps/website`): through the Service before task 4, through the Gateway
  from task 4: `200` and every header on `/homelab/`, `404` with the
  headers, `405`, the `301` and its `Location`, `/homelab/snapshot.json`
  parses.
- Network policies, `infrastructure/network-policies/56-homelab-dashboard.yaml`,
  enforced from the start (`enforce-default-deny` in the namespace, kubelet
  probes in, DNS out):

  | Pod | Ingress | Egress |
  | --- | --- | --- |
  | web | Gateway (`ingress`, `host`, `remote-node`) on 8080, from task 4; the smoke Job on 8080; Prometheus on 9464 | none |
  | collector | Prometheus on 9464 | Prometheus Service 9090, `kube-apiserver` 6443, `world` 443 (GitHub; `world`, not `toFQDNs`, as for the publisher) |
  | smoke | none | web 8080; the Gateway on 443 from task 4 |

- `ci/kind-workloads.txt`: the web Deployment and its Service (stateless,
  no Secret; the image has an amd64 variant, so the `preprod` job boots
  it). The collector stays out: it needs Prometheus and the API.
- Kyverno: every baseline policy passes with no PolicyException.

## Migration

| Step | State | Rollback |
| --- | --- | --- |
| Task 3, alongside | Both run. The publisher at 03:30 writes `website-data`, the collector at 03:45 writes `homelab-dashboard-snapshot`. Only nginx serves `/homelab/`. | Revert: the app's objects go (the namespace stays, `Prune=false`) |
| Comparison | `scripts/dashboard-compare.sh` (read-only `kubectl get` of both ConfigMaps, `jq` drops `computed_at` and `schema_version`, `diff`; exit 1 on a difference) after each night. The operator looks at the page through `kubectl -n homelab-dashboard port-forward svc/homelab-dashboard-web 8080` | — |
| Task 4, switch-over | HTTPRoute `homelab-dashboard` on `https-nedsi-blog`, hostname `blog.nedsi.io`, `PathPrefix /homelab` to the web Service. Gateway API picks the longest prefix, so `/homelab` and `/homelab/...` leave the `website` route and everything else stays. The publisher still runs. | Revert: the route goes, nginx serves `/homelab/` again with the last `website-data` |
| Task 5, deletion | After one nightly update served by the app: the publisher and the SSI path deleted | Revert: the publisher comes back; its next run (or one manual Job) fills `website-data` |

The comparison passes when three consecutive `covers` dates are equal. A
difference is a bug in one of the two, fixed before the switch-over; the
count restarts.

With the Hugo page gone (task 5), the blog's navigation still links
`/homelab/`, which is no longer in Hugo's output: `site/.htmltest.yml`
ignores `^/homelab/`, and a check in the `site` job compares the
navigation of the built `index.html` with the golden page of the app, so
the two headers cannot drift apart unnoticed.

## Error handling

| Operation | Failure | Result | Seen as |
| --- | --- | --- | --- |
| Prometheus query | Connection, non-200, empty result | Run fails, nothing written, retried | `collect_errors_total{source="prometheus"}`, log `figure`, `error` |
| GitHub call | Network, `403`/`429` rate limit, incomplete search | Run fails, next try after the reset, nothing written | `source="github"`, `github_ratelimit_remaining` |
| Validation | Any rule | Nothing written | `source="validation"`, one log line per error |
| ConfigMap patch | API error | Run fails, retried | `source="kubernetes"` |
| No success for 48 h | — | The page says the figures are stale | `HomelabDashboardSnapshotStale` pages |
| Web load | Missing, unreadable, invalid | Last good page kept, or "No figures yet" | `snapshot_load_errors_total`, log |
| Web request | Unknown path, method | `404`, `405` with the headers | `http_requests_total{code}` |
| Publish | Build, smoke, sign, verify | Nothing tagged `main`, nothing deployed | ntfy, low priority |
| Kyverno | Unsigned or wrong identity | Audit report `fail` | Security dashboard |

## Why it is like this

- **Go.** One static binary on a distroless base, `html/template`'s
  contextual escaping for a public page, the standard library for HTTP and
  JSON, and the tooling (`vet`, `staticcheck`, `govulncheck`, the race
  detector, native fuzzing) built in. Python stays fine for the repo's
  scripts; a public server is where a compiled, typed binary with no
  interpreter in the image pays off. Rejected: keeping `publisher.py`
  (no build, no signature, a CronJob with an interpreter image, rendering
  done by string building).
- **Two roles in one binary and one image.** The boundary is enforced by
  the runtime configuration, which Kyverno and the network policies check:
  no token, no Secret, no egress for the web pod. Two images would double
  the signing, the SBOMs and the digest bumps for no gain in isolation; the
  collector's code in the web image can do nothing without credentials or a
  route out.
- **The snapshot in a ConfigMap.** It is under 10 KiB, written once a
  night, and the kubelet delivers it to the web pod with no network path
  between the two. Rejected: the collector pushing to the web role over
  HTTP (a write endpoint on the public pod), a shared volume (`ReadWriteOnce`
  iSCSI for a few KiB), the web role reading Prometheus (the boundary is
  gone).
- **The collector as a Deployment, not a CronJob.** A long-running process
  has a `/metrics` endpoint, so collect durations and errors by source are
  real metrics, and it can wait for GitHub's rate-limit reset instead of
  failing within a Job deadline. Its only rights are `get` and `patch` on
  one ConfigMap, and it has no ingress except the scrape. Rejected: a
  CronJob with a Pushgateway (a new component), a CronJob with only
  kube-state-metrics (no duration or source, no retry logic).
- **The web role renders.** The templates, the stylesheet and the server
  live in one package and are tested together; the ConfigMap holds data
  only. Rejected: HTML rendered by the collector (two processes would have
  to agree on the layout, and the web role would serve markup it did not
  produce).
- **Cluster figures from Prometheus.** See [Sources](#sources).
- **Versioning by commit.** `main` is production, every merge that touches
  `dashboard/` is a release, and the image, its signature, SBOM and
  provenance all name the commit. Rejected for now: semantic-version tags
  and a release PR bot (a second merge path and a GitHub App token for one
  deployer).
- **Home Assistant.** Its own UI and companion app already do control and
  home dashboards, behind its own login; rebuilding them here would add a
  write path into the house to a project whose point is that the public
  part writes nothing. The collector may read a few production values for
  the public page.
