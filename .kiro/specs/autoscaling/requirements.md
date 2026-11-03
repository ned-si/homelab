---
kind: change
status: active
created: 2026-11-03
issue: 917
---
# Requirements: autoscaling

## Introduction

Every workload runs one replica, and most hold a `ReadWriteOnce` volume on
the one NAS ([architecture.md](../../../docs/architecture.md#cluster)). Requests
were set by hand: on 2026-11-03, 78 of the 252 containers Prometheus knew
(Job pods included) had no memory request. This spec adds three things, each
where it fits:

- VPA in recommend-only mode, so requests come from measured usage.
- HPA on CPU for the stateless workloads.
- KEDA for event-driven scaling of what can scale on events.

The operator decided these on 2026-11-02 and they are fixed here. No
workload scales to zero: it adds seconds of delay to the first request to
save a few hundred MiB.

The expected effect at today's load is small. The four nodes use about
29 GiB of their 122 GiB allocatable memory, and the stateless workloads that
can scale are the oauth2-proxies (under 20 MiB each), Headlamp, Keycloak and
Immich machine learning ([design.md: Inventory](design.md#inventory)). The main gain is
right-sized requests, and the mechanism being in place and tested before a
workload needs it.

Constraints, from [tech.md](../../steering/tech.md#constraints) and the
cluster:

- Single replica everywhere today; most volumes are `ReadWriteOnce` on one
  NAS, so a second replica of those workloads cannot mount its volume.
- arm64 only: every image must publish an arm64 variant.
- 4 Turing RK1 nodes, 32 GB RAM each (30.4 GiB allocatable), 29 GB of eMMC
  each. eMMC is the scarce part: images and `emptyDir` volumes live on it.
- Changes that can break an app merge Monday to Friday, in the daytime
  (Zurich).

Non-goals:
- Scale to zero, the KEDA HTTP add-on, or any scale-from-zero proxy.
- VPA modes that act (`Initial`, `Recreate`, `InPlaceOrRecreate`, `Auto`),
  the VPA updater and admission controller.
- More than one replica of a workload bound to a `ReadWriteOnce` volume
  (Immich server, the *arr apps, Plex, Jellyfin, Paperless, Mealie,
  Syncthing, Home Assistant, the books apps, Prometheus, Grafana).
- CloudNativePG sizing and instance counts (a database restart; disaster
  recovery is #918).
- DaemonSets (Cilium and its Envoy, Vector, Tetragon, node-exporter): they
  scale with the nodes.
- Anything in the namespaces `signoz` and `logging`, and the observability
  direction (#801), which is parked.
- Adding nodes, a cluster autoscaler or cloud nodes. Cloud bursting is a
  research note in [design.md](design.md#research-note-cloud-burst-nodes),
  not a requirement.

## Glossary

- **Autoscaler**: a `HorizontalPodAutoscaler` (HPA) or a KEDA
  `ScaledObject`, which creates its own HPA.
- **Scaled workload**: a Deployment that an autoscaler targets.
- **Recommendation**: the `target`, `lowerBound` and `upperBound` a
  `VerticalPodAutoscaler` (VPA) writes into its status, per container.
- **Rendered objects**: `deploy/` plus the Helm apps CI renders
  (`scripts/ci/render_apps.py`), the same scope as the Kyverno check.

## Requirements

### Requirement 1: No workload scales to zero

**User story:** As a household member, I want every app to answer the first
request at once, so no page load waits for a pod to start.

#### Acceptance criteria

1. EVERY HPA SHALL set `minReplicas` of at least 1, and EVERY ScaledObject
   SHALL set `minReplicaCount` of at least 1 explicitly (KEDA's default is
   0) and no `idleReplicaCount`. (repo-policy `autoscale-floor`)
2. THE rendered objects SHALL contain no object of the API group
   `http.keda.sh` (the HTTP add-on). (repo-policy `autoscale-floor`)

### Requirement 2: Only workloads that can run twice scale

**User story:** As the operator, I want an autoscaler only where a second
replica can start, so scaling never leaves a pod Pending on a volume or
fights Argo CD.

#### Acceptance criteria

1. THE target of every autoscaler SHALL be a Deployment that mounts no
   `ReadWriteOnce` PersistentVolumeClaim, does not use the `Recreate`
   strategy, sets a CPU request on every container, and is not in the
   namespaces `signoz` or `logging`. (repo-policy `autoscale-targets`)
2. A Deployment SHALL be the target of at most one autoscaler.
   (repo-policy `autoscale-targets`)
3. WHILE an autoscaler owns a Deployment, THE Deployment SHALL NOT set
   `spec.replicas` in git, or its Application SHALL ignore `/spec/replicas`
   for it, so a sync does not reset the replica count.
   (repo-policy `autoscale-targets`)
4. EVERY scaled workload SHALL spread its pods across nodes
   (`topologySpreadConstraints` on `kubernetes.io/hostname`, `maxSkew: 1`,
   `whenUnsatisfiable: ScheduleAnyway`). (repo-policy `autoscale-targets`)

### Requirement 3: VPA recommends and never acts

**User story:** As the operator, I want recommendations for every workload
without anything evicting or rewriting pods, so sizing stays a reviewed pull
request.

#### Acceptance criteria

1. THE VPA installation SHALL run the recommender only: the rendered
   objects SHALL contain no VPA updater and no VPA admission controller.
   (repo-policy `vpa-recommend-only`)
2. EVERY VerticalPodAutoscaler SHALL set `updatePolicy.updateMode: "Off"`.
   (repo-policy `vpa-recommend-only`)
3. EVERY Deployment and StatefulSet of the apps and platform layers SHALL
   be the target of one VPA, except in the namespaces `signoz` and
   `logging`. (repo-policy `vpa-coverage`)
4. THE recommendations SHALL be in Prometheus, per namespace, VPA,
   container and resource, for `target` and `upperBound`.
   (kube-state-metrics `customResourceState`; recorded check in tasks.md:
   one series per covered container)

### Requirement 4: Requests come from measured usage

**User story:** As the operator, I want requests set from what the
workloads use, so scheduling and HPA percentages mean something.

#### Acceptance criteria

1. THE script `scripts/vpa-requests.sh` SHALL print, per container, the
   current CPU and memory request and memory limit, the VPA target and
   upper bound, and the proposed values: request = target rounded up (CPU
   to 10m, memory to 16Mi), memory limit = the larger of the current limit
   and twice the upper bound, rounded up to 64Mi; no CPU limit.
   (`tests/bash/test_vpa_requests.sh`)
2. A change to a container's requests or limits made under this spec SHALL
   be a pull request that carries the script's output, and only for a
   container whose VPA has at least 8 days of history.
   (recorded in each pull request)
3. WHEN the sizing tasks are done, EVERY container of the apps and platform
   layers, except in `signoz` and `logging`, SHALL have a CPU request, a
   memory request and a memory limit. (repo-policy `container-requests`)

### Requirement 5: HPA scales the stateless workloads on CPU

**User story:** As the operator, I want the stateless request path to add a
replica under load, without growing past what the nodes hold.

#### Acceptance criteria

1. EACH workload classed `hpa` in the inventory SHALL have an
   `autoscaling/v2` HPA with `minReplicas: 1`, `maxReplicas: 2`, a CPU
   utilization target of 80% of the request and a scale-down stabilization
   window of 300 s. (repo-policy `autoscale-targets`, kubeconform)
2. WHEN every scaled workload is at `maxReplicas`, THE sum of the memory
   requests in the cluster SHALL fit in the allocatable memory of three
   nodes (one node down). (recorded check in tasks.md, from
   `kube_pod_container_resource_requests` and
   `kube_node_status_allocatable`)

### Requirement 6: KEDA scales on events

**User story:** As the operator, I want a workload that serves a queue to
follow the length of that queue, not its CPU.

#### Acceptance criteria

1. THE KEDA operator and its metrics API server SHALL run in the namespace
   `keda` in the platform layer, one replica each, and serve
   `external.metrics.k8s.io`. (recorded check:
   `kubectl get apiservice v1beta1.external.metrics.k8s.io` is `Available`)
2. THE Immich machine-learning Deployment SHALL scale between 1 and 2
   replicas on the depth of the Immich job queues that call it, through one
   ScaledObject. (repo-policy `autoscale-targets`; recorded check in
   tasks.md: a library scan moves it to 2 and back to 1)
3. IF a ScaledObject's trigger fails 3 times in a row, THEN KEDA SHALL hold
   the workload at 1 replica (`fallback.replicas: 1`).
   (repo-policy `autoscale-floor`)

### Requirement 7: It fits the hardware

**User story:** As the operator, I want the autoscaling components to run
on arm64 and cost little memory and no disk, so they do not take what the
apps need.

#### Acceptance criteria

1. EVERY image added by this spec SHALL publish `linux/arm64`.
   (recorded in the pull request: the image's manifest list)
2. THE KEDA and VPA components SHALL use no PersistentVolume and no
   `emptyDir` beyond 64Mi each, and their memory requests together SHALL
   stay under 1 GiB. (repo-policy `autoscale-targets` on the rendered
   charts; each image's compressed arm64 size recorded in its pull request)

### Requirement 8: Scaling is invisible to users and to paging

**User story:** As a household member, I want scaling events to go
unnoticed; as the operator, I want no new page for them.

#### Acceptance criteria

1. WHEN an autoscaler first scales a workload out and back in, THE public
   blackbox probes of that app SHALL record no failed probe.
   (recorded check in tasks.md: `probe_success` over the event)
2. THE spec SHALL add no `action: human` alert. A failed KEDA operator or
   VPA recommender leaves every replica count where it is, and shows as
   INFO on the Homelab / Automation dashboard; the chart rules
   `KubeHpaMaxedOut` and `KubeHpaReplicasMismatch` stay INFO.
   (`tests/alertmanager/routes.txt` gains no ntfy line;
   `scripts/ci/alertmanager-test.sh`)
3. A pull request under this spec that restarts an app (a requests change,
   the Keycloak HPA, the Immich machine-learning volume) SHALL merge Monday
   to Friday between 09:00 and 17:00 Europe/Zurich.
   (recorded in tasks.md with the merge time)

### Requirement 9: Documented as built

**User story:** As someone rebuilding the homelab, I want to read what
scales, on what, and why nothing scales to zero.

#### Acceptance criteria

1. `docs/architecture.md` SHALL list the scaled workloads and their
   autoscaler, `docs/observability.md` the VPA report and the KEDA and HPA
   panels, and `docs/decisions.md` SHALL have the entry "No scale to zero"
   with the reason and the rejected alternative. (review of the last task's
   pull request)

## Open questions

The operator was not available when this was drafted. Each question names
the default this spec assumes until it is answered.

1. HPA floor: `minReplicas: 1` everywhere, as today (default), or 2 for the
   tier-1 login path, Keycloak (about 1.4 GiB more at its 7-day peak) and
   the oauth2-proxies (about 20 MiB each), so a node drain does not
   interrupt logins?
2. Immich machine-learning cache: a second replica cannot mount the 10Gi
   `ReadWriteOnce` `iscsi` cache. Default: a static `ReadWriteMany` NFS
   volume on the NAS, which uses no eMMC. Alternatives: an `emptyDir` on
   the eMMC (models downloaded again by every pod), or keep one replica and
   drop the ScaledObject.
3. KEDA's targets: Immich machine learning is the only event-driven
   candidate found; the Paperless consumer and the Immich workers need
   `ReadWriteOnce` volumes. Install KEDA now with that one target
   (default), or wait for a second one?
4. Argo CD's repo-server and server are stateless and their chart supports
   an HPA, but Argo CD carries no SLO. Default: out of scope. Add them?
5. Paging: no page when the KEDA operator or the VPA recommender is down
   (default), because a failed autoscaler leaves the replica counts as
   they are. Or a "monitoring went blind" page like `TupprOperatorAbsent`?
6. Sizing restarts pods: most apps use `Recreate`, so a requests change is
   a short outage of that app (seconds to a minute of failed probes).
   Default: three pull requests (the platform layer; theater and books; the
   other apps), each merged on a weekday in the daytime. Acceptable, or one
   per namespace?
