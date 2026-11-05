---
kind: change
status: active
created: 2026-11-04
issue: 726
---
# Requirements: per-app-hardening

## Introduction

Most application containers run with the defaults of their image: root,
privilege escalation allowed, the runtime's default capabilities, no
seccomp profile, and a mounted ServiceAccount token they never use. Several
have no liveness probe, and some have no readiness probe. On 2026-11-04
the Kyverno PolicyReports show, outside the webhook-excluded namespaces,
`require-probes` failing on 13 Deployments and `require-requests-limits` on
Pods in 13 namespaces. Among them are Pods that operators build from code
(the eight CloudNativePG instance Pods, Prometheus and Alertmanager) and
the Tetragon and node-exporter DaemonSets.

This spec hardens each application workload in its own pull request:
probes, a restricted security context (non-root where the image allows it),
and `automountServiceAccountToken: false` where the token is unused. It
then moves `require-requests-limits` and `require-probes` to Deny. It keeps
every PersistentVolumeClaim and every data volume as it is.

It fits two specs in flight:

- [pod-security-restricted](../pod-security-restricted/) (#724) moves
  namespaces to `enforce: restricted` once their workloads pass. The
  application namespaces `paperless`, `mealie`, `syncthing`, `keycloak` and
  `immich` wait for this spec; their flips are
  [#1020](https://github.com/ned-si/homelab/issues/1020), with #724's
  procedure. The Kyverno restricted set in Deny is
  [#1021](https://github.com/ned-si/homelab/issues/1021). This spec
  changes no namespace label and no restricted-set policy.
- [autoscaling](../autoscaling/) (#917) sets the CPU and memory requests
  and memory limits of the Deployments and StatefulSets of the apps and
  platform layers from VPA recommendations (its tasks 18 to 20, repo-policy
  `container-requests`). This spec does not size those containers. It sizes
  only what #917 does not cover: the Pods that operators build (the
  CloudNativePG instances, the Barman Cloud sidecar `plugin-barman-cloud`,
  Prometheus and Alertmanager), the DaemonSets #917 leaves out (Tetragon,
  node-exporter), the infrastructure-layer charts, and `signoz`, which
  #917 excludes. #917 also moves every CloudNativePG `Cluster` to
  `instances: 2` and creates `grafana-postgresql` (its task 13, which
  sets that cluster's `spec.resources`); this spec changes the same
  `Cluster` objects at least 24 hours apart from #917's change of each.

Issue [#726](https://github.com/ned-si/homelab/issues/726), from
gitops-delivery task 19. The operator authorised the whole security
hardening on 2026-11-03 with two conditions: never lock ourselves out, and
always keep a way back. The technical defaults are decided in
[design.md](design.md#decisions); the two that needed the operator are in
[Operator decisions](#operator-decisions).

## Glossary

- **Workload**: a Deployment, StatefulSet, DaemonSet, CronJob or Job and its
  pod template.
- **Long-running container**: a regular container of a Deployment,
  StatefulSet or DaemonSet. Init containers and Job containers are not.
- **Non-root profile**: the security context of design.md "Profiles":
  `runAsNonRoot: true`, a fixed uid and gid, seccomp `RuntimeDefault`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`. It passes
  Pod Security `restricted` when the volumes do.
- **Root profile**: the same without `runAsNonRoot` and with at most
  `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `KILL`, `SETGID` and `SETUID` added
  back, for an image that needs root at start. `KILL`, `SETGID` and
  `SETUID` are for an image whose supervisor runs as root and the app as
  another uid (s6-overlay): the supervisor needs `KILL` to stop the app.
  It passes `baseline`, not `restricted`.
- **The image's own user**: the `User` of the image config at the pinned
  digest, or the user the image's entrypoint switches to (`su-exec`,
  `gosu`, `setpriv`, `s6-setuidgid`), with its uid and gid read from
  `/etc/passwd` and `/etc/group` of the image at that digest.
- **Upstream documents a uid**: a documentation page of that image, at the
  pinned version where the project versions its docs, shows running it
  with `user:`, `--user` or `runAsUser`; the pull request quotes the link.
- **Application namespaces**: the constant `APP_NAMESPACES` in
  `scripts/ci/repo_policy.py`, today `books`, `home`, `immich`,
  `keycloak`, `mealie`, `paperless`, `syncthing` and `theater`.
- **Gap**: a check of Requirement 1 that a container does not meet,
  recorded in `ci/pod-hardening-gaps.txt` with its reason.
- **Operator-built Pod**: a Pod created by an operator from a custom
  resource or from code, not from a pod template in git: CloudNativePG
  instances and Jobs, the Barman Cloud sidecar, the Prometheus and
  Alertmanager StatefulSets of the Prometheus operator, tuppr's Jobs,
  Trivy's scan Jobs, the ClickHouse Pods of SigNoz, the backup-verify
  restore clusters.
- **Weekday window**: Monday to Friday, 09:00 to 16:59 Europe/Zurich.

## Requirements

### Requirement 1: CI keeps every hardened workload hardened

**User story:** As the operator, I want CI to fail a change that undoes a
hardening, so each pull request of this spec stays done.

#### Acceptance criteria

1. THE repo-policy rule `pod-hardening` SHALL check every container of
   every pod template in the objects repo-policy reads (the
   `render_apps.py` output, Helm charts included), and fail on a container
   that does not meet one of these checks and has no line for it in
   `ci/pod-hardening-gaps.txt`:
   1. `probes`: a long-running container has a `readinessProbe` and a
      `livenessProbe`;
   2. `seccomp`: the pod or the container sets `seccompProfile.type`
      `RuntimeDefault` or `Localhost`;
   3. `privilege-escalation`: `allowPrivilegeEscalation: false`;
   4. `capabilities`: `capabilities.drop` contains `ALL`, and `add` holds
      nothing but `NET_BIND_SERVICE`, or, when the container has a
      `non-root` gap, a subset of `CHOWN`, `DAC_OVERRIDE`, `FOWNER`,
      `KILL`, `SETGID`, `SETUID`;
   5. `non-root`: the pod or the container sets `runAsNonRoot: true`;
   6. `token`: a pod that runs as the namespace's `default` ServiceAccount
      sets `automountServiceAccountToken: false`, and no RoleBinding or
      ClusterRoleBinding in the rendered objects grants that `default`
      ServiceAccount anything; in the application namespaces, so does a
      pod whose own ServiceAccount no RoleBinding or ClusterRoleBinding in
      the rendered objects names.
   Checks 1 to 5 apply to the application namespaces; check 6 applies to
   every namespace the Kyverno webhooks do not exclude. (tests in
   `tests/test_repo_policy.py`: a passing fixture, and one failing fixture
   per check)
2. THE rule SHALL fail on a line of `ci/pod-hardening-gaps.txt` that names
   a container or check that has no gap any more, and on a malformed line,
   so the file shrinks with each pull request and says what is left.
   (the same tests)
3. EACH line SHALL be `<namespace>/<kind>/<name>/<container> <check>
   <reason>`, the reason either `#726 task <n>` (pending) or a reason that
   stays (for example "pms-docker starts as root"). (the same tests)
4. THE rule SHALL pass on `main` with the file seeded from the gaps on the
   day of its pull request. (`ci` green)
5. THE rule SHALL fail WHEN an Application under
   `clusters/homelab/apps/` has a destination namespace that is not in
   `APP_NAMESPACES`, so a new app cannot escape checks 1 to 5. (a fixture
   with an unlisted namespace)

### Requirement 2: Every long-running application container has probes

**User story:** As the operator, I want Kubernetes to see when an app stops
serving, so a stuck process is restarted or shows as not ready instead of
looking healthy.

#### Acceptance criteria

1. EVERY long-running container in the application namespaces of
   Requirement 1.1 SHALL have a readiness probe and a liveness probe, and
   so SHALL the Barman Cloud plugin Deployment; a container whose start can
   exceed the liveness budget (design.md "Probes") SHALL also have a
   startup probe. (rule `pod-hardening`, check `probes`)
2. A liveness probe SHALL check only the process itself (its own port or
   its own health endpoint), never a database or another service, and
   SHALL fail only after at least 2 minutes of failures. An HTTP path not
   shown to be free of database calls is replaced by `tcpSocket` on the
   same port. (the pull request diff, review against design.md "Probes")
3. THE qBittorrent liveness probe SHALL turn its stale-socket fault
   (`docs/runbooks/arr-qbittorrent.md`) into container restarts that
   `KubePodCrashLooping` reports, and the runbook's "Prevention" section
   SHALL describe the probes as they are. (the pull request)

### Requirement 3: Application containers run with the least privilege their image allows

**User story:** As the operator, I want each container to run as non-root
with no capability it does not need, so a compromised app gets as little
as possible.

#### Acceptance criteria

1. EVERY application container SHALL run the non-root profile WHEN its
   image allows it: the image has its own non-root user, or upstream
   documents a uid (Glossary). Otherwise, and also WHEN the container sets
   `UMASK` or has a read-write NFS mount that fails the NFS check of
   design.md, it SHALL run the root profile, with a `non-root` gap line
   naming the reason. (rule `pod-hardening`; the pull request quotes the
   evidence: the image's `User` from `docker buildx imagetools inspect` at
   the pinned digest and the entrypoint line that switches user, or the
   upstream documentation link)
2. A root-profile container SHALL add back only the capabilities its image
   needs, from the six of the root profile; `KILL`, `SETGID` and `SETUID`
   only for an image that switches user at start (s6-overlay, `su-exec`,
   `gosu`). (rule `pod-hardening`, check `capabilities`)
3. NO container SHALL set `runAsUser: 0`; the root profile leaves
   `runAsUser` unset. (`require-run-as-non-root-user`, already in Deny and
   `BLOCKING`)
4. THE uid and gid of a non-root container SHALL be the image's own user
   (Glossary) when it has one, and `1000:1000` otherwise (the `PUID` and
   `PGID` the apps use today). (the pull request quotes the `/etc/passwd`
   line or the documentation)
5. `fsGroup` SHALL be set only WHEN the ownership check of design.md finds
   files on a mounted PersistentVolumeClaim that the uid and gid cannot
   write, and never on `immich-data`, the Syncthing volume or an NFS
   mount. (the check's output in the pull request)
6. A container that sets `UMASK` SHALL keep it and the root profile: a pod
   spec cannot set a umask, and whether the s6 images still apply `UMASK`
   when started non-root is not verified. It moves to non-root only in a later pull request whose
   30-minute comment shows a `stat` of a file it wrote after the rollout
   with group write. (the diff)

### Requirement 4: No unused ServiceAccount token

**User story:** As the operator, I want a token mounted only into Pods
that call the Kubernetes API, so a compromised app cannot use one.

#### Acceptance criteria

1. EVERY pod template that runs as its namespace's `default` ServiceAccount
   SHALL set `automountServiceAccountToken: false`. (rule `pod-hardening`,
   check `token`)
2. A Pod that calls the API SHALL keep its own ServiceAccount and its
   token (today `presync-backup`, `backup-verify`, `talos-drift-check` and
   the exporters with their own ServiceAccount, each named by a binding).
   (the rule does not check them)
3. IN the application namespaces, a pod template whose own ServiceAccount
   no RoleBinding or ClusterRoleBinding in the rendered objects names
   (today `immich-server` and `immich-machine-learning`, whose accounts the
   Immich chart creates) SHALL set `automountServiceAccountToken: false`
   too, through the chart's pod options. (rule `pod-hardening`, check
   `token`)

### Requirement 5: Pods built by operators carry requests and limits

**User story:** As the operator, I want the Pods that operators build to
pass `require-requests-limits`, so moving it to Deny never stops a
database from starting.

#### Acceptance criteria

1. EVERY CloudNativePG `Cluster` SHALL set `spec.resources` (CPU and memory
   requests, memory limit), and every Barman Cloud `ObjectStore` the
   resources of its `plugin-barman-cloud` sidecar, sized as in design.md
   "Sizing". A changed `ObjectStore` SHALL sync before its `Cluster`, and
   after the sync every instance Pod SHALL run a sidecar with the new
   resources, restarted with `kubectl cnpg restart` WHEN it does not.
   (the sidecar's `resources` from the instance Pods and their
   PolicyReports showing `pass` for `require-requests-limits`, quoted in
   the pull request)
2. THE `verify-source` ObjectStore of `backup-verify` SHALL set its
   sidecar's resources too; the restore clusters that
   `platform/backup-verify/scripts/verify-postgres.sh` creates already set
   `spec.resources`. (the next weekly restore test passing, its restore
   Pod's PolicyReport `pass`)
3. THE infrastructure-layer charts (`cert-manager`, `external-dns`,
   `democratic-csi`), the SigNoz ClickHouse operator, Tetragon, the
   node-exporter DaemonSet, and the Prometheus and Alertmanager custom
   resources with their config-reloader sidecars SHALL set requests and a
   memory limit on every container, through their chart values. (the
   Kyverno report in `ci` for the charts; the live PolicyReports for the
   Pods the Prometheus operator builds)
4. `grafana-postgresql`, created by #917 task 13 with its
   `spec.resources`, SHALL get its sidecar resources here, and
   `spec.resources` too WHEN #917 task 13 merged without them. (as 5.1)
5. A pull request that changes a `Cluster` SHALL merge at least 24 hours
   apart from #917's change of the same `Cluster`, and SHALL state its
   `instances` at merge time; with two instances it SHALL record the
   switchover CloudNativePG performs and count the added memory for both.
   (the pull request)

### Requirement 6: `require-requests-limits` and `require-probes` in Deny

**User story:** As the operator, I want a Pod without requests, or a
Deployment without probes, rejected, once nothing legitimate is.

#### Acceptance criteria

1. `scripts/kyverno-deny-readiness.sh <policy>` SHALL print `READY` and
   exit 0 only WHEN: the policy has no `fail` result in the PolicyReports
   on a Pod, a Deployment, StatefulSet, DaemonSet, Job, CronJob, or a
   ReplicaSet above 0 replicas, outside `EXCLUDED_NAMESPACES` of
   `scripts/ci/kyverno.sh` (read from that file); `KyvernoReportsStale`
   is not firing; and the newest PolicyReport is under 2 hours old.
   Otherwise it SHALL print each failing object and exit 1.
   It SHALL only read. (its bash test with a stubbed `kubectl`)
2. A policy SHALL move to Deny in one pull request that adds it to the
   `[Deny]` patch of `infrastructure/kyverno-policies/kustomization.yaml`
   and to `BLOCKING` in `scripts/ci/kyverno.sh`, plus the PolicyExceptions
   it needs and the policy counts in the docs (design.md "The Deny pull
   request"). (the diff; `ci` green, which proves `deploy/` and the Helm
   renders pass)
3. ITS body SHALL quote `scripts/kyverno-deny-readiness.sh <policy>` with
   the time, the list of operator-built Pods the policy matches with the
   evidence for each, and `## Rollback` with the `git revert` and the
   Kyverno break-glass of `docs/runbooks/pod-security.md`.
4. A PolicyException SHALL be used only for a chart workload whose chart
   cannot set the field, one file per Application, matched by namespace
   and name prefix, with the reason in `homelab/reason`.
5. `require-requests-limits` SHALL move only after #917 tasks 13 and 18
   to 20 and tasks 21 to 34 here have merged; `require-probes` only after
   tasks 2 to 17, 20, 27, 29 and 30.
6. THE Kyverno break-glass SHALL be tested live in the first Deny pull
   request of this spec or of #1021, whichever comes first, as #724
   Requirement 5.3 asks. (times and outputs in the pull request)

### Requirement 7: A page when Kyverno rejects

**User story:** As the operator, I want to know when a Kyverno policy in
Deny keeps rejecting Pods, so a rejected operator Pod is fixed in minutes.

#### Acceptance criteria

1. THE alert `KyvernoDenied` (`severity: critical`, `action: human`) SHALL
   fire WHEN, for one Kyverno validating webhook,
   `increase(apiserver_admission_webhook_rejection_count{name=~"vpol\\.validate\\.kyverno\\.svc.*",error_type="no_error"}[30m])`
   is above 5, and its runbook SHALL lead to the Kyverno break-glass.
   (`platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`;
   `tests/prometheus/kyverno_test.yaml`: a controller retrying fires, one
   rejected dry run does not; the live 7-day query in the pull request,
   0 rejections on 2026-11-04)
2. THE alert SHALL merge before the first Deny pull request of this spec.

### Requirement 8: Each change is small, timed and watched

**User story:** As the operator, I want each hardening to restart one app
at a time while I am around, with a way back.

#### Acceptance criteria

1. EACH task SHALL be one pull request that changes one workload (with the
   helpers it owns, such as its Valkey), one database namespace, one chart
   or one policy, and removes the gap lines it closes.
2. A pull request that restarts an app or a database SHALL merge in the
   weekday window, and not within 24 hours of a network-policy flip (#709)
   or a Pod Security flip (#724, #1020) of the same namespace.
3. ITS body SHALL have `## Rollback` with the exact `git revert`.
4. WITHIN 30 minutes of the sync, a pull request comment SHALL record: the
   Application Synced and Healthy, the PostSync smoke test passed where the
   app has one, the Pod Ready with 0 restarts, no `Permission denied` or
   `Operation not permitted` in the container logs since the start, the
   public route answering (`probe_success` 1), and for the namespaces of
   #1020 the output of `scripts/psa-readiness.sh <ns>`. FOR a
   root-profile container of an image that switches user, it SHALL also
   record the stop check of design.md: `kubectl logs -f` on the container
   while `time kubectl -n <ns> delete pod <pod>` runs, the delete
   returning in under half of `terminationGracePeriodSeconds` and the last
   log lines showing s6 stopping its services with no
   `Operation not permitted`.
5. WITHIN 26 hours, every CronJob of the namespace SHALL have run once and
   succeeded, or the comment SHALL say why not (a weekly or monthly
   schedule).
6. FOR the Keycloak and the Deny pull requests, the admin kubeconfig
   (`kubectl auth whoami`: `admin`) SHALL be checked before and after the
   merge.

### Requirement 9: No data and no volume changes

#### Acceptance criteria

1. NO pull request of this spec SHALL rename, recreate or delete a
   PersistentVolumeClaim, change a `claimName`, a `volumeClaimTemplates`
   entry, a `storageClassName` or the Immich `forceRename`, or write to
   `immich-data`. (the diff)
2. A pull request that restarts an app with a data volume SHALL quote the
   time of the volume's last successful backup, under 24 hours old (the
   24-hour freshness rule); if it is older, the pull request waits for the
   next scheduled backup to succeed. None takes an ad-hoc backup, since
   none is a one-way change. (the pull request)

### Requirement 10: Docs and close

#### Acceptance criteria

1. `docs/architecture.md` (admission policy) and `docs/threat-model.md`
   SHALL describe the profiles, the remaining gaps and the two policies in
   Deny; `docs/testing.md` the rule `pod-hardening`. (the close-out pull
   request)
2. `ci/pod-hardening-gaps.txt` SHALL hold only reasons that stay, each
   with an issue when it can be fixed later.
3. THE spec SHALL be `done` with its `closed` date when its tasks are
   ticked, gitops-delivery task 19 SHALL point here, and #726 SHALL close
   with a comment on #1020 saying which namespaces' gates are open.
4. NO file under `apps/` or `platform/` SHALL keep the header comment
   "Hardening (probes, security contexts, resources, image digests) is a
   later, separate change"; each task removes it from the files it
   hardens. (`grep -rn 'Hardening (probes' apps platform` empty in the
   close-out pull request)

## Non-functional requirements

- **Never locked out.** Nothing here touches API server authentication,
  Talos, Argo CD, the Kyverno webhook settings (`failurePolicy`,
  timeouts, namespace exclusions), `kube-system` or any namespace label.
  A broken Keycloak stops single sign-on to the UIs, not `kubectl`: the
  admin kubeconfig is a client certificate.
- **Always a way back.** Every change is a revert. A revert restores the
  old security context; files whose group `fsGroup` changed stay readable
  by the old root process.
- **Deterministic first.** The checks are the repo-policy rule, the Kyverno
  CI check, the readiness script, the alert and the recorded live checks.
- **arm64**: no new image.

## Out of scope

- CPU and memory sizing of the Deployments and StatefulSets of the apps and
  platform layers: #917 tasks 18 to 20.
- Namespace Pod Security levels (#724, #1020) and the Kyverno restricted
  set in Deny (#1021).
- `readOnlyRootFilesystem` (`require-ro-rootfs` stays in Audit): a
  follow-up issue.
- Replacing the inline `nfs` volumes (theater, books, the Immich
  `immich-library-backup-local` CronJob, backup-verify) with static NFS
  PersistentVolumes, which `restricted` allows: a follow-up issue.
- Security contexts of the privileged agents (`democratic-csi`, `logging`,
  `monitoring` node exporter, `tailscale`, `tetragon`, `lan-inventory`) and
  of the webhook-excluded namespaces (`kube-system`, `argo`, `cilium`,
  `kyverno`, `tailscale`).
- Network policies (#709). CPU limits (none, by the repo's convention).

## Operator decisions

Decided on 2026-11-05. Changing one later is a new issue.

1. **Immich server stays root.** `immich-server` writes the photo library
   on `immich-data` (277,908 files, `kubelet_volume_stats_inodes_used`,
   design.md evidence). Running it non-root
   would need the library owned by its uid: a recursive `chown`, a write
   to `immich-data` beyond reading. The operator judged the gain not worth
   it. `immich-server` runs the root profile (file access unchanged),
   `immich` stays `baseline`, and #1020 keeps `immich` open with this
   reason.
2. **Jellyfin keeps the root profile.** Whether
   `192.168.1.228:/mnt/homelab/k8s/nfs/media` maps every client to uid
   `1000` (TrueNAS: Sharing, NFS, the export, Mapall User) is not known.
   Every container that runs as root today and has a read-write NFS mount
   therefore keeps the root profile. Jellyfin was the only one whose
   outcome depended on it; the others are root for other reasons.
   Audiobookshelf already runs as `1000:1000` on a read-write mount of
   `192.168.1.228:/mnt/homelab/k8s/nfs` and stays as it is.
