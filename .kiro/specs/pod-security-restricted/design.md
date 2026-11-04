# Design: pod-security-restricted

## Overview

Pod Security admission is the enforcement; Kyverno is the audit. A
namespace moves to `enforce: restricted` when its pods and pod templates
pass `restricted` today (the gate, Requirement 2), and CI keeps them passing
afterwards (Requirement 3). Each move is a one-line pull request with a
tested way back.

1. **Audit.** `warn` and `audit` at `restricted` on the namespace, the
   Kyverno restricted set in Audit, complete reports (task 1).
2. **Gate.** `scripts/psa-readiness.sh <ns>` prints `READY` (G1 to G3), the
   operator-created Pods are checked (G4), and the flip's `ci` is green with
   the namespace in the restricted check (G5).
3. **Enforce.** The flip: one `enforce` label, watched for 30 minutes, its
   CronJobs checked the next day (Requirements 6, 7).

PSA judges a Pod when it is created. A flip does not touch running Pods, so
the risk of a flip is a Pod created later that fails `restricted`: a
rollout, a node drain, a CronJob run, an operator's Job. The gate covers the
templates that exist; CI covers the templates that change.

## Evidence at the start (2026-11-04, 08:15 UTC)

Server dry-run of `enforce=restricted` per namespace (`kubectl label
--dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=restricted`),
and the Kyverno restricted set's `fail` results on live Pods (PolicyReports):

| Namespace | Enforce today | Pods failing `restricted` | What fails | Gate |
| --- | --- | --- | --- | --- |
| `home` | baseline (Talos default) | 0 of 9 | | open |
| `system-upgrade` | baseline (Talos default) | 0 of 3 | | open |
| `paperless` | baseline (Talos default) | 2 of 8: paperless, valkey | privilege escalation, capabilities, runAsNonRoot, seccomp | closed (#726) |
| `mealie` | baseline (Talos default) | 1 of 8: mealie | same | closed (#726) |
| `syncthing` | baseline (Talos default) | 1 of 6: syncthing-0 | same | closed (#726) |
| `keycloak` | baseline (Talos default) | 1 of 5: keycloak | same | closed (#726) |
| `immich` | baseline (Talos default) | 6 of 15: server, machine-learning, valkey, 3 `immich-library-backup-local` Job pods | same; the backup Job mounts the NAS as an inline `nfs` volume | closed (#726) |
| `books` | baseline (Talos default) | 5 of 10: audiobookshelf, calibre-web, 3 config-backup Job pods | inline `nfs` volumes; calibre-web starts as root (s6-overlay) | stays baseline |
| `theater` | baseline (Talos default) | 9 of 52: the *arr apps, Plex, Jellyfin, qBittorrent, LazyLibrarian | inline `nfs` media volumes; the linuxserver images start as root | stays baseline |
| `backup-verify` | baseline (Talos default) | 1 of 4: the files restore test | inline `nfs` volume of the NAS restic repository | stays baseline |
| `signoz` | baseline | 6 of 10: ClickHouse, ZooKeeper, the collector | the chart exposes no security context for them | stays baseline |

Already `restricted`: `argo`, `cert-manager`, `external-dns`, `gateway`,
`headlamp`, `hubble`, `kubelet-serving-cert-approver`, `kyverno`,
`metrics-server`, `trivy-system`. Privileged by need, with the reason in
`namespaces.yaml`: `democratic-csi`, `logging`, `monitoring`, `tailscale`,
`tetragon`. Exempt: `kube-system`. Unused: `ingress`, `selinux-scratch`
(#1022).

Kyverno: the ten baseline policies and six others in Deny, the five
restricted policies in Audit. Each of the five fails in at least eight
namespaces. 17 policies are not ready for reporting, for want of read
access to `pods/ephemeralcontainers` (Requirement 1).

`system-upgrade` runs tuppr, whose upgrade and hook Jobs are built in code.
At the pinned 0.5.12 (`internal/controller/jobs/jobs.go`,
`BuildTalosctlPodSpec` and `BuildHookPodSpec`) both set `runAsNonRoot`,
user 65532, seccomp `RuntimeDefault`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, and mount only a Secret volume: they pass
`restricted`.

`home` runs `home-assistant-postgresql`. CloudNativePG builds its instance
Pods and its Jobs (`initdb`, `join`) from the same security context, and
the running instance passes the dry run.

Firing at 08:20 UTC: `Watchdog` and `InfoInhibitor` only.

## The checks

### `scripts/psa-readiness.sh <namespace>` (task 2)

Read-only: `get`, `list` and `--dry-run=server` only, so it runs with the
admin kubeconfig or the read-only agent kubeconfig plus dry-run rights.

- G1. `kubectl label --dry-run=server --overwrite namespace <ns>
  pod-security.kubernetes.io/enforce=restricted`: the API server evaluates
  every existing Pod in the namespace and prints a warning per failing Pod.
  Pass: no `Warning:` line.
- G2. The namespace's PolicyReports, results of the restricted set, the
  baseline policies and `require-run-as-non-root-user`: no `fail` on a Pod,
  a Deployment, StatefulSet, DaemonSet, Job, CronJob, or a ReplicaSet with
  `spec.replicas` above 0. Old ReplicaSets at 0 are ignored: going back to
  one goes through git and CI. Pass also needs `KyvernoReportsStale` not
  firing (read from Alertmanager).
- G3. For each controller in the namespace, a Pod built from its pod
  template (`metadata.namespace`, a generated name, `spec` from the
  template) is sent with `kubectl create --dry-run=server -f -`. Under
  `warn: restricted` the API server returns a PodSecurity warning for a
  failing template; after the flip it returns an error. Pass: neither. This
  covers what G1 cannot see: Deployments at 0 replicas, CronJobs between
  runs, StatefulSets whose Pod is gone.

Output: one line per check, `READY` or `NOT READY` with each failing Pod or
template and the controls it fails. Exit 0 only on `READY`.

### G4: Pods built by operators

Not in git, so neither CI nor G3 sees them until they exist. Each flip
pull request lists them for its namespace with the evidence:

| Namespace | Operator | Pods | Evidence |
| --- | --- | --- | --- |
| `home` | CloudNativePG | `home-assistant-postgresql` instances, `initdb` and `join` Jobs | the running instance passes G1; the Jobs share its security context |
| `system-upgrade` | tuppr 0.5.12 | upgrade Jobs, hook Jobs | source above; a server dry-run of an equivalent Pod after the flip |

G4 holds for the pinned operator versions. A later release can build
different Pods; decision D15 covers that.

Notes for the script:
- After a flip, G1 is a no-op: PSA evaluates existing Pods only when the
  enforce level changes. G2 and G3 carry the 30-minute check of
  Requirement 7.2.
- A StatefulSet with `volumeClaimTemplates` (`syncthing`): the Pod built
  for G3 gets one `persistentVolumeClaim` volume per claim template, named
  as the StatefulSet controller names it (`<claim>-<statefulset>-0`). Any
  dry-run error that does not name PodSecurity prints `NOT READY` with the
  error, so a template the script cannot build never reads as clean.
- `system-upgrade` also runs the `talos-drift` CronJob, which mounts
  `image` volumes. It is in git, so G3 decides it at flip time, and the
  flip pull request names its result. If it fails, the gate is closed and
  `system-upgrade` stays `baseline` with that reason.

### CI (task 3)

`scripts/ci/kyverno.sh` reads `infrastructure/namespaces/namespaces.yaml`
with `yq` and adds a rule: a finding of the restricted set on an object in a
namespace labelled `enforce: restricted` blocks, as a finding of a
`BLOCKING` policy does. The baseline policies and
`require-run-as-non-root-user` block everywhere already.

The script drops the Helm-rendered objects of `EXCLUDED_NAMESPACES`
because the webhooks skip them, but PSA does not. For this rule it keeps
the objects of every namespace that is in `EXCLUDED_NAMESPACES` and marked
`enforce: restricted` in `namespaces.yaml`, computed at run time from the
two lists. Today that is `argo` (the Argo CD chart) and `kyverno` (the
Kyverno chart, `clusters/homelab/infrastructure/kyverno.yaml`), and the CI
log prints the set. A Kyverno or Argo CD chart bump with a container PSA
would reject then fails its own `ci`.

A flip pull request adds its namespace to the label, so its own `ci` is G5.

## Break-glass

A flip that rejects Pods shows as `FailedCreate` events naming PodSecurity
and a rollout or Job that does not start. Running Pods are not affected.

1. Stop Argo CD from putting the label back, for the `namespaces`
   Application only:
   `kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile=true`.
2. Put the namespace back to `baseline`:
   `kubectl label --overwrite namespace <ns> pod-security.kubernetes.io/enforce=baseline`.
   PSA reads the label at the next Pod creation; the controllers' retries
   then succeed.
3. Hold merges (disable `renovate-next`, auto-merge off on open pull
   requests, stop other runners), then merge the revert with
   `scripts/pr-merge.sh`.
4. After the revert has synced:
   `kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile-`,
   then check the `namespaces` Application is Synced and the label matches
   git.

Steps 1 and 2 need only the admin kubeconfig over the LAN, and take less
than a minute. Task 7 tests them live. The test rejects at most two Pods,
below the threshold of `PodSecurityEnforceDenied` (D15).

Kyverno (for #1021): the same `skip-reconcile` on the `kyverno-policies`
Application, then `kubectl patch validatingpolicy <name> --type merge -p
'{"spec":{"validationActions":["Audit"]}}'`, then the revert. Written in
the runbook here, tested in #1021's first pull request.

## The flip, step by step

1. Before: `date -u` inside the window (D8); `scripts/psa-readiness.sh
   <ns>` prints `READY`; the G4 list; the lockout checks (Requirement 7.4).
2. Open the pull request: the label line in `namespaces.yaml`, its header
   line, `deploy/`; the body quotes the readiness output with its time, the
   G4 list and `## Rollback`.
3. `scripts/maintenance-silence.sh <ns> 1h "PSA enforce <ns>, PR #<n>"`.
4. `scripts/pr-merge.sh <n>`.
5. After the sync, the checks of Requirement 7.1 and 7.2, then expire the
   silence and post the comment.
6. The next day, the CronJob comment of Requirement 7.3.

## Decisions

The operator delegated these decisions (see requirements.md). Each has its
reason and the alternatives rejected.

- **D1. PSA enforces, per namespace.** PSA runs inside the API server: no
  webhook, nothing to fail open, the same in a cold start and with Kyverno
  down, and it is already how the ten platform namespaces enforce. Rejected:
  Kyverno Deny as the enforcement (its webhooks fail open by design, so it
  cannot be the only control); a second copy of the five Kyverno policies,
  scoped to restricted namespaces and in Deny (five more policies, double
  report entries, and patches over vendored files, for an earlier rejection
  that CI already gives before merge).
- **D2. The Kyverno restricted set stays in Audit here.** Each policy moves
  to Deny cluster-wide, one per pull request, when its live reports have no
  `fail` outside the webhook-excluded namespaces and the committed
  PolicyExceptions (#1021, after #726). Rejected: Deny now with a
  PolicyException for each of the roughly 30 failing workloads (the
  exceptions turn their results into `skip`, which hides the findings #726
  works from, and every #726 pull request would edit the list); one
  PolicyException for every namespace not enforcing `restricted` (the same
  loss of findings).
- **D3. CI blocks the restricted set in enforced namespaces.** Without it, a
  change that fails `restricted` merges, its new ReplicaSet cannot create
  Pods, and a Deployment with the `Recreate` strategy (19 of the 29 in
  `deploy/`) is down until the revert. The namespace list comes from
  `namespaces.yaml`, so a flip cannot forget it. Rejected: a second list in
  `kyverno.sh` (drifts); relying on the PSA warning at sync (nothing reads
  it).
- **D4. The gate reads the evaluation directly.** G1 and G3 ask the API
  server for the same PSA verdict an audit event would hold. Rejected:
  the audit annotations, because Talos keeps the API server audit log on
  each control plane's disk and nothing ships it (Vector ships Talos service
  logs and auditd records), and shipping it is a log-volume decision for
  #801; the API server metric `pod_security_evaluations_total`, because it
  has no namespace label.
- **D5. Order: `home`, then `system-upgrade`.** The two namespaces whose gate
  is open. `home` first: an app namespace with a public route to check
  (`home.lilalala.com`) and a CloudNativePG cluster, which proves the
  CloudNativePG path before `immich` (the operator's namespace) in #1020.
  `system-upgrade` second: tuppr's Jobs pass `restricted` in code, and a
  rejected upgrade Job leaves the nodes running and raises
  `TalosUpgradeStuck`; nothing in Talos or the kubelet depends on it.
  A later tuppr or CloudNativePG release that changes the Pods it builds
  is D15. Rejected: all clean namespaces in one pull request (one namespace per
  change); skipping `system-upgrade`. The gain there is small, since whoever
  can create Pods in `system-upgrade` can mount the `os:admin` talosconfig
  anyway, but the gate is open, the cost is one label, and every namespace
  then sits at the strictest level its workloads allow, which leaves only
  the namespaces with a stated reason below `restricted`.
- **D6. No 7-day window.** PSA judges Pod specs, not traffic. The templates
  that exist today are the whole input, and G2 and G3 read them all,
  CronJobs included, whatever their schedule. Rejected: a soak before each
  flip as in netpol-default-deny (it measures nothing here).
- **D7. Break-glass: `skip-reconcile` on the `namespaces` Application, then
  relabel.** It stops Argo CD from restoring the label for that Application
  only, and the layer above does not remove an annotation it does not
  manage (task 7 checks this). Rejected: scaling the Argo CD application
  controller to 0 (stops every app and the auto-rollback's syncs); turning
  off self-heal in the Application (the `infrastructure` layer heals it
  back); the git revert alone (10 to 20 minutes of CI while Pods cannot
  start).
- **D8. Flips merge Monday to Friday, 09:00 to 16:59 Zurich time.** A wrong
  flip stops Pods from starting; the operator is around to see it (the
  hard rule of 2026-11-02). Spec, docs and CI pull requests have no window.
- **D9. One silence per flip**, `scripts/maintenance-silence.sh <ns> 1h`,
  expired after the 30-minute checks. Never `Watchdog`, never the cluster.
- **D10. No soak between flips.** A label in one namespace cannot change
  what another admits. Each flip still gets its next-day CronJob check.
- **D11. `enforce-version` stays `latest`**, as in the ten restricted
  namespaces today. The PSS `restricted` controls have not changed since
  Kubernetes 1.25, and `warn: latest` on the same namespace warns on the
  next apply of each workload after an upgrade. Rejected: pinning the version
  (a label bump in every namespace at each Kubernetes minor, by hand).
- **D12. Explicit `enforce` labels everywhere** (task 4). `backup-verify`,
  `books` and `theater` enforce `baseline` only through the Talos admission
  default. Written in git, the level holds on any cluster, including the
  disaster-recovery site and the kind pre-production cluster, and
  repo-policy can require the label. No change on this cluster.
- **D13. No backup and no etcd snapshot for a flip.** A flip changes one
  Namespace label; it touches no database, volume, running Pod or Talos
  setting. The 24-hour freshness rule applies as usual.
- **D14. Auto-rollback is a backstop only.** A Deployment that cannot create
  Pods turns Degraded after `progressDeadlineSeconds` (600 s), and
  auto-rollback reverts the newest merge 5 minutes later. A CronJob whose Pod
  is rejected does not degrade an Application, so `PodSecurityEnforceDenied`
  (D15), the 30-minute watch and the next-day check are the real detection.
- **D15. Operator releases: a page on any enforce denial, and merges in the
  day.** tuppr builds its Jobs in code, and CloudNativePG builds the
  `home-assistant-postgresql` instance Pod and its Jobs in code; the
  Barman Cloud plugin adds its sidecar to that Pod. CI cannot see these
  Pods, and G4 holds only for the pinned versions. A release that builds a
  Pod `restricted` rejects merges on green CI today; CloudNativePG can then
  recreate the single instance during its upgrade and fail, so Home
  Assistant loses its database, and tuppr's next upgrade Job fails, so
  Talos and Kubernetes upgrades stop while the nodes keep running. Two
  controls, both before the first flip (tasks 5 and 6):
  1. Detection: the alert `PodSecurityEnforceDenied`, `critical`,
     `action: human`, on
     `sum(increase(pod_security_evaluations_total{decision="deny",mode="enforce",resource="pod"}[30m])) > 5`.
     The API server counts every Pod PSA rejects in enforce mode, whichever
     controller or operator sent it; on 2026-11-04 the series has no
     `deny` in `enforce` mode over 7 days, so the alert is silent today. A
     controller retries a rejected Pod with back-off, which passes 5 within
     minutes; the flip's own checks (one rejected dry run in Requirement
     7.1, two rejected Pods in the break-glass test) stay below it. The
     metric has no namespace label (why D4 does not use it for the gate);
     the runbook finds the namespace from the `FailedCreate` events
     (`kubectl get events -A --field-selector reason=FailedCreate`) and
     the operator's logs, then runs the break-glass. A namespace silence
     does not cover the alert: a real denial during a flip still pages.
  2. Timing: a Renovate rule gives the tuppr chart, the `cloudnative-pg`
     chart and `plugin-barman-cloud` `automergeSchedule: ['* 9-16 * * 1-5']`
     and the label `automerge-weekdays`, as for Cilium, without the 3-day
     release age. A release that breaks lands when the operator is around
     (the hard rule of 2026-11-02).
  Accepted residual risk: such a release still stops the database or the
  upgrade until someone runs the break-glass, which takes under a minute
  after the page; the controllers' retries then create the Pods. Other
  alerts that see it: `TalosUpgradeStuck` and `TalosUpgradeFailed` (tuppr's
  chart) for an upgrade Job, and the `home` blackbox probe's SLO alerts if
  Home Assistant stops answering without its database. The CNPG alerts do
  not: their series come from the instance Pod and vanish with it, which is
  why `PodSecurityEnforceDenied` is the main detection.
  Rejected: a G4 check in the Renovate pull request's body (nothing writes
  into Renovate pull requests, and these updates automerge); a post-sync
  CronJob that dry-runs a Pod equivalent to the operator's (the new Pod
  spec exists only in the new release's code, so a Pod copied from the old
  one proves nothing, and CloudNativePG recreates its instance during the
  sync, so the check would come no earlier than the alert); running
  CloudNativePG and tuppr in the kind pre-production cluster with a
  `restricted` namespace (a database cluster with storage on every `ci`
  run, and tuppr's Jobs need Talos, for a class of update that comes a few
  times a year); `no-automerge` on these updates (a human gate, against the
  no-human-gates principle).

## Lockout invariants

- The admin kubeconfig (client certificate, `system:masters`) and the
  talosconfig are checked before and after every merge. Nothing here
  touches API server authentication or Talos.
- `kube-system` stays exempt; `argo`, `kyverno` and `immich` keep their
  level; the Kyverno webhooks keep failing open and skipping `kube-system`,
  `argo`, `cilium`, `kyverno` and `tailscale`.
- The break-glass needs only the admin kubeconfig over the LAN.

## Risks

| Risk | Detection | Mitigation |
| --- | --- | --- |
| A Pod the gate did not see fails `restricted` after a flip | `PodSecurityEnforceDenied`, `FailedCreate` events, a stuck rollout | G4 list; break-glass; revert |
| A later change fails `restricted` | `ci` (D3), Helm charts of `argo` and `kyverno` included | blocks before merge |
| An operator release (tuppr, CloudNativePG, Barman Cloud plugin) changes the Pods it builds | `PodSecurityEnforceDenied`; `TalosUpgradeStuck`; the `home` probe | D15: merges on weekdays in the day; break-glass; accepted residual |
| A Kubernetes upgrade tightens `restricted` | the `warn` label at the first apply | D11; the upgrade's CI rehearsal |
