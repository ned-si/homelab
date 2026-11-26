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
| `dashboard/internal/tools/gridcheck/` | A test-only `main` that fails on a card off the column grid, or a lone card stretched across its row, in a screenshot; used by the screenshot step, never in the image |
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
| `cluster` | Every cycle | Now, or the last 5 minutes for rates; restarts over 24 h; from task 26 the databases over the rolling 24 h, 26 h, 8 days and 30 days of [Databases](#databases-tasks-25-and-26) |
| `project` | Every 15 min with the GitHub token, hourly without | The rolling 30 days ending at the fetch |

Every window is rolling, the daily bars excepted
([Time windows](#time-windows-2026-11-25)).
The page therefore shows an outage, or a power cut, while it happens.
That was the reason for the finished-day rule; the operator chose the
live page. Household energy consumption and every other Home Assistant
value except solar production stay out (Requirement 2.5).

## Time windows (2026-11-25)

Operator, 2026-11-25: every time window on the page is a rolling window
ending now, never a calendar month, week or day; the daily bars may be
calendar days in Zurich time (Requirement 2.8). "Ending now" means the
cycle's evaluation time, the last evaluation of the recording rule read
(every 2 minutes for the long SLO windows), or the project block's last
GitHub refresh (15 minutes with the token, 60 without), which the card
already states with "as of" and its staleness notice.

The audit of the collector at `07cafaf7` (main, 2026-11-25), every
window the page shows:

| Window on the page | Computed in | Today | Required |
| --- | --- | --- | --- |
| Availability, 30 days, and the error budget | `slo:availability:ratio_rate30d` and `slo:error_budget_remaining:ratio_rate30d` (groups `homelab.slo.sli-long` and `homelab.slo.observability-long` of `platform/kube-prometheus-stack/routes/slo.yaml`, every 2 min), read at now by `availability` in `internal/collector/live.go` | Rolling 720 h ending at the rule's last evaluation | Unchanged |
| Daily bars, the 29 finished days | `readFinished`, `internal/collector/live.go`: `1 - slo:probe_error:ratio_rate1d` at each Zurich midnight | **Not the calendar day.** A fixed 24 h ending at the rule's last evaluation, up to 2 min before midnight: the 23-hour day (last Sunday of March) takes in the last hour of the day before, the 25-hour day (last Sunday of October) leaves out its own first hour | Midnight to midnight, Zurich: the expression of today's bar, `avg_over_time(probe_success{...}[<s>s])` with `<s>` the day's length in seconds, at the next midnight; read once a day as today |
| Daily bar, today | `todayValues`, `internal/collector/live.go` | Zurich midnight to now, at least 60 s | Unchanged |
| Certificates | `certificates`, `internal/collector/live.go` | No window: the latest probe | Unchanged |
| Cluster USE and RED | `nodeUse`, `nas` and `gateway`, `internal/collector/use.go` | Rolling 5 min ending now (rates), or now | Unchanged |
| Restarts | `use`, `internal/collector/use.go` (`restarts_24h`) | Rolling 24 h ending now | Unchanged |
| Security, 24 h and 7 days | `security`, `internal/collector/security.go` | Rolling 24 h and 168 h ending now | Unchanged |
| Security sparklines | `buckets`, `internal/collector/security.go` | 28 rolling 6-hour buckets, the last ending now | Unchanged |
| Deploys, pull requests merged, Renovate's share | The window in `(*Collector).readProject`, `internal/collector/collector.go` (from the same Zurich wall time 30 days earlier, 719 to 721 h, to the fetch); the counts in `(*GitHub).Project` and `mergedCount`, `internal/collector/github.go` | Rolling 30 days ending at the fetch | Unchanged |
| Median `ci` run | `(*GitHub).Project`, `internal/collector/github.go` (`ciPages = 3`) | **Not 30 days.** It reads the 3 newest pages of 100 successful runs. On 2026-11-25 the 30 days held 2,304 successful `ci` runs and the 300th newest was created on 2026-11-20 at 10:05Z, so the median covered about 5 days | Every successful run of the 30 days: slices `[start + i*24h, min(start + (i+1)*24h, end))` for `i = 0, 1, ...` until a slice ends at `end` (30 or 31 slices, so the 719 h and 721 h windows have no gap and no overlap), each passed as `created=<utc(s)>..<utc(e - 1s)>` and paged to its end. GitHub's runs API returns at most 1,000 results for a filter, so a slice whose first page has `total_count >= 1000` fails the block with `figure="ci_median_seconds_30d"`, `source="github"`, as the search cap does. About 35 calls a refresh, 140 an hour of the token's 5,000. Without the token `Project` lists no runs for the median, and `ci_median_seconds_30d` follows the DORA rule below |
| Lead time, failed changes, change failure rate, rework rate | `mergedPRs` and `setDORA`, `internal/collector/dora.go` | Rolling 30 days, the same window | Unchanged |
| Time to restore, incidents | `alertFirings` and `setDORA`, `internal/collector/dora.go` | Rolling 30 days for the end of an incident, but the `ALERTS` range starts at the window's start, so a firing that began before it counts from the window's start and its duration is cut Count the incidents that started in the window and have ended (Requirement 10.4). The range stays at the window, which the 30-day Prometheus retention covers (`retention: 30d`, the oldest sample 30.66 days old on 2026-11-25), so no extension before it is readable. In `setDORA`: `if !i.open && i.start.After(start) && i.end.Before(end)`; a firing already firing at the window's first sample started before it and is left out. A rollback whose reverted pull request is not in `byOID` (merged before the window) is left out, rather than counted from its creation; one whose message names no commit starts at its `createdAt`, as today. `incidents_30d` follows the same rule, and so does the recount of `scripts/dashboard-dora-check.sh` (its `select` on `.s` as well as `.e`) |
| DORA figures without the token | `keepDORA` and `(*Collector).readProject`, `internal/collector/dora.go` and `collector.go` | The figures of the last refresh with the token are kept for ever, while `project.as_of` moves on hourly: their window can end hours or days before now At a refresh without the token, the DORA keys and `ci_median_seconds_30d` are copied when `now.Sub(doraAt) <= time.Hour` (`doraAt` the last refresh with the token; 60 minutes is the project block's staleness threshold), otherwise `null` ("No data") |
| Databases (task 26): the database count, WAL files archived | `cnpg_cluster:seen_24h`, `cluster:cnpg_wal_archived:increase24h` ([Databases](#databases-tasks-25-and-26)), read by `databases`, `internal/collector/databases.go` | New | Rolling 24 h ending at the rule's last evaluation (every minute) |
| Databases: base backups | `cluster:cnpg_base_backup_fresh:count` | New | Rolling 26 h ending at the rule's last evaluation |
| Databases: restore tests | `cluster:cnpg_restore_passed:count`, `-failed:count`, `-rows:sum`, `-duration:median_seconds` | New | Rolling 8 days ending at the rule's last evaluation (every 2 minutes) |
| Databases: backup freshness | `min(slo:backup_freshness:ratio_rate30d{kind="cnpg"})` at `t` | New | Rolling 30 days ending at the rule's last evaluation (every 2 minutes) |
| Databases: up, data size | `cluster:cnpg_databases_up:count`, `cluster:cnpg_data:bytes` | New | The last 10 minutes ending at the rule's last evaluation, so a pod restart's gap is bridged; the page names no window: 10 minutes is the grace before a database counts as down |
| Databases: WAL archiving now, oldest base backup, point-in-time recovery | The other `cluster:cnpg_*` aggregates | New | No window: the state at the rule's last evaluation, the Barman timestamps the latest of the rolling 26 h |
| Overall DORA level, the last five `ci` runs, Supply chain (tasks 21 and 24) | `overallBand`, `internal/web/status.go`; `ciRuns`, `github.go`; `supply.go` | No window of their own: the bands above, the last five runs, the latest Scorecard result and Kyverno report | Unchanged |

The page's own words for the windows ("over 30 days" in the target
line, "Project, last 30 days", "the last 24 hours, the last 7 days",
"Restarts in 24 h", "in 24 h", "in 7 days"; `templates/page.html` and
`render.go`) become "rolling 30 days", "rolling 24 h" and "rolling 7
days" in task 18 (Requirement 3.14). The Databases group (task 26)
says "rolling 24 h", "rolling 26 h", "rolling 8 days" and "rolling 30
days" from the start.

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
| `project.incidents_30d`, `project.restore_seconds` | Incidents ended in the window (from task 19: started in the window and ended), and their median duration (integer, `null` without one) |
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

Until task 18, rounding matched `publisher.py`, so the comparison of
task 3 found no false differences: `math.Floor(r*1000+1e-9)/10` for the
percentages, `math.RoundToEven` for the error budget, Renovate's share
and the CI median (Python's `round()` rounds half to even), and the
median of an even count is the mean of the two middle values. The
publisher is gone (task 6); from task 18 the percentages follow
[Rounding](#rounding-task-18).

### Rounding (task 18)

The bug, found by the operator on 2026-11-25: every percentage on the
page has two decimals and the last one is always 0. The collector rounds
each percentage to one decimal (`snapshot.PercentDown` and
`snapshot.Percent` in `internal/snapshot/round.go`, `snapshot.Round(x,
1)` for the change failure rate in `internal/collector/dora.go`
`setDORA`), the error budget and Renovate's share to integers
(`snapshot.Budget`, `snapshot.Share`), and the web role then prints the
result with `fixed(v, 2)` or `percent(v)`: "99.90%", "62.00%",
"33.00%".

The rule from task 18:

- **Compute at full precision.** The collector writes every percentage
  and the error budget as the float64 it computes from Prometheus or
  GitHub (`100 * ratio`, clamped to the key's range), with no rounding.
  The keys are listed in [Version 5](#version-5-task-18).
- **Round once, when formatting.** The web role turns a percentage
  into text in one new function of `internal/web/chart.go`,
  `pct(v float64) string`, which returns
  `strconv.FormatFloat(v, 'f', 2, 64)`. `percent(v)` is `pct(v) + "%"`
  for text, chart titles and `aria-label`s, and every percentage tile
  in `render.go` calls `pct` instead of `fixed(v, 2)`. Nothing calls `math.Round` or a
  `snapshot.Round` helper on a percentage before it, so there is no
  double rounding.
- **Ties: half to even.** `strconv.FormatFloat` rounds the exact binary
  value to the nearest, and an exact tie to the even digit: 0.125 shows
  "0.12%", 0.375 "0.38%". Most decimal values are not exact in binary
  and are no tie at all: 99.957 is stored as 99.95699999999999363...
  and shows "99.96%". Rejected: half up, which needs a `math.Round(v*100)/100`
  step before the formatting, two roundings instead of one.
- **Maths at full precision.** The status rules of
  [Status colours](#status-colours), the error-budget meter, the
  "Exhausted" test, the daily bar heights and the DORA band of the
  change failure rate read the raw snapshot value, never the text. A
  budget of 25.004% is `ok` ("Met", above 25%) while it reads
  "25.00%"; an availability from 99.995% up to but not including 100%
  reads "100.00%", and its status word and budget still show that it
  is not perfect. A day from 99.495% up to 99.5% reads "99.50%" and
  is `warn`: `dayStatus` reads the raw value against the 99.5 target.
  The SLO recording rules are unchanged.
- **Types.** `snapshot.LiveApp.ErrorBudgetRemaining30d` becomes
  `*float64` and `snapshot.Project.RenovateShare30d` `float64`;
  `monthStatus`, `budgetMeter` and `shareBar` in `internal/web` take a
  `float64`.
- **Other figures.** Counts stay integers; rates per second and load
  per core keep two decimals, rounded in the collector as today;
  "22.6 a day" keeps one decimal. They are not percentages.

Tests (task 18): a table test of `percent` with 99.957 → "99.96%",
0.125 → "0.12%", 0.375 → "0.38%", 0 → "0.00%" and 100 → "100.00%"; a
collector test with a fake Prometheus answering 0.99957 for
`slo:availability:ratio_rate30d` that finds 99.957 in the snapshot and
"99.96" on the page; a status test with a raw budget of 25.004. The
helpers `PercentDown`, `Percent`, `Budget` and `Share` are deleted, so
the compiler finds any caller left.

Shown apps, `internal/snapshot/shown.go`: the list of today's
`config.json` (Immich, Mealie, Paperless-ngx, Jellyfin, Syncthing,
Keycloak, the landing page, the blog), each with its `slo_app` label;
task 12 changes it ([Versions 2 and 3](#versions-2-and-3-the-redesign)). The
hidden pattern is the one of `publisher.py`
(`sonarr|radarr|lidarr|readarr|prowlarr|bazarr|recyclarr|lazylibrarian|qbittorrent|torrent|jackett|flaresolverr|theater|arr$`);
a test fails when an entry of the list matches it. The list is compiled
in, not configuration: adding an app is a reviewed, signed release, and
the web role refuses a snapshot that names any other app.

### Version 4 (task 16)

Version 4 is version 3 plus the `security` block; the rollout rule of
version 3 applies.

| Key | Value |
| --- | --- |
| `security.as_of` | RFC 3339, the Prometheus evaluation time |
| `security.signals[]` | `id`, `name` (the compiled list of [Security signals](#security-signals-task-16), in order); `count_24h`, `count_7d` (integers, 0 or more, rounded to the nearest, `null` without a series); `buckets`: 28 integers or `null`, oldest first, six hours each, the last one ending at `as_of` |

`Validate` gains: `security.signals` equals the compiled list, in order,
by `id` and `name`; `buckets` has 28 entries; `count_24h` is at most
`count_7d` when both are set. The block holds no other string.

### Version 5 (task 18)

Version 5 is version 4 with every percentage and the error budget at
full precision ([Rounding](#rounding-task-18)) and the security block of
[Security card figures](#security-card-figures-tasks-22-and-23) (its
signals, `share_24h`, `share_7d` and `unattributed_24h`):

| Key | From version 5 |
| --- | --- |
| `availability.apps[].availability_30d`, `availability_daily[]` | Number, 0-100, not rounded (was one decimal, rounded down) |
| `availability.apps[].error_budget_remaining_30d` | Number, -100 to 100, clamped, not rounded (was an integer) |
| `cluster.node_use[].cpu`, `memory`, `disk`, `cpu_pressure`, `memory_pressure`, `io_pressure`; `cluster.nas.pool`, `cpu`, `memory`; `cluster.volumes.fullest` | Number, 0-100, not rounded (was one decimal) |
| `cluster.gateway.errors_5xx` | Number, 0-100, not rounded (was two decimals) |
| `project.renovate_share_30d` | Number, 0-100, not rounded (was an integer) |
| `project.change_failure_rate` | Number, 0-100, or `null`, not rounded (was one decimal) |
| `security.signals[]` | The signals of task 23 by `id` and `name`; new `share_24h`, `share_7d` (number 0 to 1, or `null`), `total_24h`, `total_7d`, `part_24h` and `unattributed_24h` (integers 0 or more, or `null`) |

In `snapshot.schema.json`: `$defs/budget` becomes
`{"type": "number", "minimum": -100, "maximum": 100}`;
`project.renovate_share_30d` becomes
`{"type": "number", "minimum": 0, "maximum": 100}`; `$defs/percent`,
`$defs/share` and `change_failure_rate` already are numbers. The
rollout rule of version 3 applies.

### Version 6 (task 19)

Version 6 is version 5 plus `project.rework` (`count`, `deploys`
integers; `rate` a number from 0 to 1 or `null`; the whole object `null`
when the DORA figures are, without the token); `Validate` gains
`count` at most `deploys`. `project.ci_median_seconds_30d` becomes an
integer or `null` ([Time windows](#time-windows-2026-11-25): it needs
the token). The rollout rule of version 3 applies.

### Versions 7 and 8 (tasks 21 and 24)

Version 7 (task 21, the SLSA panel) is version 6 plus the
`supply_chain` block without `scorecard`; version 8 (task 24, the
Scorecard panel) adds `supply_chain.scorecard`. Two pull requests, one
per operator item (2026-11-25), each its own version.

| Key | Value |
| --- | --- |
| `supply_chain.as_of` | RFC 3339, the Prometheus evaluation time |
| `supply_chain.images[]` | `name` (the compiled list `homelab-dashboard`, `homelab-site`, in order), `level` (`2` when `verified` is `true`, else `null`), `verified` (`true`, `false` or `null` without a report), `builder` (the compiled builder text of the image) |
| `supply_chain.scorecard` (version 8) | `as_of` (RFC 3339, the last successful fetch, which the 60-minute staleness rule reads), `score` (0 to 10, one decimal), `date` (the result's date); all three `null`, and `lowest` empty, before the first fetch; `lowest[]`: at most 3 of `name` (from the compiled check list), `score` (0 to 10), `reason` (plain text, at most 160 characters), lowest first |

`Validate` gains: `images` equals the compiled list by `name` and
`builder`, in order; a `level` only with `verified` `true`; from version
8, every check name is in the compiled list of Scorecard checks and
`reason` has no control character and at most 160 characters. The
rollout rule of version 3 applies to each.

### Version 9 (task 27)

Version 9 is version 8 with every Scorecard check (#1756):
`supply_chain.scorecard.lowest` becomes `checks`.

| Key | Value |
| --- | --- |
| `supply_chain.scorecard.checks[]` | Every check of the result, at most 20 (the compiled list): `name` (from the compiled check list), `score` (0 to 10, or `null` where Scorecard gives `-1`), `reason` (plain text, at most 160 characters); in name order, each name once; empty before the first fetch |

`Validate` gains: the names strictly ascending (Go string order, which
is alphabetical for the compiled names). The rollout rule of version 3
applies.

### Version 10 (task 26)

Version 10 is version 9 plus `cluster.databases`, built every cycle
with the cluster block and covered by `cluster.as_of`
([Databases](#databases-tasks-25-and-26)). Numbers only: the object
has no string, so no name can travel in it.

| Key | Value |
| --- | --- |
| `count` | Databases seen in the rolling 24 h, integer 0-100 |
| `up` | Databases up in the last 10 minutes, integer 0 to `count` |
| `data_bytes` | Size of the app databases, integer 0 or more, `null` without a series |
| `wal_archiving`, `wal_behind` | Databases archiving normally, and with more than 5 WAL files waiting but none failed; integers, their sum at most `count` |
| `wal_archived_24h` | WAL files archived in the rolling 24 h, integer 0 or more (rounded to the nearest), `null` without a series |
| `base_fresh` | Databases with a base backup in the rolling 26 h and no failed one since, integer 0 to `count` |
| `base_oldest_seconds` | The largest age of a database's latest base backup, integer seconds 0 or more (rounded down), `null` without one |
| `recovery_window_seconds` | The shortest point-in-time recovery window, integer seconds 0 or more (rounded down), `null` without one |
| `restore_passed`, `restore_failed` | Databases whose latest restore test passed in the rolling 8 days, and whose latest visible test failed; integers, their sum at most `count` |
| `restore_rows` | Rows compared in each database's latest passing restore test in the rolling 8 days, summed; integer 0 or more, `null` without a result |
| `restore_median_seconds` | Median time to a Ready restored cluster over those tests, integer seconds (rounded down), `null` without a result |
| `freshness_30d` | The lowest backup freshness of a database over the rolling 30 days, 0-100 at full precision, `null` without a series |

`Validate` gains: `up`, `base_fresh` at most `count`;
`wal_archiving + wal_behind` and `restore_passed + restore_failed` at
most `count`. The rollout rule of version 3 applies.

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
100; from task 19 every run of the window, see
[Time windows](#time-windows-2026-11-25)) for the median wall time. `User-Agent: homelab-dashboard/<version>`.

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
| `availability_daily`, finished days | `1 - slo:probe_error:ratio_rate1d{app=~"<shown>"}` at each of the 29 Zurich midnights, the newest at today's 00:00; from task 19 each Zurich day midnight to midnight ([Time windows](#time-windows-2026-11-25)) |
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
at start-up; from task 19 for at most 60 minutes after the last refresh
with the token ([Time windows](#time-windows-2026-11-25)). From these:

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
  intervals merge; the median duration of those ended in the window
  (from task 19, of those started in the window and ended, see
  [Time windows](#time-windows-2026-11-25)) is `restore_seconds`. The range query runs at each GitHub refresh, not
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
| Tech radar | `https://techradar.nedsi.io/` (tech-radar task 3) |
| About | `https://blog.nedsi.io/about/` |

`page.html` is an observability dashboard, not a page of text. From top
to bottom:

1. The title, the one-line intro "An over-engineered homelab, in
   numbers." (no word on the apps left out: they are simply absent), the target ("SLA: 99.50% availability
   over a rolling 30 days per app"; "SLA", not "Target", from #1738:
   the readers it is for know SLA, SLO and burn rate) and "Updated <time> (Zurich time)" from
   `generated_at`, with the staleness notices below.
2. **Availability**: a grid of cards (`div.cards`), one per shown app in
   the allow-list order. Each card (`div.card`):
   - the app's name and, from task 12, its state: "Up" (`ok`), "Down"
     (`bad`) or "No data" (`none`), a word next to a dot of its colour;
   - the 30-day availability as the big number, `99.90` with the unit
     `%` in a smaller `span.unit`, coloured by the 30-day status, and the
     status word next to it ("Met", "At risk", "Missed");
   - the error budget meter: an SVG bar of the budget left (0-100%; empty
     and "Exhausted" at or below 0), with the text "62.00% of the error
     budget left"; when the first daily value is `null` (under 30 days
     of data), the figure is in the neutral `none` colour with "since
     <first day>" next to it, no status word, no meter and no budget
     text, whatever its value;
   - the 30-day bar chart: 30 SVG bars, oldest left, each bar's height
     from that day's availability on a 95-100% scale (a day at or below
     95% gets the minimum height), each coloured by that day's status, a
     dashed line at 99.5%, `none` bars at a fixed small height for
     days without probes. From task 12 the last bar is today so far,
     outlined (class `today`) and titled "<date> (today so far): <n>%", `<n>` with two decimals.
3. **Cluster**: from task 14 three groups of tiles. USE: one row per
   node and one for the NAS, each with CPU, memory and disk (pool for the
   NAS) as meters with their percentage, the pressures (load per core for
   the NAS) and errors; a node that is not Ready reads "Not ready"
   (`bad`). RED: the Gateway's requests per second, `5xx` share and p95
   in milliseconds. State: Argo CD ("56 apps, 56 Synced, 55 Healthy"),
   restarts in 24 h, volumes ("31 PVCs, 412 GiB of 1.2 TiB, fullest
   78.00%"), nodes, Talos and Kubernetes versions. From task 26 a
   fourth group after State, "Databases and backups": its paragraph
   and six tiles ([Databases](#databases-tasks-25-and-26)). "as of
   <time>" from `cluster.as_of`.
4. **Project, last 30 days**: from task 15, the four DORA tiles, each a
   big number, its band word and colour. From task 17 they sit in their
   own group under the heading "DORA metrics": two short paragraphs (what
   DORA is, the four metrics in plain words, the bands from the
   [2023 report](https://dora.dev/research/2023/dora-report/), links to
   `https://dora.dev/` and that report), then "Overall level" with the
   level of [DORA bands](#dora-bands) as a big word in its colour, and
   the rule under it. Renovate's share and the median `ci` run move to
   their own group, "Renovate and CI". The tiles: deployment frequency ("678
   deploys, 22.6 a day"), lead time ("2 h 10 min"), change failure rate
   ("1.30%"), time to restore ("38 min", or "None"); then Renovate's
   share, the median `ci` run, and the last five `ci` runs on `main` as a
   list (result word and colour, the run's pull request as a link to
   `https://github.com/ned-si/homelab/pull/<n>`, the short commit, when,
   how long). "as of <time>" from `project.as_of`.
   From task 19 the DORA group gains a fifth tile, "Rework rate"
   ("1.30%" with "9 of 678 deploys" as its detail line), after the four
   banded tiles and outside the overall level, in the neutral colour
   with no band word, and under it two sentences: "Rework rate counts
   the unplanned deploys: rollbacks, fix forwards, and `fix` merges made
   during an incident or in the 24 hours after it, over all deploys."
   and "Rework rate, DORA's fifth metric since 2024, has no band here:
   the 2023 clusters these bands come from predate it." The second paragraph's "one person and a
   few bots" becomes "one person and a few agents".
5. **Supply chain** (tasks 21 and 24): two panels of stat tiles, after the
   project card and before Security (2026-11-25: delivery first, then
   how what is delivered is built and trusted, then how the running
   system defends itself). "SLSA provenance": one tile per first-party
   image (`homelab-dashboard`, `homelab-site`) with the level as the
   value ("Build L2"), the verification as the status word
   ("Verified", "Not verified", "No data") and the builder as the
   detail line ("GitHub-hosted runner, dashboard-publish.yaml on
   main"), and a short paragraph with the link to the
   [SLSA levels](https://slsa.dev/spec/v1.0/levels): GitHub-hosted
   runners and a provenance GitHub signs make Build L2, Kyverno checks
   every running Pod, L3 needs a reusable workflow. A tile shows the
   level only when `level` is set; otherwise its status word alone.
   "OpenSSF
   Scorecard": the score as the value ("7.5" with the unit "/ 10") and
   its date, then every check as a tile in `div.tiles.checks`, in
   alphabetical order (task 27: the check's name as the label, its score
   as the value with "/ 10" at `1.25rem`, or the word "Not applicable"
   in `--none` for a `-1`, Scorecard's reason as the detail line;
   task 28: the value in the status colour of its score with the status
   word beside it, as every other figure, and the compiled note of
   [Scorecard](#scorecard-task-24) as a second detail line where the
   check has one; the paragraph says how the colours read and what a
   note is), and a link to the
   [full report](https://scorecard.dev/viewer/?uri=github.com/ned-si/homelab).
   "as of <time>" from `supply_chain.as_of`.
6. **Security** (task 16): a panel of stat tiles, one per security
   signal in the compiled order. Each tile: the signal's name, the 24 h
   count as the big number ("8,044 in 24 h") with its status word and
   colour, "<n> in 7 days", and the sparkline: 28 SVG bars of the
   six-hour counts, oldest left, heights on a linear scale from 0 to the
   tile's largest bar (all bars at the minimum height when every one is
   0), class `spark`, each titled "<start> to <end>: <n>" in Zurich time.
   "as of <time>" from `security.as_of`. From task 23 the signals,
   names, shares and lines of
   [Security card figures](#security-card-figures-tasks-22-and-23).
7. **Certificates** (task 13): one tile per shown certificate, the days
   left as the big number ("40 days"), its status word and colour.
8. **Coming later**: two muted placeholder panels, solar production and
   home automation, with today's text.

The order is the operator's (2026-11-24, task 17), with Supply chain
placed in it on 2026-11-25. Every percentage, in
text, `aria-label` and `<title>`, has two decimals (`percent` and
`fixed(v, 2)` in `render.go` and `chart.go`); the snapshot keeps its own
precision and the status functions read the raw values.

Layout, in `dashboard.css`:

- Each grid (`div.cards`: the app cards, the panels, the "Coming later"
  panels) is a CSS grid of fixed column tracks, `repeat(auto-fill,
  minmax(17rem, 1fr))`, gap `1rem`, left-aligned: `auto-fill` keeps the
  empty tracks, so a card alone on the last row stays one track wide
  (operator, 2026-11-24: no lone card or tile stretches across a row).
  Three tracks on a desktop, so ten app cards give 3, 3, 3 and 1.
  Rejected: a wrapping flexbox (the last row's cards grow to fill it, a
  lone card across the whole row). A panel of stat tiles (class `stats`)
  spans the row, `grid-column: 1 / -1`; its tiles sit on tracks of
  `minmax(10rem, 1fr)` (the node and NAS groups as under
  [Stat tiles](#stat-tiles-task-18)), so a lone tile stays one track
  wide too. The page is at most `72rem`
  wide, wider than the blog's `44rem` column, and centred on wider
  screens. Below `40rem` every grid has one track, so the page reads
  from 320 px without horizontal scrolling. The layout depends on the
  width only: no viewport-height units.
  Charts have a `viewBox`, `preserveAspectRatio="none"`, `width: 100%`
  and a fixed height (meters `1.25rem`, daily bars `4rem`), so a wider
  card gets wider bars, not taller ones.
- Big numbers `2.5rem`, tabular figures (`font-variant-numeric:
  tabular-nums`), labels in the muted colour. The font is the site's
  `system-ui` stack: no web font, so `font-src` stays unused.
- Colours: the site's palette ([site-theme-language](../site-theme-language/design.md#palette)), dark by
  default and light on the reader's choice, embedded as
  `assets/theme-dark.css` and `theme-light.css` and served as
  `/theme.css` by the cookie. Cards on `--panel` with a `1px` `--rule`
  border and rounded corners, tiles on `--tile`, status colours `--ok`,
  `--warn`, `--bad` and `--none`. `dashboard.css` holds no colour.
- Styling is by class only, in the SVG too (`fill` from the class); no
  `style=` attribute, no `<style>` element.

Every chart is built by a Go function in `chart.go` from numbers only
(coordinates formatted with `strconv`) and passed to the template as
`template.HTML`. A test proves each builder's output contains only the
elements `svg`, `g`, `rect`, `line` and `title`; attributes that are
numbers, `class` from the fixed set (`ok`, `warn`, `bad`, `none`,
`track`, `target`, `today`, and `spark` from task 16), `role="img"`, `focusable="false"` and an
`aria-label` built from numbers and dates; and text only inside `title`
("2026-11-19: 100.0%"). Everything else goes through `html/template`'s
contextual escaping.

Accessibility: each chart has `role="img"` and an `aria-label` that
states its figures ("30 days: 28 met, 1 at risk, 1 without data"); every
status has its word next to its colour; every text and status colour has
a contrast of at least 4.5:1 against `--panel`, which a unit test
computes from the custom properties of `dashboard.css`.

### Stat tiles (task 18)

From the Cluster card down, the figures read as a wall of text: labels
and values in the same weight, spread over lines with nothing grouping
a label with its number. Task 18 applies one pattern, the stat panel
of observability tools (a small title above one large value), with the
Gestalt rules of common region and proximity:

- **Common region and proximity**: each figure is a box, `div.tile`,
  `--tile #1a1c1f` (a shade darker than `--panel #212427`), radius
  `0.5rem`, padding `0.75rem`; the label sits directly above its value,
  closer to it than to any other tile.
- **Hierarchy**: the label, `.tile-label`, `0.75rem`, bold, uppercase
  with `0.04em` letter spacing, in `--muted`; the value, `.tile-value`,
  `1.75rem`, tabular figures, in `--fg`; the unit, `.unit`, `0.6em` in
  `--muted`, beside the value; an optional status word and a detail
  line, `.tile-detail`, `0.875rem`, muted, under the value. The DORA
  tiles (`div.tiles.bands`) put the band word on its own line under
  the value, whatever the value's length (#1738).
- **Colour on the value only**: a status class (`ok`, `warn`, `bad`,
  `none`) colours `.tile-value`; a tile whose value is a word (a
  version, "Verified") carries the status as a `3px` left border
  instead. Labels, boxes and detail lines never take a status colour, so
  colour still marks only the status, next to its word.
- **One grid**: tiles sit in `div.tiles`, `repeat(auto-fill,
  minmax(10rem, 1fr))`, gap `0.5rem`, so they wrap and a lone tile stays
  one track wide; meters stay inside their tile, under the value. Each
  tile spans two rows of that grid as a subgrid, the label and
  `div.tile-body` (the value and what follows it), so a label that
  wraps moves every value of its row down with it and the values stay
  level (#1738).
- **Node and NAS groups**: each node and the NAS stays one
  `div.tile-group` (1px `--rule` border, its name and state as the
  heading); its figures are compact tiles in an inner `div.tiles` on
  `repeat(auto-fill, minmax(6rem, 1fr))`, `.tile-value` at `1.25rem`.
  The groups sit on `repeat(auto-fill, minmax(14rem, 1fr))`, so two
  figures sit side by side inside a group and the groups wrap like
  cards. Below `40rem` the
  tracks shrink to `minmax(8.5rem, 1fr)` (two tiles side by side on a
  390 px phone).
- **Contrast**: darker, not lighter, because a lighter tile (`#2a2e32`)
  would put `--bad` at 4.08:1; on `#1a1c1f` every text and status
  colour is at least 5.09:1 (`--bad`), against 4.65:1 on `--panel`.
  `TestContrast` checks every text and status colour on both `--panel`
  and `--tile`.

Each figure is one tile: the Gateway's requests per second, `5xx` share
and p95; each node's and the NAS's CPU, memory, disk or pool (with their
meters), pressures or load and errors; the State figures (Argo CD,
restarts, volumes, nodes, Talos, Kubernetes); the DORA tiles, the
overall level and rework rate; Renovate's share and the median `ci` run;
the security signals (the sparkline under the value); the certificates;
the Supply chain tiles. The last five `ci` runs stay a list. One
template, `{{template "tile" .}}`, renders every tile, so the pattern
cannot drift between cards; a test over the full fixture fails when a
card from the Cluster card down has a label or value outside a tile, or
a status class on a label.

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
| Security, expected zero | 0 in 24 h ("None") | Above 0 ("Seen") | — | Dashboard default: one is worth a look |
| Scorecard score (task 24) | 7.0 or more | 4.0 to under 7.0 | Under 4.0 | Dashboard default; Scorecard's own badge turns from green under 7 |
| Scorecard check (task 28) | 7 to 10 ("OK") | 4 to 6 ("Warning") | 0 to 3 ("Critical") | The overall score's thresholds, so a check and the total read the same way; a `-1` is `none` with "Not applicable"; a check with a note keeps its colour |
| SLSA provenance (task 21) | Verified by Kyverno ("Verified") | Not verified, or no provenance ("Not verified") | — | `verify-own-images` runs in Audit; the page reports, the policy decides |
| Databases (task 26) | `up` equal to `count` ("Up") | — | `up` below `count` ("Down") | A database is down after 10 minutes without a series or with `cnpg_collector_up` 0 (the shortest `for:` of the CNPG alerts), so a pod restart changes nothing; `CNPGMetricsAbsent` when none reports |
| WAL archiving | `wal_archiving` equal to `count` ("Archiving") | Below, and `wal_archiving + wal_behind` equal to `count` ("Behind") | Otherwise: a database failing or not up ("Failing") | `CNPGWALArchivingFailing`; `CNPGWALArchiveLag` (more than 5 files waiting) is `warn`, because the page has no `for:` and a burst of writes queues files for a minute |
| Base backups | `base_fresh` equal to `count` ("Fresh") | — | Below ("Stale") | `CNPGBaseBackupTooOld` (26 h, also the backup-freshness SLO's), `CNPGBackupFailed`; no warning band, so the nightly cycle (up to about 24 h old just before each backup) never turns the tile amber |
| Restore tests | `restore_passed` equal to `count` ("Passed") | None failed, some without a test in the rolling 8 days ("Overdue") | `restore_failed` above 0 ("Failed") | `BackupVerifyFailed` (pages), `BackupVerifyStale` (8 days, review) |
| Backup freshness | 99% or more ("Met") | — | Below 99% ("Missed") | The objective of `homelab-backup-slo` (`docs/backups.md`, Freshness) |
| Point-in-time recovery | — | — | — | No status: the window is a property of the retention, not a health signal; `none` with "No data" when `null` |
| Every database tile with `count` 0 | — | — | — | `none` with "No data": nothing reports, so nothing can be judged |
| Security, background | Otherwise ("Usual") | 24 h count above 20 and above 3 times the daily mean of the 6 days before, `(count_7d - count_24h) / 6` ("Above usual") | — | Dashboard default |

The security rules are compiled per signal in
[Security signals](#security-signals-task-16); neither has a `bad`
class, so the card never claims an incident the alerts have not paged.

Each rule is a function of `internal/web/status.go` taking the figure
and returning the class and the word, table-tested on each boundary; a
`null` figure is `none` with "No data". A figure whose rule names no word
reads "OK", "Warning" or "Critical", the alerts' severities. "A to B" includes both ends, so a
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
The overall level (task 17) is the lowest of the four bands, so one weak
metric is never averaged away; it takes that band's word and colour. When
any metric is `none`, the overall level is "No data" (`none`). DORA's own
clusters come from a cluster analysis of survey answers, not from a rule
a single team can apply; the lowest band is the strictest rule that can.

Rework rate (task 19) has no band and no status: DORA added it in its
[2024 report](https://dora.dev/research/2024/dora-report/) and defines it
as the ratio of deployments that are unplanned and happen because of an
incident in production
([DORA metrics guide](https://dora.dev/guides/dora-metrics/)); the 2023
clusters used for the four bands predate it. Here, over the window of
Requirement 2.1:

- the deploys `D` are those of 10.1;
- the rework deploys `W` are the merged pull requests, each counted
  once, that are a rollback or a fix forward of 10.3, plus the deploying
  merges of 10.2 whose title matches `^fix(\([^)]*\))?!?: ` and whose
  merge time falls inside an incident of 10.4 or within 24 hours after
  its end, both bounds included (the incidents from the same `ALERTS`
  range query and rollbacks as time to restore, merged, before the
  start-in-window filter: one still open or begun before the window
  counts too);
- rework rate `W / D`, `null` when `D` is 0.

The incident condition is what makes a `fix` unplanned: without it every
routine `fix` would count, and the metric would measure commit types.
Change failure rate counts the rollbacks and fix forwards only, so rework
rate is at least the change failure rate; the gap is the follow-up fixes
that incidents cause.

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
`style=`, `on*`, inline `<script>`, foreign origins, except an `<a>` to
`https://github.com/ned-si/homelab/` for the `ci` runs' pull requests and,
from task 17, to `https://dora.dev/` for the DORA links) are
not repeated in Go: `tests/test_site_markup.py`, in the `tests` job that always runs,
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
   `scripts/ci/install-tool.sh`) at the widths of a phone (390), a 4:3
   screen (1024), 16:10 (1440) and 16:9 (1920, 2560), each taller than
   the page so the whole page is in the shot, with `--screenshot` and
   Chrome's log on stderr.
3. Fail when Chrome exits non-zero, a PNG is missing or empty, Chrome's
   log has a CSP violation (`Refused to`) or a failed load,
   `internal/tools/gridcheck` finds a card off the grid, or the web
   role's access log has a status other than `200` for the page or the
   stylesheet. `gridcheck` takes `--panel` and `--bg` from
   `dashboard.css` and finds the cards on each pixel row as the runs
   between page-background pixels that hold at least 12 px of the panel
   colour. It fails a pixel row whose cards neither span the whole card
   area nor sit one track wide on the tracks from its left edge (the
   track is the most common card width, 8 px of slack for corners and
   rounding), and, when there are tracks, a count of whole-area blocks
   other than `--wide`, the `panel stats` sections of the page: one
   more is a lone card stretched across its row.
4. Upload the PNGs as the `dashboard-screenshots` artefact, so the look
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
(`physmem`), and the last point of the `cpu`, `memory` and `arcsize`
graphs of `reporting/get_data` for `truenas_cpu_utilisation_ratio`,
`truenas_memory_used_bytes` and `truenas_memory_arc_bytes`. Used memory
is `physmem` minus available minus the ZFS ARC: the ARC is reclaimable
cache, like Linux's buff/cache, and counted as used it would hold a
healthy NAS near 100% (#1637). The task checks both calls against the NAS
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

### Security signals (task 16)

The `security` block, built every cycle. Each signal is one PromQL
expression with a window `<w>`: an instant query with `24h` and one with
`7d` at the cycle's evaluation time `t`, and a range query with `6h`
from `t - 162h` to `t` at a 6 h step for the 28 buckets. That is 21
queries a cycle, each returning one series.

The signals, `internal/snapshot/shown.go`, in this order:

| `id` | Name on the card | Rule | Query |
| --- | --- | --- | --- |
| `gateway_rejected` | Requests rejected (4xx) | background | `sum(increase(envoy_http_downstream_rq_xx{envoy_response_code_class="4", envoy_http_conn_manager_prefix=~"listener-secure\|listener-insecure"}[<w>]))` |
| `gateway_forbidden` | Access refused (403) | background | `sum(increase(envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+", envoy_response_code="403"}[<w>]))` |
| `gateway_method` | Method not allowed (405) | background | The same with `envoy_response_code="405"` |
| `signin_failed` | Failed sign-ins | background | `sum(increase(keycloak_user_events_total{event="login", error!=""}[<w>]))` |
| `admission_denied` | Admission denials | expected zero | `sum(increase(apiserver_admission_webhook_rejection_count{name=~"i?vpol\\.validate\\.kyverno\\.svc.*", error_type="no_error"}[<w>])) or vector(0)` |
| `ingress_dropped` | Ingress packets dropped by network policy | background | `sum(increase(cilium_drop_count_total{reason="Policy denied", direction="INGRESS"}[<w>]))` |
| `runtime_detections` | Runtime detections (observe mode) | expected zero | `count(max_over_time(ALERTS{alertname=~"Runtime.+", alertstate="firing"}[<w>])) or vector(0)` |

- `or vector(0)` only where the series is born with the first event (a
  denial, a detection); every other signal without a series is `null`
  ("No data"). A counter born inside the window counts from its first
  sample, which `increase()` alone misses, as
  `tetragon:policy_events:increase5m` does: for a counter selector `S`
  the collector queries `sum((S unless S offset <w>) or increase(S[<w>]))`,
  so a series absent at `t - <w>` counts its whole value; a collector
  test with a fake Prometheus pins the expression.
- The Gateway signals are every request on the public listeners, the
  household's included (NAT loopback goes through the same Gateway).
  `4xx` comes from Envoy's downstream counter, so it includes the `404`s
  Envoy answers itself for unknown hosts; `403` and `405` come from the
  upstream counter by code (the downstream one has only the class).
- `admission_denied` uses the selector of `KyvernoDenied`, with
  `ivpol` added for `verify-own-images`; `runtime_detections` counts the
  firings of the `Runtime*` alerts of `tetragon-alerts.yaml`, so the
  card subtracts the same allow-lists as the pager.
- The selectors name webhooks, clusters and alerts inside the
  collector only; every expression sums them away before the answer
  leaves Prometheus, as for the cluster block.
- `ingress_dropped` counts the enforced policies only. The app
  allow-lists in audit mode drop nothing and Hubble exports no audit
  verdict (`hubble_policy_verdicts_total{action="audit"}` has no series);
  they count through the same query once spec netpol-default-deny
  enforces them.

Signals checked on 2026-11-24 at 12:52Z (Grafana's Prometheus
datasource, read-only), 24 h and 7 d:

| Signal | Data today | 24 h | 7 d |
| --- | --- | --- | --- |
| `gateway_rejected` | Found: Envoy downstream counters of the shared Gateway | 8,044 | 48,127 |
| `gateway_forbidden` | Found: Envoy upstream counters by code | 0 | 661 |
| `gateway_method` | Found: the same | 29 | 114 |
| `signin_failed` | Found: `keycloak_user_events_total` (feature `user-event-metrics`) | 2 | 16 |
| `admission_denied` | Found: the API server's webhook counter (3 denials in 30 days) | 0 | 0 |
| `ingress_dropped` | Found: Cilium agent's drop counter | 1 | 1 |
| `runtime_detections` | Found: `ALERTS` of the `Runtime*` alerts (fired in the last 30 days) | 0 | 0 |

Deferred or not used:

| Signal | Why |
| --- | --- |
| Scanner paths (requests for paths scanners probe, one category) | Deferred: no metric carries a path. Envoy's and Hubble's metrics have no path label; only the Gateway's logs in SigNoz do. Added once a log-derived counter exists |
| Kyverno's own admission metrics (`kyverno_admission_requests_total`, `kyverno_policy_results_total`) | Not used: only the reports controller is scraped; the API server's counter already counts the denials |
| Kyverno PolicyReport `fail` results (`kyverno_policyreport_summary`) | Not used: background-scan results on objects already admitted, a posture level and not a denial |
| Hubble's ingress drop verdicts (`hubble_policy_verdicts_total{action="dropped", direction="ingress"}`) | Not used: 0 in 24 h where the Cilium agent counted 1; `hubble_drop_total` has no direction |
| Raw Tetragon events (`tetragon_policy_events_total`, `tetragon_events_total`) | Not used: about 750,000 policy events a day, nearly all from allow-listed actors (runc, mounts, the agent); the detections are what the alerts leave |
| Brute-force lockouts (`keycloak_user_events_total{event=~"user_disabled_by_.+_lockout"}`) | Not shown (2026-11-24): Keycloak locks existing accounts only, so a public count that moves after ten failed sign-ins tells a stranger the username exists. Failed sign-ins stay, as a count and a sparkline |
| Canary tokens | Their own spec, #1618 (operator: next month) |

### Security card figures (tasks 22 and 23)

Operator, 2026-11-25: the public 4xx figures count only traffic that is
not ours. On 2026-11-25 about 45% of the Gateway's 4xx in 24 h came
from our own `theater` probe (Plex answers 401 on `/`), most of the rest
from scanners asking for `/.env` or `/.git/config`, and about 12% from
replies Envoy gives itself (malformed or reset requests), which no
backend counter records.

Sources first (task 22, not visible):

- The `theater` probe targets an endpoint that answers 2xx without a
  session (Plex `/identity`, which the smoke hook already uses, or the
  SSO proxy's `/oauth2/` path), and the stale comment in
  `platform/blackbox-exporter/probes/probes.yaml` (`/` goes to Plex,
  the route's catch-all) is corrected. The `http_gated` module's
  `valid_status_codes` drops `401`.
- A CI check (a repo-policy rule over
  `platform/blackbox-exporter/values.yaml` and its tests) fails on a
  module used by a `probe: public` Probe whose `valid_status_codes`
  holds a code outside 200-399.
- Every check that triggers a 4xx or 405 on purpose (the PostSync smoke
  hooks' `POST /` and `404` requests, `site-serve-check.sh` already
  runs against a local nginx) targets the app's Service inside the
  cluster, never a public name.
- The task lists every own client still crossing the public listeners
  (probes, the weekly `dast` and pentest runs) and whether Envoy can
  attribute it by listener or route. What it can attribute is
  excluded in the queries below; what it cannot gets one plain line
  under its tile, such as "Includes our own weekly security scan."
- Hubble gains a drop metric with the source's reserved identity
  (`drop:sourceContext=reserved-identity`, no destination context), so
  drops from the internet have a series: labels `reason`, `protocol`
  and `source` (`reserved:world`, `reserved:host`, ...), a handful of
  series.
- #1677 handles the in-cluster drops into `trivy-server` and
  `signoz-otel-collector` seen on w-1.

Found by task 22 (2026-11-25, Grafana's Prometheus datasource):

- The `theater` probe targets `https://theater.lilalala.com/oauth2/sign_in`,
  the SSO proxy's own page, which answers `302` to Keycloak without a
  session and without calling Keycloak; `http_gated` keeps `302` only.
  Plex's `/identity` is already the `watch` probe.
- The Hubble metric exists already: the `drop` metric of
  `infrastructure/cilium/values.yaml` has
  `sourceContext=namespace|reserved-identity`, so `hubble_drop_total`
  carries `source="reserved:world"` for drops from the internet. No
  Cilium change and no agent restart. With no drop from the internet
  the series is absent, so the query adds
  `or on() (0 * sum(hubble_drop_total))`: 0 while Hubble is scraped,
  `null` when it is not.
- The smoke hooks of `apps/website` and `apps/homelab-dashboard` send
  their `404` and `POST` requests to the Service (`http://website:8080`
  with the `Host` header, `http://homelab-dashboard-web:8080`). nginx
  sets no security header (the HTTPRoute does), so the website's `404`
  header check goes: the route's `ResponseHeaderModifier` applies to
  every answer and stays checked on the `200`s. The dashboard's web
  role sets its own headers, so its check stays, on the Service.
- Own clients still crossing the public listeners: the public probes
  (2xx or 3xx only from this task), the smoke hooks' `200` and `301`
  checks, the weekly `dast` scan (Sunday 03:00 UTC) and the quarterly
  pentest, both from GitHub-hosted runners. Envoy cannot tell the scans
  apart from anyone else by listener or route, so `<own>` is empty and
  the three Gateway tiles carry the line "Includes our own weekly
  security scan."
- Envoy's own replies (the unattributed line) are the downstream `4xx`
  minus `envoy_http_no_route` minus every upstream `4xx` of the
  `gateway/.+` clusters, clamped at 0.

The signals from task 23, replacing the list of
[Security signals](#security-signals-task-16), in this order (`<P>` is
`envoy_http_conn_manager_prefix=~"listener-secure|listener-insecure"`,
`<own>` the exclusions task 22 found, empty if none):

| `id` | Name on the card | Rule | Count | Share of |
| --- | --- | --- | --- | --- |
| `gateway_unknown` | Unknown host or path | background | `sum(increase(envoy_http_no_route{<P>}[<w>]))` plus the upstream `404`s of the static sites' clusters (`website`, `homelab-dashboard`) | the public requests |
| `gateway_refused` | Refused by an app | background | `sum(increase(envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+", envoy_response_code=~"401\|403"<own>}[<w>]))`; the detail line gives the `403` part | the public requests |
| `gateway_method` | Method not allowed (405) | background | the same with `envoy_response_code="405"` | the public requests |
| `signin_failed` | Failed sign-ins | background | as in task 16 | `keycloak_user_events_total{event="login"}` |
| `blocked` | Deployments blocked by policy | expected zero | the Kyverno selector of task 16 plus `sum(increase(pod_security_evaluations_total{decision="deny", mode="enforce"}[<w>]))`, each `or vector(0)` | none |
| `ingress_world` | Ingress packets dropped from the internet | background | `sum(increase(hubble_drop_total{reason="POLICY_DENIED", source="reserved:world"}[<w>]))` | none |
| `runtime_detections` | Runtime detections | expected zero | as in task 16 | none |

- The public requests are
  `sum(increase(envoy_http_downstream_rq_total{<P>}[<w>]))`, minus
  `<own>` where it applies. A share is the count over its denominator
  for the same window, two decimals, next to the count: "10.11% of
  63,000 requests", "2.50% of 80 sign-ins". No share without a
  denominator series.
- Under the two 4xx tiles, one line gives the downstream 4xx that
  neither tile counts (Envoy's own replies): "Another 760 answered by
  the Gateway itself cannot be attributed." Shown only when above 0.
- Pod Security runs in `audit` and `warn` today, so its part is 0 until
  a namespace enforces; its warnings are not denials.
- Time windows read "rolling 24 h" and "rolling 7 days"; the page never
  says "observe mode". Once Tetragon enforces, the runtime tile may
  count "blocked" separately (a later change).
- Snapshot version 5, with the rounding of task 18 (tasks 18, 22 and
  23 ship in one pull request, operator 2026-11-25): `security.signals[]`
  holds the list above by `id` and `name`, and per signal `share_24h`,
  `share_7d` (0 to 1, or `null` without a denominator), `total_24h`,
  `total_7d` (the denominators, integers or `null`, for "of 63,000
  requests"), `part_24h` (the `403` part of `gateway_refused`, integer
  or `null`) and `unattributed_24h` (integer, set for `gateway_unknown`
  only, `null` for the others and without a series). The rollout rule
  of version 3 applies.
- A signal born with its first event whose source always has series
  (the Envoy upstream codes, the Hubble drops) adds
  `or on() (0 * sum(<source>))`, so a quiet signal reads 0 and a
  missing source "No data"; `or vector(0)` stays on the expected-zero
  signals only.

## Supply chain (tasks 20 and 21)

### Which SLSA Build level

The [SLSA v1.0 Build track](https://slsa.dev/spec/v1.0/levels) has three
levels: L1, provenance exists; L2, the provenance is generated and signed
by a hosted build platform; L3, the platform also keeps the signing
material out of reach of the user-defined build steps and isolates runs
from each other. What each option gives here:

| Build and provenance | Level | Why |
| --- | --- | --- |
| BuildKit's `--provenance=mode=max` alone (`homelab-site` today) | L1 | Provenance exists, but unsigned: anyone who can push the image can rewrite it |
| `actions/attest-build-provenance` in the job that builds, on a GitHub-hosted runner (`homelab-dashboard` today, `homelab-site` from task 20) | L2 | GitHub signs the provenance with the workflow's OIDC identity through Sigstore; GitHub's documentation states that artifact attestations give Build L2. The build steps run in the same job and could request the same token, so not L3 |
| The build moved into a reusable workflow that makes the attestation | L3, per GitHub | GitHub documents [reusable workflows with artifact attestations as Build L3](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/increase-security-rating): the signing identity is the reusable workflow, which the caller cannot change |
| The SLSA GitHub generator's container workflow (`slsa-framework/slsa-github-generator`) | L3 | The provenance is made in a separate job of the generator's reusable workflow, isolated from the build job |

So both images show **Build L2** once task 20 lands. L3 is a later
change (out of scope here): it changes the signing identity that
Kyverno, `ci/image-signers.yaml` and the inventory check, so it is its
own spec.

The builder identity shown: the runner environment of the provenance,
`buildDefinition.internalParameters.github.runner_environment`
(`github-hosted`), and the signing workflow, which is also
`runDetails.builder.id`:
`https://github.com/ned-si/homelab/.github/workflows/<image's
workflow>@refs/heads/main` (read from the attestation of
`homelab-dashboard` on 2026-11-25). The text is compiled per image in
`shown.go` ("GitHub-hosted runner, <workflow> on main"); the publishing
workflow fails when its fresh attestation names another workflow, ref or
runner (`gh attestation verify --bundle-from-oci --signer-workflow
--source-ref refs/heads/main --deny-self-hosted-runners` and a `jq` check
of the builder id), so the compiled text cannot drift from the evidence.

Level and verification per image: Kyverno writes one result per Pod
for `verify-own-images`, covering the signature and the provenance
together, so a missing provenance and a failed signature look the same.
`verified` is `null` when no running Pod of the image has a result,
`false` when one has a result other than `pass`, `true` otherwise (a
Pod without a result yet, just after a rollout, is left out). The level
is claimed only on that evidence: `level` is `2` when `verified` is
`true`, `null` otherwise, and the tile then shows its status word alone
(Requirement 13.2).

### Provenance (task 20)

- `site-publish` gains `attestations: write` and the
  `actions/attest-build-provenance` step that `dashboard-publish`
  already has (`push-to-registry: true`), then verifies it with
  `gh attestation verify --signer-workflow`, before signing and
  tagging.
- `verify-own-images` (Audit, fail-open) gains, per image, an
  attestation check next to the signature check: a SLSA v1 provenance
  (`https://slsa.dev/provenance/v1`) on the running digest, signed by
  that image's workflow identity on `main`, whose
  `runner_environment` is `github-hosted`. Kyverno 1.20 reads the
  Sigstore bundle the attest action pushes as an OCI referrer, so no
  `cosign attest` copy is needed (task 20: `kyverno apply` passed for
  the running `homelab-dashboard` digest and failed for the running
  `homelab-site` digest, signed but without a provenance, and for a
  provenance from another workflow).
- kube-state-metrics' `customResourceState` (the config that already
  exports `kyverno_policyreport_summary`) gains an `Info` metric
  `result` over the path `[results]` of the PolicyReport resource
  (`kyverno_policyreport_result_info`), with `labelsFromPath`
  `policy: [policy]`, `rule: [rule]`, `result: [result]` and, at report
  level, `resource: [scope, name]`. `customResourceState` cannot filter
  list elements by value, so it exports every result of every policy;
  the kube-state-metrics ServiceMonitor keeps only `verify-own-images`
  at scrape time (RE2 has no negative lookahead, hence the temporary
  label):
  ```yaml
  metricRelabelings:
    - sourceLabels: [__name__, policy]
      regex: kyverno_policyreport_result_info;verify-own-images
      targetLabel: __tmp_keep
      replacement: "1"
    - sourceLabels: [__name__, __tmp_keep]
      regex: kyverno_policyreport_result_info;
      action: drop
  ```
  `tests/test_ksm_policyreport.py` checks the metric's config and applies
  the relabelling as Prometheus does: only `verify-own-images` results
  survive, every other metric is untouched (promtool cannot run
  `metricRelabelings`). The pinned kube-state-metrics (v2.20.0) was run
  once against the live PolicyReports with this config (task 20): 20,911
  result series exported, 858 of `verify-own-images` kept, one per
  reported resource, the Pod's name in `resource`. The
  collector joins the result with
  `kube_pod_container_info{image_spec=~"ghcr.io/ned-si/<image>(:[^@]+)?@sha256:[0-9a-f]{64}"}`
  (`image_spec` is the image as the Pod spec pins it, `:main@sha256:…`;
  `image` is the runtime's) on namespace and Pod and reduces it to one
  boolean per image: verified
  when every running Pod of the image passes both checks. No namespace
  or Pod name leaves the collector (Requirement 2.7).
- `README.md`: the badge
  `[![SLSA Build L2](https://slsa.dev/images/gh-badge-level2.svg)](https://slsa.dev/spec/v1.0/levels#build-l2)`
  after the Scorecard badge.

### Scorecard (task 24)

- Source: `GET https://api.securityscorecards.dev/projects/github.com/ned-si/homelab`
  (the public Scorecard API; the README badge uses its other name,
  `api.scorecard.dev`), no token, `User-Agent` as for GitHub, hourly in
  the project refresh, 10 s timeout, redirects only to `https://`
  Scorecard hosts. The collector's egress to `world:443` already allows
  it; no policy change.
- The answer's `score`, `date` and `checks[]` (`name`, `score`,
  `reason`) are read; every check is kept, sorted by name, a
  `score: -1` as `null` (task 27). Unknown check names, a name seen
  twice, scores outside -1 to 10, reasons over 160 characters or with
  control characters are dropped and counted in
  `collector_errors_total{source="scorecard"}`. A failed fetch keeps
  the last result; the block's staleness rule is the project block's
  (60 min), read from `scorecard.as_of`. One attempt an hour, a failed
  one included, so an unreachable API is never asked more often.
- The compiled check list: Binary-Artifacts, Branch-Protection,
  CI-Tests, CII-Best-Practices, Code-Review, Contributors,
  Dangerous-Workflow, Dependency-Update-Tool, Fuzzing, License,
  Maintained, Packaging, Pinned-Dependencies, SAST, SBOM,
  Security-Policy, Signed-Releases, Token-Permissions, Vulnerabilities,
  Webhooks.
- Check colours (task 28): `checkStatus(score *int)` in
  `internal/web/status.go` gives `none` and "Not applicable" for `nil`,
  otherwise `scoreStatus` on the score (7 and 4, "OK", "Warning",
  "Critical"); `checkTiles` sets the tile's status and word from it.
- Notes (task 28): compiled in the web role, keyed by check name, shown
  under Scorecard's reason; the collector and the snapshot are
  unchanged (version 10 stays). A note adds context; the score, the
  reason and "Not applicable" stay Scorecard's own. English (the French
  is the operator's correction of the coder's proposal, in the task's
  pull request):

  | Check | Note |
  | --- | --- |
  | Branch-Protection | On purpose: main takes only pull requests with signed commits and a green CI, and needs no approval, so Renovate and the agents merge without waiting for a person. |
  | Code-Review | On purpose: I run this alone and agents open the pull requests, so nobody else approves them. Green CI is the only gate. |
  | Contributors | On purpose: one operator and a few agents, with no company or organisation behind the repository. |
  | Signed-Releases | The images are signed with cosign and carry SLSA Build L2 provenance. No GitHub releases on purpose: these are personal apps, not meant for others to download. |

  CII-Best-Practices has no note: Scorecard's reason ("badge detected:
  InProgress") says where it stands. The Scorecard paragraph gains one
  sentence: "A check is green from 7 out of 10, yellow from 4 and red
  below; a note under a check says why where Scorecard's reason is not
  enough."
- Signed-Releases: Scorecard reads only GitHub release assets and gives
  `-1` when there is no release. The repository publishes none: it
  delivers from `main`, versioned by commit (Decided defaults,
  Versioning), and its images are signed and attested on GHCR (task
  20). GitHub releases made only so Scorecard can see the signatures
  would duplicate them, so the check stays "Not applicable" with its
  note.

## Databases (tasks 25 and 26)

Operator, 2026-11-25: a database part in the Cluster card, with the
backup status. What it shows, how the hidden databases are counted and
the thresholds are the orchestrator's defaults
([requirements, Decided defaults](requirements.md#decided-defaults)).

### What exists

Checked on 2026-11-25 at 19:30Z (Grafana's Prometheus datasource,
read-only):

- Eight CloudNativePG clusters, one instance each, scraped by the
  PodMonitor `cnpg-instances` of `platform/barman-cloud-plugin/monitoring.yaml`:
  `cnpg_collector_up` (with a `cluster` label), `cnpg_pg_stat_archiver_*`,
  `cnpg_collector_pg_wal_archive_status`, `cnpg_pg_database_size_bytes`
  (by `datname`) and the Barman Cloud plugin's
  `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`,
  `_last_failed_backup_timestamp` and `_first_recoverability_point`.
  Except `cnpg_collector_up`, they carry `namespace` and `pod`
  (`<cluster>-<n>`), no `cluster`.
- The alerts on them, PrometheusRule `cnpg-backups` in the same file,
  and the backup-freshness SLO, `slo:backup_freshness:ratio_rate30d{kind="cnpg"}`
  (`platform/kube-prometheus-stack/routes/backup-slo.yaml`).
- The weekly restore test, CronJob `backup-verify-postgres` (Sunday
  21:00 UTC, `platform/backup-verify/restore-postgres.yaml`), which
  pushes `backup_verify_*{check="postgres", target="<cluster>"}` to the
  Pushgateway in `backup-verify` ([docs/backups.md, Reading the results](../../../docs/backups.md#reading-the-results)).

Three facts shape the rules:

- **Time since the last archived WAL file is not a health signal.** A
  database that writes nothing archives nothing (`archive_timeout`
  switches only a segment that holds WAL): on 2026-11-25 two healthy
  databases had archived nothing for 19 hours. Archiving fails only
  when the last failure is newer than the last success, the rule of
  `CNPGWALArchivingFailing`.
- **Instance pods restart, and their series gap.** Every CNPG and
  Barman series comes from the instance pod, so while it is
  rescheduled the database has no series, and it comes back with a
  new `instance` label. In the rolling 7 days to 2026-11-25 each of
  the 8 databases had 3 to 4 `instance` labels on
  `cnpg_collector_up`. No alert fires on such a gap (the shortest
  `for:` of the CNPG alerts is 10 minutes), so the rules smooth it:
  `up` is the maximum over the last 10 minutes, the Barman
  timestamps the maximum over the rolling 26 h, each aggregated by
  database before any comparison, so an old `instance` series cannot
  carry a stale value.
- **A new Pushgateway pod starts empty.** The Pushgateway persists
  its results to an emptyDir, so a container restart keeps them, but
  a new pod (rescheduled, rolled out) has no `backup_verify_*` series
  until the next weekly run (on 2026-11-25 none had been current
  since the pod was replaced, while 8 days of history held every
  result). While the pod lives, it serves the last pushed value on
  every scrape, however old. So every restore-test rule reads the
  rolling 8 days of history, never only the current sample, and
  bounds a pass by its own age (`time() - last_success < 8 days`, as
  `BackupVerifyStale` does).

### Recording rules (task 25)

PrometheusRule `homelab-databases` in
`platform/kube-prometheus-stack/routes/databases.yaml` (namespace
`monitoring`, label `release: kube-prometheus-stack`), listed in that
directory's `kustomization.yaml` with a one-line comment, rendered by
`task render`. Per-database rules first, keyed by `namespace` and
`cluster` (the pod name without its `-<n>`, with `label_replace` as
`slo:backup_fresh` does), or by `cluster` alone for the restore tests
(the Pushgateway's `target` is the cluster name and its `namespace` is
`backup-verify`); then label-free aggregates. The collector reads only
the aggregates, so no database, namespace or pod name reaches it. Rules
of one group run in order at one instant, so each aggregate reads the
per-database rules of the same evaluation.

```yaml
groups:
  - name: homelab.databases
    interval: 1m
    rules:
      # 1 per database seen in the rolling 24 h: the denominator of every
      # "<n> of <m>", so a database that stops reporting still counts.
      - record: cnpg_cluster:seen_24h
        expr: group by (namespace, cluster) (max_over_time(cnpg_collector_up[24h]))
      # Down after 10 minutes without a series: the shortest for: of the
      # CNPG alerts, so a pod restart changes nothing.
      - record: cnpg_cluster:up
        expr: |
          max by (namespace, cluster) (max_over_time(cnpg_collector_up[10m]))
          or on (namespace, cluster) (cnpg_cluster:seen_24h * 0)
      - record: cnpg_cluster:wal_failing
        expr: |
          max by (namespace, cluster) (label_replace(
            cnpg_pg_stat_archiver_last_failed_time > bool cnpg_pg_stat_archiver_last_archived_time,
            "cluster", "$1", "pod", "(.+)-[0-9]+"))
      - record: cnpg_cluster:wal_behind
        expr: |
          max by (namespace, cluster) (label_replace(
            cnpg_collector_pg_wal_archive_status{value="ready"} > bool 5,
            "cluster", "$1", "pod", "(.+)-[0-9]+"))
      # The Barman timestamps: the latest in the rolling 26 h, by database
      # first, so a pod restart neither drops nor duplicates one. No age
      # series before the first base backup (the timestamp is 0).
      - record: cnpg_cluster:base_backup_age:seconds
        expr: |
          time() - (max by (namespace, cluster) (label_replace(
            max_over_time(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp[26h]),
            "cluster", "$1", "pod", "(.+)-[0-9]+")) > 0)
          and on (namespace, cluster) cnpg_cluster:seen_24h
      - record: cnpg_cluster:base_backup_failed
        expr: |
          max by (namespace, cluster) (label_replace(
            max_over_time(barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp[26h]),
            "cluster", "$1", "pod", "(.+)-[0-9]+"))
          > bool
          max by (namespace, cluster) (label_replace(
            max_over_time(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp[26h]),
            "cluster", "$1", "pod", "(.+)-[0-9]+"))
          and on (namespace, cluster) cnpg_cluster:seen_24h
      - record: cnpg_cluster:recovery_window:seconds
        expr: |
          time() - (max by (namespace, cluster) (label_replace(
            max_over_time(barman_cloud_cloudnative_pg_io_first_recoverability_point[26h]),
            "cluster", "$1", "pod", "(.+)-[0-9]+")) > 0)
          and on (namespace, cluster) cnpg_cluster:seen_24h
      - record: cluster:cnpg_databases:count
        expr: count(cnpg_cluster:seen_24h) or vector(0)
      - record: cluster:cnpg_databases_up:count
        expr: sum(cnpg_cluster:up) or vector(0)
      # The app databases, without Postgres's own postgres and template*;
      # by database first, so a restart's new instance label counts once.
      - record: cluster:cnpg_data:bytes
        expr: |
          sum(max by (namespace, cluster, datname) (label_replace(
            max_over_time(cnpg_pg_database_size_bytes{datname!~"postgres|template[0-9]+"}[10m]),
            "cluster", "$1", "pod", "(.+)-[0-9]+")))
      - record: cluster:cnpg_wal_archiving:count
        expr: |
          count(
            (cnpg_cluster:up == 1)
            unless on (namespace, cluster) (cnpg_cluster:wal_failing == 1 or cnpg_cluster:wal_behind == 1)
          ) or vector(0)
      - record: cluster:cnpg_wal_behind:count
        expr: |
          count(
            (cnpg_cluster:wal_behind == 1)
            unless on (namespace, cluster) (cnpg_cluster:wal_failing == 1)
          ) or vector(0)
      - record: cluster:cnpg_wal_archived:increase24h
        expr: sum(increase(cnpg_pg_stat_archiver_archived_count[24h]))
      - record: cluster:cnpg_base_backup_fresh:count
        expr: |
          count(
            (cnpg_cluster:base_backup_age:seconds < 26 * 3600)
            unless on (namespace, cluster) (cnpg_cluster:base_backup_failed == 1)
          ) or vector(0)
      - record: cluster:cnpg_base_backup_age:max_seconds
        expr: max(cnpg_cluster:base_backup_age:seconds)
      - record: cluster:cnpg_recovery_window:min_seconds
        expr: min(cnpg_cluster:recovery_window:seconds)

  # Weekly results over the rolling 8 days of history (a new Pushgateway
  # pod starts empty). Every 2 minutes: the 8-day subqueries are the
  # heaviest rules here and the results change once a week.
  - name: homelab.databases.restore
    interval: 2m
    rules:
      - record: cnpg_cluster:restore_last_run:timestamp
        expr: |
          max by (cluster) (label_replace(
            max_over_time(backup_verify_last_run_timestamp_seconds{check="postgres"}[8d]),
            "cluster", "$1", "target", "(.+)"))
      - record: cnpg_cluster:restore_last_success:timestamp
        expr: |
          max by (cluster) (label_replace(
            max_over_time(backup_verify_last_success_timestamp_seconds{check="postgres"}[8d]),
            "cluster", "$1", "target", "(.+)"))
      # Rows and time of the latest passing test (verify-postgres.sh pushes
      # them only on a pass), whichever Pushgateway pod served them.
      - record: cnpg_cluster:restore_rows
        expr: |
          max by (cluster) (label_replace(
            last_over_time((max by (target) (backup_verify_rows{check="postgres"}))[8d:5m]),
            "cluster", "$1", "target", "(.+)"))
      - record: cnpg_cluster:restore_duration:seconds
        expr: |
          max by (cluster) (label_replace(
            last_over_time((max by (target) (backup_verify_restore_seconds{check="postgres"}))[8d:5m]),
            "cluster", "$1", "target", "(.+)"))
      # A pass counts while it is under 8 days old: the Pushgateway keeps
      # serving an old one.
      - record: cluster:cnpg_restore_passed:count
        expr: |
          count(
            (cnpg_cluster:restore_last_success:timestamp >= on (cluster) cnpg_cluster:restore_last_run:timestamp)
            and on (cluster) (time() - cnpg_cluster:restore_last_success:timestamp < 8 * 86400)
            and on (cluster) cnpg_cluster:seen_24h
          ) or vector(0)
      # The latest run in the 8-day history failed, whatever its age.
      - record: cluster:cnpg_restore_failed:count
        expr: |
          count(
            (
              (cnpg_cluster:restore_last_run:timestamp > on (cluster) cnpg_cluster:restore_last_success:timestamp)
              or (cnpg_cluster:restore_last_run:timestamp unless on (cluster) cnpg_cluster:restore_last_success:timestamp)
            )
            and on (cluster) cnpg_cluster:seen_24h
          ) or vector(0)
      # Only passes inside the rolling 8 days, the window the tile names.
      - record: cluster:cnpg_restore_rows:sum
        expr: |
          sum(cnpg_cluster:restore_rows
            and on (cluster) (time() - cnpg_cluster:restore_last_success:timestamp < 8 * 86400)
            and on (cluster) cnpg_cluster:seen_24h)
      - record: cluster:cnpg_restore_duration:median_seconds
        expr: |
          quantile(0.5, cnpg_cluster:restore_duration:seconds
            and on (cluster) (time() - cnpg_cluster:restore_last_success:timestamp < 8 * 86400)
            and on (cluster) cnpg_cluster:seen_24h)
```

- A passing run pushes `backup_verify_last_success_timestamp_seconds`
  equal to its `backup_verify_last_run_timestamp_seconds`
  (`platform/backup-verify/scripts/common.sh`); a failing run pushes
  only `last_run`. So "passed" is the latest run passed and its
  success is under 8 days old; "failed" is the latest visible run newer
  than its success, or a run with no success in the history, whatever
  its age. This matches `BackupVerifyFailed` while the Pushgateway pod
  lives, and keeps the failure after a new pod starts empty; a
  database with neither is "overdue": `count - restore_passed -
  restore_failed`. Overdue covers both ways a test goes missing: the
  Pushgateway still serving a pass older than 8 days (the CronJob
  stopped), and no series at all (a new Pushgateway pod and no run in
  8 days).
- Rows and restore time are bounded by the age of the last success,
  not of the last run: the figures come from the last passing run, so
  a pass older than 8 days drops out of the sum and the median even
  when a newer run failed.
- The restore rules match on `cluster` alone: cluster names are unique
  across namespaces today, and a duplicate would make `and on
  (cluster)` count both, which the promtool test does not need to
  cover. The day a name repeats, the restore test's `target` needs its
  namespace first.
- The groups have no alerts. `CNPGBackupFailed`, `CNPGBaseBackupTooOld`,
  `CNPGWALArchivingFailing`, `CNPGWALArchiveLag`, `CNPGMetricsAbsent`,
  `BackupVerifyFailed` and `BackupVerifyStale` already page or list
  the same conditions per database; the card reports.

`tests/prometheus/databases_test.yaml` (`rule_files:
[homelab-databases.yaml]`, run by `scripts/ci/promtool-check.sh`) has
the cases of acceptance criterion 31, each with `promql_expr_test`s on
the aggregates: all healthy (8 of 8 everywhere); one database's
series stopping for 3 minutes and coming back with a new `instance`
label (every aggregate still 8 of 8, data bytes counted once); one
database's series stopping for good (`up` 8 for 10 minutes, then 7,
`count` 8 until 24 h later, then 7 and 7, base backups with it); one
database backing up and stopping 30 minutes later while another one's
base backup is 27 h old (from 24 h to 25.5 h after the stop, `count`
7 and `base_fresh` 6, not 7); `last_failed_time` after `last_archived_time`
(failing) and 6 files `ready` (behind); a base backup 26 h old, one
failed after the last good one, and one with timestamp 0 (no age
series, not fresh); a restore run newer than its success (failed);
overdue twice, a pass 8 days and 1 minute old that the series keeps
reporting up to the evaluation (Pushgateway alive), and a series that
stopped 8 days and 1 minute ago (Pushgateway replaced), both with
their rows and time left out of the sum and median; the
Pushgateway's `pod` label changing with a gap of a day between the
two series (same passed count, rows and median); and a check that
every aggregate has an empty label set.

Values on 2026-11-25 at 19:30Z, from the raw queries the rules
encode:

| Aggregate | Value |
| --- | --- |
| `cluster:cnpg_databases:count`, `_databases_up:count` | 8, 8 |
| `cluster:cnpg_data:bytes` | 1,345,968,964 (1.25 GiB) |
| `cluster:cnpg_wal_archiving:count`, `_wal_behind:count` | 8, 0 |
| `cluster:cnpg_wal_archived:increase24h` | 1,516.5 |
| `cluster:cnpg_base_backup_fresh:count`, `_base_backup_age:max_seconds` | 8, 70,292 (19 h 31 min) |
| `cluster:cnpg_recovery_window:min_seconds` | 2,658,197 (30.8 days) |
| `cluster:cnpg_restore_passed:count`, `_restore_failed:count` | 8, 0 (last run 2026-11-22) |
| `cluster:cnpg_restore_rows:sum`, `_restore_duration:median_seconds` | 1,031,332, 414 (6 min 54 s) |
| `min(slo:backup_freshness:ratio_rate30d{kind="cnpg"})` | 0.99966 (99.97%) |

### Collector and page (task 26)

`internal/collector/databases.go`, `databases(ctx, q, at)
(snapshot.Databases, error)`, called at the end of `use` and stored in
`Cluster.Databases`. Instant queries at `t`, through the helpers of
`use.go`:

| Key | Query | Helper |
| --- | --- | --- |
| `count`, `up`, `wal_archiving`, `wal_behind`, `base_fresh`, `restore_passed`, `restore_failed` | `cluster:cnpg_databases:count`, `cluster:cnpg_databases_up:count`, `cluster:cnpg_wal_archiving:count`, `cluster:cnpg_wal_behind:count`, `cluster:cnpg_base_backup_fresh:count`, `cluster:cnpg_restore_passed:count`, `cluster:cnpg_restore_failed:count` | `counted`: 0 without a series |
| `data_bytes`, `base_oldest_seconds`, `recovery_window_seconds`, `restore_rows`, `restore_median_seconds` | `cluster:cnpg_data:bytes`, `cluster:cnpg_base_backup_age:max_seconds`, `cluster:cnpg_recovery_window:min_seconds`, `cluster:cnpg_restore_rows:sum`, `cluster:cnpg_restore_duration:median_seconds` | `optional`, then `integer` (rounded down) |
| `wal_archived_24h` | `cluster:cnpg_wal_archived:increase24h` | `optional`, rounded to the nearest |
| `freshness_30d` | `min(slo:backup_freshness:ratio_rate30d{kind="cnpg"})` | `optional`, times 100, clamped to 0-100, full precision |

- **Clamp.** Every per-database rule is limited to the databases in
  `cnpg_cluster:seen_24h`, so the figures agree with `count` except for
  the up to 2 minutes between the two groups' evaluations, when a
  database appears or goes away and the restore counts can disagree. The collector clamps `up`, `base_fresh` and
  `wal_archiving` to `count`, then `wal_behind` to `count -
  wal_archiving` and `restore_failed` to `count - restore_passed`
  (after clamping `restore_passed` to `count`), without logging: it is
  expected. `Validate` keeps the same bounds as a guard.
- **Errors.** A Prometheus error fails the cluster block, which keeps
  its last value, as every cluster query does. A missing rule is no
  error and is not logged: a missing count rule reads 0 and its tile
  falls short of all; a missing figure rule reads `null` and its
  detail line is left out; without `cluster:cnpg_databases:count`
  every tile is "No data". The dry run of acceptance criterion 32
  catches each.

The page, `internal/web`: `figures.Databases []tile`, from
`databaseTiles(d snapshot.Databases)` in `render.go`; a helper `durationText(s int) string` joins
`durationParts` with spaces ("19 h 31 min"). `page.html` adds, after
State and before the "as of" line:

```html
<h3>Databases and backups</h3>
<p class="meta">Each database is its own CloudNativePG cluster. Every change is archived to S3 within 5 minutes and every night adds a base backup, so a database can be restored to any moment of its recovery window. Every week each one is restored into a new cluster and its tables and rows are compared with the source.</p>
<div class="tiles">{{range .Databases}}{{template "tile" .}}{{end}}</div>
```

The tiles, in this order, each through `{{template "tile" .}}`, with
the rules of [Status colours](#status-colours); with `count` 0 every
tile is `noDataTile(label)`:

| Label | Value | Status words | Detail lines |
| --- | --- | --- | --- |
| PostgreSQL | `count`, unit "databases" | "Up", "Down" | "Seen in the rolling 24 h"; "<up> up, <bytesText(data_bytes)> of data" (", … of data" left out when `null`) |
| WAL archiving | `wal_archiving`, unit "of <count>" | "Archiving", "Behind", "Failing" | "<wal_archived_24h> files archived, rolling 24 h" (`thousands`) |
| Base backups | `base_fresh`, unit "of <count>" | "Fresh", "Stale" | "Nightly, each in the rolling 26 h"; "Oldest <durationText(base_oldest_seconds)> ago" |
| Point-in-time recovery | `recovery_window_seconds / 86400` rounded down, unit "days" | none (no class) | "The shortest window of all databases" |
| Restore tests | `restore_passed`, unit "of <count>" | "Passed", "Overdue", "Failed" | "Weekly, rolling 8 days"; "<restore_rows> rows compared" (`thousands`); "Median <durationText(restore_median_seconds)> to a restored copy" |
| Backup freshness | `pct(freshness_30d)`, unit "%" | "Met", "Missed" | "Lowest database, rolling 30 days, target 99.00%" |

A detail line whose figure is `null` is left out; a tile whose value is
`null` is `noDataTile`. The words and thresholds are one function each
in `status.go` (`databasesStatus`, `walStatus`, `baseBackupStatus`,
`restoreStatus`, `freshnessStatus`), table-tested on each boundary
(acceptance criterion 33). On 2026-11-25 the group would read: 8
databases seen in the rolling 24 h, 8 up, 1 GiB of data; 8 of 8 archiving, 1,517 files; 8 of 8
fresh, oldest 19 h 31 min ago; 30 days; 8 of 8 passed, 1,031,332 rows,
median 6 min 54 s; 99.97%, Met.

Tests: unit tests of the status functions, `durationText` and
`databaseTiles` (a `null` detail left out, `count` 0); a collector
test with a fake Prometheus that pins every query string above and
the clamp; `snapshot` tests that refuse a `databases` object with a
string, an unknown key, or a count above `count`; the golden pages
(`full` with every tile `ok`, `alarms` with `warn` and `bad`, `since`
with `count` 0); the hidden-name test of acceptance criterion 19 over
the new fixture. Integration: the promtool test of task 25 and the
live comparison of acceptance criterion 32.

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
| Database rules (task 26) | A `cluster:cnpg_*` rule missing or renamed | No error: a missing count rule reads 0 and its tile falls short of all; a missing figure rule reads `null` and its detail line is left out; without `cluster:cnpg_databases:count` every tile is "No data" | The dry run of acceptance criterion 32; a Prometheus error fails the cluster block like any cluster query |

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
- **Security as cluster-wide counts.** A count says the defences turn
  things away without saying where they stand: no address, path, rule
  or workload survives the sum. Someone probing sees a count move within
  a minute, which tells them only that they were counted. Rejected:
  per-rule or per-route breakdowns (a map of the defences), raw Tetragon
  events (noise from allow-listed actors), and a `bad` status (the
  alerts page; the page reports).
- **Databases summed, in recording rules.** Every database counts in
  every figure and none is named, so the hidden apps' databases need no
  exception and cannot be told apart; the Argo CD and Volumes tiles
  already count them that way. The joins over database names stay in
  Prometheus, where promtool tests them and from where only label-free
  numbers leave. Rejected: one row per database (the hidden ones would
  have to be left out, or named); the joins in the collector's queries
  (names in the collector's answers, tested only against a fake
  Prometheus); new alerts (the CNPG and `backup-verify` alerts already
  page).
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
- **Stat tiles.** A label belongs to its value when both share a box
  and sit closer to each other than to anything else; one label style
  everywhere makes the hierarchy readable at a glance. Rejected: bold
  labels alone (the figures still run together across a card), and a
  coloured box per status (colour would cover the label too and read as
  an alarm).
- **Rework rate without a band.** DORA has published no thresholds for
  it, and an invented band would claim a comparison that does not
  exist; the number and its counts are still a fair yardstick over time.
- **SLSA level stated, not computed.** The level is a property of the
  build, which changes only with the publishing workflow; the page shows
  the compiled level with the cluster's live verification next to it,
  and the workflow fails if the evidence stops matching. Rejected:
  verifying Sigstore bundles in the collector (a large dependency for a
  check Kyverno already makes).
- **Scorecard from its API, not the badge.** The JSON has the checks
  and reasons; the browser fetches nothing, so the CSP is unchanged.
- **Home Assistant.** Its own UI and companion app already do control and
  home dashboards, behind its own login; rebuilding them here would add a
  write path into the house to a project whose point is that the public
  part writes nothing. The collector may read a few production values for
  the public page.
