# Design: homelab-dashboard

## Overview

One Go module in `dashboard/` builds one binary, `homelab-dashboard`, with
two roles:

- `homelab-dashboard collect`: the backend, a Deployment in namespace
  `homelab-dashboard`. Every 60 s it reads Prometheus (and, on its own
  slower cadence, the public GitHub API), builds the snapshot, validates
  it against the embedded JSON Schema and the compiled allow-list of shown
  apps, signs it with Ed25519 and pushes it to every web pod.
- `homelab-dashboard web`: the frontend, a second Deployment in the same
  namespace. It verifies each push (signature, freshness, schema,
  allow-list), keeps the last good snapshot in memory and renders
  `https://homelab.nedsi.io/` on every request with `html/template`, plus
  the snapshot as JSON and its embedded assets.

```text
Prometheus ──┐                                      ┌──> web :8080 ──> Gateway ──> reader
GitHub API ──┴──> collector ── signed POST :9465 ───┤    (public key only,
                  (push key, GitHub token, egress)  │     no token, no egress)
                                                    └──> every web pod (headless Service)
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
| Binary | `homelab-dashboard` (`cmd/homelab-dashboard`), subcommands `collect`, `web`, `version` |
| Image | `ghcr.io/ned-si/homelab-dashboard`, tags `<git sha>` and `main` |
| Workflow | `.github/workflows/dashboard-publish.yaml` |
| Deployments | `homelab-dashboard-collector`, `homelab-dashboard-web` |
| Services | `homelab-dashboard-web` (8080 `http`), `homelab-dashboard-web-push` (headless, 9465 `push`) |
| Push key | Secret `homelab-dashboard-push` (key `private-key`, collector only); ConfigMap `homelab-dashboard-push-pubkey` (key `public-keys`, web only) |
| GitHub token | Secret `homelab-dashboard-github`, key `token` (collector only) |
| ServiceAccount | Both roles use the namespace's `default` ServiceAccount with `automountServiceAccountToken: false` |
| Labels | `app.kubernetes.io/name: homelab-dashboard`, `app.kubernetes.io/component: collector` or `web` |
| Ports | web `http` 8080 (public) and `push` 9465 (internal); both roles `metrics` 9464 (`/metrics`, `/healthz`, `/readyz`) |

Stack, locked: Go (the version in `go.mod`'s `go` and `toolchain` lines),
the standard library first (`crypto/ed25519` for the push signature);
`github.com/prometheus/client_golang` for the metrics and the Prometheus
HTTP API client; `github.com/santhosh-tekuri/jsonschema/v6` for
validation; `github.com/google/go-cmp` in tests only; `log/slog` for logs;
`govulncheck` as a `tool` directive in `go.mod`; golangci-lint v2 pinned
in CI; `gcr.io/distroless/static-debian13:nonroot` and the `golang`
builder image by digest; Docker BuildKit, cosign, GitHub Actions, GHCR,
Renovate, Argo CD, Kustomize.

## Module layout

| Path | Holds |
| --- | --- |
| `dashboard/go.mod`, `go.sum` | The module, its libraries and the `govulncheck` tool |
| `dashboard/.golangci.yaml` | The lint configuration ([Code style](#code-style)) |
| `dashboard/cmd/homelab-dashboard/main.go` | Flags, the subcommands, signal handling |
| `dashboard/internal/snapshot/` | The snapshot types, `snapshot.schema.json` (embedded), `Validate`, the shown apps (`shown.go`), the hidden-tooling pattern, the rounding helpers |
| `dashboard/internal/collector/` | Prometheus queries, the GitHub client, the cadences, the signer and the pusher |
| `dashboard/internal/web/` | The public server, the push receiver, headers, the renderer, the status rules and the SVG chart builders (`chart.go`) |
| `dashboard/internal/web/templates/` | `layout.html`, `page.html`, `notfound.html` (embedded) |
| `dashboard/internal/web/assets/` | `dashboard.css` (embedded, served with its content hash in the name) |
| `dashboard/internal/web/testdata/` | Snapshot fixtures, test keys, the golden HTML files and `headers.golden` |
| `dashboard/internal/metrics/` | The metric definitions and the metrics server |
| `dashboard/internal/tools/pushfixture/` | A test-only `main` that signs a fixture with the test key and pushes it to a web role; used by the screenshot step and the publish smoke, never in the image |
| `dashboard/internal/tools/gridcheck/` | A test-only `main` that fails on a row of cards with a hole in a screenshot; used by the screenshot step, never in the image |
| `dashboard/Dockerfile` | Builder and runtime stages |

Neither role talks to the Kubernetes API, so there is no `client-go`.
GitHub is plain `net/http`.

## Freshness

Every figure is live (operator, 2026-11-23; until the redesign,
availability covered finished days only):

| Block | Refreshed | Window |
| --- | --- | --- |
| `availability` | Every cycle (60 s) | State: the latest probes. 30-day figures: the rolling 30 days ending now. Daily bars: the 29 finished Zurich days before today, then today from midnight to now |
| `certificates` | Every cycle | The latest probes |
| `cluster` | Every cycle | Now, or the last 5 minutes for rates; restarts over 24 h |
| `project` | Every 15 min with the GitHub token, hourly without | The rolling 30 days ending at the fetch |

The page therefore shows an outage, or a power cut, while it happens.
That was the reason for the finished-day rule; the operator chose the
live page. Household energy consumption and every other Home Assistant
value except solar production stay out (Requirement 2.5).

## The snapshot

`snapshot.json`, schema version 1 (tasks 1-3; the redesign's versions
follow):

| Key | Value |
| --- | --- |
| `schema_version` | `1` |
| `generated_at` | RFC 3339, second precision, Zurich offset: when the collector built this document |
| `daily.covers` | `YYYY-MM-DD`, the last finished Zurich day the block covers |
| `daily.computed_at` | RFC 3339, when the block was computed |
| `daily.apps[]` | `id`, `name`, `availability_30d` (0-100, one decimal, rounded down), `error_budget_remaining_30d` (-100 to 100, integer, clamped), `availability_daily` (30 values, `null` for a day without probes) |
| `cluster.as_of` | RFC 3339, the Prometheus evaluation time |
| `cluster.*` | `nodes` (1-10), `apps` (1-200), `talos_version`, `kubernetes_version` (`^v\d+\.\d+\.\d+$`, the lowest when nodes disagree) |
| `project.as_of` | RFC 3339, when the GitHub figures were fetched |
| `project.*` | `prs_merged_30d`, `renovate_share_30d` (0-100), `ci_median_seconds_30d` (1-21600) |

The figures and their meaning are those of today's `figures.json`
([public-website design, Public figures](../public-website/design.md#public-figures)
and `apps/website/publisher/schema.json`), regrouped by freshness.
Solar (public-website task 8) will be a new block with its own schema
version; nothing reserves it.

### Versions 2 and 3 (the redesign)

Version 2 (task 11) is version 1 plus the keys below, so the page of
version 1 still renders from it. Version 3 (task 12) drops `daily`: the
availability cards then read `availability`. The web role accepts only
the version it embeds; during a rollout the pushes of the other version
are refused (`push_rejected_total{reason="schema"}`) and the last good
snapshot stays, for the minute or two until both Deployments run the
same digest.

| Key | Value |
| --- | --- |
| `availability.as_of` | RFC 3339, the Prometheus evaluation time |
| `availability.days` | 30 Zurich dates `YYYY-MM-DD`, oldest first, consecutive, the last one today |
| `availability.apps[]` | `id`, `name`; `state`: `up`, `down` or `none`; `availability_30d` (0-100, one decimal, rounded down) and `error_budget_remaining_30d` (-100 to 100, integer, clamped), each `null` without data; `availability_daily`: 30 values (0-100, one decimal, rounded down, `null` for a day without probes), aligned with `days`, the last one today so far |
| `certificates.as_of` | RFC 3339 |
| `certificates.certs[]` | `id`, `name`, `days_left` (integer, rounded down, -30 to 400, `null` without a probe result) |
| `cluster.synced`, `cluster.healthy` | Argo CD applications `Synced` and `Healthy` (0 to `cluster.apps`) |
| `cluster.node_use[]` | One per node, by name (`^[a-z0-9-]{1,63}$`), sorted: `ready` (boolean); `cpu`, `memory`, `disk` (utilisation, 0-100, one decimal); `cpu_pressure`, `memory_pressure`, `io_pressure` (share of time with a task waiting, 0-100, one decimal); `net_errors_per_second` (0 or more, two decimals); each figure `null` without a series for the node |
| `cluster.nas` | `up` (boolean, false without a series), `pool_healthy` (boolean); `pool` (utilisation, 0-100, one decimal); `cpu`, `memory` (0-100, one decimal); `load_per_core` (two decimals); `device_errors`, `scrub_errors` (integers, 0 or more); each but `up` `null` when the exporter has no value |
| `cluster.gateway` | `requests_per_second` (two decimals), `errors_5xx` (share of answers, 0-100, two decimals), `latency_p95_ms` (integer); the last two `null` without requests, all three without a series |
| `cluster.restarts_24h` | Container restarts in the last 24 h, summed over the cluster (integer, 0 or more) |
| `cluster.volumes` | `count`, `used_bytes`, `capacity_bytes` (integers), `fullest` (the highest used share of one PVC, 0-100, one decimal; no name) |
| `project.deploys_30d` | Equal to `prs_merged_30d` (Requirement 10.1); the page shows both the count and the count over 30 |
| `project.lead_time_seconds` | Median lead time (integer, `null` without a counted merge), and `project.lead_time_count`, the merges counted |
| `project.failed_changes_30d` | Rollbacks and fix forwards merged in the window (integer) |
| `project.change_failure_rate` | `failed_changes_30d` over `deploys_30d`, 0-100, one decimal, rounded half to even |
| `project.incidents_30d`, `project.restore_seconds` | Incidents ended in the window, and their median duration (integer, `null` without one) |
| `project.ci_runs[]` | Up to 5, newest first: `run` (run number), `result` (`success`, `failure`, `cancelled`, `other`), `commit` (7 hex digits), `pr` (integer or `null`), `started_at`, `duration_seconds` |

`Validate` gains: `availability.apps` equals the shown apps and
`certificates.certs` the shown certificates, in order, by `id` and
`name`; `availability.days` is consecutive and ends on the Zurich date
of `generated_at`; `node_use` has `cluster.nodes` entries and no name
matches the hidden pattern; `synced` and `healthy` are at most `apps`;
`ci_runs` is newest first. No key of version 2 or 3 holds free text
from a source other than the compiled lists, the node names and the
version strings.

Shown apps from task 12 (`SLOApp` in brackets): Immich (`media`),
Mealie (`cook`), Paperless-ngx (`archive`), Plex (`watch`), Syncthing
(`syncthing`), Keycloak (`auth`), Observability (`observability`),
Landing page (`nedsi`), Blog (`blog`), Homelab dashboard (`homelab`).
Jellyfin's card goes; its probe and SLO stay. Shown certificates
(`internal/snapshot/shown.go`), each with the probe targets it covers:

| `id` | `name` | Probe targets |
| --- | --- | --- |
| `lilalala` | `*.lilalala.com` | `instance=~"https://[^/]+\\.lilalala\\.com/.*"` |
| `nedsi` | `nedsi.io` | `instance=~"https://(blog\\.)?nedsi\\.io/.*"` |
| `homelab` | `homelab.nedsi.io` | `instance=~"https://homelab\\.nedsi\\.io/.*"`, `null` until task 4's probe exists |

`snapshot.schema.json` (JSON Schema 2020-12, `additionalProperties: false`
at every level, body at most 64 KiB) is embedded in the binary.
`snapshot.Validate` runs the schema, then the checks a schema cannot
express: `daily.apps` equals the compiled allow-list, in order, by `id`
and `name`; no `id` matches the hidden pattern; `daily.covers` is before
the day of `daily.computed_at`; no `as_of` and no `computed_at` is after
`generated_at`. The collector runs it before every push; the web role on
every push it receives.

Rounding matches `publisher.py`, so the comparison of task 3 finds no
false differences: `math.Floor(r*1000+1e-9)/10` for the percentages,
`math.RoundToEven` for the error budget, Renovate's share and the CI
median (Python's `round()` rounds half to even), and the median of an
even count is the mean of the two middle values. Tests cover `.5` cases
for each.

Shown apps, `internal/snapshot/shown.go`: the list of today's
`config.json` (Immich, Mealie, Paperless-ngx, Jellyfin, Syncthing,
Keycloak, the landing page, the blog), each with its `slo_app` label;
task 12 changes it ([Versions 2 and 3](#versions-2-and-3-the-redesign)). The
hidden pattern is the one of `publisher.py`
(`sonarr|radarr|lidarr|readarr|prowlarr|bazarr|recyclarr|lazylibrarian|qbittorrent|torrent|jackett|flaresolverr|theater|arr$`);
a test fails when an entry of the list matches it. The list is compiled
in, not configuration: adding an app is a reviewed, signed release, and
the web role refuses a snapshot that names any other app.

## Collector

### Cadence

One loop, ticking every 60 s:

| Block | Refreshed | Source |
| --- | --- | --- |
| `cluster` | Every cycle | Prometheus instant queries at "now" |
| `project` | Every 15 min with the GitHub token, every 60 min without; cached between refreshes | GitHub, about 5 calls per refresh |
| `daily` | Once per Zurich day, at the first cycle after 03:45; held in memory | Prometheus instant queries at the end of `covers` |

- `daily.covers` is the Zurich day before the most recent 03:45. At
  start-up the collector computes the block for that day straight away:
  before 03:45 that is the day before yesterday, which the previous
  process was already serving, so a restart at night shows no gap and
  never computes yesterday before 03:45. 03:45 leaves time for the
  midnight recording rules and GitHub's search index to settle, and is
  15 minutes after the publisher's 03:30 while both run. Nothing persists:
  a restart recomputes from Prometheus.
- A block that fails keeps its last good value and is retried next cycle
  (`project`: at its next refresh, or after `X-RateLimit-Reset` plus 30 s
  on a `403`/`429` with `X-RateLimit-Remaining: 0`). The collector pushes
  only once it holds all three blocks.
- Each cycle has a 50 s deadline (`context.WithTimeout`), each HTTP call
  10 s. A due `project` refresh runs first, outside that deadline, with
  its own 3 min: its GraphQL pages and `ALERTS` range queries take longer
  than a cycle.
- `homelab-dashboard collect --once --dry-run [--as-of YYYY-MM-DD]` runs
  one collection, prints it and exits without pushing. `--as-of` sets
  every query time to the end of that Zurich day and prints the
  publisher's `figures.json` shape; `scripts/dashboard-compare.sh` uses it
  ([Migration](#migration)).

### Sources

Prometheus, `PROM_URL` (default
`http://kube-prometheus-stack-prometheus.monitoring.svc:9090`), the
queries of `publisher.py`:

| Figure | Query |
| --- | --- |
| `availability_30d` | `slo:availability:ratio_rate30d{app=~"<shown>"}` |
| `error_budget_remaining_30d` | `slo:error_budget_remaining:ratio_rate30d{app=~"<shown>"}` |
| `availability_daily` | `1 - slo:probe_error:ratio_rate1d{app=~"<shown>"}` at each of the 30 Zurich midnights (instant queries, not a range with a 86400 s step, so the DST days stay right) |
| `nodes` | `count(kube_node_info)` |
| `apps` | `count(argocd_app_info)` |
| `talos_version`, `kubernetes_version` | `count by (os_image) (kube_node_info)`, `count by (kubelet_version) (kube_node_info)`; version taken with `v\d+\.\d+\.\d+`, the lowest kept |

The cluster figures come from Prometheus, not from the Kubernetes API: no
ClusterRole on nodes, no read of Argo CD's Applications, and the same
numbers as the publisher for the comparison.

GitHub, `https://api.github.com`, repository `ned-si/homelab`: the search
API for merged pull requests and those by `app/renovate`; the `ci.yaml`
workflow runs (`status=success`, created in the window, up to 3 pages of
100) for the median wall time. `User-Agent: homelab-dashboard/<version>`.

`prs_merged_30d` is the pull requests merged into `main` in the rolling 30
days ending at the collection: `is:pr is:merged base:main
merged:<start>..<end - 1 s>`, with `start` the same Zurich wall time 30
days earlier (720 h, or 721 h and 719 h across a change of summer time).
The search answer's `total_count` is exact, so no page limit applies.
The publisher used the same query from midnight 30 days before its 03:30
run to the run: on 2026-11-23 it showed 729 against the collector's 678,
which the two windows explain exactly (57 pull requests merged between
2026-10-23 00:00 and 2026-10-24 16:31, 6 since 2026-11-22 03:30; none
merged into another branch). `TestProjectWindow` pins the query.

The token is a fine-grained GitHub token with read-only access to public
repositories and no expiry (operator decision, 2026-11-20: it reads only
public data), reviewed yearly: its row in `ci/secret-rotation.tsv` is
`credential` (365 days), because `api-token` means 180 days there.
Secret `homelab-dashboard-github`, mounted `optional: true` at
`/var/run/secrets/github/token`. The anonymous quota is 60 calls an hour
shared by the WAN address (#1551), so the 15-minute cadence needs it;
without the file the collector falls back to hourly. On a `401` the
collector logs `github token rejected`, counts `source="github"`, sets
`github_token_valid` to 0, keeps the last project figures and does not
fall back to anonymous calls (that would hide an expired token).

### Cadence and sources of the redesign

From task 11 the loop also builds `availability`, `certificates` and the
new `cluster` keys every cycle, and the new `project` keys at each
GitHub refresh. Task 12 drops the `daily` block and the 03:45 rule; the
`--as-of` dry run keeps the publisher's `figures.json` shape and its
queries until task 6, so the comparison of the migration still works.

The 29 finished days of the daily bars are queried once, at the first
cycle after each Zurich midnight (and at start-up), and held in memory;
today's bar and everything else are queried every cycle. All queries are
instant queries at the cycle's evaluation time `t`. `<shown>` is the
`SLOApp` list, `<today>` the seconds since Zurich midnight (at least
60), `<node>` the join `* on (instance) group_left (nodename)
node_uname_info` that names each node.

| Figure | Query |
| --- | --- |
| `state` | `min by (app) (probe_success{job=~"blackbox-public\|blackbox-internal", app=~"<shown>"})` at `t`: 1 `up`, 0 `down`, no series `none`; for `observability`, `down` when any of its four probes fails |
| `availability_30d`, `error_budget_remaining_30d` | `slo:availability:ratio_rate30d` and `slo:error_budget_remaining:ratio_rate30d` (`app=~"<shown>"`) |
| `availability_daily`, finished days | `1 - slo:probe_error:ratio_rate1d{app=~"<shown>"}` at each of the 29 Zurich midnights, the newest at today's 00:00 (as for version 1, so DST days stay right) |
| `availability_daily`, today | `avg by (app) (avg_over_time(probe_success{job="blackbox-public", app=~"<shown>"}[<today>s]))`, and for `observability` the mean over its four probes |
| `days_left` | `floor((min(probe_ssl_earliest_cert_expiry{job="blackbox-public", instance=~"<cert>"}) - time()) / 86400)` per shown certificate |
| `synced`, `healthy` | `count(argocd_app_info{sync_status="Synced"})`, `count(argocd_app_info{health_status="Healthy"})` |
| `node_use.ready` | `kube_node_status_condition{condition="Ready", status="true"}` by `node` |
| `node_use.cpu` | `1 - avg by (nodename) (rate(node_cpu_seconds_total{mode="idle"}[5m]) <node>)` |
| `node_use.memory` | `1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes`, `<node>` |
| `node_use.disk` | `1 - node_filesystem_avail_bytes{mountpoint="/var"} / node_filesystem_size_bytes{mountpoint="/var"}`, `<node>` (the EPHEMERAL partition on the eMMC) |
| `node_use.*_pressure` | `rate(node_pressure_cpu_waiting_seconds_total[5m])`, `rate(node_pressure_memory_waiting_seconds_total[5m])`, `rate(node_pressure_io_waiting_seconds_total[5m])`, `<node>` |
| `node_use.net_errors_per_second` | `sum by (nodename) ((rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m])) <node>)` |
| `nas.up` | `truenas_up` |
| `nas.pool`, `pool_healthy` | `nas:pool_used:ratio{pool="homelab"}` (the rule of `routes/nas-alerts.yaml`), `truenas_pool_healthy{pool="homelab"}` |
| `nas.device_errors`, `scrub_errors` | `sum(truenas_pool_device_errors{pool="homelab"})`, `truenas_pool_scrub_errors{pool="homelab"}` |
| `nas.cpu`, `memory`, `load_per_core` | `truenas_cpu_utilisation_ratio`, `truenas_memory_used_bytes / truenas_memory_total_bytes`, `truenas_load1 / truenas_cpu_cores` (task 9) |
| `gateway.requests_per_second` | `sum(rate(envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix=~"listener-secure\|listener-insecure"}[5m]))` |
| `gateway.errors_5xx` | `sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5", <listeners>}[5m]))` over the same sum for every class; `<listeners>` is the `envoy_http_conn_manager_prefix` matcher of the row above |
| `gateway.latency_p95_ms` | `histogram_quantile(0.95, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{<listeners>}[5m])))` (Envoy's histogram is in milliseconds) |
| `restarts_24h` | `sum(increase(kube_pod_container_status_restarts_total[24h]))`, rounded down |
| `volumes` | `count(kubelet_volume_stats_capacity_bytes)`, `sum(kubelet_volume_stats_used_bytes)`, `sum(kubelet_volume_stats_capacity_bytes)`, `max(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes)` |

The cluster queries aggregate in PromQL (the per-node ones not
aggregated above under `max by (nodename)`, the NAS ones under `max`), so
no namespace, pod or volume name reaches the collector's memory, let alone
the snapshot.
Envoy's request time runs to the end of the response, so long media
downloads raise the p95; task 14 checks the live value before it
settles the thresholds of [Status colours](#status-colours).

GitHub, from task 11. One GraphQL query (`POST /graphql`, token only)
pages through the merged pull requests of the window, 100 a page, and
returns for each: `number`, `title`, `createdAt`, `mergedAt`, the
`labels`, whether any file is under `deploy/` or `clusters/` (`files`,
first 100 paths; a pull request with more is counted as deploying), the
merge commit's `oid`, its message, and its commit status contexts
`argocd/*` with their state and `createdAt`. The search caps at 1000
results: above that the block fails (`source="github"`) rather than
undercount. Without a token the DORA keys keep their last value, `null`
at start-up. From these:

- `lead_time_seconds`: Requirement 10.2, the median over the counted
  merges; `createdAt` to the earliest `argocd/*` `success` after
  `mergedAt`, or to `mergedAt` for a merge that deploys nothing.
- `failed_changes_30d`: the merged pull requests with label
  `auto-rollback` or `fix-forward`, or a title matching `(?i)^revert`.
- Incidents (Requirement 10.4): the rollbacks, each from the merge of the
  commit named by "This reverts commit <sha>" in its merge commit's
  message (when the message names none, from the rollback's
  `createdAt`) to its sync; and the firings of `action: human` alerts,
  from a Prometheus range query of `max by (alertname, app, namespace,
  instance) (ALERTS{alertstate="firing", action="human"})` over the 30
  days at a 60 s step, in five 6-day slices (each under Prometheus's
  11,000 points), a gap of more than 120 s ending a firing. Overlapping
  intervals merge; the median duration of those ended in the window is
  `restore_seconds`. The range query runs at each GitHub refresh, not
  every cycle.
- `ci_runs`: `GET /repos/ned-si/homelab/actions/workflows/ci.yaml/runs?branch=main&event=push&status=completed&per_page=5`;
  `pr` from the last `(#<n>)` in the head commit's title; `result` is
  the run's `conclusion` mapped to the four values.

### Pushing

1. Validate the document ([The snapshot](#the-snapshot)). A failure logs
   every error, counts `source="validation"` and pushes nothing.
2. Sign the exact body with the Ed25519 private key read from
   `/var/run/secrets/push/private-key` (PKCS #8 PEM).
3. Resolve `homelab-dashboard-web-push.homelab-dashboard.svc` (headless,
   `publishNotReadyAddresses: true`) and `POST
   http://<address>:9465/v1/snapshot` to every address, with
   `Content-Type: application/json` and `Snapshot-Signature:
   ed25519=<base64>`.
4. Count each answer in `push_total{result}`.

A web pod that misses a push gets the next one a minute later.

## Web

### Push receiver

Port 9465, in no Service other than the headless one and in no HTTPRoute.
It answers only `POST /v1/snapshot`; everything else is `404`.

| Check, in order | Answer on failure |
| --- | --- |
| Body at most 64 KiB, `Content-Type: application/json` | `413`, `400` |
| `Snapshot-Signature` verifies against one of the public keys | `401` |
| `generated_at` newer than the current snapshot's, at most 5 min old, at most 1 min in the future | `409` |
| Schema, `Validate` and the allow-list | `400` |
| All pass: the snapshot is swapped in atomically (`atomic.Pointer`) | `204` |

The signature is checked before the body is parsed, so an unsigned
request costs one signature check and nothing else. Each refusal is
counted in `push_rejected_total{reason}` and logged without the body.

The public keys come from the ConfigMap `homelab-dashboard-push-pubkey`
(key `public-keys`, one or two PKIX PEM blocks), mounted read-only and
re-read every 30 s, so a rotation needs no release: add the new public
key, then reseal the private key, then drop the old public key, one merge
each. A public key is not a credential: the web pod still holds no Secret
and no token.

### Routes

The public port 8080 serves only these paths. Anything else is the `404`
page, any method other than `GET` or `HEAD` is `405` with `Allow: GET,
HEAD`.

| Path | Answer | `Cache-Control` |
| --- | --- | --- |
| `/` | The page | `no-cache` |
| `/snapshot.json` | The snapshot as held, `application/json` | `no-cache` |
| `/assets/dashboard.<sha256-8>.css` | The stylesheet | `public, max-age=31536000, immutable` |

The app owns its host, so it serves from the root and answers no
redirect itself: `http://` and `blog.nedsi.io/homelab/` are redirected by
nginx ([Address](#address)).

The page is rendered on every request from the snapshot in memory (a few
microseconds for a page this size); `ETag` is the hash of the rendered
body, and `If-None-Match` gets `304`. No `<meta http-equiv="refresh">`:
automatic reloads disturb screen readers (WCAG 2.2.1). The operator can
overrule this default with a 60 s refresh.

The metrics port 9464 serves `/metrics`, `/healthz` (the process runs) and
`/readyz`. Web: ready once it holds a valid snapshot, or 120 s after
start, whichever comes first, so a new pod gets data before it takes
traffic and the page still comes up while the collector is down.
Collector: ready once its first cycle has started. Port 9464 is in no
HTTPRoute.

Both servers: `http.Server` with `ReadHeaderTimeout` 5 s, `ReadTimeout`
10 s, `WriteTimeout` 10 s, `IdleTimeout` 60 s, `MaxHeaderBytes` 8 KiB;
graceful shutdown on `SIGTERM` within 10 s.

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
and holds when the route's filter is lost. The app is its own origin, so
the blog's CSP changes (the statistics script of public-website task 6)
do not apply to it; if the dashboard ever gets that script, both of its
copies change in the same PR (a test compares them, see [Tests](#tests)).

### The page

`layout.html` reproduces the blog's `baseof` (`site/layouts/baseof.html`):
the same header, the navigation bar and the footer (author, RSS, privacy;
no tags link, the dashboard has no tags), with absolute links because the
app is its own origin:

| Link | `href` |
| --- | --- |
| Home | `https://nedsi.io/` |
| Blog | `https://blog.nedsi.io/` |
| Homelab | `/`, with `aria-current="page"` (resolves to `https://homelab.nedsi.io/`) |
| About | `https://blog.nedsi.io/about/` |

`page.html` is an observability dashboard, not a page of text. From top
to bottom:

1. The title, the one-line intro "An over-engineered homelab, in
   numbers." (no word on the apps left out: they are simply absent), the target ("Target: 99.5% availability
   over 30 days per app") and "Updated <time> (Zurich time)" from
   `generated_at`, with the staleness notices below.
2. **Availability**: a grid of cards (`div.cards`), one per shown app in
   the allow-list order. Each card (`div.card`):
   - the app's name and, from task 12, its state: "Up" (`ok`), "Down"
     (`bad`) or "No data" (`none`), a word next to a dot of its colour;
   - the 30-day availability as the big number, `99.9` with the unit
     `%` in a smaller `span.unit`, coloured by the 30-day status, and the
     status word next to it ("Met", "At risk", "Missed");
   - the error budget meter: an SVG bar of the budget left (0-100%; empty
     and "Exhausted" at or below 0), with the text "62% of the error
     budget left"; when the first daily value is `null` (under 30 days
     of data), the figure is in the neutral `none` colour with "since
     <first day>" next to it, no status word, no meter and no budget
     text, whatever its value;
   - the 30-day bar chart: 30 SVG bars, oldest left, each bar's height
     from that day's availability on a 95-100% scale (a day at or below
     95% gets the minimum height), each coloured by that day's status, a
     dashed line at 99.5%, `none` bars at a fixed small height for
     days without probes. From task 12 the last bar is today so far,
     outlined (class `today`) and titled "<date> (today so far): <n>%".
3. **Certificates** (task 13): one tile per shown certificate, the days
   left as the big number ("40 days"), its status word and colour.
4. **Cluster**: from task 14 three groups of tiles. USE: one row per
   node and one for the NAS, each with CPU, memory and disk (pool for the
   NAS) as meters with their percentage, the pressures (load per core for
   the NAS) and errors; a node that is not Ready reads "Not ready"
   (`bad`). RED: the Gateway's requests per second, `5xx` share and p95
   in milliseconds. State: Argo CD ("56 apps, 56 Synced, 55 Healthy"),
   restarts in 24 h, volumes ("31 PVCs, 412 GiB of 1.2 TiB, fullest
   78%"), nodes, Talos and Kubernetes versions. "as of <time>" from
   `cluster.as_of`.
5. **Project, last 30 days**: from task 15, the four DORA tiles, each a
   big number, its band word and colour: deployment frequency ("678
   deploys, 22.6 a day"), lead time ("2 h 10 min"), change failure rate
   ("1.3%"), time to restore ("38 min", or "None"); then Renovate's
   share, the median `ci` run, and the last five `ci` runs on `main` as a
   list (result word and colour, the run's pull request as a link to
   `https://github.com/ned-si/homelab/pull/<n>`, the short commit, when,
   how long). "as of <time>" from `project.as_of`.
6. **Coming later**: two muted placeholder panels, solar production and
   home automation, with today's text.

Layout, in `dashboard.css`:

- Each grid (`div.cards`: the app cards, the cluster and project panels,
  the "Coming later" panels) is a wrapping flexbox, cards `flex: 1 1
  17rem`, gap `1rem`: the cards of the last row grow to share its width,
  so no row has a hole whatever the number of cards (three app cards a
  row on a desktop, so eight give 3, 3 and 2 wider ones). Rejected: a
  CSS grid with `auto-fill` (the last row keeps empty cells) and
  `grid-auto-flow: dense` (it fills holes only with smaller items, and
  every card is the same size). A panel of stat tiles (Cluster,
  Project, class `stats`) takes a whole row, so its tiles sit side by
  side; tiles are a wrapping flexbox too (`flex: 1 1 10rem`), so tiles
  that still wrap share the last row. The page is at most `72rem` wide, wider
  than the blog's `44rem` column. Below `40rem` every card takes the full
  width, so the page reads from 320 px without horizontal scrolling.
  Charts have a `viewBox`, `preserveAspectRatio="none"`, `width: 100%`
  and a fixed height (meters `1.25rem`, daily bars `4rem`), so a wider
  card gets wider bars, not taller ones.
- Big numbers `2.5rem`, tabular figures (`font-variant-numeric:
  tabular-nums`), labels in the muted colour. The font is the site's
  `system-ui` stack: no web font, so `font-src` stays unused.
- Always dark (`color-scheme: dark`): the dark values of
  `site/assets/css/main.css` (`--bg #17191b`, `--fg #e3e5e7`, `--muted
  #a0a6ab`, `--link #79b8ff`, `--rule #34383c`), cards on `--panel
  #212427` (the site's `--code-bg`) with a `1px` `--rule` border and
  rounded corners. Status colours `--ok #3fb950`, `--warn #d29922`,
  `--bad #f85149`, `--none` the muted colour.
- Styling is by class only, in the SVG too (`fill` from the class); no
  `style=` attribute, no `<style>` element.

Every chart is built by a Go function in `chart.go` from numbers only
(coordinates formatted with `strconv`) and passed to the template as
`template.HTML`. A test proves each builder's output contains only the
elements `svg`, `g`, `rect`, `line` and `title`; attributes that are
numbers, `class` from the fixed set (`ok`, `warn`, `bad`, `none`,
`track`, `target`, `today`), `role="img"`, `focusable="false"` and an
`aria-label` built from numbers and dates; and text only inside `title`
("2026-11-19: 100.0%"). Everything else goes through `html/template`'s
contextual escaping.

Accessibility: each chart has `role="img"` and an `aria-label` that
states its figures ("30 days: 28 met, 1 at risk, 1 without data"); every
status has its word next to its colour; every text and status colour has
a contrast of at least 4.5:1 against `--panel`, which a unit test
computes from the custom properties of `dashboard.css`.

### Status colours

| Figure | `ok` | `warn` | `bad` | `none` |
| --- | --- | --- | --- | --- |
| 30 days, with a budget | Budget left above 25% ("Met") | 0% to 25% ("At risk") | Below 0%, the target missed ("Missed") | — |
| 30 days, "since <first day>" | — | — | — | Always: no word, no budget (fewer than 30 days cannot be judged against a 30-day target) |
| One day | 99.5% or more | 96.25% to 99.5% | Below 96.25%: that day alone spent a quarter of the month's budget (54 min), the postmortem trigger of `docs/sre.md` | No probes that day ("No data") |

The redesign's figures, one rule each (tasks 12-15). "From an alert"
means the threshold is that alert's, so the page turns `warn` or `bad`
when the alert would fire:

| Figure | `ok` | `warn` | `bad` | Source of the thresholds |
| --- | --- | --- | --- | --- |
| App state | "Up" | — | "Down" | The probes |
| Certificate days left | Above 21 ("Valid") | 7 to 21 ("Renewal late") | Below 7 ("Expiring") | `CertificateExpiringSoon` (21 d), `CertificateExpiringVerySoon` (7 d) |
| Node CPU, memory | Below 80% | 80% to 95% | Above 95% | Dashboard default |
| Node disk (`/var`) | Below 85% | 85% to 92% | Above 92% | `NodeFilesystemNearlyFull`, `-CriticallyFull` |
| Node pressure (each) | Below 10% | 10% to 25% | Above 25% | Dashboard default |
| Node network errors | 0 | — | Above 0 | Dashboard default |
| Node ready | Ready | — | "Not ready" | `kube_node_status_condition` |
| NAS pool | Below 80% | 80% to 90% | Above 90%, or the pool not healthy | `NASPoolNearlyFull`, `NASPoolCriticallyFull`, `NASPoolUnhealthy` |
| NAS CPU, memory | Below 80% | 80% to 95% | Above 95% | Dashboard default |
| NAS load per core | Below 1 | 1 to 2 | Above 2 | Dashboard default |
| NAS errors | 0 | — | Above 0 | `NASPoolDeviceErrors` |
| Gateway `5xx` share | Below 0.5% | 0.5% to 5% | Above 5% | 0.5% is the SLO's error rate |
| Gateway p95 | Below 1 s | 1 s to 5 s | Above 5 s | Dashboard default, checked in task 14 |
| Argo CD | All Synced and Healthy | Any not | — | Auto-rollback acts on Degraded after 5 min |
| Restarts in 24 h | 0 to 5 | 6 to 20 | Above 20 | Dashboard default |
| Fullest volume | Below 85% | 85% to 95% | Above 95% | `PersistentVolumeNearlyFull`, `-CriticallyFull` |
| DORA metrics | `elite` and `high` | `medium` | `low` | [DORA bands](#dora-bands) |

Each rule is a function of `internal/web/status.go` taking the figure
and returning the class and the word, table-tested on each boundary; a
`null` figure is `none` with "No data". "A to B" includes both ends, so a
value on a boundary takes the middle class (CPU at exactly 80% is
`warn`).

### DORA bands

The bands of the
[2023 Accelerate State of DevOps report](https://dora.dev/research/2023/dora-report/)
(its four performance clusters), as thresholds. Deployment frequency,
lead time and time to restore use the report's ranges as boundaries;
change failure rate uses each cluster's value (5%, 10%, 15%) as its
upper bound:

| Metric | `elite` | `high` | `medium` | `low` |
| --- | --- | --- | --- | --- |
| Deployment frequency (deploys over 30 days) | 30 or more (daily or on demand) | 4 to 29 (weekly to daily) | 1 to 3 (monthly to weekly) | 0 |
| Lead time for changes | Under 1 day | 1 day to 1 week | 1 week to 1 month | Over 1 month |
| Change failure rate | 5% or less | Over 5% to 10% | Over 10% to 15% | Over 15% |
| Time to restore | Under 1 hour | 1 hour to 1 day | 1 day to 1 week | Over 1 week |

A `null` lead time or time to restore is `none`; "None" (no incident in
30 days) is `elite` with the word "No incident".

Staleness, from the injected clock:

- No snapshot: "No figures yet".
- `generated_at` more than 5 min old: "Live figures from <time>" under the
  title.
- Until task 12: `daily.covers` more than two days before today
  (Zurich): "Availability figures are from <date>: the daily update is
  failing."
- From task 12: a block whose `as_of` is more than 5 min before
  `generated_at` (60 min for `project`): "Figures from <time>" on its
  card.

### Logs and privacy

`log/slog` JSON handler on stdout. One line per public request: `time`,
`level`, `msg: request`, `method`, `path`, `status`, `bytes`,
`duration_ms`. The path is `r.URL.Path` (no query string). No client
address, user agent, referrer or header value is ever logged
(public-website Requirement 6.3). Accepted pushes are not logged one by
one (they are counted); refused pushes log the reason only.

## Code style

The Go code follows the
[Google Go Style Guide](https://google.github.io/styleguide/go/), its
Decisions and Best Practices pages. golangci-lint enforces what a linter
can check. Review checks the rest:

- Names without stutter (`snapshot.Validate`, not
  `snapshot.ValidateSnapshot`), no `Get` prefix on getters, no `util`,
  `common` or `helpers` packages.
- `context.Context` is the first parameter of anything that does I/O, and
  is never stored in a struct.
- Errors wrapped with `%w`, messages lower case without final punctuation;
  no panic across a package boundary.
- A doc comment on every exported name and every package.
- Table-driven tests with failure messages of the form
  `F(x) = got, want want`; diffs with `cmp.Diff(want, got)` from
  `github.com/google/go-cmp/cmp`, the guide's recommendation, as a test-only
  dependency.

`dashboard/.golangci.yaml` (version 2):

- Formatters: `gofmt`, `goimports`.
- Linters: `govet`; `staticcheck` with all checks, the ST style checks
  included; `errcheck`; `errorlint`; `revive` with `exported`,
  `package-comments`, `var-naming`, `receiver-naming`, `error-strings`,
  `error-naming`, `error-return`, `context-as-argument`,
  `context-keys-type`, `indent-error-flow`, `unexported-return`,
  `blank-imports`, `dot-imports`, `time-naming`; `gosec`; `bodyclose`;
  `noctx`; `misspell`; `nolintlint` with a reason required on every
  `//nolint`.

## Metrics

Prefix `homelab_dashboard_`, both roles on port 9464, scraped by one
`PodMonitor` (label `release: kube-prometheus-stack`, repo-policy
`monitor-selected`).

| Metric | Role | Type | Labels |
| --- | --- | --- | --- |
| `build_info` | both | gauge 1 | `version`, `goversion`, `role` |
| `collect_runs_total` | collector | counter | `block` = `availability`, `certificates` (task 11), `cluster`, `project`, `daily`; `result` = `success`, `failure` |
| `collect_errors_total` | collector | counter | `source` = `prometheus`, `github`, `validation` |
| `collect_duration_seconds` | collector | histogram | `block` |
| `push_total` | collector | counter | `result` = `accepted`, `rejected`, `error` |
| `github_ratelimit_remaining` | collector | gauge | none |
| `github_token_valid` | collector | gauge, 1 when the last authenticated call succeeded, 0 after a `401` or without a token | none |
| `push_rejected_total` | web | counter | `reason` = `size`, `content_type`, `signature`, `replay`, `schema`, `allowlist` |
| `snapshot_age_seconds` | web | gauge, computed at scrape: now minus `generated_at`; without a snapshot, now minus the process start | none |
| `daily_age_seconds` | web | gauge: now minus the end of `daily.covers`; removed by task 12 | none |
| `block_age_seconds` | web | gauge: now minus the block's `as_of` (task 11) | `block` = `availability`, `certificates`, `cluster`, `project` |
| `http_requests_total` | web | counter | `code`, `method` (`GET`, `HEAD`, `other`) |
| `http_request_duration_seconds` | web | histogram | none |

Labels never carry a path, so a scanner cannot grow the series count.

Alert, in `platform/kube-prometheus-stack/routes/homelab-dashboard-alerts.yaml`
with the other alert rules:

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

It is the only page: a person has to act when no push has been accepted
for two days. It goes in the "Automation gave up or failed" row of
`docs/sre.md`. A shorter stall, a failing block, `daily_age_seconds` over
two days (from task 12, `block_age_seconds` over 15 minutes, 2 hours
for `project`) and `github_token_valid` at 0 are INFO on the Automation
dashboard. With no snapshot at all, the age counts from the web pod's
start, so a fresh deployment does not page at once and one that never
gets a snapshot pages after 48 h. A promtool unit test in
`tests/prometheus/` covers both.

## Build and release

### CI on pull requests

A `dashboard` job in `ci.yaml`, through `scripts/ci/dashboard-check.sh`,
in the `needs` of the final `ci` job. Like the `site` job it always runs
and exits 0 early when `git diff --name-only origin/main...HEAD` touches
none of `dashboard/`, `scripts/ci/dashboard-check.sh`,
`scripts/ci/dashboard-screenshots.sh` (from task 2) and
`.github/workflows/dashboard-publish.yaml`.

| Step | Fails when |
| --- | --- |
| `actions/setup-go` (SHA-pinned), `go-version-file: dashboard/go.mod`, module cache on `go.sum` | — |
| `go mod verify`; `go mod tidy -diff` | A module does not match `go.sum`; `go.mod` is not tidy |
| `golangci-lint run` (v2, version and sha256 in the `ci.yaml` env, installed by `scripts/ci/install-tool.sh`) | Any finding, formatting included |
| `go vet ./...` | Any finding |
| `go tool govulncheck ./...` | A known vulnerability in reachable code |
| `go test -race -count=1 ./...` | Any test, the golden files included |
| `go build ./cmd/homelab-dashboard` | It does not build |
| The builder image's Go version equals `go.mod`'s `toolchain` line, or its `go` line when there is none (`go mod tidy` drops a `toolchain` equal to `go`) | Renovate bumped one without the other |

`codeql.yaml` gains Go: its matrix becomes `matrix.include` with
`{language: go, build-mode: manual}` next to the existing languages
(`build-mode: none`); when `matrix.language == 'go'`, `actions/setup-go`
and `go build ./...` in `dashboard/` run between `init` and `analyze`.
The header comment says so.

`govulncheck` is a `tool` directive in `go.mod`, so its version and
checksum are in `go.mod` and `go.sum`, Renovate's `gomod` manager updates
its `require` line, and it is not linked into the binary or listed in the
image SBOM. Between pull requests, new advisories for the running image
(Go standard library included) are the scope of the weekly scan of the
running images (#1507).

### Tests

| Package | Covers |
| --- | --- |
| `snapshot` | Schema and `Validate`: a valid fixture; a missing key, an extra key at each level, an out-of-range value, a bad version string, an app outside the allow-list, apps out of order, an `as_of` after `generated_at`; the allow-list against the hidden pattern; the rounding helpers on `.5` cases; a fuzz target `FuzzValidate` with the fixtures as seed corpus |
| `collector` | A fake Prometheus and a fake GitHub (`httptest`): the full snapshot; each source failing (the last block kept); an empty result; a budget below -100; the version split mid-upgrade; a day without probes (`null`, "since"); DST: `covers` on the last Sunday of March and of October; the cadences and the 03:45 rule with an injected clock, start-up before and after 03:45; the rate-limit reset moving the refresh; a `401` (no anonymous fallback, `github_token_valid` 0); `--dry-run` and `--as-of` against a recorded publisher `figures.json`; the search query and window of `prs_merged_30d`, across a change of summer time; the pusher against two fake web pods, one refusing |
| `web` | Push: `204`, and `400`, `401`, `409`, `413`, `404` for each failing check, a body signed by another key, a replayed and a future `generated_at`, a key rotation with two public keys; golden HTML of the page for a full snapshot (its apps cover `ok`, `warn`, `bad` and a day of `none`), a snapshot with a new app ("since": neutral, no word, no budget, whatever its figure), an exhausted budget, stale live figures, a stale daily block and no snapshot (`-update` rewrites them); the status rules on each boundary of [Status colours](#status-colours); each chart builder's elements, attributes and text; the contrast of every status and text colour of `dashboard.css` against `--panel` (at least 4.5:1); every header on `200`, `304`, `404` and `405`; `/readyz` before and after the first snapshot and after 120 s; the access log line has no address, user agent or query |
| `metrics` | The names and labels, and that no label value comes from the request path |
| Redesign, `snapshot` | Versions 2 and 3: every new key missing, extra and out of range; days not consecutive or not ending today; an unknown certificate; a node name matching the hidden pattern; `synced` above `apps`; `ci_runs` out of order; no free-text key outside the compiled lists |
| Redesign, `collector` | The fake Prometheus answers every query of [Cadence and sources of the redesign](#cadence-and-sources-of-the-redesign): a probe failing turns `state` to `down` and lowers today's bar in the same cycle; the finished days read once after midnight, across both DST changes; `<today>` at 00:00:30 (60 s minimum); no node, NAS or Gateway series (`null`, block kept); the fake GitHub's GraphQL pages: lead time with a status, without one (left out, then dropped after 24 h), a non-deploying merge, more than 100 files, the 1000-result cap; failed changes by label and by title; incidents from alerts and rollbacks, overlapping and merged, a revert without "This reverts commit"; the alert range query sliced under 11,000 points; `ci_runs` mapping; no token (DORA keys kept) |
| Redesign, `web` | Golden pages for each card with every class and word, a down app, today's bar, `null` figures, stale blocks; each rule of [Status colours](#status-colours) and [DORA bands](#dora-bands) on each boundary |

The markup rules (navigation, no `<form>`, `<iframe>`, `<style>`,
`style=`, `on*`, inline `<script>`, foreign origins) are not repeated in
Go: `tests/test_site_markup.py`, in the `tests` job that always runs,
feeds every `dashboard/internal/web/testdata/*.golden.html` to
`site_markup.Checker("homelab.nedsi.io", "https://homelab.nedsi.io/")`
and asserts no problems, `check_nav()` included. A navigation change in
the blog that the app does not follow fails there. Task 1 adds
`homelab.nedsi.io` to `SITE_HOSTS` in `scripts/ci/site_markup.py` and
makes the expected Homelab link depend on the page's host:
`https://homelab.nedsi.io/` on `homelab.nedsi.io`,
`https://blog.nedsi.io/homelab/` elsewhere. Task 5 switches the blog and
the landing page to `https://homelab.nedsi.io/` and drops the
difference, so from then on one navigation bar is expected everywhere.

### Screenshot check

Task 2 adds a step to the `dashboard` job, `scripts/ci/dashboard-screenshots.sh`:

1. Build the binary, start `web` with the test public key of
   `internal/web/testdata/` on `127.0.0.1`, and push the full fixture
   with `go run ./internal/tools/pushfixture`.
2. Render `http://127.0.0.1:8080/` with `chrome-headless-shell` (Chrome
   for Testing, version and sha256 in the `ci.yaml` env, installed by
   `scripts/ci/install-tool.sh`) at `390x4200` and `1280x2000` (taller
   than the page, so the whole page is in the shot), with `--screenshot`
   and Chrome's log on stderr.
3. Fail when Chrome exits non-zero, a PNG is missing or empty, Chrome's
   log has a CSP violation (`Refused to`) or a failed load,
   `internal/tools/gridcheck` finds a row of cards with a hole, or the
   web role's access log has a status other than `200` for the page or
   the stylesheet. `gridcheck` takes the `--panel` colour from
   `dashboard.css`, finds the cards as runs of at least 12 px of it on
   each pixel row, and fails a pixel row whose cards stop short of the
   card area's left or right edge by more than a rounded corner (8 px).
4. Upload both PNGs as the `dashboard-screenshots` artefact, so the look
   can be checked in the pull request.

No pixel comparison: the rendering changes with every browser update,
and a golden image would fail for reasons that are not regressions. The
golden HTML and the markup checks are the regression tests; the
screenshots prove the page renders under the real CSP and show what it
looks like.

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
  read-only with a test public key mounted, push a fixture snapshot signed
  with the test key to 9465 with `pushfixture` (`204`), then check `200`
  on `/` with every header, `405` on `POST`, `404`, `/readyz`, and `401`
  on an unsigned push; run `version` and check it prints the commit.
- `docker buildx build --builder attest --platform
  linux/arm64,linux/amd64 --sbom=true --provenance=mode=max --build-arg
  VERSION=$SHA --push -t $IMAGE:$SHA dashboard`, then read the index
  digest.
- Check the index lists `linux/arm64` and `linux/amd64`, then run the
  arm64 image under QEMU (`docker/setup-qemu-action`, SHA-pinned):
  `docker run --rm --platform linux/arm64 "$IMAGE@$DIGEST" version` must
  print the commit.
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
  automerge on green CI). A second group puts the Go toolchain
  (`matchDatasources: ['golang-version']`) and the builder image
  (`matchDepNames: ['golang']`) in one pull request, so the version check
  above passes.
- The `dockerfile` manager already reads `site/Dockerfile`; it also picks
  up `dashboard/Dockerfile` (both `FROM` lines are `repo:tag@digest`).
- A package rule for `ghcr.io/ned-si/homelab-dashboard`, the copy of the
  `homelab-site` one: digest updates, `automerge: true`,
  `minimumReleaseAge: '0 days'`, group `homelab-dashboard`.
- golangci-lint is pinned in the `ci.yaml` env like the other CI tools and
  follows their Renovate rule.

### Signature verification in the cluster

- `ci/image-signers.yaml`: an entry for
  `ghcr.io/ned-si/homelab-dashboard` with the `dashboard-publish` identity.
- `infrastructure/kyverno-policies/verify-own-images.yaml`: one attestor
  per image and one validation per image prefix, so each image is bound
  to its own workflow, as in the signer list. A single attestor with both
  identities would let `site-publish` sign a dashboard image and still
  pass.

  ```yaml
  attestors:
    - name: site
      cosign: {keyless: {identities: [{issuer: https://token.actions.githubusercontent.com, subject: https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main}]}, ctlog: {url: https://rekor.sigstore.dev}}
    - name: dashboard
      cosign: {keyless: {identities: [{issuer: https://token.actions.githubusercontent.com, subject: https://github.com/ned-si/homelab/.github/workflows/dashboard-publish.yaml@refs/heads/main}]}, ctlog: {url: https://rekor.sigstore.dev}}
  validations:
    - expression: >-
        images.containers.filter(i, i.startsWith('ghcr.io/ned-si/homelab-site')).all(i, verifyImageSignatures(i, [attestors.site]) > 0)
      message: ghcr.io/ned-si/homelab-site must be signed by site-publish on main.
    - expression: >-
        images.containers.filter(i, i.startsWith('ghcr.io/ned-si/homelab-dashboard')).all(i, verifyImageSignatures(i, [attestors.dashboard]) > 0)
      message: ghcr.io/ned-si/homelab-dashboard must be signed by dashboard-publish on main.
  ```

  The policy stays Audit, as for the site; #1506 decides enforcement for
  both.
- `tests/test_security_controls.py`: every `ghcr.io/ned-si/*` signer-list
  entry matches exactly one attestor (same identity) and one validation
  (same prefix).
- The `--gate-own` check in the `security` job verifies new digests of
  this image in pull requests, like the site's.

## Kubernetes

`apps/homelab-dashboard/`, rendered to `deploy/apps/homelab-dashboard/`:

- Namespace `homelab-dashboard` in `infrastructure/namespaces/namespaces.yaml`,
  Pod Security `restricted`, `Prune=false`; destination in the `apps`
  AppProject; `clusters/homelab/apps/homelab-dashboard.yaml`.
- Both Deployments: one replica, strategy `RollingUpdate` with
  `maxSurge: 1`, `maxUnavailable: 0`, image by digest, the `default`
  ServiceAccount with `automountServiceAccountToken: false`,
  `runAsNonRoot`, `runAsUser: 65532`, `readOnlyRootFilesystem`,
  capabilities drop `ALL`, `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, requests `10m`/`16Mi`, limit `64Mi`,
  liveness `/healthz` and readiness `/readyz` on 9464, `GOMEMLIMIT` at
  80 % of the limit.
  - Web: the ConfigMap `homelab-dashboard-push-pubkey` read-only at
    `/etc/homelab-dashboard/`; no Secret.
  - Collector: the Secret `homelab-dashboard-push` at
    `/var/run/secrets/push/` and the optional Secret
    `homelab-dashboard-github` at `/var/run/secrets/github/`, both
    read-only.
- `apps/secrets/homelab-dashboard-push.sops.yaml` (the Ed25519 private
  key, PKCS #8 PEM, made with `openssl genpkey -algorithm ed25519`; the
  public key with `openssl pkey -pubout`) and
  `apps/secrets/homelab-dashboard-github.sops.yaml`, each with an
  `.example`; rows in `ci/secret-rotation.tsv` (both `credential`) and in the rotation table of `docs/secrets.md`.
- ConfigMap `homelab-dashboard-push-pubkey` in git.
- Services: `homelab-dashboard-web` (8080 `http` only; the PodMonitor
  scrapes Pods) and the headless `homelab-dashboard-web-push` (9465,
  `clusterIP: None`, `publishNotReadyAddresses: true`). No Service for the
  collector.
- PodMonitor; the alert in `platform/kube-prometheus-stack/routes/` and
  the runbook `docs/runbooks/alerts/HomelabDashboardSnapshotStale.md`.
- PostSync smoke (`components/postsync-smoke`, own script like
  `apps/website`): through the Service before task 4, through the Gateway
  on `homelab.nedsi.io` from task 4: `200` and every header on `/`, `404`
  with the headers, `405`, `/snapshot.json` parses. With `maxSurge: 1` and the readiness rule, the new web pod has a
  snapshot (or has waited 120 s) before the smoke reaches it.
- Network policies, `infrastructure/network-policies/56-homelab-dashboard.yaml`,
  enforced from the start (`enforce-default-deny` in the namespace, kubelet
  probes in, DNS out):

  | Pod | Ingress | Egress |
  | --- | --- | --- |
  | web | Gateway (`ingress`, `host`, `remote-node`) on 8080, from task 4; the smoke Job on 8080; Prometheus on 9464; the collector on 9465 | none |
  | collector | Prometheus on 9464 | Prometheus Service 9090; web 9465; `world` 443 (GitHub; `world`, not `toFQDNs`, because Cilium FQDN rules route all DNS through its proxy, as for the publisher) |
  | smoke | none | web 8080; the Gateway on 443 from task 4 |

  The `monitoring` namespace enforces ingress, so the `prometheus` policy
  in `infrastructure/network-policies/88-monitoring.yaml` gains a 9090
  rule from `homelab-dashboard` pods with
  `app.kubernetes.io/component: collector` (task 3); task 6 removes its
  `website-publisher` rule.
- `ci/kind-workloads.txt`: the web Deployment and its Services
  (stateless, no Secret; the image has an amd64 variant, so the `preprod`
  job boots it; it turns ready after 120 s without a push). The collector
  stays out: it needs Prometheus and its Secret.
- Kyverno: every baseline policy passes with no PolicyException.

## Sources added by the redesign

### Probes and SLO rules (task 8)

- `platform/blackbox-exporter/probes/probes.yaml`: in `public-https`,
  `https://watch.lilalala.com/identity` (Plex's identity endpoint,
  `200` without a session; `app` `watch` from the relabeling). A new
  Probe `internal-observability` (job `blackbox-internal`, module
  `http_internal`, 30 s) with
  `http://kube-prometheus-stack-prometheus.monitoring.svc:9090/-/ready`
  and `http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/-/ready`,
  its relabeling setting `app` to `prometheus` and `alertmanager`.
- `infrastructure/network-policies/88-monitoring.yaml`: no change. The
  blackbox exporter, Prometheus and Alertmanager all run in
  `monitoring`, whose namespace-wide `monitoring` policy admits every
  pod there to every other, in both directions.
- `platform/kube-prometheus-stack/routes/slo.yaml`: `watch`, `grafana`
  and `signoz` join the `app` matcher of every SLI rule; `watch` gets
  its `slo:app:info` (namespace `theater`), its `SLOTargetProbeAbsent`
  and its latency threshold (`scripts/slo-latency-thresholds.sh`), so
  its burn alerts fire like the other user-facing apps'. The rule groups
  `homelab.slo.observability` (30 s) and `homelab.slo.observability-long`
  (2 m, the windows of a day and more) record the same windows for app
  `observability` as `1 - avg(avg_over_time(probe_success{job=~"blackbox-public|blackbox-internal", app=~"grafana|signoz|prometheus|alertmanager"}[<w>]))`
  with the label `app="observability"`, plus its 30-day availability and
  budget. `grafana`, `signoz` and `observability` get no
  `slo:app:info`, and every burn alert joins on it, so none of them
  alerts. The `homelab` app comes with task 4's probe.
- `docs/sre.md`: Plex in the user-facing app table; the Observability
  figure named as display-only.
- `tests/prometheus/slo_test.yaml`: the `watch` burn alert fires; the
  `observability` series exists and no burn alert fires for it.

### NAS CPU, memory and load (task 9)

`platform/truenas-exporter/exporter.py` reads `system/info` (already one
call per scrape or added to `GETS`) for `truenas_cpu_cores` and
`truenas_load1` (its `loadavg[0]`) and `truenas_memory_total_bytes`
(`physmem`), and the last point of the `cpu` and `memory` graphs of
`reporting/get_data` for `truenas_cpu_utilisation_ratio` and
`truenas_memory_used_bytes`. The task checks both calls against the NAS
(TrueNAS SCALE 25.10, REST v2.0) first; a call the API does not answer
leaves its metric out, the snapshot key `null` and the tile "No data",
and the move to the JSON-RPC API stays #1490. Tests in
`tests/test_truenas_exporter.py` with recorded answers.

### Sync statuses on GitHub (task 10)

Argo CD Notifications (`bootstrap/argocd-values.yaml`) gains a trigger
`on-deployed`: `app.status.operationState.phase == 'Succeeded' &&
app.status.health.status == 'Healthy'`, `oncePer` the sync revision,
sending the template `argocd-commit-status` through the existing
`github-dispatch` webhook service: `POST
/repos/ned-si/homelab/statuses/<revision>` with `state: success`,
`context: argocd/<application>`, `description: Synced and Healthy`.
Every Application is subscribed, as for the two rollback triggers. The
token of `argocd-notifications-github` needs "Commit statuses: write"
on the repository (operator first). The statuses are public and say
which Application synced which commit, nothing more. A new
`tests/test_argocd_notifications.py` asserts the trigger, the template
and the subscription in `bootstrap/argocd-values.yaml`.

### The `fix-forward` label (task 11)

The repository gets the label `fix-forward` ("Repairs a merged change
that broke production"), and `docs/sre.md` (incident handling) says
when to set it. Pull requests from before the label have none: the
change failure rate counts only what is labelled.

## Address

The dashboard is its own origin, `homelab.nedsi.io`, set up by task 4
with the automation that serves the other `nedsi.io` names:

- Certificate `homelab-nedsi-io` in namespace `gateway`
  (`infrastructure/gateway/certificate-homelab-nedsi.yaml`), one SAN
  `homelab.nedsi.io`, the `letsencrypt` ClusterIssuer (its DNS-01 solver
  already covers the `nedsi.io` zone), the key and duration settings of
  `nedsi-io`. A Certificate of its own, so the `nedsi-io` certificate of
  the three live names is not reissued.
- Gateway listeners `https-nedsi-homelab` (443, `homelab-nedsi-io-tls`)
  and `http-nedsi-homelab` (80), one hostname each, `allowedRoutes` as
  the other `nedsi.io` listeners.
- HTTPRoute `homelab-dashboard` in namespace `homelab-dashboard` on
  `https-nedsi-homelab`, hostname `homelab.nedsi.io`, `PathPrefix /` to
  `homelab-dashboard-web:8080`, with the response headers of
  [Headers](#headers).
- `http://`: the `website-http` route gains the hostname
  `homelab.nedsi.io`, and nginx's `$https_host` map in
  `apps/website/nginx.conf` the entry `homelab.nedsi.io
  homelab.nedsi.io`, so port 8081 answers `301
  https://homelab.nedsi.io$request_uri` like the other names (no
  `RequestRedirect`, see the public-website design, Redirects).
- DNS: external-dns creates the A record from the HTTPRoute, to the WAN
  address, DNS only, like the other names. Operator first: check the
  `nedsi.io` zone has no `homelab` record that external-dns does not own.
- Lists: `homelab.nedsi.io` in `docs/pentest/scope.yaml`
  (`public_hostnames`, which `scripts/pentest-scope-check.sh` compares
  with `scripts/published-hostnames.sh`, and so the `dast` targets);
  `https://homelab.nedsi.io/` in the static list of
  `platform/blackbox-exporter/probes/probes.yaml` (app `homelab` from the
  relabeling), its SLO rules like `nedsi` and `blog`, and its row in the
  user-facing app table of `docs/sre.md`.

Task 5 moves the readers:

- `apps/website/nginx.conf`, the blog's server block: the `/homelab/`
  SSI location becomes `location ~ ^/homelab(/.*)?$`, which answers `301`
  to `https://homelab.nedsi.io/` for `/homelab` and `/homelab/`, and to
  `https://homelab.nedsi.io/<rest>` for `/homelab/<rest>` (no port, query
  dropped: the app ignores it). `scripts/ci/site-serve-check.sh` checks
  the three forms instead of the SSI page.
- The Homelab link: `site/layouts/baseof.html` (an absolute link to
  `https://homelab.nedsi.io/`), the landing page's navigation
  and its "See the dashboard" button in `apps/website/landing/index.html`,
  and `NAV` in `scripts/ci/site_markup.py`. The landing page and the
  redirect are ConfigMaps and change with the merge; the blog's
  navigation changes with the next site image, so the PR is followed by
  the `homelab-site` digest bump (Renovate or by hand, as in #1549).

## Migration

| Step | State | Rollback |
| --- | --- | --- |
| Task 3, alongside | Both run. The publisher at 03:30 writes `website-data`; the collector pushes to the web pod every minute. Only nginx serves `/homelab/`. | Revert: the app's objects go (the namespace stays, `Prune=false`) |
| Comparison | `scripts/dashboard-compare.sh` after each night (below). The operator looks at the page through `kubectl -n homelab-dashboard port-forward svc/homelab-dashboard-web 8080` | — |
| Task 4, the host | `homelab.nedsi.io` live ([Address](#address)). nginx still serves `blog.nedsi.io/homelab/` from the publisher, and no link points at the new host yet. | Revert: the route, listeners and certificate go. external-dns is upsert only, so the A record stays and answers nothing; delete it in the console if the move is abandoned |
| Task 5, redirect and links | Once acceptance criteria 5 and 13 pass on the public name, in the same run if they do: `blog.nedsi.io/homelab/` answers `301`, every Homelab link points at `homelab.nedsi.io`. The publisher still runs. | Revert: nginx serves `/homelab/` again with the last `website-data`. Browsers that saw the `301` keep it cached and still land on the working app |
| Task 6, deletion | After one daily block served with the redirect live: the publisher and the SSI page deleted | Revert: the publisher comes back; its next run (or one manual Job) fills `website-data` |

Live figures cannot match the publisher's end-of-day figures, so the
comparison uses the dry run, whose `--as-of` output keeps the
publisher's shape and queries through the redesign until task 6: `scripts/dashboard-compare.sh` reads
`covers` from `website-data`'s `figures.json` (read-only `kubectl get`),
runs `kubectl -n homelab-dashboard exec deploy/homelab-dashboard-collector
-- /homelab-dashboard collect --once --dry-run --as-of <covers>`, and
compares the two numerically, not as text (jq 1.7 keeps number literals,
so `100.0` and `100` differ as text):

```sh
jq -n --slurpfile a pub.json --slurpfile b app.json \
  '($a[0] | del(.computed_at)) == ($b[0] | del(.computed_at))'
```

On `false` it prints the `diff` of both documents sorted with `jq -S` and
exits 1. The comparison passes when three consecutive `covers` dates are
equal. A difference is a bug in one of the two, fixed before the
switch-over; the count restarts.

From task 5 the blog's navigation links `https://homelab.nedsi.io/`, so
task 6 also drops `^/homelab/` from `IgnoreURLs` in `site/.htmltest.yml`
once the Hugo page is gone; the golden-page test in
`tests/test_site_markup.py` ([Tests](#tests)) keeps the navigation bars
of the blog, the landing page and the app equal.

## Error handling

| Operation | Failure | Result | Seen as |
| --- | --- | --- | --- |
| Prometheus query | Connection, non-200, empty result | The block keeps its last value, retried next cycle | `collect_errors_total{source="prometheus"}`, log `figure`, `error` |
| GitHub call | Network, `403`/`429` rate limit, incomplete search | Last project figures kept, next try at the next refresh or after the reset | `source="github"`, `github_ratelimit_remaining` |
| GitHub `401` | The token is rejected | Log `github token rejected`, last project figures kept, no anonymous fallback | `source="github"`, `github_token_valid` 0 (INFO) |
| Validation | Any rule | Nothing pushed | `source="validation"`, one log line per error |
| Push | Connection, non-`204` | Retried next cycle | `push_total{result}` |
| Push received | Size, type, signature, replay, schema, allow-list | Refused, the current snapshot kept | `push_rejected_total{reason}`, log the reason |
| No accepted push for 48 h | — | The page says the live figures are old | `HomelabDashboardSnapshotStale` pages |
| Web request | Unknown path, method | `404`, `405` with the headers | `http_requests_total{code}` |
| Publish | Build, smoke, sign, verify | Nothing tagged `main`, nothing deployed | ntfy, low priority |
| Kyverno | Unsigned or wrong identity | Audit report `fail` | Security dashboard |

## Why it is like this

- **Go.** One static binary on a distroless base, `html/template`'s
  contextual escaping for a public page, the standard library for HTTP,
  JSON and Ed25519, and the tooling (`vet`, golangci-lint, `govulncheck`,
  the race detector, native fuzzing) built in or one pinned binary away.
  Python stays fine for the repo's scripts; a public server is where a
  compiled, typed binary with no interpreter in the image pays off.
  Rejected: keeping `publisher.py` (no build, no signature, a CronJob with
  an interpreter image, rendering done by string building).
- **Two roles in one binary and one image.** The boundary is enforced by
  the runtime configuration, which Kyverno and the network policies check:
  no token, no Secret, no egress for the web pod. Two images would double
  the signing, the SBOMs and the digest bumps for no gain in isolation; the
  collector's code in the web image can do nothing without its key, its
  token or a route out.
- **The collector pushes a signed snapshot every minute.** The page shows
  live cluster and project figures, the web pod keeps no egress and no
  Kubernetes rights, and neither role needs a ServiceAccount token: a
  stronger boundary than a ConfigMap the collector patches. Rejected: the
  ConfigMap hand-off (an API write every minute, a kubelet sync delay of
  up to a minute, and a Role for the collector); the web role pulling from
  the collector (the public pod would need egress); a shared volume
  (`ReadWriteOnce` iSCSI for a few KiB); the web role reading Prometheus
  (the boundary is gone).
- **Ed25519 signatures on the push.** The content is public, so integrity
  is the only property the hop needs, and the web pod holds only a public
  key, which forges nothing. Rejected: HMAC (the web pod would hold a
  secret that can also forge pushes); mTLS (certificate issuance and
  rotation for one in-cluster hop, and a TLS server on the public pod).
  The freshness window stops a replayed or rolled-back snapshot.
- **Everything live.** The operator's decision of 2026-11-23, which
  replaced the finished-day availability of 2026-11-20; see
  [Freshness](#freshness).
- **DORA from GitHub and Argo CD's commit statuses.** Each metric can be
  recounted by a reader from public data: pull requests, labels, commit
  statuses and the `ci` runs; the incidents add the `action: human`
  alerts, the one source outside GitHub. Rejected: deriving the sync time
  from Prometheus (`argocd_app_info` carries no revision) and the Argo
  CD API (the collector would need Kubernetes or Argo CD rights).
- **Thresholds from the alerts.** Where an alert exists, the card turns
  the colour the alert would fire at, so the page and the pager never
  disagree; the remaining defaults are listed as such.
- **Cluster figures aggregated in PromQL.** The collector never receives
  a namespace, pod or volume name, so no later change to the page can
  leak one.
- **Its own host, `homelab.nedsi.io`.** A separate origin gets its own
  HTTPRoute, certificate and CSP, serves from `/`, and shares no path
  space with nginx: the route is a plain backend route and the app never
  depends on the blog's build. Rejected: `blog.nedsi.io/homelab/` (a
  path-prefix split of the blog's host between nginx and the app, and an
  app tied to the blog's layout); `nedsi.io/homelab/` (the same split on
  the landing page's host, with the app's assets under a prefix).
- **A dashboard, not a text page.** The page is the project's showcase,
  so it reads like an observability tool: cards, big numbers, status
  colours tied to the SLO and the error-budget policy, charts built
  server-side as SVG so the CSP needs no script and no exception.
  Rejected: a client-side chart library (JavaScript, `script-src`, a
  dependency to patch); colour thresholds by taste.
- **Screenshots without a pixel diff.** See
  [Screenshot check](#screenshot-check).
- **The collector as a Deployment.** A long-running process with a
  `/metrics` endpoint, so durations and errors by block are real metrics,
  and it waits for GitHub's rate-limit reset instead of failing within a
  Job deadline. Rejected: a CronJob (a minute cadence of Jobs, and no
  metrics without a Pushgateway).
- **The web role renders on every request.** The templates, the stylesheet
  and the server live in one package and are tested together; the
  snapshot holds data only, and a page rendered per request is never older
  than the last push. Rejected: HTML rendered by the collector (two
  processes would have to agree on the layout, and the web role would
  serve markup it did not produce).
- **Cluster figures from Prometheus.** See [Sources](#sources).
- **Google's Go style guide, enforced by golangci-lint.** A published,
  widely used standard that a reader of the code already knows, with a
  linter set that checks most of it; the rest is listed in
  [Code style](#code-style) for review.
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
