# Design: per-app-hardening

## Overview

Each application workload gets, in its own pull request, probes, one of two
security profiles and no unused token. A repo-policy rule, `pod-hardening`,
records what is still missing in `ci/pod-hardening-gaps.txt` and fails CI
when a change adds a gap, so the file shrinks with every task and the work
cannot slide back. Once the Pods that operators build and the
infrastructure charts carry requests, and #917 has sized the rest, a
readiness script and a new page (`KyvernoDenied`) let
`require-requests-limits` and `require-probes` move to Deny, one policy per
pull request.

Stack, unchanged: Kustomize manifests and Helm values under `apps/`,
`platform/`, `infrastructure/`, rendered to `deploy/` by `task render`;
Kyverno `ValidatingPolicy` and `PolicyException`; the Python repo-policy in
`scripts/ci/repo_policy.py` with pytest; bash scripts with bash tests in
`tests/bash/`; a `PrometheusRule` with `promtool` tests. No new tool and no
new image.

## Evidence at the start (2026-11-04, 22:15 UTC)

From `deploy/`, the Immich chart values and the live PolicyReports
(`kubectl get policyreports -A`). Resources are left out where #917 sizes
them. The image column gives the config `User` and the entrypoint from
`docker buildx imagetools inspect` (linux/arm64) at the pinned digest on
2026-11-04; the profile column applies D2 to it.

| Task | Workload | Image: `User`, entrypoint | Missing today | Expected profile and evidence |
| --- | --- | --- | --- | --- |
| 2 | `theater/qbittorrent` | hotio: `""`, `/init` (s6) | liveness, security context, token | root: sets `UMASK=002`, read-write NFS mount |
| 3 | `paperless/paperless` | paperless-ngx 3.4.2: `""`, `/init` (s6) | liveness, security context, token | non-root `1000:1000`: upstream documents `user: '1000:1000'` ([setup.md at v3.4.2](https://github.com/paperless-ngx/paperless-ngx/blob/v3.4.2/docs/setup.md), "Rootless"); its one exception, extra `PAPERLESS_OCR_LANGUAGES`, is unset (`PAPERLESS_OCR_LANGUAGE` uses languages the image ships) |
| 3 | `paperless/valkey` | valkey 9.2-alpine: `""`, `docker-entrypoint.sh` steps down to `valkey` | readiness, liveness, security context, token | non-root `999:1000`: the entrypoint's user (the Dockerfile's `adduser -u 999`, group `valkey` gid `1000`) |
| 4 | `mealie/mealie` | mealie v3.30.0: `""`, `/app/run.sh` (`gosu $PUID`) | liveness, security context, token | non-root `1000:1000`: the entrypoint switches to `PUID` 1000 and skips the switch when started as that uid (`docker/entry.sh` at v3.30.0) |
| 5 | `syncthing/syncthing` (StatefulSet) | syncthing 2.1.7: `""`, `/bin/entrypoint.sh` (`su-exec $PUID:$PGID`) | readiness, liveness, security context, token | non-root `1000:1000`, no `fsGroup`: the entrypoint's user (`script/docker-entrypoint.sh` at v2.1.7); its init container already runs as `1000:1000` |
| 6 | `immich/valkey` | as in `paperless` | as in `paperless` | non-root `999:1000` |
| 6 | `immich/immich-machine-learning` | Immich ML v3.3.6: `""`, `tini` | security context, token | non-root `1000:1000`: upstream documents `user:` ([FAQ](https://docs.immich.app/FAQ), "How can I run Immich as a non-root user?"); `fsGroup` on its cache PVC if the check asks (it runs as root today) |
| 7 | `immich/immich-server` | Immich server v3.3.6: `""`, `tini` | security context, token | root (To settle 1) |
| 8 | `keycloak/keycloak` | keycloak 26.8.1: `"1000"`, `kc.sh` | security context, token | non-root `1000:0`: the config user; its files are group `0` and group-writable |
| 9-12 | `theater/{sonarr,radarr,lidarr,prowlarr}` | hotio: `""`, `/init` (s6); exportarr: `nonroot:nonroot` | security context (exportarr: pod seccomp), token | app root: `UMASK=002`, read-write NFS mount; exportarr non-root `65532:65532` set on the container (distroless `nonroot`; a non-numeric `User` needs `runAsUser` for `runAsNonRoot`) |
| 13 | `theater/bazarr` | hotio: `""`, `/init` (s6) | capabilities, non-root, token | root: `UMASK=002` (group-writable subtitles for Sonarr and Radarr), read-write NFS mount |
| 14 | `theater/lazylibrarian` | linuxserver: `/init` (s6) | capabilities, non-root, token | root: `UMASK=002`, read-write NFS mount |
| 15 | `theater/jellyfin` | jellyfin 12.4: `""`, `/jellyfin/jellyfin` (no switch, root today) | liveness, security context, token | non-root `1000:1000` when the NFS check passes and To settle 2 is answered, else root: upstream documents `user: uid:gid` ([container install](https://jellyfin.org/docs/general/installation/container/), not versioned); `jellyfin-config` and `jellyfin-cache` by the ownership check |
| 16 | `theater/plex` | pms-docker: `""`, `/init` (s6) | liveness, security context, token | root: its init needs root and upstream documents no uid |
| 17 | `books/calibre-web` | calibre-web-automated v4.0.8: `""`, `/init` (s6) | capabilities, non-root, token | root: upstream documents no uid; read-write NFS mount |

What this means for #1020: `paperless`, `mealie`, `syncthing` and
`keycloak` are expected to read `READY` after their tasks; `immich` stays
open (To settle 1, and the inline NFS volume of
`immich-library-backup-local`); `theater` and `books` stay `baseline`.
Each pull request re-reads the image evidence at the digest it merges
with, and the `/etc/passwd` line of the user it runs as.

Already at the non-root profile with probes, missing only the token:
`audiobookshelf`, `home-assistant`, `mosquitto`, `zigbee2mqtt`,
`subtitle-exporter`, the SSO proxies, and every backup, prune and smoke
Job (tasks 18 and 19).

Operator-built Pods without requests (`require-requests-limits` `fail`):
the eight CloudNativePG instance Pods (`home-assistant-postgresql-1`,
`immich-db-1`, `keycloak-db-1`, `mealie-postgresql-1`, and
`{sonarr,radarr,lidarr,prowlarr}-postgresql-1`), and
`prometheus-kube-prometheus-stack-prometheus-0` and
`alertmanager-kube-prometheus-stack-alertmanager-0`. Every `Cluster`
except `home-assistant-postgresql` (50m, 256Mi, limit 512Mi) sets no
`spec.resources`; no `ObjectStore` sets resources for its
`plugin-barman-cloud` sidecar, whose live `resources` are `{}`, so
`home-assistant-postgresql-1` fails on the sidecar alone.

Charts outside #917's sizing that fail `require-requests-limits`:
`cert-manager` (3 Deployments), `external-dns`, `democratic-csi`
(controller and node DaemonSet), `signoz-clickhouse-operator`, and two
DaemonSets #917 leaves out: `tetragon/tetragon` and
`monitoring/kube-prometheus-stack-prometheus-node-exporter`. #917 task 13
adds a ninth cluster, `grafana-postgresql`.
`require-probes` fails, outside the excluded namespaces, on
`cert-manager`, `cert-manager-cainjector`,
`iscsi-democratic-csi-controller`, `barman-cloud` (the plugin, namespace
`immich`), `kube-prometheus-stack-grafana`, `signoz-clickhouse-operator`,
and the application Deployments above.

Volumes the profiles touch (`kubelet_volume_stats_inodes_used`): every
application PVC holds under 48,000 files (`plex-config` 47,156,
`jellyfin-config` 37,929, the rest under 4,000), except `immich-data` with
277,908. `kube_node_status_allocatable`: 30.4 GiB of memory per node,
4.1 to 10.3 GiB requested.

## Profiles

### Non-root

```yaml
spec:
  automountServiceAccountToken: false     # unless its own ServiceAccount is bound and calls the API
  securityContext:
    runAsNonRoot: true
    runAsUser: <uid>
    runAsGroup: <gid>
    seccompProfile:
      type: RuntimeDefault
    # fsGroup: <gid> and fsGroupChangePolicy: OnRootMismatch only when the
    # ownership check asks for it
  containers:
    - securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
```

The uid and gid are the image's own user (requirements.md Glossary: the
config `User`, or the user the entrypoint switches to, read from the
image's `/etc/passwd`; Valkey `999:1000`, Keycloak `1000:0`), else
`1000:1000`, the `PUID`/`PGID` the apps pass today, so the files on their
volumes and on the NAS already belong to it. `PUID` and `PGID` stay where
the entrypoint reads them (Mealie, Syncthing skip the switch when started
as that uid). `UMASK` is never removed: a container that sets it keeps
the root profile (requirements.md 3.6), because a pod spec cannot set a
umask and whether the s6 images still apply it when started non-root is
not verified.

**Ownership check**, before the pull request, for each read-write mount
of the container (the implementation brief must allow `kubectl exec` for
read-only commands). On a PersistentVolumeClaim:

```sh
kubectl -n <ns> exec <pod> -c <container> -- \
  find <mount> \( ! -user <uid> -o ! -group <gid> \) -print | head -20
```

Empty output: no `fsGroup`. Otherwise `fsGroup: <gid>` with
`fsGroupChangePolicy: OnRootMismatch` (the kubelet changes the group of
every file once and adds group write; under 48,000 files it takes seconds),
the output quoted in the pull request. Never on `immich-data` (the hard
rule) and never on the Syncthing volume: Syncthing syncs permission bits,
so a group change would push a change of every file to every peer. If the
Syncthing check is not empty, task 5 stops and records it.

On an NFS mount (`fsGroup` has no effect there, and a full traversal of
the media share is too large), the NFS check:

```sh
kubectl -n <ns> exec <pod> -c <container> -- \
  find <mount> -maxdepth 2 ! -user <uid> -print | head -20
```

The container keeps the root profile when the output is not empty or the
export's Mapall user is not known to be `1000` (To settle 2). `fsGroup`
is never set for an NFS mount.

### Root

```yaml
spec:
  automountServiceAccountToken: false
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
          add: [CHOWN, DAC_OVERRIDE, FOWNER, KILL, SETGID, SETUID]   # KILL, SETGID, SETUID only if the image switches user
```

No `runAsUser`: `require-run-as-non-root-user` (Deny) rejects
`runAsUser: 0`. Root keeps `DAC_OVERRIDE` and `FOWNER`, so its file access
is what it is today. In the s6 images (hotio, linuxserver, Plex,
Calibre-Web) the supervisor runs as root and the app as uid 1000
(`s6-setuidgid`); signalling a process of another uid needs `KILL`, so
without it `s6-svc` and the stage-3 `SIGTERM` fail with `EPERM` and every
stop ends in the runtime's `SIGKILL` after the grace period (the stale
qBittorrent `ipc-socket`, a torn Plex SQLite write). What goes is the rest
of the runtime's default set (`NET_RAW`, `MKNOD`, `SYS_CHROOT`,
`AUDIT_WRITE`, `SETPCAP`, `SETFCAP`, `FSETID`, `NET_BIND_SERVICE`),
privilege escalation and the unconfined seccomp profile. All six are in
the `baseline` allowed list (`disallow-capabilities`). Every application
port is above 1024. A capability is removed from the six when the app
starts and stops without it in the pull request's rollout; one is never
added beyond the six (it would be a new gap reason, out of this spec).

**Stop check** (requirements.md 8.4), for a root-profile container of an
image that switches user, after the sync (the brief allows the delete):

```sh
kubectl -n <ns> logs -f <pod> -c <container> > /tmp/<app>-stop.log 2>&1 &
time kubectl -n <ns> delete pod <pod>
tail -20 /tmp/<app>-stop.log
```

Expected: `delete` returns in under half of
`terminationGracePeriodSeconds`, and the log ends with s6 stopping its
services and no `Operation not permitted`. Otherwise the pull request is
reverted and the capability the log names is added back, within the six.

## Probes

| Probe | Default | Rule |
| --- | --- | --- |
| readiness | the existing one; else the app's health endpoint or the path the PostSync smoke test checks, `periodSeconds: 10`, `failureThreshold: 3` | may check what serving needs |
| liveness | same port as readiness, `httpGet` on a path that does not touch the database (or `tcpSocket`), `periodSeconds: 30`, `timeoutSeconds: 5`, `failureThreshold: 5` | the process only; 2.5 minutes of failures before a restart |
| startup | the readiness check, `periodSeconds: 10`, `failureThreshold: 30` (5 minutes) | WHEN the running Pod took over 60 s from container start to Ready (its `Ready` condition's `lastTransitionTime` minus the container's `state.running.startedAt`), or the app runs migrations at start (Paperless, Mealie, Jellyfin, Plex; the *arr apps have one already) |

Per workload: Valkey readiness `exec: [valkey-cli, ping]`, liveness
`tcpSocket: 6379`; Syncthing readiness and liveness
`GET /rest/noauth/health` on `web-ui`; qBittorrent liveness `GET /` on
`http`; Mealie and Paperless liveness `tcpSocket` on their HTTP port
(their HTTP paths, `/api/app/about` and `/accounts/login/`, are not shown
to be free of database calls, so they serve readiness only);
Jellyfin `GET /health`; Plex `GET /identity`; Immich and Keycloak keep the
chart's and their own. Each pull request checks its endpoints with the
running Pod (`kubectl exec ... wget -qO- http://127.0.0.1:<port><path>` or
the probe's own port from the PostSync smoke test) before it relies on
them.

qBittorrent's stale `ipc-socket` makes the process exit every two seconds
while s6 restarts it inside the container. The readiness probe already
marks it NotReady; the liveness probe then restarts the container, the
socket is still there, and the restarts reach `KubePodCrashLooping`. The
runbook's "Prevention" section is rewritten to say so (the probes exist,
the image is pinned).

Liveness probes come from the kubelet on the node. The Cilium allow-lists
in audit or enforced (`paperless` ingress since #1038) allow the `host`
and `remote-node` entities, so a new probe is not dropped; the pull
request confirms it with the Pod Ready after the sync.

## Tokens

`automountServiceAccountToken: false` on the pod spec of every pod
template that runs as `default`. A Pod with its own ServiceAccount keeps
its token: today `presync-backup`, `backup-verify`, `talos-drift-check`,
`aws-cost-exporter`, `github-exporter`, `usage-exporter`, `vuln-enrich`,
`pushgateway`, `plugin-barman-cloud` and the charts' controllers. The
`default` ServiceAccount has no RoleBinding in git; the rule checks that
it stays so, because a Pod relying on such a binding would lose its access.

In the application namespaces, an own ServiceAccount that no binding in
the render names gets the same treatment (requirements.md 4.3): today the
accounts the Immich chart creates for `immich-server` and
`immich-machine-learning`, set through the chart's pod options in tasks 6
and 7. A Pod there that does use such a token outside RBAC keeps it with
a `token` gap line naming why.

Tasks 2 to 17 set it with their workload. Task 18 sets it on what is left
in the apps layer (`audiobookshelf`, the `home` apps, `subtitle-exporter`,
`theater-sso`, `syncthing-sso`, the backup, prune, import and apply Jobs,
and the `components/postsync-smoke` Job); task 19 on the platform and
infrastructure layers (the other SSO proxies, `lan-inventory`,
`truenas-exporter`, `grafana-backup`, `signoz-backup`, the Keycloak Jobs,
and chart values where a chart exposes it). A chart that cannot set it is a
`token` gap with the chart's name as reason.

## Sizing (tasks 21 to 34 only)

For the containers #917 does not size, from Prometheus over the 14 days
before the pull request, quoted in it:

- CPU request: p95 of `rate(container_cpu_usage_seconds_total[5m])`,
  rounded up to 10m, at least 10m, at most 1000m. No CPU limit.
- Memory request: p95 of `container_memory_working_set_bytes`, rounded up
  to 16Mi, at least 32Mi.
- Memory limit: the largest of the current limit, twice the 14-day maximum
  working set and twice the request, rounded up to 64Mi, at least 128Mi;
  for a `postgres` container at least 512Mi (shared buffers plus
  maintenance and backup work, which a quiet fortnight does not show).
- Under 7 days of history: request 10m and 64Mi, limit four times the
  maximum seen and at least 512Mi.

The rounding matches #917's `scripts/vpa-requests.sh` (16Mi, 64Mi, 10m), so
the two specs produce the same shape of values.

Today's values by that rule, recomputed in each pull request:

| Container | 14-day p95 / max working set | CPU p95 | Request | Limit |
| --- | --- | --- | --- | --- |
| `immich-db` `postgres` | 337 / 433 MiB | 25m | 30m, 352Mi | 896Mi |
| `keycloak-db` `postgres` | 103 / 103 MiB | 25m | 30m, 112Mi | 512Mi |
| theater `postgres` (largest of the four) | 145 / 158 MiB | 37m | 40m, 160Mi | 512Mi |
| `mealie-postgresql` `postgres` | 107 / 114 MiB | 25m | 30m, 112Mi | 512Mi |
| Barman sidecar, `theater` | 90 / 174 MiB | 10m | 10m, 96Mi | 384Mi |
| Barman sidecar, `mealie` | 89 / 161 MiB | 7m | 10m, 96Mi | 384Mi |
| Barman sidecar, `immich` | 25 / 193 MiB | 10m | 10m, 32Mi | 448Mi |
| Barman sidecar, `keycloak` | 23 / 109 MiB | 10m | 10m, 32Mi | 256Mi |

`home-assistant-postgresql` keeps its own `spec.resources` (50m, 256Mi,
limit 512Mi) unless the rule gives more; its sidecar is computed in task
21 (the query above did not include `home`). Tetragon, node-exporter,
Prometheus, Alertmanager, their config reloaders and `grafana-postgresql`
are computed in tasks 31 to 34 by the same rule.

The CloudNativePG fields: `Cluster.spec.resources` (it applies to the
instance container, the `bootstrap-controller` init container and the
operator's Jobs for that cluster) and
`ObjectStore.spec.instanceSidecarConfiguration.resources` for the
`plugin-barman-cloud` sidecar the plugin injects (the field is in the live
CRD, plugin v0.15.1). The ObjectStores are named `cnpg-backup` in the
application namespaces.

The plugin injects the sidecar when it creates the instance Pod, so an
`ObjectStore` edit does not change a running Pod, and if the `Cluster` is
applied first in the same sync, its restarted Pod gets the old sidecar.
So:

1. Each `ObjectStore` changed in tasks 21 to 26 and 34 carries a sync wave
   lower than its `Cluster`'s (`argocd.argoproj.io/sync-wave: "-1"` when
   the `Cluster` has none).
2. After the sync, for every instance Pod:

   ```sh
   kubectl -n <ns> get pod <cluster>-<n> \
     -o jsonpath='{.spec.initContainers[?(@.name=="plugin-barman-cloud")].resources}'
   ```

   Expected: the new requests and limit. If it is empty (the `Cluster`
   did not change, as in `home`), `kubectl cnpg restart -n <ns> <cluster>`
   under the silence in the weekday window; the implementation brief
   allows that write.

A change of `Cluster.spec.resources` restarts the instances. With one
instance that is seconds to a minute of database downtime; with the two of
#917 Requirement 4.1, CloudNativePG restarts the replica, switches over
and restarts the old primary, a few seconds of failover. Each of tasks 21
to 25 and 34 merges at least 24 hours apart from #917's change of the same
`Cluster`, states `instances` at merge time, records the switchover when
there are two (`kubectl cnpg status` before and after), counts the added
memory for every instance, and runs under
`scripts/maintenance-silence.sh <ns> 30m` in the weekday window.
`backup-verify` builds its restore clusters in
`platform/backup-verify/scripts/verify-postgres.sh`, which already sets
`spec.resources` (100m, 256Mi, limit 2Gi); task 26 adds the sidecar
resources to the `verify-source` ObjectStore, the largest of the values
above (10m, 96Mi, limit 448Mi), since one ObjectStore serves every
restore.

## The rule `pod-hardening` (task 1)

A method `rule_pod_hardening` in `scripts/ci/repo_policy.py`, run over
`self.entries()` and `self.docs_of(e)` like the other rules, so it sees the
Helm renders (the Immich chart) as well as `deploy/`.

- Pod templates: `spec.template.spec` of Deployments, StatefulSets,
  DaemonSets, ReplicaSets and Jobs, `spec.jobTemplate.spec.template.spec`
  of CronJobs, `spec` of Pods. Containers: `containers` and
  `initContainers` (an init container with `restartPolicy: Always` counts
  as long-running). Ephemeral containers are not in templates.
- Checks 1 to 5 run in the namespaces of a constant `APP_NAMESPACES` in
  `repo_policy.py`; the rule fails when an Application under
  `clusters/homelab/apps/` has a destination namespace missing from it
  (requirements.md 1.5), so a new app is checked from its first pull
  request. Check 6 runs in every namespace except `EXCLUDED_NAMESPACES` of
  `scripts/ci/kyverno.sh`, parsed from that file (one list), plus the
  own-ServiceAccount case in `APP_NAMESPACES`.
- The effective value of `runAsNonRoot` and `seccompProfile` is the
  container's, else the pod's, as the kubelet resolves it.
- Data file `ci/pod-hardening-gaps.txt`, read with `self.read_list` (blank
  lines and `#` comments skipped). A line is three or more
  whitespace-separated fields: a reference
  `<namespace>/<kind>/<name>/<container>` (`*` as container for check 6,
  which is per pod), a check name from the six, and a free-text reason.
  The reference for a CronJob's Job is the CronJob. Duplicate lines fail.

Failure details, one `self.fail("pod-hardening", <detail>)` per finding,
all in the same run (`fail` adds the `FAIL pod-hardening: ` prefix):

| Condition | Detail |
| --- | --- |
| a gap with no line | `<ref> fails <check> (<what is missing>); fix it or add "<ref> <check> <reason>" to ci/pod-hardening-gaps.txt` |
| a line with no gap | `ci/pod-hardening-gaps.txt:<n>: <ref> <check> is no longer a gap; remove the line` |
| a line naming no container in the render | the same "no longer a gap" detail |
| a malformed line, an unknown check, a duplicate | `ci/pod-hardening-gaps.txt:<n>: <the problem>` |
| a RoleBinding or ClusterRoleBinding naming a `default` ServiceAccount | `<binding> grants <ns>/default; give the Pod its own ServiceAccount` |
| an `apps` Application whose namespace is not in `APP_NAMESPACES` | `<application>: namespace <ns> is not in APP_NAMESPACES; add it` |
| the data file missing while the rule has pod templates to check | `ci/pod-hardening-gaps.txt not found; refusing to pass` |

The rule is fatal for the `ci` run (exit 1, as every repo-policy rule) and
prints nothing else. The seed file is generated once in task 1 from the
rule's own findings, each line with `#726 task <n>` from the table above
or its lasting reason, and reviewed by hand.

## One application pull request, step by step

1. Before: `date -u` inside the weekday window; no network-policy or Pod
   Security flip of the namespace in the last 24 hours, and none planned
   for the next 24; the last successful backup of each data volume under
   24 hours old, read from the backup-age series the backup alerts use
   (`platform/kube-prometheus-stack/routes/backup-slo-targets.yaml`); the
   image evidence of Requirement 3.1; the ownership check; the probe
   endpoints checked.
2. The change: profile, probes, token, the gap lines removed or reworded,
   `task render`, `deploy/`. The body: the evidence, the check outputs and
   `## Rollback` with the `git revert`.
3. `scripts/maintenance-silence.sh <ns> 30m "hardening <app>, PR #<n>"`
   for a `Recreate` workload (an expected restart fails its probe for a
   minute).
4. `scripts/pr-merge.sh <n>`.
5. After the sync, the checks of Requirement 8.4 in a comment (with the
   stop check for a root-profile container of an image that switches
   user), then expire the silence. For `paperless`, `mealie`, `syncthing`, `keycloak` and
   `immich`: `scripts/psa-readiness.sh <ns>`; a `READY` is posted on #1020.
6. The next day, the CronJob comment of Requirement 8.5.

## Pods built by operators

Not in git, so CI and the rule do not see them. Each Deny pull request
lists those its policy matches, with the evidence:

| Operator | Pods | Requests from | Probes |
| --- | --- | --- | --- |
| CloudNativePG | instance Pods, `initdb`, `join` and other Jobs per `Cluster` | `Cluster.spec.resources` (tasks 21 to 25) | instances: the operator's; Jobs: not Deployments |
| CloudNativePG, `grafana-postgresql` (#917 task 13) | its instance Pods and Jobs | `Cluster.spec.resources` from #917 task 13; its sidecar, and the resources if task 13 left them unset (task 34) | as above |
| Barman Cloud plugin | the `plugin-barman-cloud` sidecar in each instance Pod | `ObjectStore.spec.instanceSidecarConfiguration.resources`, applied at Pod creation | not a Deployment |
| backup-verify | the weekly restore clusters | `verify-postgres.sh` (already set); the `verify-source` sidecar (task 26) | not a Deployment |
| Prometheus operator | `prometheus-kube-prometheus-stack-prometheus-0`, `alertmanager-kube-prometheus-stack-alertmanager-0`, their `config-reloader` containers | `prometheus.prometheusSpec.resources`, `alertmanager.alertmanagerSpec.resources`, `prometheusOperator.prometheusConfigReloader.resources` (task 33) | StatefulSets, not checked by `require-probes` |
| tuppr | upgrade and hook Jobs (`system-upgrade`) | its source at the pinned version, quoted in task 37; if it sets none, a PolicyException with that reason | Jobs |
| Trivy operator | scan Jobs (`trivy-system`) | its chart's `trivyOperator.scanJob*` resources, live reports pass today | Jobs |
| ClickHouse operator (SigNoz) | `chi-signoz-clickhouse-*` | the SigNoz chart values (task 30) | StatefulSet, not checked by `require-probes` |
| Tailscale operator | proxies | namespace `tailscale` is webhook-excluded | |

## Moving to Deny (tasks 35 to 38)

### `scripts/kyverno-deny-readiness.sh <policy>` (task 35)

Read-only: `kubectl get` and `curl` to Alertmanager only, with
`--request-timeout=10s` and `curl -m 10`.

- K1. `kubectl get policyreports -A -o json`: for `<policy>`, every
  `fail` result on a Pod, Deployment, StatefulSet, DaemonSet, Job,
  CronJob, or a ReplicaSet with `spec.replicas` above 0, in a namespace not
  in `EXCLUDED_NAMESPACES` (parsed from `scripts/ci/kyverno.sh`).
  PolicyExceptions already turn their objects' results into `skip`.
- K2. `KyvernoReportsStale` not firing (Alertmanager API), and the newest
  `results[].timestamp.seconds` across the PolicyReports under 2 hours old
  (the background scan runs every hour).
- Output: `K1 ok` or one line per failing object with its message, `K2
  ok` or the reason, then `READY` (exit 0) or `NOT READY` (exit 1).
  `kubectl` unreachable or a report it cannot parse: `NOT READY` with the
  error (exit 1), never `READY`. A policy name not in the cluster:
  `NOT READY: no ValidatingPolicy <policy>` (exit 1).

#1021 can use it unchanged for the five restricted policies.

### The Deny pull request (tasks 37 and 38)

1. Before: weekday window; `scripts/kyverno-deny-readiness.sh <policy>`
   prints `READY`; the operator-built list above with evidence; the admin
   kubeconfig check.
2. The diff: the policy name added to the `[Deny]` patch regex of
   `infrastructure/kyverno-policies/kustomization.yaml` and to `BLOCKING`
   in `scripts/ci/kyverno.sh` (the two lists stay equal, as their comments
   require); the PolicyExceptions of D7; `docs/testing.md` and the policy
   count in `docs/architecture.md` and
   `docs/runbooks/alerts/KyvernoReportsStale.md` (16 becomes 17, then 18).
   `ci` green proves `deploy/` and the Helm renders pass it.
3. The first one runs the live Kyverno break-glass test of
   `docs/runbooks/pod-security.md` (Requirement 6.6): `skip-reconcile` on
   `kyverno-policies`, the patch to `[Audit]` on the newly denied policy, a
   server dry-run of the test object below admitted, the annotation
   removed, with the times.
4. After the sync (30 minutes): the live ValidatingPolicy shows
   `validationActions: [Deny]`; `kubectl -n mealie create --dry-run=server`
   of the test object is rejected naming the policy. The test object
   matches what the policy checks: a Pod without requests for
   `require-requests-limits`, a Deployment without probes for
   `require-probes` (it matches Deployments only). `KyvernoDenied`
   silent; no `FailedCreate`
   event naming the policy (`kubectl get events -A
   --field-selector reason=FailedCreate`); the Applications Synced and
   Healthy.
5. The next day: every CronJob ran (Requirement 8.5 for all namespaces);
   one week later: the weekly restore tests in `backup-verify` passed
   (they build CloudNativePG clusters).

### `KyvernoDenied` (task 36)

```yaml
- alert: KyvernoDenied
  expr: |
    sum by (name) (increase(apiserver_admission_webhook_rejection_count{name=~"vpol\\.validate\\.kyverno\\.svc.*",error_type="no_error"}[30m])) > 5
  labels:
    severity: critical
    action: human
  annotations:
    runbook_url: https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/KyvernoDenied.md
    summary: Kyverno policy {{ $labels.name }} rejected {{ $value | printf "%.0f" }} requests in 30 minutes
```

In `platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`, next to
`PodSecurityEnforceDenied` and built the same way. The API server labels
each rejection with the webhook's name, which Kyverno derives from the
policy (`vpol.validate.kyverno.svc-ignore-finegrained-<policy>` on
2026-11-04), so `name` says which policy. It counts every rejection the
API server got from Kyverno, for all Deny policies, the 16 of today
included; over the 7 days before 2026-11-04 the increase is 0. A
controller retries a rejected Pod with back-off and passes 5 within
minutes; the checks of this spec (one rejected dry run per Deny pull
request, at most two in the break-glass test) stay below. A namespace
silence does not match it (no `namespace` label), so a real denial during
a maintenance window still pages. Runbook
`docs/runbooks/alerts/KyvernoDenied.md`: the policy from the label, the
object from `FailedCreate` events or the Kyverno admission controller's
logs, then the Kyverno break-glass. Listed in the runbook index,
`docs/sre.md` and `tests/alertmanager/routes.txt`.

## Error handling

| Operation | Failure | Recoverable | What happens | Logged |
| --- | --- | --- | --- | --- |
| `pod-hardening` in `ci` | new gap, stale line, malformed file, bound `default` SA | yes, by the author | `ci` red with the messages above | `ci` log and step summary |
| Rollout of a non-root workload | the image cannot start non-root (`Permission denied`, `s6-overlay-suexec: fatal`, exit within seconds) | yes | `Recreate`: the app is down. The PostSync smoke test fails, or the Deployment turns Degraded after `progressDeadlineSeconds` (600 s); auto-rollback reverts 5 minutes later. The author reverts at once with `git revert` and `scripts/pr-merge.sh`, then redoes the task with the root profile and a `non-root` gap line | container logs; the PR comment |
| Rollout of the Syncthing StatefulSet (task 5) | `syncthing-0` never becomes Ready | yes | under `OrderedReady` the revert does not replace a Pod that is not Ready (the StatefulSet "forced rollback"), and auto-rollback deletes no Pods. After the revert syncs, `kubectl -n syncthing delete pod syncthing-0` (the task's brief allows it), then confirm the new Pod runs the reverted spec (`kubectl -n syncthing get pod syncthing-0 -o jsonpath='{.spec.securityContext}'`) and is Ready | the PR comment |
| Rollout, root profile | a dropped capability was needed, at start or at stop (the stop check) | yes | as above; the next attempt adds back the capability the log names, within the six | the same |
| `fsGroup` change | slow start on a large volume | yes | the kubelet holds the container until done; under 48,000 files it takes seconds. Over 100,000 files the task stops before merging (only `immich-data`, which never gets one) | kubelet events |
| Liveness probe too strict | restarts of a healthy app | yes | `KubePodCrashLooping`; a revert or a looser probe in a new PR | Alertmanager |
| Memory limit too low (tasks 21 to 34) | `OOMKilled` | yes | the container restarts; for `postgres`, crash recovery from WAL. Next-day and 7-day checks (`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`) and `KubePodCrashLooping`; a new PR with the limit from the rule and the new maximum | Prometheus |
| `Cluster.spec.resources` change | the instance does not come back | yes | CloudNativePG keeps the PVC; the revert restores the old spec; the 24-hour backup is the last resort | `kubectl cnpg status`, the operator log |
| `automountServiceAccountToken: false` | the app did call the API | yes | its errors name `serviceaccount` or `401`; revert and give it its own ServiceAccount in a new PR | container logs |
| Deny of a policy | a legitimate Pod rejected | yes | `KyvernoDenied` pages; the Kyverno break-glass (under a minute, admin kubeconfig only); then the revert | Alertmanager, events |
| `kyverno-deny-readiness.sh` | API, Alertmanager or JSON error | yes | `NOT READY` with the error, exit 1; the Deny PR waits | stdout |

## Testability

- Unit: `tests/test_repo_policy.py` for `pod-hardening` (a hardened
  fixture passes; one failing fixture per check; a root-profile container
  with `CHOWN` and `KILL` passes only with its `non-root` line, and one
  with `SYS_ADMIN` never; a stale line; a malformed line; a duplicate; a
  `default` RoleBinding; an own ServiceAccount with no binding in an
  application namespace; an `apps` Application whose namespace is not in
  `APP_NAMESPACES`; container-level
  `seccompProfile` overriding the pod's; a native sidecar counted as
  long-running). `tests/bash/test_kyverno_deny_readiness.sh` with a
  stubbed `kubectl` and `curl` (clean, one failing Pod, a ReplicaSet at 0
  ignored, an excluded namespace ignored, a stale report, an API error read
  as `NOT READY`, an unknown policy, a write verb refused).
  `tests/prometheus/kyverno_test.yaml` for `KyvernoDenied`.
- CI integration: the Kyverno check in `ci` reports every changed
  workload; the kind `preprod` job boots both Valkeys with their new
  security context and probes (`ci/kind-workloads.txt`), so tasks 3 and 6
  prove Valkey starts non-root before merge.
- Live: the recorded checks of Requirement 8, the readiness script, the
  break-glass test.

## Decisions

The operator delegated these (requirements.md). Each has its reason and the
alternatives rejected.

- **D1. One pull request per workload, theater included.** The issue asks
  for one per app; in `theater` and `books` an Application holds several
  apps with different images, so the unit is the workload with the helpers
  it owns (its Valkey, its exportarr sidecar). A failure then stops one
  app. Rejected: one per Argo CD Application (nine theater apps restarting
  together).
- **D2. Non-root by evidence, not by trial.** A container gets the
  non-root profile when the image has its own non-root user (the config
  `User`, or the user its entrypoint switches to, uid from the image's
  `/etc/passwd`) or upstream documents a uid (a docs page at the pinned
  version, where versioned, showing `user:`, `--user` or `runAsUser`,
  linked in the pull request); and it sets no `UMASK` and passes the NFS
  check. Otherwise the root profile with a reason. The evidence table
  applies this today, so each #1020 namespace has a stated outcome.
  Rejected: trying non-root on every image and
  reverting on failure (each failed try is an outage of a `Recreate` app
  until the revert); a start test in a scratch namespace with empty
  volumes (the app's first-run path differs from its real start, so a pass
  proves little, and scratch namespaces outlive their test, see #1022).
- **D3. A root profile instead of leaving root images alone.** Plex and
  the s6 images that need root still lose `NET_RAW`, `MKNOD` and the rest,
  privilege escalation and the unconfined seccomp profile, which `baseline`
  allows but nothing here uses. Root keeps `DAC_OVERRIDE` and `FOWNER`, so
  file access does not change, and the s6 images keep `KILL`, `SETGID` and
  `SETUID`, so the root supervisor can still drop to the app's uid and
  stop it cleanly. Rejected: dropping `KILL` (every stop would end in a
  `SIGKILL` after the grace period, which corrupts state such as
  qBittorrent's `ipc-socket`); no change for root images (among
  them are qBittorrent, whose port 50000 the router forwards from the
  internet, and the media servers, which stay off single sign-on).
- **D4. `fsGroup` only where the ownership check asks.** The apps have run
  with `PUID=1000` for years, so their files are already theirs; a
  recursive group change on every start-up (`Always`) or once
  (`OnRootMismatch`) changes data it does not need to, and on Syncthing it
  would sync to every peer. Rejected: `fsGroup` everywhere, as
  `audiobookshelf` and `home-assistant` have (harmless there, but not a
  rule to copy).
- **D5. Requests and limits from #917, except what it does not cover.**
  #917 sizes Deployments and StatefulSets from VPA after 8 days of
  history and adds `container-requests`; doing it here as well would size
  the same containers twice with two methods. VPA covers only rendered
  Deployments and StatefulSets, and #917 leaves out DaemonSets and
  `signoz`. So this spec sizes the operator-built Pods (the CloudNativePG
  instances and their `plugin-barman-cloud` sidecars, Prometheus,
  Alertmanager and their config reloaders), the DaemonSets that fail today
  (Tetragon, node-exporter), the infrastructure charts and SigNoz, with
  Prometheus percentiles in the same rounding. `grafana-postgresql` is
  #917's (its task 13 sets `spec.resources`); this spec adds its sidecar
  and fills `spec.resources` only if task 13 did not. Rejected: sizing in
  each application pull request (conflicts with #917 tasks 18 to 20);
  leaving the DaemonSets and Prometheus to #917 (it has no method for
  them, and `require-requests-limits` could never read `READY`).
- **D6. A ratchet file, not a list of hardened workloads.** The gaps file
  says what is missing and why, shrinks with each task, and fails CI both
  on a regression and on a fixed gap still listed, so the list is never
  stale. Rejected: Kyverno `BLOCKING` for the restricted set in the
  application namespaces (#1021's job, and it would need a second
  namespace list); review by eye.
- **D7. Fix through chart values; PolicyException only where a chart
  cannot.** One exception file per Application, matched by namespace and
  name prefix, as `policies/kyverno/exceptions/` does today. Rejected:
  Deny with exceptions for every platform finding (it hides findings that
  values can fix); post-render patches of charts (Argo CD renders the
  charts directly, and the repo has no post-renderer).
- **D8. A page on Kyverno rejections before any new Deny.** A Deny policy
  that rejects an operator's Pod (a database instance) stops it, and the
  CloudNativePG alerts lose their series with the Pod. The API server
  metric is already scraped, carries the policy in the webhook name and
  needs no Kyverno metric (the Kyverno metrics are filtered to two series,
  `infrastructure/kyverno/values.yaml`). Rejected: scraping Kyverno's
  `kyverno_policy_results_total` (thousands of series for one alert);
  relying on `FailedCreate` events (nothing alerts on events).
- **D9. Merge windows.** Application and database pull requests in the
  weekday window (the hard rule of 2026-11-02), 24 hours apart from a
  network-policy or Pod Security flip of the same namespace, so a failure
  has one cause. Spec, CI, script, alert and docs pull requests have no
  window.
- **D10. Order.** qBittorrent first, as the issue says: its known fault
  becomes visible. Then the namespaces of #1020, least used first
  (`paperless`, `mealie`, `syncthing`, `immich`), then `keycloak` (it
  serves every login, but its `RollingUpdate` keeps the old Pod until the
  new one is Ready), then `theater` and `books`, which stay `baseline` for
  their `nfs` volumes. Tokens, operator Pods and charts follow; the two
  Deny moves last.
- **D11. No ad-hoc backup.** Nothing here is one-way: a revert restores
  the old security context, and a group change leaves every file readable
  by the old root process. The 24-hour freshness rule applies and each
  pull request quotes the last backup time.
- **D12. `readOnlyRootFilesystem` stays out.** It needs a writable
  `emptyDir` per path each image writes, found by trial per app, and
  `restricted` does not require it. A follow-up issue.

## Lockout invariants

- No change to API server authentication, Talos, Argo CD, `kube-system`,
  namespace labels or the Kyverno webhook settings (`failurePolicy`,
  timeouts, `forceFailurePolicyIgnore`, the excluded namespaces
  `kube-system`, `argo`, `cilium`, `kyverno`, `tailscale`).
- The admin kubeconfig (client certificate) and the talosconfig do not
  depend on Keycloak; both are checked before and after the Keycloak and
  Deny pull requests.
- The Kyverno break-glass needs only the admin kubeconfig over the LAN.

## Risks

| Risk | Detection | Mitigation |
| --- | --- | --- |
| An image starts non-root but fails later (a task writes a root-owned path) | container logs, the 30-minute and next-day checks | ownership check; revert; root profile |
| A probe restarts a slow but healthy app | `KubePodCrashLooping` | startup probes from the measured start time; revert |
| Keycloak fails with the new context | its readiness; `auth` probe | `RollingUpdate` keeps the old Pod; revert |
| An operator release builds Pods without requests after the Deny | `KyvernoDenied` | Renovate merges CloudNativePG and the plugin on weekdays (#1085); break-glass; revert |
| A chart bump drops resources or probes | `ci` (`BLOCKING`) | blocks before merge |
| #917 sizing lags | the readiness script stays `NOT READY` | task 37 waits; nothing else depends on it |
| This spec and #917 change the same `Cluster` together | two causes for one failure | 24 hours apart; each pull request states `instances` at merge time |
| A s6 supervisor cannot stop its app | the stop check | `KILL` in the root profile; revert |

## Follow-up issues (opened with the spec pull request)

- `readOnlyRootFilesystem` per application (D12).
- Static NFS PersistentVolumes for the inline `nfs` volumes (theater,
  books, `immich-library-backup-local`, backup-verify), which would let
  `books` and `immich` pass `restricted`.
- `docs/runbooks/arr-qbittorrent.md` is stale today (it says there are no
  probes and the tag is `latest`): fixed in task 2, no issue needed.
