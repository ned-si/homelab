# Design: autoscaling

## Overview

High availability first, then autoscaling on top of it, behind CI rules that
land first:

1. An HA inventory in `ci/ha-inventory.yaml` and repo-policy rules that
   hold every workload to its class: replicas, spread, disruption budget,
   and every autoscaler above zero on a workload that can run twice.
2. Two replicas for each HA-capable workload, with Keycloak as one
   Infinispan cluster and a streaming replica for the CloudNativePG
   clusters.
3. The VPA recommender with one `updateMode: "Off"` VPA per workload, its
   recommendations in Prometheus, and a script that turns them into request
   changes reviewed in pull requests.
4. HPAs on CPU for the stateless request path, floor 2; KEDA, installed
   with the HA work, for Immich machine learning on its job queues.

## Cost and benefit

Measured on 2026-11-03, read-only: `kubectl top nodes`, `kubectl describe
node` (requests), Prometheus `node_memory_MemAvailable_bytes`,
`container_memory_working_set_bytes` (7-day peaks),
`node_filesystem_avail_bytes{mountpoint="/var"}` and `probe_success`.

### Nodes today

| Node | CPU used (of 8) | Memory used | Memory requested | Available now | Available, 7-day low | `/var` free |
| --- | --- | --- | --- | --- | --- | --- |
| `homelab-cp-1` | 1.7 | 5.9 GiB | 2.5 GiB | 24.5 GiB | 20.0 GiB | 8.9 GiB |
| `homelab-cp-2` | 2.4 | 7.2 GiB | 3.2 GiB | 22.2 GiB | 21.4 GiB | 8.8 GiB |
| `homelab-cp-3` | 1.5 | 8.0 GiB | 4.0 GiB | 23.8 GiB | 21.0 GiB | 12.7 GiB |
| `homelab-w-1` | 1.5 | 7.8 GiB | 2.9 GiB | 23.7 GiB | 22.5 GiB | 11.3 GiB |
| Total | 7.1 of 32 | 28.9 GiB | 12.6 GiB | 94.2 GiB | 84.9 GiB | |

Allocatable is 30.4 GiB per node, 121.7 GiB in all. Requests (12.6 GiB) are
under half of use because 78 containers request no memory; the sizing tasks
fix that.

### What HA adds

7-day peak working set of the pod each addition copies. NAS is new iSCSI
storage on the TrueNAS pool.

| Addition | Memory | NAS |
| --- | --- | --- |
| A second Keycloak | 1411 MiB | none |
| A replica of `keycloak-db` | 109 MiB | 5 GiB |
| A replica of the six app databases (`home-assistant`, `mealie`, `sonarr`, `radarr`, `lidarr`, `prowlarr`) | 883 MiB | 30 GiB |
| A second oauth2-proxy for `theater`, `headlamp`, `hubble` | 42 MiB | none |
| A second Headlamp, Hubble UI and Hubble Relay | 183 MiB | none |
| Argo CD: a second server, repo-server and ApplicationSet controller | 376 MiB | none |
| Controllers: cert-manager (3), Kyverno (3), metrics-server, democratic-csi controller, CloudNativePG operator | 878 MiB | none |
| Alertmanager, blackbox exporter | 91 MiB | none |
| Subtotal | 3973 MiB (3.9 GiB) | 35 GiB |
| A second Immich machine learning | 2395 MiB | none (cache: open question 1) |
| Total | 6368 MiB (6.2 GiB) | 35 GiB |

KEDA and the VPA recommender are new components, not copies; their memory
requests together stay under 1 GiB (requirement 11.2).

Against the nodes: 6.2 GiB is 7% of the 94.2 GiB available now, and 7% of
the 84.9 GiB sum of the 7-day lows. With one node down, the other three
keep at least 62 GiB available at their lows; the lost node's pods (at
most 8.0 GiB) and every addition fit with more than 45 GiB left. Memory is
not what limits HA here. The eMMC is tighter: a replica on a new node pulls
its image to that node's `/var`, which has 8.8 GiB free on the fullest
node; requirement 11.3 records each large image and keeps 5 GiB free.

### What HA buys on four nodes and one NAS

It covers the loss of one pod or one node:

- A node drained: tuppr drains each node in turn for every Talos and
  Kubernetes upgrade. Today each drain restarts every app on that node.
  No node rebooted or was cordoned in the 14 days before 2026-11-03
  (`changes(node_boot_time_seconds[14d])` and
  `changes(kube_node_spec_unschedulable[14d])` are 0 on all four).
- A node lost (crash, eMMC failure): a pod with a `ReadWriteOnce` iSCSI
  volume waits until the volume detaches, 6 minutes by default unless the
  node gets the `node.kubernetes.io/out-of-service` taint. A second replica
  without a volume keeps serving; a CloudNativePG replica on its own volume
  is promoted.
- A pod that crashes or runs out of memory, and every rolling update.

It does not cover the NAS (every `ReadWriteOnce` volume, and both instances
of each database, live on it), the Turing Pi 2 board and its power supply
(shared by all four nodes), power, the router or the uplink.

The probes show where downtime comes from. Over the 14 days before
2026-11-03, `count_over_time` of failed public probes at one-minute steps:

| App | Minutes failing | Of which every app failed at once | App only |
| --- | --- | --- | --- |
| `auth` | 169 | 155 | 14 |
| `media` | 167 | 155 | 12 |
| `cook` | 162 | 155 | 7 |
| `theater` | 162 | 155 | 7 |
| `home` | 173 | 155 | 18 |

The 155 shared minutes (WAN, router or Gateway; #915) are out of reach of
pod-level HA. Of the app-only minutes, only `auth` has a request path that
becomes fully HA under this spec. So HA buys little measured availability
today. What it buys is drains, upgrades and deploys of the login path,
the SSO proxies, the operator UIs and the cluster controllers without an
outage, and a database that survives its node.

### Recommendation

HA wherever the cost is in the table above, which is every capable
workload but two; the exclusions are justified in the last column.

| Workload | Class | Recommendation | Extra memory | Why |
| --- | --- | --- | --- | --- |
| `keycloak` | active-active | 2 to 3 (HPA) | 1411 MiB | every SSO login and token refresh; clustering already configured |
| `keycloak-db` | active-passive | `instances: 2` | 109 MiB, 5 GiB NAS | Keycloak's only state: two Keycloak pods on one database still stop with it |
| `theater-sso`, `headlamp-sso`, `hubble-sso` | active-active | 2 to 3 (HPA) | 42 MiB | cookie sessions signed with one shared secret, no server-side state |
| `headlamp` | active-active | 2 to 3 (HPA) | 36 MiB | no persistence, read-only ServiceAccount |
| `hubble-ui`, `hubble-relay` | active-active | 2 | 147 MiB | stateless; Relay reads every agent |
| `argocd-server`, `argocd-repo-server` | active-active | 2 | 308 MiB | stateless, share Redis |
| `argocd-applicationset-controller` | active-passive | 2, leader election | 68 MiB | `applicationsetcontroller.enable.leader.election` is `false` today |
| cert-manager controller, cainjector; webhook | active-passive; active-active | 2 each | 187 MiB | leader election; the webhook is stateless |
| Kyverno admission controller; reports and cleanup controllers | active-active; active-passive | 2 each | 434 MiB | every admission request goes through it |
| `metrics-server` | active-active | 2 | 43 MiB | the HPAs read it |
| CloudNativePG operator | active-passive | 2 | 114 MiB | leader election; failover needs it |
| democratic-csi controller | active-passive | 2 | 100 MiB | provisioning and attach; leader election of its CSI sidecars checked in task 9 |
| KEDA operator; metrics API server | active-passive; active-active | 2 each | new, under 1 GiB with VPA | leader election; the API server replicas share the load |
| Alertmanager | active-active | 2 | 63 MiB | gossip cluster deduplicates notifications; a silence survives a pod restart (storage is an `emptyDir` today) |
| `blackbox-exporter` | active-active | 2 | 28 MiB | the probes measure the SLOs |
| App databases: `home-assistant`, `mealie`, `sonarr`, `radarr`, `lidarr`, `prowlarr` | active-passive | `instances: 2` | 883 MiB, 30 GiB NAS | the apps stay at one replica, but the database no longer restarts with its node, and backups run from the standby; small cost |
| `immich-machine-learning` | active-active | 2 to 3 (KEDA) | 2395 MiB | the largest item; open question 5 |
| `immich-db` | active-passive | excluded, 1 | (342 MiB, 5 GiB NAS) | Immich server stays at one replica, so a replica keeps nothing up; the pinned image is under the hard rule (changes through a spec, with a fresh backup) and its SELinux relabel is pending |
| Prometheus | active-active | excluded, 1 | (5033 MiB, 40 GiB NAS) | an empty TSDB on the second replica pages falsely on 30-day windows for 30 days; open question 4 |

## Inventory

Checked against `deploy/`, the Helm values and the live cluster on
2026-11-03. The HA-capable workloads are in the recommendation above; the
rest stay at one replica.

### Apps that cannot run twice

| Workload | Why | What would make it possible |
| --- | --- | --- |
| `immich-server` | the 2 TiB library `immich-data` is `ReadWriteOnce` | Immich runs several server processes given a shared library, so the library on a `ReadWriteMany` volume (NFS); a one-way move of the photo library, its own spec |
| Valkey (`immich`, `paperless`) | job queue and Celery broker in memory; a second instance is a second, empty store | Valkey with Sentinel (three sentinels) and Sentinel-aware clients; not worth it for a queue that refills |
| `paperless` | SQLite on `paperless-data`; one container runs the web server, worker, scheduler and consumer | PostgreSQL (a CloudNativePG cluster), the media on `ReadWriteMany`, and the web server split from the worker |
| `mealie` | data directory (images, backups) on a 100Gi `ReadWriteOnce` volume; the database is already PostgreSQL | the data directory on `ReadWriteMany`, if upstream supports more than one instance (not documented) |
| `home-assistant` | one instance by design; the recorder is already on PostgreSQL | nothing upstream |
| `mosquitto` | the open-source broker has no clustering | a broker with clustering |
| `zigbee2mqtt` | one USB coordinator; 0 replicas until it is attached | nothing |
| `syncthing` | device identity and index database per instance; a second pod is a second device | nothing |
| `audiobookshelf`, `calibre-web`, `lazylibrarian` | SQLite on a `ReadWriteOnce` volume | nothing upstream |
| `sonarr`, `radarr`, `lidarr`, `prowlarr` | already on PostgreSQL, but the scheduler and command queue run in-process with no coordination between instances; `/config` is `ReadWriteOnce` | nothing upstream |
| `bazarr` | SQLite here; PostgreSQL is supported, but the scheduler is in-process too | nothing upstream |
| `qbittorrent` | session state per client, one seeding IP (`.200`) | nothing |
| `plex`, `jellyfin` | SQLite library database, one server per library | nothing upstream |

### Platform that stays at one replica

| Workload | Why | What would make it possible |
| --- | --- | --- |
| Grafana | SQLite on a 1Gi `ReadWriteOnce` volume; no SLO | a PostgreSQL database (a CloudNativePG cluster) |
| Argo CD application controller | replicas shard by cluster, and there is one cluster | nothing; a restart resumes reconciliation |
| `argocd-redis` | a cache; HA is the `redis-ha` chart, three Redis and three HAProxy pods | not worth it for a cache |
| `argocd-notifications-controller` | one replica, no leader election; a restart delays an auto-rollback dispatch | nothing upstream |
| `argocd-dex-server` | unused: login goes to Keycloak through `oidc.config` | removal, #969 |
| external-dns | no leader election (its chart caps replicas at 1); records stay at Cloudflare while it restarts | nothing upstream |
| kube-prometheus-stack operator, kube-state-metrics | the operator runs one replica; a second kube-state-metrics doubles every series | sharding, not HA |
| `pushgateway` | pushed metrics live in memory; a second replica splits them | nothing |
| `aws-cost-exporter`, `github-exporter`, `truenas-exporter`, `usage-exporter`, `lan-inventory`, `subtitle-exporter`, `yace` | pollers: a second replica doubles API calls and series | nothing needed |
| `barman-cloud` | more than one replica not verified; WAL archiving retries while it restarts | an upstream statement that it supports replicas |
| tuppr, Trivy operator and server, Tetragon operator, `kubelet-serving-cert-approver` | background controllers off the request path; a restart delays their work by seconds | nothing needed |
| Tailscale operator | one replica; it also serves the Kubernetes API proxy, so a restart interrupts `kubectl` | a `ProxyGroup` for the API proxy with replicas, to verify upstream |

Already HA and unchanged: the Kubernetes API (three control planes, the
Talos VIP, etcd 3/3), CoreDNS (2), the Cilium operator (2), the Tailscale
exit node (2), and the Gateway: Cilium Envoy runs on every node, and the
L2 lease that announces `192.168.1.254` moves to another node when its
holder goes (Cilium's default lease of 15 s). Issue #917 listed Envoy as an
HPA candidate; as a DaemonSet it is not one.

## Components

| Component | Change |
| --- | --- |
| `ci/ha-inventory.yaml` | one entry per workload: kind, namespace, name, class, reason, `enabler` for `none`, `excluded`, `pending`, `hpa` |
| `scripts/ci/repo_policy.py` | rules `ha-inventory`, `ha-replicas`, `autoscale-floor`, `autoscale-targets`, `vpa-recommend-only`, `vpa-coverage`, `container-requests`, over the rendered objects; tests in `tests/` |
| PodDisruptionBudgets, topology spread | next to each HA workload's manifests, or the chart's values (`podDisruptionBudget`, `topologySpreadConstraints`, `replicas`) |
| `platform/keycloak/` | HPA, PDB, spread, `spec.replicas` out of git; the cache settings unchanged |
| CloudNativePG clusters | `instances: 2`, `affinity.podAntiAffinityType: required` |
| `bootstrap/argocd-values.yaml` | `server.replicas: 2`, `repoServer.replicas: 2`, `applicationSet.replicas: 2` with leader election on, PDBs |
| `infrastructure/cert-manager/`, `infrastructure/kyverno/`, `infrastructure/metrics-server/`, `infrastructure/democratic-csi/`, `infrastructure/cilium/values.yaml` (Hubble) | replicas, PDBs and spread through chart values |
| `platform/cloudnative-pg/values.yaml`, `platform/kube-prometheus-stack/values.yaml` | the operator at 2; Alertmanager and the blackbox exporter at 2 |
| `clusters/homelab/platform/vpa.yaml`, `platform/vpa/values.yaml` | the `vertical-pod-autoscaler` chart of kubernetes/autoscaler, recommender only, namespace `vpa` |
| `clusters/homelab/platform/keda.yaml`, `platform/keda/values.yaml` | the `keda` chart of kedacore, namespace `keda`, no HTTP add-on, 2 replicas of the operator and the metrics API server |
| `clusters/homelab/bootstrap/project-platform.yaml` | `clusterResourceWhitelist`: `APIService` (KEDA, `v1beta1.external.metrics.k8s.io`), with its reason |
| `infrastructure/namespaces/namespaces.yaml` | namespaces `vpa` and `keda`, PSA `restricted` |
| `ci/schemas/`, `ci/crd-scopes.txt` | the VPA and KEDA CRD schemas for kubeconform and the AppProject check |
| VPA objects | one per Deployment and StatefulSet, next to the workload's manifests |
| `platform/kube-prometheus-stack/values.yaml` | `kube-state-metrics.customResourceState`: `kube_vpa_recommendation_target` and `kube_vpa_recommendation_upper_bound{namespace, verticalpodautoscaler, container, resource}`, plus the RBAC rule to list VPAs |
| `scripts/vpa-requests.sh` | the sizing table of requirement 8.1, from Prometheus |
| Grafana, Homelab / Automation | panels: replicas per HA workload, KEDA and VPA component health (INFO) |
| `apps/immich/values.yaml`, `apps/immich/resources/` | the machine-learning cache volume (open question 1), the ScaledObject |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| HA where the app supports it; `none` documented with its enabler | shared volumes to force HA on every app | the operator's direction; a standby sharing a `ReadWriteOnce` iSCSI volume cannot run on another node, and SQLite apps are single-writer |
| `whenUnsatisfiable: DoNotSchedule` | `ScheduleAnyway` | two replicas on one node do not survive that node; four nodes leave room for two pods, three during a rolling update, with one node down |
| PDB `maxUnavailable: 1` on HA workloads only | `minAvailable: 1` everywhere | on a one-replica workload it blocks tuppr's drain |
| Keycloak on the JGroups `kubernetes` stack, already configured | `jdbc-ping`, Keycloak's default since 26.1 | the operator's direction; Keycloak 26.x deprecates the `kubernetes` stack, so the move is #968, and a release that removes it fails the 2-member check of task 8 |
| CloudNativePG asynchronous replication | synchronous (`synchronous.number: 1`) | with one replica, a synchronous commit waits on it; failover loses at most the replica's lag, and WAL is archived to S3 |
| `immich-db` and Prometheus excluded | HA everywhere | the reasons in the recommendation; open question 4 for Prometheus |
| Argo CD: server, repo-server, ApplicationSet controller at 2; the rest at 1 | the `redis-ha` chart and controller sharding | about 0.4 GiB buys the UI and rendering; six more pods for a cache is not cheap |
| `minReplicas` / `minReplicaCount` 2, `maxReplicas` 3 | scale to zero with the KEDA HTTP add-on; a floor of 1 | the operator's decisions: HA floor 2, no scale to zero; 3 fits with one node down |
| VPA `updateMode: "Off"`, recommender only | `Auto` or `InPlaceOrRecreate` | changing requests restarts `Recreate` pods outside a pull request and outside the weekday window; sizing stays a reviewed diff ([decisions.md](../../../docs/decisions.md#main-is-production)) |
| Recommendations into requests by a script, in a pull request | an agent picks numbers | deterministic first; the same pattern as the latency thresholds ([sre.md](../../../docs/sre.md#latency)) |
| CPU requests of the HA tasks from 7-day peaks | waiting 8 days of VPA history | the HPAs need a CPU request now; the sizing tasks refine them |
| VPA history from metrics-server and its checkpoints | Prometheus as the history provider | no extra configuration or Prometheus load; 8 days of history before any change |
| HPA on CPU only | memory | the scaled workloads are request-bound; memory grows with caches and would never scale back in |
| KEDA installed with the HA work, for Immich machine learning on queue depth | waiting for a second target; an HPA on its CPU | the operator's decision; ML CPU lags the queue |
| One autoscaler per Deployment | KEDA and an HPA on the same target | KEDA creates its own HPA; two HPAs on one target fight |
| `spec.replicas` dropped from git for scaled workloads | `ignoreDifferences` everywhere | the object in git then says what the cluster runs; `ignoreDifferences` only where a chart always renders `replicas` |
| No new page | a page when KEDA or VPA is down | a failed autoscaler leaves the replica counts as they are ([sre.md](../../../docs/sre.md#paging)); open question 2 |
| KEDA and VPA in the platform layer | infrastructure | they need metrics-server (infrastructure) and serve the apps layer; nothing in a cold start waits for them |

## Error handling

- One replica of an HA workload down: the other serves; the PDB keeps a
  drain from taking both.
- Keycloak pods that do not form one Infinispan cluster: sessions split
  between pods; the task 8 check fails and the change is reverted.
- A CloudNativePG primary lost: the operator promotes the replica; the
  app's `-rw` Service follows. Both lost (the NAS): restore from S3, #918.
- VPA recommender down: recommendations stop updating; the report script
  flags a VPA whose status is older than 24 h.
- KEDA operator or metrics API server down: KEDA's HPA keeps the last
  replica count; `fallback.replicas: 2` applies once the trigger has failed
  3 times.
- A pod Pending (no room or no node for the spread): the other replica
  keeps serving; `PodPendingTooLong` is INFO.
- A change that breaks an app: the PostSync smoke or the degraded sync
  triggers the automatic rollback, as for any merge
  ([decisions.md](../../../docs/decisions.md#automatic-rollback)).

## Verification

- Requirements 1, 2.1 to 2.4, 4.1, 5, 6, 7.1 to 7.3, 8.3, 9.1: the
  repo-policy rules in CI, each with a passing and a failing fixture.
- Requirements 2.5, 3.2, 3.3, 4.2, 9.2, 10.1, 10.2, 12.1, 12.3: recorded
  checks in tasks.md.
- Requirement 7.4: recorded check in task 3, one series per covered
  container.
- Requirement 8.1: `tests/bash/test_vpa_requests.sh` on a fixed Prometheus
  response.
- Requirements 4.3, 11: recorded in each pull request that adds a replica
  or an image.
- Requirement 12.2: `scripts/ci/alertmanager-test.sh` unchanged and green.

## Research note: cloud-burst nodes

Not a requirement, and no task. Running pods on cloud nodes when the four
RK1s are full could take two shapes:

- A Talos node in a cloud, joined to this cluster over KubeSpan (WireGuard).
  It would need an arm64 instance type (the images are arm64), a node label
  and taint so only stateless workloads land there, and a way to add and
  remove it (a cluster autoscaler or a scheduled OpenTofu apply).
- A separate cluster in the cloud, which shares nothing with this one.

Limits: the data stays on the NAS, and iSCSI or NFS over the WAN is not an
option, so only the stateless workloads could move. Pods on that node
would reach Keycloak, the databases and the Gateway over the house uplink,
and the cluster would gain a node outside the house, in a cloud account.
At today's load (29 GiB used of about 122 GiB, 6.2 GiB more with HA) there
is no case for it. If it becomes one, it is its own `type/research` issue.
