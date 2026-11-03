# Design: autoscaling

## Overview

Three tools, each on the workloads it fits, behind CI rules that land first:

1. Repo-policy rules that keep every autoscaler above zero, on a workload
   that can run twice, and VPA from ever acting.
2. The VPA recommender with one `updateMode: "Off"` VPA per workload, its
   recommendations in Prometheus, and a script that turns them into request
   changes reviewed in pull requests.
3. HPAs on CPU for the stateless request path, once their requests are
   measured; KEDA for Immich machine learning on its job queues.

## Inventory

Checked against `deploy/`, the Helm values and the live cluster on
2026-11-03. Memory is the 7-day peak working set per pod.

### Scales

| Workload | Namespace | Autoscaler | Why it can | Peak memory |
| --- | --- | --- | --- | --- |
| `theater-sso` (oauth2-proxy) | `theater` | HPA, CPU | no volume, cookie sessions, `RollingUpdate` | 11 MiB |
| `headlamp-sso` (oauth2-proxy) | `headlamp` | HPA, CPU | same | 20 MiB |
| `hubble-sso` (oauth2-proxy) | `hubble` | HPA, CPU | same | 11 MiB |
| `headlamp` (chart) | `headlamp` | HPA, CPU | no persistence in `platform/headlamp/values.yaml`, read-only ServiceAccount | 37 MiB |
| `keycloak` | `keycloak` | HPA, CPU | state in `keycloak-db`; clustering already set (`KC_CACHE=ispn`, `KC_CACHE_STACK=kubernetes`, `-Djgroups.dns.query=keycloak`, headless Service `keycloak`) | 1.4 GiB |
| `immich-machine-learning` (chart) | `immich` | KEDA, job queue depth | stateless inference; blocked today by its `ReadWriteOnce` cache (open question 2) | 2.2 GiB |

`signoz-sso` is an oauth2-proxy too, but sits in `signoz`, which this spec
does not touch.

### Stays at one replica

| Workloads | Why |
| --- | --- |
| Immich server, Mealie, Paperless, Syncthing (StatefulSet), Home Assistant, Audiobookshelf, Calibre-Web, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, LazyLibrarian, qBittorrent, Plex, Jellyfin | `ReadWriteOnce` volume and `Recreate` strategy: a second pod cannot mount the volume |
| Zigbee2MQTT | `ReadWriteOnce` volume; 0 replicas in git until a coordinator is attached |
| Prometheus, Alertmanager, Grafana | `ReadWriteOnce` volumes; two Prometheus replicas would double the TSDB on the NAS |
| CloudNativePG clusters | a database instance count is a disaster-recovery decision (#918), not load |
| Valkey (`immich`, `paperless`), Mosquitto | state in memory; a second instance is a second, empty store or broker |
| `pushgateway` | pushed metrics live in memory; a second replica splits them |
| `aws-cost-exporter`, `github-exporter`, `truenas-exporter`, `usage-exporter`, `lan-inventory`, `subtitle-exporter`, blackbox exporter | pollers: a second replica doubles API calls and Prometheus series |
| cert-manager, external-dns, the CloudNativePG operator, `barman-cloud`, Kyverno, tuppr, the Tailscale and Trivy operators, `kubelet-serving-cert-approver`, metrics-server | controllers with leader election or a single webhook; load does not grow with replicas |
| Argo CD | stateless parts could scale; out of scope (open question 4) |
| Cilium Envoy (the shared Gateway) | a DaemonSet, `cilium-envoy`, one per node: it scales with the nodes. Issue #917 listed it as an HPA candidate; it is not one |
| Vector, Tetragon, node-exporter, the democratic-csi node plugin | DaemonSets |
| SigNoz, Vector | `signoz` and `logging`: out of scope |

## Capacity

Live on 2026-11-03 (metrics-server and Prometheus):

| Node | CPU used (of 8) | Memory used | Memory requested | Allocatable |
| --- | --- | --- | --- | --- |
| `homelab-cp-1` | 4.8 | 6.2 GiB | 2.5 GiB | 30.4 GiB |
| `homelab-cp-2` | 2.7 | 7.4 GiB | 3.2 GiB | 30.4 GiB |
| `homelab-cp-3` | 1.6 | 8.0 GiB | 4.0 GiB | 30.4 GiB |
| `homelab-w-1` | 1.4 | 7.6 GiB | 2.9 GiB | 30.5 GiB |

Requests (12.5 GiB) are under half of use (29.1 GiB) because 78 containers
request no memory. Every scaled workload at `maxReplicas` adds at most one
pod each: about 3.7 GiB at today's peaks, mostly Keycloak and Immich
machine learning. Three nodes hold 91 GiB, so the one-node-down check of
requirement 5.2 has a wide margin; it is rerun after the sizing tasks,
when requests are close to use.

eMMC: a second replica on another node pulls its image there. The large
one is the Immich machine-learning image; its compressed arm64 size is
recorded in task 12 and checked against `NodeFilesystemNearlyFull` headroom
on the node it lands on.

## Components

| Component | Change |
| --- | --- |
| `scripts/ci/repo_policy.py` | rules `autoscale-floor`, `autoscale-targets`, `vpa-recommend-only`, `vpa-coverage`, `container-requests`, over the rendered objects; tests in `tests/` |
| `clusters/homelab/platform/vpa.yaml`, `platform/vpa/values.yaml` | the `vertical-pod-autoscaler` chart of kubernetes/autoscaler, recommender only (updater and admission controller disabled), namespace `vpa` |
| `clusters/homelab/platform/keda.yaml`, `platform/keda/values.yaml` | the `keda` chart of kedacore, namespace `keda`, no HTTP add-on, one replica of the operator, the metrics API server and the webhooks |
| `clusters/homelab/bootstrap/project-platform.yaml` | `clusterResourceWhitelist`: `APIService` (KEDA, `v1beta1.external.metrics.k8s.io`), each line with its reason; CRDs, ClusterRoles and webhooks are already listed |
| `infrastructure/namespaces/namespaces.yaml` | namespaces `vpa` and `keda`, PSA `restricted` |
| `ci/schemas/`, `ci/crd-scopes.txt` | the VPA and KEDA CRD schemas for kubeconform and the AppProject check |
| VPA objects | one per Deployment and StatefulSet, next to the workload's manifests (`<app>/vpa.yaml`, or the `resources` path of a chart app) |
| `platform/kube-prometheus-stack/values.yaml` | `kube-state-metrics.customResourceState`: the VPA recommendations as `kube_vpa_recommendation_target` and `kube_vpa_recommendation_upper_bound{namespace, verticalpodautoscaler, container, resource}`, plus the RBAC rule to list VPAs |
| `scripts/vpa-requests.sh` | the sizing table of requirement 4.1, from Prometheus |
| Grafana, Homelab / Automation | panels: replicas per scaled workload, KEDA and VPA component health (INFO) |
| HPAs | next to each workload: `apps/theater/`, `platform/headlamp/resources/`, `platform/hubble-access/`, `platform/keycloak/` |
| `apps/immich/values.yaml`, `apps/immich/resources/` | the machine-learning cache volume (open question 2), the ScaledObject |

## Decisions

| Decision | Rejected | Why |
| --- | --- | --- |
| `minReplicas` / `minReplicaCount` at least 1 | scale to zero with the KEDA HTTP add-on | the operator's decision: seconds of delay on the first request to save a few hundred MiB; the blackbox probes would also keep idle apps awake |
| VPA `updateMode: "Off"`, recommender only | `Auto` or `InPlaceOrRecreate` | changing requests restarts `Recreate` pods outside a pull request and outside the weekday window; sizing stays a reviewed diff ([decisions.md](../../../docs/decisions.md#main-is-production)) |
| Recommendations into requests by a script, in a pull request | an agent picks numbers | deterministic first; the same pattern as the latency thresholds ([sre.md](../../../docs/sre.md#latency)) |
| VPA history from metrics-server and its checkpoints | Prometheus as the history provider | no extra configuration or Prometheus load; 8 days of history before any change is enough for the decaying histograms |
| HPA on CPU only | memory | the scaled workloads are request-bound; memory grows with caches and would never scale back in |
| `maxReplicas: 2` | 3 or more | the nodes hold it with one node down, and no workload here has needed more than one |
| KEDA for Immich machine learning on queue depth | an HPA on its CPU | ML CPU lags the queue; the queue says when a scan starts and when it ends |
| One autoscaler per Deployment | KEDA and an HPA on the same target | KEDA creates its own HPA; two HPAs on one target fight |
| `spec.replicas` dropped from git for scaled workloads | `ignoreDifferences` everywhere | the object in git then says what the cluster runs; `ignoreDifferences` only for chart targets whose chart always renders `replicas` |
| No new page | a page when KEDA or VPA is down | a failed autoscaler leaves the replica counts as they are, which is today's state ([sre.md](../../../docs/sre.md#paging)); open question 5 |
| HPAs on CPU before KEDA | KEDA for everything | plain HPA needs no extra component; KEDA only where the signal is not CPU |
| KEDA and VPA in the platform layer | infrastructure | they need metrics-server (infrastructure) and serve workloads of the apps layer; nothing in a cold start waits for them |

## Error handling

- VPA recommender down: recommendations stop updating; nothing else
  changes. The report script flags a VPA whose status is older than 24 h.
- KEDA operator or metrics API server down: KEDA's HPA keeps the last
  replica count; `fallback.replicas: 1` applies once the trigger has failed
  3 times. An unavailable `external.metrics.k8s.io` APIService makes
  `kubectl` warn on discovery; it does not block other API calls.
- A scaled pod Pending (no room): the HPA keeps trying; `PodPendingTooLong`
  is INFO and the first replica keeps serving.
- A requests change that breaks an app: the PostSync smoke or the degraded
  sync triggers the automatic rollback, as for any merge
  ([decisions.md](../../../docs/decisions.md#automatic-rollback)).
- Keycloak with two replicas that do not form one Infinispan cluster:
  sessions split between pods; the task 10 check fails and the HPA is
  reverted.

## Verification

- Requirements 1, 2, 3.1 to 3.3, 4.3, 5.1: the repo-policy rules in CI, each
  with a passing and a failing fixture.
- Requirement 3.4: recorded check in task 3, one series per covered
  container.
- Requirement 4.1: `tests/bash/test_vpa_requests.sh` on a fixed Prometheus
  response.
- Requirements 5.2, 6.1, 6.2, 8.1, 8.3: recorded checks in tasks.md.
- Requirement 7: recorded in each pull request that adds an image.
- Requirement 8.2: `scripts/ci/alertmanager-test.sh` unchanged and green.

## Research note: cloud-burst nodes

Not a requirement, and no task. Running pods on cloud nodes when the four
RK1s are full could take two shapes:

- A Talos node in a cloud, joined to this cluster over KubeSpan (WireGuard).
  It would need an arm64 instance type (the images are arm64), a node label
  and taint so only stateless workloads land there, and a way to add and
  remove it (a cluster autoscaler or a scheduled OpenTofu apply).
- A separate cluster in the cloud, which shares nothing with this one.

Limits: the data stays on the NAS, and iSCSI or NFS over the WAN is not an
option, so only the stateless workloads of the inventory could move, and
they use under 4 GiB at their peak. Pods on that node would reach Keycloak,
the databases and the Gateway over the house uplink, and the cluster would
gain a node outside the house, in a cloud account. At today's load (29 GiB used
of about 122 GiB) there is no case for it. If it becomes one, it is its own
`type/research` issue.
