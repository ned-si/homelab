---
kind: change
status: active
created: 2026-11-03
issue: 917
---
# Requirements: autoscaling

## Introduction

Every workload runs one replica, except CoreDNS, the Cilium operator and the
Tailscale exit node, and most hold a `ReadWriteOnce` volume on the one NAS
([architecture.md](../../../docs/architecture.md#cluster)). A node drain or a
node failure stops every app on that node until its pod starts elsewhere.

The operator decided on 2026-11-03 that everything that can be highly
available should be: two replicas where an app supports it, active-active
where it can, active-passive where only that is supported. This spec makes
that change, and adds autoscaling on top of it:

- High availability (HA): a per-workload inventory, two replicas for every
  workload that supports it, spread across the four nodes, with a
  PodDisruptionBudget; Keycloak as a two-member Infinispan cluster; a
  streaming replica for the CloudNativePG clusters.
- VPA in recommend-only mode, so requests come from measured usage. On
  2026-11-03, 78 of the 252 containers Prometheus knew (Job pods included)
  had no memory request.
- HPA on CPU for the stateless request path, floor 2.
- KEDA for event-driven scaling, installed with the HA work.

No workload scales to zero (operator, 2026-11-02): it adds seconds of delay
to the first request to save a few hundred MiB.

What it costs and what it buys, measured on 2026-11-03
([design.md: Cost and benefit](design.md#cost-and-benefit)): the HA additions
take about 7.1 GiB of memory at their 7-day peaks (4.7 GiB without a second
Immich machine-learning pod), against 94 GiB available on the four nodes,
and 50 GiB on the NAS. Over the 14 days before, each public app failed its
probe for 162 to 173 minutes, and 155 of those minutes were outages of every
app at once (WAN, router or Gateway), out of reach of pod-level HA. Of the
remaining 7 to 18 minutes per app, only `auth` has a request path that this
spec makes fully HA; `media`, `cook`, `theater` and `home` keep
single-replica backends. What HA buys is drains, upgrades and deploys of the
login path, the SSO proxies, the operator UIs and the cluster controllers
without an outage, and databases that survive their node. It does nothing
for the NAS, the Turing Pi board, power or the uplink.

Constraints, from [tech.md](../../steering/tech.md#constraints) and the
cluster:

- Most volumes are `ReadWriteOnce` iSCSI on one NAS: a volume attaches to
  one node, so a second pod on another node cannot mount it.
- arm64 only: every image must publish an arm64 variant.
- 4 Turing RK1 nodes, 32 GB RAM each (30.4 GiB allocatable), 29 GB of eMMC
  each, 8.8 to 12.7 GiB of it free on `/var`. eMMC is the scarce part:
  images and `emptyDir` volumes live on it.
- Changes that can break an app merge Monday to Friday, in the daytime
  (Zurich).

Non-goals:

- Scale to zero, the KEDA HTTP add-on, or any scale-from-zero proxy.
- VPA modes that act (`Initial`, `Recreate`, `InPlaceOrRecreate`, `Auto`),
  the VPA updater and admission controller.
- Making an app HA that the inventory classes `none`, except Grafana
  (answered question 11). The inventory says what would make each possible;
  any other enabler is its own issue.
- Moving the Immich library (`immich-data`) off `ReadWriteOnce`.
- HA of the NAS, the Turing Pi board, power, the router or the uplink;
  disaster recovery is #918.
- DaemonSets (Cilium and its Envoy, Vector, Tetragon, node-exporter): they
  run on every node already.
- Anything in the namespaces `signoz` and `logging`, and the observability
  direction (#801), which is parked.
- Adding nodes, a cluster autoscaler or cloud nodes. Cloud bursting is a
  research note in [design.md](design.md#research-note-cloud-burst-nodes).

## Glossary

- **HA class**: one of three, per workload, in the HA inventory.
  - `active-active`: two or more replicas serve at once (stateless, or
    state in a shared database or cache).
  - `active-passive`: two replicas, one leads and the other stands by:
    leader election, or a primary with a streaming replica on its own
    volume (CloudNativePG).
  - `none`: one replica. A standby sharing the active pod's
    `ReadWriteOnce` volume is not possible on another node, so a single
    writer to such a volume, SQLite included, is `none`.
- **HA inventory**: `ci/ha-inventory.yaml`, one entry per Deployment,
  StatefulSet and CloudNativePG `Cluster` of the rendered objects (outside
  `signoz` and `logging`): kind, namespace, name, class, reason, and for
  `none` what would make HA possible. An entry whose change has not merged
  yet carries `pending: <task>`; a capable workload kept at one replica on
  purpose carries `excluded: <reason>`; a workload with an HPA carries
  `hpa: true`.
- **HA workload**: a workload classed `active-active` or `active-passive`,
  neither `pending` nor `excluded`.
- **Autoscaler**: a `HorizontalPodAutoscaler` (HPA) or a KEDA
  `ScaledObject`, which creates its own HPA.
- **Recommendation**: the `target`, `lowerBound` and `upperBound` a
  `VerticalPodAutoscaler` (VPA) writes into its status, per container.
- **Rendered objects**: `deploy/` plus the Helm apps CI renders
  (`scripts/ci/render_apps.py`), the same scope as the Kyverno check.

## Requirements

### Requirement 1: Every workload has an HA class

**User story:** As the operator, I want to see for each workload whether it
can run twice, and why not, so HA is a decision per app and not a guess.

#### Acceptance criteria

1. THE HA inventory SHALL have exactly one entry per Deployment,
   StatefulSet and CloudNativePG `Cluster` of the rendered objects outside
   `signoz` and `logging`, and no entry without a workload. (repo-policy
   `ha-inventory`)
2. EVERY entry SHALL have a class and a reason; EVERY `none` entry SHALL
   also say what would make HA possible, and EVERY `excluded` entry why
   the cost outweighs the benefit. (repo-policy `ha-inventory`)
3. WHEN the last task of this spec merges, no entry SHALL be `pending`.
   (repo-policy `ha-inventory`, enabled by the last task)

### Requirement 2: HA workloads survive the loss of one pod or one node

**User story:** As a household member, I want an app that can run twice to
keep answering while a node is drained, upgraded or lost.

#### Acceptance criteria

1. EVERY HA workload SHALL run at least 2 replicas: `spec.replicas` of at
   least 2, or an autoscaler with a floor of at least 2.
   (repo-policy `ha-replicas`)
2. EVERY HA workload SHALL spread its pods across nodes:
   `topologySpreadConstraints` on `kubernetes.io/hostname`, `maxSkew: 1`,
   `whenUnsatisfiable: DoNotSchedule`, `nodeTaintsPolicy: Honor` (a
   cordoned or failed node is then not a domain, so a rollout surge at 3
   replicas during a drain still schedules), or a required pod
   anti-affinity on the same key where a chart offers only that.
   (repo-policy `ha-replicas`)
3. EVERY HA workload SHALL have a PodDisruptionBudget with
   `maxUnavailable: 1`. (repo-policy `ha-replicas`)
4. A workload that is not an HA workload SHALL NOT have a
   PodDisruptionBudget that allows no disruption, so it never blocks a node
   drain. (repo-policy `ha-replicas`; CloudNativePG's own PDBs excepted)
5. WHEN one node is drained, THE public probes of the apps whose request
   path is all HA workloads (`auth`, `headlamp`, `hubble`, `argo`) SHALL
   record no failed probe, except at most one of `auth` while `keycloak-db`
   switches over. (recorded check in the drain task: `probe_success` over
   the drain; the `headlamp` probe, oauth2-proxy's `/ping`, is added by
   task 6)
6. EVERY HA Deployment SHALL use the `RollingUpdate` strategy, not
   `Recreate`, so a rollout never stops every replica at once.
   (repo-policy `ha-replicas`)

### Requirement 3: Keycloak is a two-member cluster

**User story:** As a household member, I want to stay logged in, and to be
able to log in, while one Keycloak pod restarts.

#### Acceptance criteria

1. THE Keycloak Deployment SHALL run 2 replicas at least, through an HPA
   with `minReplicas: 2` and `maxReplicas: 3`. (repo-policy `ha-replicas`,
   `autoscale-floor`)
2. THE Keycloak pods SHALL form one Infinispan cluster through the JGroups
   `kubernetes` stack, with DNS discovery on a headless Service
   `keycloak-discovery` that sets `publishNotReadyAddresses: true`, so two
   pods starting at once find each other. (recorded check: the Keycloak
   log shows a cluster view of 2 members, after one pod is deleted and
   after both are deleted together)
3. WHEN one Keycloak pod is deleted, a session opened before SHALL stay
   valid and a new login SHALL succeed. (recorded check in the Keycloak
   task)

### Requirement 4: The databases fail over

**User story:** As the operator, I want a database to survive the loss of
its node, without waiting for its volume to move.

#### Acceptance criteria

1. EVERY CloudNativePG cluster SHALL set `instances: 2` and
   `affinity.podAntiAffinityType: required`, `immich-db` included (its
   volume was relabelled on 2026-11-02; a fresh backup comes first).
   (repo-policy `ha-replicas`)
2. WHEN the primary's node is drained, THE cluster SHALL switch over to the
   replica, and its app SHALL reconnect with no manual step. (recorded
   check in the database task: `cnpg_pg_replication_is_wal_receiver_up`,
   the app's probe)
3. THE added memory and NAS storage of the replicas SHALL be recorded in
   the pull request. (recorded in the pull request)

### Requirement 5: No workload scales to zero

**User story:** As a household member, I want every app to answer the first
request at once, so no page load waits for a pod to start.

#### Acceptance criteria

1. EVERY HPA SHALL set `minReplicas` of at least 2, and EVERY ScaledObject
   SHALL set `minReplicaCount` of at least 2 explicitly (KEDA's default is
   0) and no `idleReplicaCount`. (repo-policy `autoscale-floor`)
2. THE rendered objects SHALL contain no object of the API group
   `http.keda.sh` (the HTTP add-on). (repo-policy `autoscale-floor`)

### Requirement 6: Only HA workloads autoscale

**User story:** As the operator, I want an autoscaler only where another
replica can start, so scaling never leaves a pod Pending on a volume or
fights Argo CD.

#### Acceptance criteria

1. THE target of every autoscaler SHALL be a Deployment classed
   `active-active` that mounts no `ReadWriteOnce` PersistentVolumeClaim,
   does not use the `Recreate` strategy, and sets a CPU request on every
   container. (repo-policy `autoscale-targets`)
2. A Deployment SHALL be the target of at most one autoscaler.
   (repo-policy `autoscale-targets`)
3. WHILE an autoscaler owns a Deployment, THE Deployment SHALL NOT set
   `spec.replicas` in git, or its Application SHALL ignore `/spec/replicas`
   for it, so a sync does not reset the replica count.
   (repo-policy `autoscale-targets`)

### Requirement 7: VPA recommends and never acts

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

### Requirement 8: Requests come from measured usage

**User story:** As the operator, I want requests set from what the
workloads use, so scheduling and HPA percentages mean something.

#### Acceptance criteria

1. THE script `scripts/vpa-requests.sh` SHALL print, per container, the
   current CPU and memory request and memory limit, the VPA target and
   upper bound, and the proposed values: request = target rounded up (CPU
   to 10m, memory to 16Mi), memory limit = the larger of the current limit
   and twice the upper bound, rounded up to 64Mi; no CPU limit.
   (`tests/bash/test_vpa_requests.sh`)
2. A change to a container's requests or limits made by the sizing tasks
   SHALL be a pull request that carries the script's output, and only for
   a container whose VPA has at least 8 days of history. An HA task that
   needs a CPU request before then sets it from the container's 7-day peak
   in Prometheus, recorded in its pull request. (recorded in each pull
   request)
3. WHEN the sizing tasks are done, EVERY container of the apps and platform
   layers, except in `signoz` and `logging`, SHALL have a CPU request, a
   memory request and a memory limit. (repo-policy `container-requests`)

### Requirement 9: HPA scales the stateless request path on CPU

**User story:** As the operator, I want the stateless request path to add a
replica under load, without growing past what the nodes hold.

#### Acceptance criteria

1. EACH workload marked `hpa` in the HA inventory SHALL have an
   `autoscaling/v2` HPA with `minReplicas: 2`, `maxReplicas: 3`, a CPU
   utilization target of 80% of the request and a scale-down stabilization
   window of 300 s. (repo-policy `autoscale-targets`, kubeconform)
2. WHEN every HA workload is at its maximum, THE sum of the memory requests
   in the cluster SHALL fit in the allocatable memory of three nodes (one
   node down). (recorded check in tasks.md, from
   `kube_pod_container_resource_requests` and
   `kube_node_status_allocatable`)

### Requirement 10: KEDA scales on events

**User story:** As the operator, I want a workload that serves a queue to
follow the length of that queue, not its CPU.

#### Acceptance criteria

1. THE KEDA operator and its metrics API server SHALL run in the namespace
   `keda` in the platform layer, 2 replicas each (the operator with leader
   election), and serve `external.metrics.k8s.io`. (recorded check:
   `kubectl get apiservice v1beta1.external.metrics.k8s.io` is
   `Available`)
2. THE Immich machine-learning Deployment SHALL scale between 2 and 3
   replicas through one ScaledObject with KEDA `redis` triggers on the
   length of the BullMQ wait lists of the queues that call it
   (`immich_bull:smartSearch:wait`, `immich_bull:faceDetection:wait`,
   `immich_bull:ocr:wait` in Valkey), `listLength: "100"` per replica, and
   a scale-down stabilization window of 300 s.
   ([design.md: KEDA trigger](design.md#keda-trigger-for-immich-machine-learning);
   repo-policy `autoscale-targets`; recorded check in tasks.md: a library
   scan moves it to 3 and back to 2)
3. IF a ScaledObject's trigger fails 3 times in a row, THEN KEDA SHALL hold
   the workload at 2 replicas (`fallback.replicas: 2`).
   (repo-policy `autoscale-floor`)
4. THE `immich` network policy SHALL allow the KEDA operator in `keda` to
   reach Valkey on 6379, and nothing else in `immich`. Until `immich`
   enforces its policies (`enableDefaultDeny: false` today), Valkey is
   reachable from every namespace, so the absence of drops proves nothing.
   (`infrastructure/network-policies/20-immich.yaml`; recorded check: the
   ScaledObject is `Ready`, and `hubble observe` shows the flow from `keda`
   to Valkey with `ingress_allowed_by` naming the `immich` policy, or the
   check is recorded once `immich` enforces)

### Requirement 11: It fits the hardware

**User story:** As the operator, I want the HA and autoscaling changes to
run on arm64 and fit in memory and on the eMMC, so they do not take what the
apps need.

#### Acceptance criteria

1. EVERY image added by this spec SHALL publish `linux/arm64`.
   (recorded in the pull request: the image's manifest list)
2. THE KEDA and VPA components SHALL use no PersistentVolume and no
   `emptyDir` beyond 64Mi each, and their memory requests together SHALL
   stay under 1 GiB. (repo-policy `autoscale-targets` on the rendered
   charts)
3. A pull request that adds a replica of an image above 500 MiB
   compressed SHALL record its size and the free space on `/var` of every
   node; no node SHALL drop under 5 GiB free. (recorded in the pull
   request, from `node_filesystem_avail_bytes{mountpoint="/var"}`)

### Requirement 12: Scaling and failover are invisible to paging

**User story:** As a household member, I want scaling and failover to go
unnoticed; as the operator, I want no new page for them.

#### Acceptance criteria

1. WHEN an autoscaler first scales a workload out and back in, THE public
   probes of that app SHALL record no failed probe. (recorded check in
   tasks.md: `probe_success` over the event)
2. THE spec SHALL add no `action: human` alert. A failed KEDA operator or
   VPA recommender leaves every replica count where it is, and shows as
   INFO on the Homelab / Automation dashboard; the chart rules
   `KubeHpaMaxedOut` and `KubeHpaReplicasMismatch` stay INFO.
   (`tests/alertmanager/routes.txt` gains no ntfy line;
   `scripts/ci/alertmanager-test.sh`)
3. A pull request under this spec that restarts an app (a requests change,
   a replica count, a database instance) SHALL merge Monday to Friday
   between 09:00 and 17:00 Europe/Zurich. (recorded in tasks.md with the
   merge time)

### Requirement 13: Documented as built

**User story:** As someone rebuilding the homelab, I want to read what runs
twice, what scales, on what, and why the rest does not.

#### Acceptance criteria

1. `docs/architecture.md` SHALL list the HA classes and the scaled
   workloads with their autoscaler, `docs/observability.md` the VPA report
   and the KEDA and HPA panels, and `docs/decisions.md` SHALL have the
   entries "No scale to zero" and "HA where an app supports it", each with
   the reason and the rejected alternative. (review of the last task's
   pull request)

## Answered questions

No question is open. From the operator's review on 2026-11-03:

1. HPA floor: `minReplicas: 2` for every HA-capable workload; Keycloak
   runs 2 replicas at least (requirements 3, 5).
2. KEDA: installed with the HA work, without waiting for a second
   event-driven target (task 5).
3. Argo CD: HA where it is cheap. `argocd-server` and `argocd-repo-server`
   run 2 replicas, the ApplicationSet controller 2 with leader election,
   about 0.4 GiB in total; the application controller and Redis stay at
   one, for the reasons in [design.md](design.md#inventory) (task 10).
4. Frontends: 2 replicas wherever the app supports it, one passive where
   only active-passive is supported, decided per app in the HA inventory
   ([design.md: Inventory](design.md#inventory)).

Decided on 2026-11-03, the operator accepting the defaults this spec
proposed:

5. Immich machine-learning cache: two replicas cannot share the 10Gi
   `ReadWriteOnce` `iscsi` cache, so it moves to a static `ReadWriteMany`
   NFS volume on the NAS, which uses no eMMC (task 15). Rejected: an
   `emptyDir`, which downloads the models again in every pod, onto the
   scarce eMMC.
6. Paging: no page when the KEDA operator or the VPA recommender is down,
   because a failed autoscaler leaves the replica counts as they are; their
   health is INFO on the Homelab / Automation dashboard (requirement 12.2).
7. Sizing restarts pods: most apps use `Recreate`, so a requests change is
   a short outage of that app (seconds to a minute of failed probes). Three
   pull requests (the platform layer; theater and books; the other apps),
   each merged on a weekday in the daytime (tasks 18 to 20).
8. Prometheus stays at one replica (`excluded`): a second costs about
   5 GiB of memory and 40 GiB on the NAS, starts with an empty TSDB, so its
   30-day SLO and backup-window alerts would page falsely for 30 days, and
   Grafana would read either replica at random. The healthchecks.io
   watchdog already pages when Prometheus or Alertmanager stops. Two
   replicas behind a Thanos querier that deduplicates would be its own
   spec.
9. Immich machine learning: floor 2, spread across nodes, the worker still
   preferred for the first pod, `RollingUpdate` (`maxSurge: 1`,
   `maxUnavailable: 0`) once the cache leaves `ReadWriteOnce`, and a CPU
   limit of 4 of the 8 cores on the machine-learning container (an
   exception to "no CPU limit"), so a library scan leaves etcd and the API
   server half of a control plane (tasks 15, 16). It costs about 2.3 GiB
   and a copy of its image on a second node's eMMC. Rejected:
   `ScheduleAnyway`, which stacks the replicas on the worker (no node HA),
   and a floor of 1.
10. `immich-db` replica: `instances: 2`, about 342 MiB and 5 GiB on the
    NAS, the same pinned image (the hard rule on its image is untouched),
    with a fresh backup first (task 14). Its volume was relabelled on
    2026-11-02, so nothing else waits.
11. Grafana moves to a CloudNativePG cluster `grafana-postgresql` at
    `instances: 2` (about 220 MiB, 10 GiB on the NAS) with a second Grafana
    pod (about 310 MiB), which makes it `active-active` (task 13). The new
    database starts empty. Dashboards and datasources are provisioned from
    git and users come back through Keycloak at their next login, but
    `grafana.db` also holds what Grafana cannot provision: the service
    account `agent-readonly` and its token (the identity of the Grafana MCP
    server and of the agents' read-only checks), annotations, stars and
    user preferences. Task 13 re-creates `agent-readonly` as Viewer with a
    new token through the Grafana API and writes the token to its file
    under `~/homelab-backups/agent/` (mode 600, never printed); until then
    the old token gets 401s. Annotations, stars and preferences are lost:
    no script writes annotations, so they are the few added by hand, and
    the last `grafana/data` snapshot keeps the SQLite file readable.
    Rejected: a scripted migration of `grafana.db` into PostgreSQL, since
    Grafana ships no tool for it and the schema is version-specific, for a
    handful of rows. Paperless, the other supported enabler (PostgreSQL,
    the media on `ReadWriteMany`, the web server split from the worker), is
    a one-way migration of the document archive and stays out of this
    spec; its own `type/spec` issue if wanted.
