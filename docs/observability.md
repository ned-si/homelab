# Observability

Metrics, dashboards and push alerting run. Prometheus,
Alertmanager and Grafana come from `kube-prometheus-stack` (chart 92.6.0,
Prometheus v3.15.0, Alertmanager v0.34.1) in namespace `monitoring`, at the
chart's defaults apart from Prometheus storage and the Grafana login.

| Part | State |
| --- | --- |
| Prometheus | running, 15 Gi volume, the chart's default rules and scrape targets |
| Grafana | `https://grafana.lilalala.com`, Keycloak login (client `grafana-oauth`, secret from `monitoring/grafana-oidc`), the chart's default dashboards |
| Alertmanager | `Watchdog` goes to the dead-man's switch every 5 minutes ([Heartbeat](#heartbeat)); SLO burn rates, infrastructure criticals, backup failures and critical security alerts go to the hosted ntfy.sh topic ([Notifications](#notifications), policy in [sre.md](sre.md#paging)); everything else goes to `null` and is visible in Grafana only |
| Custom alert rules | `backup-verify` (group `backup.verify`, the restore tests, in `platform/backup-verify/alerts.yaml`; [backups.md](backups.md#verification)); `cnpg-backups` (group `cnpg.backups`, CNPG backup and WAL archiving) with PodMonitor `cnpg-instances`, in `platform/barman-cloud-plugin/monitoring.yaml`; `homelab-argocd` ([Argo CD alerts](#argo-cd-alerts)); `vuln-enrich` ([Vulnerability priority](#vulnerability-priority)); `talos-drift` in `system-upgrade` ([Talos drift check](talos.md#drift-check)) |
| Notification credentials | Secret `monitoring/alertmanager-notify` (keys `ntfy-url`, `ntfy-guard-url`, `heartbeat-url`), mounted into Alertmanager; `ntfy-url` is `https://ntfy.sh/<topic>`, `ntfy-guard-url` the same plus `-guard`, `heartbeat-url` is a healthchecks.io ping URL (check period 5 minutes, grace 15 minutes) |
| Hubble | on in the Cilium agents with flow, drop, TCP, ICMP and HTTP metrics, scraped with the Cilium agent, operator and Envoy metrics ([networking.md](networking.md#metrics)); relay and UI not enabled |
| truenas-exporter | Application `truenas-exporter` in `democratic-csi` ([NAS metrics](#nas-metrics)) |
| blackbox-exporter | Application `blackbox-exporter` in `monitoring`; Probes in `platform/blackbox-exporter/probes/`: every public hostname (job `blackbox-public`, label `app`) and the API VIP, Gateway, NAS iSCSI/NFS, Keycloak, Argo CD, router DNS and CoreDNS (job `blackbox-internal`); a ping to the router, the NAS, the four nodes and the BMC (job `blackbox-lan`, label `device`; module `icmp` through the unprivileged-ICMP sysctl `net.ipv4.ping_group_range`, no NET_RAW). `LANDeviceUnreachable` (warning) fires when the router or the BMC does not answer for 10m (PrometheusRule `homelab-lan`) |
| github-exporter | Application `github-exporter` in `monitoring` (`platform/github-exporter/exporter.py`, stdlib Python): every 15 minutes reads the workflows and their last 30 runs, open and recently closed pull requests and Renovate's Dependency Dashboard from the public GitHub API, unauthenticated (about 11 requests per cycle, ETag-cached, quota 60/hour per IP); metrics `github_*` |
| usage-exporter | Application `usage-exporter` in `monitoring` (`platform/usage-exporter/exporter.py`, stdlib Python): every 5 minutes Immich `/api/server/statistics` (totals and per user) and Jellyfin `/Items/Counts` and `/Sessions`; API keys in Secret `monitoring/usage-exporter` (keys `IMMICH_API_KEY`, `JELLYFIN_API_KEY`, sealed as PENDING until created, see its template); metrics `immich_*`, `jellyfin_*`, `usage_source_*` |
| exportarr | a sidecar in Sonarr, Radarr, Lidarr and Prowlarr (port `metrics`, 9707), API key read from the app's `config.xml` by an init container; PodMonitor `theater/exportarr` every 5 minutes |
| trivy-operator | Application `trivy-operator` in `trivy-system` (`platform/trivy-operator/values.yaml`): a VulnerabilityReport per running workload, fixable MEDIUM and above, rescanned every 24 h; one scan Job at a time against the built-in Trivy server (DB in an emptyDir); metrics `trivy_image_vulnerabilities` (counts) and `trivy_vulnerability_id` (one series per finding with its fixed version; findings without a severity are dropped at the scrape). CVEs show in Grafana only, they do not page |
| vuln-enrich | Application `vuln-enrich` in `monitoring` (`platform/vuln-enrich/`): a daily CronJob (06:20 UTC, `enrich.py`, stdlib Python) that looks up every CVE of `trivy_vulnerability_id` in the [CISA KEV catalog](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) and the [FIRST EPSS](https://www.first.org/epss/) scores, lists the namespaces an HTTPRoute sends traffic to, and pushes `vuln_kev`, `vuln_epss_score`, `vuln_epss_percentile`, `vuln_namespace_exposed` to the backup-verify Pushgateway; recording rules `vuln:*` ([Vulnerability priority](#vulnerability-priority)) |

Manual checks: the smoke suite
([runbooks/cold-start.md](runbooks/cold-start.md#step-8-smoke-suite)), the
Argo CD application list, and `scripts/status.sh`.

`scripts/status.sh` is a read-only, one-screen view without Grafana: nodes,
etcd and the API VIP, Applications not Synced/Healthy, unhealthy pods and the
most restarted, PVCs, CNPG clusters, NAS ports, Immich asset counts,
certificates, the Gateway, HTTPRoutes and LoadBalancer addresses, backup
CronJob freshness, the WAN address against `--default-targets`, and Secrets by
name and age. It exits 1 when anything is red; `--json` prints the same data
as one document. Tested against a fake kubectl in `tests/bash/test_status.sh`.

## Looking at it

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/alerts : what would fire
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093 : what Alertmanager holds (and drops)
```

## Dashboards

JSON in `platform/kube-prometheus-stack/dashboards/`, one ConfigMap each
(label `grafana_dashboard: "1"`, loaded by the Grafana sidecar). Checked by
`tests/test_dashboards.py` (layout, `${datasource}` everywhere, PromQL parses).

| Dashboard (uid) | Shows |
| --- | --- |
| Homelab / Overview (`homelab-overview`) | the start page: links to every dashboard (a text row, plus the `homelab` tag dropdown); now: nodes Ready, alerts firing, Argo CD apps not Synced/Healthy, public probes down, stale backups, NAS pool used, fixable critical CVEs, AWS month-end estimate; 30-day availability and error budget per app with the share of the 30 days that has SLI data, 1h burn rate, probe status; hours since the last Postgres base backup and backup CronJob success; one or two figures per area (node CPU and memory, Gateway 5xx share, drops, NAS full in, LAN devices down, CI on main, open PRs, new LAN MACs, soonest certificate expiry, Immich assets, Jellyfin streams); internal endpoints, pods not Ready, restarts, certificate expiry, running image tags. Small stat panels come first so the page reads top to bottom on a phone |
| Homelab / Security (`homelab-security`) | certificate expiry, TLS version and HTTP status per hostname, Kubernetes API 401/403 rate, public endpoints answering 401/403, Keycloak failed logins and lockouts (`keycloak_user_events_total`, ServiceMonitor `keycloak/keycloak` on the management port), Secret age (names only), images without a pinned tag; the act-now findings with their fixed version, CVEs in CISA KEV and with EPSS above 0.1, the enrichment's age; fixable CVEs in running images by severity, namespace and image (trivy-operator) |
| Homelab / Usage (`homelab-usage`) | Immich photos, videos and storage, in total and per user; Sonarr/Radarr/Lidarr series, episodes, movies, music, missing and wanted, library size on disk, download queues, Prowlarr grabs per indexer; Jellyfin items per type, streams now, hours watched per user and day; which sources report. Plex, Audiobookshelf and Calibre are not covered (no stats without another app or a token) |
| Homelab / CI-CD (`homelab-cicd`) | latest run on main and success rate per GitHub workflow, run durations, open pull requests by age, Renovate automerge rate and lead time, Dependency Dashboard sections, auto-rollback pull requests, Argo CD applications not Synced/Healthy, time since each application's last successful sync |
| Homelab / Nodes (`homelab-nodes`) | per node: Talos, kernel, Kubernetes and containerd versions, Ready, uptime; saturation (CPU, memory, PSI, eMMC busy), latency (eMMC and iSCSI per operation), traffic (NIC, eMMC, iSCSI, eMMC bytes written per day), errors (NIC errors and drops, link flaps, OOM kills); SoC temperature, eMMC wear; etcd leader, database size, WAL fsync and commit p99, failed proposals, peer round trip |
| Homelab / Storage (`homelab-storage`) | NAS pools healthy, exporter up, days since the last scrub and its errors; pool used, "full in N days" at the 7-day trend, free space, used with a 30-day projection, used per dataset; disk temperatures, pool devices ONLINE, device errors, newest SMART self-test, disk models and sizes, the NAS's own alerts; iSCSI PVC usage ([NAS metrics](#nas-metrics)) |
| Homelab / LAN (`homelab-lan`) | ping status and round trip of the static devices; devices on the LAN now, randomised MACs, MACs first seen in the last 7 days, age of the last ARP scan, every MAC and IP that answered, device count over time ([LAN inventory](#lan-inventory)) |
| Homelab / Network (`homelab-network`) | Gateway requests/s, 5xx share, p50/p95/p99 duration and active connections (Envoy), HTTP status and p95 per backend namespace (Hubble); flows by verdict, destination, node and from `world`; drops by reason (Hubble and datapath) and destination, unanswered SYNs and RSTs; CoreDNS responses by code, SERVFAIL/NXDOMAIN share, duration and upstream duration; BPF map pressure, endpoints not ready, unreachable nodes |
| Homelab / Data protection (`homelab-data-protection`) | restore tests failing, stale and passing, rows compared; the last result per check and target (result, days since a pass, age of the tested backup, duration, rows, files); hours since each backup CronJob's last success, each Postgres base backup and each archived WAL; restore results over time ([backups.md](backups.md#reading-the-results)) |
| Homelab / AWS (`homelab-aws`) | cost month to date, month-end estimate, last month, yesterday, cost per day and per service; S3 bucket size per storage class and objects (CloudWatch), the backup bucket per prefix and storage class; exporter health ([AWS metrics](#aws-metrics)) |

eMMC wear comes from a sidecar (`emmc-wear`) in the node-exporter DaemonSet:
it reads `life_time` and `pre_eol_info` of every eMMC from node-exporter's
read-only `/host/sys` every 5 minutes and writes them for the textfile
collector as `node_emmc_life_time_estimate{device,type}` (1 to 11, each step
10% of rated wear) and `node_emmc_pre_eol_info{device}` (1 normal, 2 warning,
3 urgent). `NodeEmmcWearHigh` (warning) fires at step 9 or pre-EOL 2,
`NodeEmmcEndOfLife` (critical) at step 11 or pre-EOL 3. etcd is scraped on the
control-plane IPs (`kubeEtcd.endpoints`), because on Talos it is not a pod.

Not shown, and what each would need:

| Missing | Needs |
| --- | --- |
| cert-manager metrics | its ServiceMonitor carries no `release: kube-prometheus-stack` label, so Prometheus ignores it |

## AWS metrics

Argo CD Application `aws-exporter` (namespace `monitoring`) runs two
exporters with the read-only key of IAM user `homelab-metrics-reader`
(`bootstrap/aws-backup`, Secret `aws-exporter`, keys `access_key` and
`secret_key`):

| Exporter | Reads | Metrics |
| --- | --- | --- |
| YACE (chart `prometheus-yet-another-cloudwatch-exporter`, `platform/aws-exporter/values.yaml`) | CloudWatch `AWS/S3` daily storage metrics of every tagged bucket in `eu-central-1`, once an hour | `aws_s3_bucket_size_bytes_average{dimension_BucketName,dimension_StorageType}`, `aws_s3_number_of_objects_average` |
| `aws-cost-exporter` (`platform/aws-exporter/exporter.py`, Python standard library, JSON logs, port 9173) | `ListObjectsV2` of the backup bucket every 6 h; Cost Explorer `GetCostAndUsage` and `GetCostForecast` once per UTC day | `aws_s3_prefix_bytes` and `aws_s3_prefix_objects{prefix,storage_class}` (current versions, first two path segments), `aws_cost_yesterday_usd`, `aws_cost_month_to_date_usd`, `aws_cost_last_month_usd{service}`, `aws_cost_month_forecast_usd{method}` (`cost_explorer`, or `linear` from the month-to-date daily average while AWS has too little history to forecast), `aws_exporter_source_up{source}` |

Cost Explorer bills $0.01 per request: two a day, plus two per pod restart.
The CloudWatch reads cost a few cents a month. The prefix figures leave out
noncurrent versions (kept 30 days); the CloudWatch bucket size includes them.

## NAS metrics

`truenas-exporter` (`platform/truenas-exporter/exporter.py`, Python standard
library, JSON logs) reads the TrueNAS REST API v2.0 on `192.168.1.228` and
serves `truenas_*` metrics on port 9814, scraped every 60 s by ServiceMonitor
`democratic-csi/truenas-exporter`. It runs in `democratic-csi` and reads the
API key from the CSI driver's Secret `iscsi-democratic-csi-driver-config`
(key `driver-config-file.yaml`, field `httpConnection.apiKey`), so the key
exists once. TrueNAS CORE 13 API keys cannot be scoped; the exporter only
sends GETs, plus the `disk/temperatures` query, which the API exposes as POST.

| Metric | From |
| --- | --- |
| `truenas_pool_healthy`, `truenas_pool_status` | `pool`, `boot/get_state` |
| `truenas_pool_device_online`, `truenas_pool_device_errors` (`type` read, write, checksum) | each leaf device of each pool, label `role` data, cache, log, ... |
| `truenas_pool_scrub_end_timestamp_seconds`, `truenas_pool_scrub_errors` | the last scrub |
| `truenas_dataset_used_bytes`, `truenas_dataset_available_bytes` | each pool's root dataset and its direct children |
| `truenas_disk_temperature_celsius`, `truenas_disk_info`, `truenas_disk_size_bytes` | `disk`, `disk/temperatures` |
| `truenas_disk_smart_tests`, `truenas_disk_smart_last_test_success` | `smart/test/results` (absent for a disk with no self-test) |
| `truenas_alerts` (`level`, `klass`) | the NAS's own alert list, not dismissed |
| `truenas_up` | 1 when every call of the last scrape succeeded |

Recording rules `nas:pool_used:ratio` and `nas:pool_days_until_full` (7-day
linear trend) and the alerts are in PrometheusRule `homelab-nas`
(`platform/kube-prometheus-stack/routes/nas-alerts.yaml`):

| Alert | Fires when | Severity |
| --- | --- | --- |
| `NASPoolUnhealthy` | ZFS reports a pool unhealthy for 5m | `critical` |
| `NASPoolDeviceNotOnline` | a pool device is not ONLINE for 10m | `warning` |
| `NASPoolDeviceErrors` | a pool device has read, write or checksum errors | `warning` |
| `NASSmartTestFailed` | the newest SMART self-test of a disk failed | `warning` |
| `NASDiskHot` | a disk above 65 °C for 30m | `warning` |
| `NASPoolNearlyFull`, `NASPoolCriticallyFull` | a pool over 80% / 90% used | `warning` / `critical` |
| `NASPoolFillingUp` | full within 30 days at the 7-day trend, for 6h | `warning` |
| `NASScrubOverdue` | no finished scrub for 40 days | `warning` |
| `NASExporterFailing` | API calls failing for 15m while the NAS ports answer | `warning` |
| `NASExporterAbsent` | no `truenas_up` for 15m | `warning` |

The NAS's own alerts are shown, not paged: they include conditions already
known, such as its expired self-signed certificate. Tests:
`tests/test_truenas_exporter.py`, `tests/prometheus/nas_test.yaml`.

```sh
kubectl -n democratic-csi port-forward deploy/truenas-exporter 9814:9814 > /dev/null 2>&1 &
PF=$!
sleep 3
curl -s -m 30 http://localhost:9814/metrics | grep -E '^truenas_(up|pool_healthy)'
kill "$PF"
```

Expected: `truenas_up 1` and `truenas_pool_healthy{pool="..."} 1` for
`homelab` and `boot-pool`.

## LAN inventory

`lan-inventory` (`platform/lan-inventory/inventory.py`, Python standard
library, JSON logs) sends an ARP request to every address of the node's /24
every 5 minutes, twice, and records each reply: `lan_device_present{mac, ip,
random_mac}` (1 per MAC and IP that answered the last scan; `random_mac` is
the locally administered bit, set by phones and laptops with a private
address), `lan_inventory_devices`, `lan_inventory_scan_success` and
`lan_inventory_scan_timestamp_seconds`, on port 9815, scraped every 60 s by
ServiceMonitor `monitoring/lan-inventory`. ARP only reaches the LAN from a
node's own interface, so the pod runs with host networking and CAP_NET_RAW,
as root with every other capability dropped (Kubernetes grants added
capabilities to uid 0 only); `monitoring` enforces the privileged Pod
Security level. No MAC address is kept in git: the baseline is the last 30
days of Prometheus data.

PrometheusRule `homelab-lan` (`routes/lan-alerts.yaml`), evaluated every 5
minutes:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `LANNewDeviceSeen` | a fixed (vendor) MAC answers that did not answer in the 30 days before the last hour; quiet during the first day of data; resolves after an hour | `warning` |
| `LANNewRandomMACSeen` | the same for a randomised MAC: phones and laptops can rotate those, and ARP carries no hostname to recognise them by | `info` (Grafana only, no ntfy) |
| `LANInventoryFailing` | no completed scan for 30m | `warning` |
| `LANInventoryAbsent` | no `lan_inventory_devices` for 30m | `warning` |

The scan sees what answers ARP on the LAN: Cilium answers for the
LoadBalancer addresses and Talos for the API VIP, with a node's MAC. A
device that changes its private MAC (some phones rotate it per day) shows up
as new each time, which is why randomised MACs are `info`. Tests: `tests/test_lan_inventory.py`,
`tests/prometheus/lan_inventory_test.yaml`.

```sh
kubectl -n monitoring logs deploy/lan-inventory --tail=3
```

Expected: JSON lines with `"msg": "scan"`, `"ok": true` and a `devices`
count.

## Notifications

The alerts of the paging policy ([sre.md](sre.md#paging)) go as a webhook
POST to the hosted ntfy.sh topic in Secret `monitoring/alertmanager-notify` key `ntfy-url`, mounted at
`/etc/alertmanager/secrets/alertmanager-notify/ntfy-url` (`url_file`). The
topic name is the only credential: anyone who knows it can read and post, so
it is long, random and only in SOPS. Hosted ntfy.sh, not a self-hosted ntfy,
so a notification can still leave when the cluster or the NAS is in trouble.
Nothing goes to this topic from 23:00 to 08:00 Europe/Zurich
([quiet hours](sre.md#quiet-hours)). Key `ntfy-guard-url` (the same topic
plus `-guard`) gets `HomelabNodeNotReady` and `HomelabNASUnreachable` at any
hour, for the auto-rollback outage guard; do not subscribe to it.

ntfy formats the message itself: the receiver sends `X-Template: yes` and Go
templates in `X-Title`, `X-Message` and `X-Priority`
([inline templating](https://docs.ntfy.sh/publish/#message-templating)), all in
`platform/kube-prometheus-stack/values.yaml`.

| Alert | Title | Priority |
| --- | --- | --- |
| `critical` firing | `CRITICAL: <alertname> (<namespace>)` | 5 (urgent) |
| `warning` firing | `Warning: <alertname> (<namespace>)` | 4 (high) |
| resolved | `Resolved: <alertname> (<namespace>)` | 2 (low) |

The body is one `summary` per alert, plus the `description` when the batch has
one alert. A batch carries at most 5 alerts (ntfy caps a message at 4 KiB).

Subscribe: install the ntfy app, add the topic on server `ntfy.sh`. Test from
the Mac, without Alertmanager:

```sh
curl -m 10 -d "test" "https://ntfy.sh/<topic>"
# expected: a JSON line with "event":"message"; the phone shows "test"
```

Test the whole path with a synthetic slow burn of a made-up app (it resolves
after 10 minutes):

```sh
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add SLOErrorBudgetBurnSlow severity=warning app=synthetic namespace=monitoring \
  --annotation=summary="Synthetic test" --end="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
  --alertmanager.url=http://localhost:9093
# expected after the 5m group_wait: "Warning: SLOErrorBudgetBurnSlow (monitoring)"
```

Rotating the topic: a new one in `secrets.local.env` (`NTFY_TOPIC`), then
`rm platform/secrets/alertmanager-notify.sops.yaml && scripts/seal-secrets-from-env.sh`,
a pull request, and the new topic in the app.

### Heartbeat

Alertmanager sends the always-firing `Watchdog` alert every 5 minutes (route
`group_interval: 1m`, `repeat_interval: 5m`) as a webhook POST to the URL in
Secret `monitoring/alertmanager-notify` key `heartbeat-url`, mounted at
`/etc/alertmanager/secrets/alertmanager-notify/heartbeat-url` (`url_file`).
The provider alerts when the pings stop, which covers Prometheus, Alertmanager,
the cluster and the house's internet being down. While the key holds its
sentinel, every send fails: Alertmanager logs `Notify attempt failed` for
receiver `heartbeat`, and nothing else is affected.

Turning it on (one signup, then one secret edit):

1. Sign up at <https://healthchecks.io> (free tier), create a check with period
   5 minutes and grace 15 minutes, set its notification to the ntfy
   integration with the same topic as `ntfy-url` (one place for every
   notification), and copy its ping URL
   (`https://hc-ping.com/<uuid>`).
2. Put it in the Secret, then commit and open a pull request:

   ```sh
   task secrets:edit -- platform/secrets/alertmanager-notify.sops.yaml
   # replace the heartbeat-url value, save
   ```

   Or set `HEARTBEAT_URL=<ping URL>` in `secrets.local.env` and run
   `scripts/seal-secrets-from-env.sh --force`.
3. After Argo CD syncs `secrets-platform` (the mounted file follows within a
   minute or two, no restart): the check turns green within 5 minutes, and
   `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=10m | grep -c 'Notify attempt failed'`
   prints `0`.

### Routing and inhibition

Which alerts notify, how they are grouped and what they inhibit is the paging
policy in [sre.md](sre.md#paging), implemented in
`platform/kube-prometheus-stack/values.yaml`. Several pod rules join
`kube_pod_info` with `group_left(node)` so that a node going down inhibits
them (`equal: [node]`); the SLO burn alerts carry the app's `namespace`
(recording rule `slo:app:info`) and the Argo CD alerts the Application's
destination namespace, so that an app outage inhibits the cause alerts of
that namespace. Do not remove those labels.

`scripts/ci/alertmanager-test.sh` (CI, render job) tests the routing: amtool
checks the receiver of every label set in `tests/alertmanager/routes.txt`, and
each scenario in `tests/alertmanager/*.json` (the Keycloak outage, a node
down, the NAS unreachable) is replayed against a real Alertmanager with the
repository's config, counting the notifications it sends.

`Watchdog` always fires, by design: the heartbeat provider alerts when it stops
arriving, which is the only way to learn that the cluster, Alertmanager or the
house's internet is down. Never silence it.

## Vulnerability priority

trivy-operator reports every fixable CVE (thousands); most are never
exploited. The Security dashboard ranks them deterministically, from public
data, no judgement:

| Signal | Source | Meaning |
| --- | --- | --- |
| fixable | trivy-operator `ignoreUnfixed`; every finding has a `fixed_version` | an image tag can remove it |
| KEV | CISA Known Exploited Vulnerabilities, `vuln_kev` | exploited in the wild |
| EPSS | FIRST EPSS, `vuln_epss_score` | probability of exploitation activity in the next 30 days |
| exposed | an HTTPRoute backend in the namespace, `vuln_namespace_exposed` | reachable from the internet through the Gateway |

`vuln:act_now:epss` (PrometheusRule `vuln-enrich`, `platform/vuln-enrich/rules.yaml`)
is one series per finding that is fixable, exposed, and KEV or EPSS above 0.1,
with the image, package, installed and fixed version, CVE and `kev` as labels
and EPSS as the value: the "Act now" table. The headline counts (overview,
"Fixable CVEs in running images") stay the full fixable set.

The data refreshes once a day. `VulnEnrichmentStale` (warning, Grafana only)
fires when no push succeeded for 3 days. Run it now:

```sh
kubectl -n monitoring create job --from=cronjob/vuln-enrich vuln-enrich-manual
kubectl -n monitoring logs -f job/vuln-enrich-manual
# expected: {"msg": "pushed", "cves": <n>, "kev": <n>, ...}
kubectl -n monitoring delete job vuln-enrich-manual
```

Tests: `tests/test_vuln_enrich.py`, `tests/prometheus/vuln_enrich_test.yaml`.

## Argo CD alerts

Failed deploys are alerts, not GitHub issues. PrometheusRule `homelab-argocd`
(`platform/kube-prometheus-stack/routes/argocd-alerts.yaml`) reads the
application controller's metrics (ServiceMonitor
`argo/argocd-application-controller`, label `release: kube-prometheus-stack`
in `bootstrap/argocd-values.yaml`):

| Alert | Fires when | Severity |
| --- | --- | --- |
| `ArgoCDAppDegraded` | an Application is `Degraded` for 5m | `critical` |
| `ArgoCDSyncFailed` | a sync ended `Failed` or `Error` in the last 10m | `warning` |
| `ArgoCDAppOutOfSync` | an Application is `OutOfSync` for 30m | `warning` |
| `ArgoCDMetricsAbsent` | no `argocd_app_info` for 15m | `warning` |

They resolve on their own. An automatic rollback is recorded by its revert
pull request (label `auto-rollback`). The Homelab / Overview dashboard has two
annotations: `Argo CD failure` (red, while one of the first two alerts fires)
and `Argo CD recovery sync` (green, a successful sync of an app that failed in
the previous hour: the auto-rollback revert, or a fix).

Tests: `tests/prometheus/argocd_test.yaml`.

## SLOs

Each user-facing app (auth cinema theater media archive cook drive syncthing)
has one availability SLO: 99.5% of its public blackbox probes succeed over 30
days, an error budget of about 3.6 hours a month. Plain recording rules, no
SLO generator: `slo:probe_error:ratio_rate<window>`,
`slo:availability:ratio_rate30d` and `slo:error_budget_remaining:ratio_rate30d`,
all by `app`. `slo:sli_coverage:ratio_rate30d` is the share of the 30 days
that has probe results (samples over the 2,880 a day of the 30s probes):
until it reaches 100%, the 30-day figures cover a shorter window and one
outage weighs more. The overview shows it next to availability and budget.

| Alert | Fires when | Severity |
| --- | --- | --- |
| `SLOErrorBudgetBurnFast` | burn rate above 14.4x over 1h and 5m, or 6x over 6h and 30m | `critical` |
| `SLOErrorBudgetBurnSlow` | burn rate above 3x over 1d and 2h, or 1x over 3d and 6h | `warning` |
| `SLOProbesAbsent` | no `probe_success` for job `blackbox-public` for 15m | `warning` |
| `SLOTargetProbeAbsent` | no `probe_success` for one SLO target for 15m (quiet while `SLOProbesAbsent` fires) | `warning` |

Prometheus keeps `retention: 30d` capped by `retentionSize: 20GiB` on a 25Gi
volume. At about 0.55 GB of blocks a day, 30 days take about 17 GB; the rest
of the volume is for the WAL and compaction.

The rules are unit-tested: `scripts/ci/promtool-check.sh` runs `promtool check
rules` on every rendered PrometheusRule and `promtool test rules` on
`tests/prometheus/*_test.yaml` (CI, render job).

## Silencing

Silences are imperative, expire on their own, and are the tool for planned
work. Before a planned disruptive change (a database image, a node reboot, a
cutover), silence what it will break, then start:

```sh
scripts/maintenance-silence.sh keycloak 30m "PR 123: keycloak-db image"
# expected: silenced namespace=keycloak for 30m: <silence id>
scripts/maintenance-silence.sh --expire <silence id>   # when done early
# expected: expired <silence id>
```

| Target | Silences |
| --- | --- |
| `<namespace>` | every alert with that `namespace`: its pods and workloads, its Argo CD Application, the app's SLO burns |
| `node/<node>` | every alert with that `node`: `HomelabNodeNotReady`, `KubeNodeNotReady`, the pod rules of `routes/alerts.yaml` |
| `cluster` | every alert except `Watchdog`, which keeps the heartbeat alive |

The script runs `amtool silence add` inside
`alertmanager-kube-prometheus-stack-alertmanager-0` (so it needs `pods/exec`
in `monitoring`, the admin kubeconfig, not the agent's read-only one), with a
duration of 1 minute to 12 hours and the reason as the comment. The
Alertmanager UI shows and edits the same silences:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093 -> Silences
```

- Always set a duration; an indefinite silence is a deleted alert nobody
  remembers deleting.
- Match the narrowest target that works; `cluster` only for work that takes
  everything down (power, the switch, the NAS).
- A Talos or Kubernetes upgrade reboots one node at a time: one
  `node/<node>` silence per node, as each starts.

## When something looks healthy and is not

Two failure modes this cluster has had:

- A container stuck `Waiting` (`CreateContainerError`, `ImagePullBackOff`) does
  not crash-loop, so `KubePodCrashLooping` never sees it. Read `state`, not
  `lastState`, in `kubectl describe pod`. A stale containerd name reservation
  from a dead sandbox is cleared by deleting the pod (new UID, new name).
- A pod `Running 1/1` with nothing listening: the qBittorrent case
  ([runbooks/arr-qbittorrent.md](runbooks/arr-qbittorrent.md)). Only a readiness
  probe, or a check from outside like blackbox-exporter, catches it. The
  syncthing and qBittorrent LoadBalancer ports are not probed from inside: their
  network policies admit `world` only, so a pod's probe would be dropped.

## Why it is like this

- Parity first: the chart was adopted with its running values, and alerting is
  new behaviour that ships in its own changes
  ([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).
- Hosted ntfy.sh plus an external heartbeat: one person, one phone, no account
  and open source. A self-hosted ntfy was rejected for now: it would go down
  with the cluster it reports on. Pushover was the earlier plan; it needs a
  paid app per platform for the same result.
- Only symptoms and a few infrastructure criticals notify
  ([sre.md](sre.md#why-it-is-like-this)): sending every `warning` and
  `critical` sent eight notifications for one Keycloak outage.
- Credentials as mounted files, not values: nothing about the destination
  devices is in git.
- eMMC wear from sysfs through a node-exporter sidecar: Talos has no metric
  for it, and reading the file through the Talos API needs the `os:admin`
  role, which no pod should hold. The sidecar reuses node-exporter's
  read-only host mount, so it adds no privilege.
