# Design: netpol-default-deny

## Overview

Nothing new is built for enforcement itself. The switches exist
(`infrastructure/network-policies/90-enforcement.yaml`), the allow-lists exist
for five namespaces, and the would-be drops are recorded. This spec adds what
is missing around them: a readiness series that can be queried, a tested
break-glass runbook, allow-lists for five more namespaces, and the order and
checks for the flips. Each flip is a one-line pull request.

Audit, then enforce, per namespace and direction:

1. **Audit.** The allow-lists are synced default-allow. Hubble counts every
   connection no rule covers (`match="all"`), recorded as
   `netpol:would_drop:*` (`platform/kube-prometheus-stack/routes/netpol.yaml`).
2. **Decide.** Every residual would-be drop becomes an allow rule or an
   intended drop (Requirement 3), in its own pull request.
3. **Gate.** 7 days of verdicts with zero would-be drops, or only intended
   ones (`netpol:ready_to_enforce`, Requirement 2).
4. **Enforce.** The flip: one switch value `false` to `true`, watched for 30
   minutes, soaked for 24 hours (Requirements 4, 7).

## Evidence at the start (2026-11-04 02:43 UTC)

Would-be drops over 7 days (`avg_over_time(netpol:would_drop:rate5m[7d]) *
604800`); 10,079 one-minute samples of `netpol:verdicts:rate5m` in every
namespace and direction, so verdicts cover the whole window. Ready is the
recorded `netpol:ready_to_enforce`, read with `last_over_time(...[20m])`
(see "The readiness gap").

| Namespace | Ingress drops | Ingress ready | Egress drops | Egress ready | Known residuals |
| --- | --- | --- | --- | --- | --- |
| `paperless` | 0 | 1 | 0 | 1 | none |
| `mealie` | 2.1 | 0 | 2.1 | 0 | not identified yet (task 4) |
| `syncthing` | 0 | 1 | 15,442 | 0 | peers' private addresses, NAT-PMP to the host, Syncthing to the API server (331 in 7 days on 2026-10-26) |
| `immich` | 0 | 1 | 7.6 | 0 | not identified yet (task 8) |
| `theater` | 3.9 | 0 | 1,576 | 0 | Plex and Jellyfin to the internet off 443, qBittorrent to `remote-node` |

Namespaces with workloads and no allow-list: `books` (audiobookshelf,
calibre-web; LazyLibrarian runs in `theater` and is covered by
`10-theater.yaml`), `home` (Home Assistant, Mosquitto, Zigbee2MQTT and
`home-assistant-postgresql`), `backup-verify`, `keycloak` (Keycloak and
`keycloak-db`), `monitoring`.

Firing at 02:30 UTC: `Watchdog` only. Argo CD: 53 of 53 Applications Synced
and Healthy at 02:21 UTC.

## The readiness gap

`netpol:would_drop:increase7d` and `netpol:ready_to_enforce` returned no
series to an instant query although Prometheus reports the group
`netpol.ready` healthy (last evaluation 02:36:01 UTC, 0.036 s). Cause: the
group runs every 15 minutes and Prometheus' lookback delta is 5 minutes
(`query.lookback-delta: 5m`), so an instant query finds the series only in
the 5 minutes after each evaluation, and the dashboard's stat panels show
gaps two thirds of the time. `last_over_time(netpol:ready_to_enforce[20m])`
returns all 10 series, and `count_over_time(netpol:ready_to_enforce[1d])` is
96 per series, one per 15 minutes: the rules work. The promtool test passes
because its `eval_time: 8d` falls on the 15-minute grid.

Fix (task 1): `interval: 2m` for `netpol.ready`. One missed evaluation still
leaves the series inside the lookback. A promtool case at `eval_time: 8d10m`
fails with 15 minutes and passes with 2.

## Decisions

The operator delegated these on 2026-11-03. Each is final for this spec;
changing one is an edit here in its own pull request.

- **D1. The gate is zero would-be drops over 7 days, or only intended ones.**
  The metric counts connections, and one dropped connection can be an OIDC
  login or a WAL upload, so any non-zero count is a finding, not noise.
  7 days covers the weekly jobs (`backup-verify` on Sundays). A monthly
  CronJob (`paperless-prune`, the monthly pack reads) counts as covered when
  its pod is selected by the same policy and reaches the same peers and ports
  as a daily one that ran in the window; otherwise the window waits for its
  run. Rejected: a percentage threshold (a rare flow is exactly the one that
  breaks at 03:00), and 14 days (no job runs less often than weekly except
  the monthly ones, which the rule above covers).
- **D2. The readiness rules run every 2 minutes.** Below the 5-minute
  lookback with one missed evaluation to spare; the group costs about 0.04 s
  per run. Rejected: a longer lookback delta (changes every query in
  Prometheus) and `last_over_time` in every consumer (each new query and
  panel has to remember it).
- **D3. One namespace and one direction per pull request, ingress first.**
  A mistake costs one app in one direction, and the revert is one line.
  Ingress has few, known peers (the Gateway's `ingress` identity, Prometheus,
  the namespace itself); egress holds DNS, OIDC through the WAN address, S3,
  CloudNativePG and the internet, so it is far more likely to be incomplete.
- **D4. Order: `paperless`, `mealie`, `books`, `syncthing`, `immich`,
  `theater`, `home`, `backup-verify`, `keycloak`, `monitoring`.**
  `paperless` first: nobody uses it yet and both directions are ready.
  `mealie` next: the smallest used app. `books` is audited from its new
  allow-list and goes when ready. `syncthing` before `immich` because the
  CloudNativePG operator runs in `immich`, so an `immich` egress mistake
  stops the reconciliation of all eight database clusters. `theater` is the
  largest (23 policies, four databases). `home`, `backup-verify`, `keycloak`
  and `monitoring` need allow-lists first. `keycloak` and `monitoring` come
  after every application: a Keycloak outage locks every UI behind SSO, and a
  monitoring outage hides every other failure, so they go once the pattern is
  proven nine times. A namespace whose gate is closed does not hold back the
  next application namespace.
- **D5. A residual flow that fails today anyway is an intended drop.**
  Example: Syncthing dialling addresses that peers announce on their own
  private networks, which no route reaches from the cluster, and NAT-PMP to
  the host, which the router does not offer. Syncthing falls back to the
  addresses that work. Each one is listed in the namespace's policy file with
  peer, port and reason, decided in the allow-list pull request. Rejected:
  widening the allow-list until the counter is zero (it would turn the
  `world` rule of Syncthing into "everything", which it nearly is already).
- **D6. Break-glass is deleting the switch with the admin kubeconfig, then
  the revert.** `kubectl -n <ns> delete ciliumnetworkpolicy
  enforce-default-deny` returns the namespace to allow-all in seconds: the
  remaining allow-lists are all default-allow, so Cilium synthesises the
  wildcard rule again, with no pod or agent restart. It sticks because the
  `network-policies` Application has `selfHeal: false`, but only until the
  next revision of `main` syncs it (any merge). So the runner also holds the
  Renovate train (`gh workflow disable renovate-next.yaml`) and merges the
  revert before anything else, then re-enables the train. Rejected:
  `cilium-dbg` per-endpoint policy changes (not in git, lost on restart,
  needs exec in `kube-system`), `policyEnforcementMode` or
  `policyAuditMode` (cluster-wide, restarts every agent), and editing the
  Argo CD Application (an ad-hoc write on the delivery path).
- **D7. Used-application flips run Monday to Friday, 09:00 to 16:59
  Europe/Zurich.** That is the operator's rule of 2026-11-02 for any change
  that can break an app. A run whose brief explicitly lifts it (the security
  tracks of the overnight run of 2026-11-04 do) may flip outside it, with the
  same checks. `paperless` flips may run at any time while it holds no
  household documents.
- **D8. No automatic rollback for a flip; a watched window instead.**
  `scripts/ci/auto-rollback-decide.sh` reverts only a commit that changed a
  file of the Degraded Application. A flip changes the `network-policies`
  Application, which never degrades (CiliumNetworkPolicies have no health),
  and the app it breaks had no file changed. Teaching auto-rollback the
  mapping is its own change (#1012). Until then the runner watches each flip
  for 30 minutes and the 24-hour soak catches the nightly jobs; a broken
  backup pages through the backup alerts.
- **D9. `kube-system`, `argo` and the Cilium agents are not enforced, now or
  later in this spec.** The agents, the API server and etcd run in the host
  network, which pod policy does not select, so there is nothing to gain for
  `cilium`. `kube-system` holds CoreDNS, which every namespace depends on,
  and already has two enforced CiliumNetworkPolicies. `argo` is the path that carries every
  revert, including the revert of its own policy; its chart NetworkPolicies
  already limit it. Rejected: enforcing them last in this spec (a mistake
  there blocks the fix for itself).
- **D10. The other platform namespaces wait for #1011.** `tailscale` carries
  the tailnet API proxy, `kyverno` the admission webhooks, `cert-manager`,
  `external-dns`, `gateway` and `democratic-csi` the certificates, DNS, the
  edge and storage. Each needs its own audit, and none is an application.
- **D11. Soak 24 hours; an egress flip also waits for the nightly backup.**
  The daily jobs (restic, CloudNativePG base backups at 00:00 UTC, the
  presync freshness check) are the flows most likely to be missing; 24 hours
  runs each once. The weekly ones were already seen in the audit.
- **D12. Check the CloudNativePG webhook path with a server-side dry run.**
  After a flip of `immich` or of a namespace with a Cluster,
  `kubectl apply --dry-run=server -f` the rendered Cluster object of that
  namespace calls the operator's validating webhook through the API server
  and changes nothing. `cnpg_collector_up` stays 1 for every Cluster.
- **D13. A new allow-list restarts the clock only for what it adds.** A
  namespace that gets its first allow-list (`books`, `home`,
  `backup-verify`, `keycloak`, `monitoring`) starts its 7 days at that merge.
  A rule added to cover a residual does not reset the window of flows that
  were already matched.
- **D14. `paperless` egress waits for the Paperless spec.** Tasks 4 to 6 of
  [paperless-documents](../paperless-documents/tasks.md) add the export
  volume, the monthly restore and the ingest canary with its Pushgateway
  egress. The egress flip comes 7 days after the last of them merges.
  `paperless` ingress goes once the Paperless lane of the current run is
  done.
- **D15. Silence the namespace only.** `scripts/maintenance-silence.sh
  <namespace> 2h "<PR>"`, expired when the checks pass. `Watchdog` is never
  silenced, so the heartbeat still proves alerting works, which matters most
  for the `monitoring` flips.

## Lockout invariants

| # | Invariant | Mechanism | Check |
| --- | --- | --- | --- |
| L1 | The admin kubeconfig works | client certificate to the API VIP `192.168.1.11:6443` on the LAN; the API server is host network, never selected by a pod policy | `kubectl --request-timeout=20s get --raw /readyz` returns `ok`, before and after every merge |
| L2 | `talosctl` works | apid on the node IPs, host network | `talosctl version` answers on cp-1, cp-2, cp-3, w-1 |
| L3 | Nothing outside the scope is touched | no policy in `kube-system`, `argo`, `tailscale`, `kyverno`, `cert-manager`, `external-dns`, `gateway`, `democratic-csi`; no change to `infrastructure/cilium/`, `talos/` or `bootstrap/tailscale/` | review of each diff |
| L4 | Probes, webhooks and DNS pass | every switch keeps ingress from `host` and `remote-node` and egress to `kube-dns` 53 UDP and TCP | review; the switch blocks of `90-enforcement.yaml` |
| L5 | CloudNativePG keeps reconciling | `cnpg-operator` egress to every `cnpg.io/cluster` on 8000 and 5432 and to `kube-apiserver` 6443; each instance policy allows the operator in and reaches `kube-apiserver` and S3 | D12 |
| L6 | Argo CD can sync | `argo` is never policed (D9); the hook Jobs of a namespace are in its 7-day window (Requirement 2.2) | the flip pull request lists them |
| L7 | The break-glass needs nothing else | admin kubeconfig over the LAN only: no Keycloak, Gateway, Argo CD, Tailscale or GitHub | the runbook test (task 2) uses only that |
| L8 | Alerting survives a `monitoring` flip | Alertmanager to ntfy.sh and the healthchecks.io heartbeat are in the `monitoring` allow-list; the heartbeat pages from outside if they are cut | `Watchdog` firing and the healthchecks.io check green after the flip |

## Break-glass per layer

Written out with commands and expected output in
`docs/runbooks/netpol-enforcement.md` (task 2).

| Layer | Symptom | Break-glass | Lasts until |
| --- | --- | --- | --- |
| The switch | an app in the flipped namespace loses a flow | `kubectl -n <ns> delete ciliumnetworkpolicy enforce-default-deny` | the next revision of `main` syncs `network-policies`; hold the train, merge the revert |
| The allow-lists of a namespace | a wrong allow-list rule (an `ingressDeny` or `egressDeny` added by mistake drops traffic even without default-deny) | `kubectl -n <ns> delete ciliumnetworkpolicy --all` | same |
| Git | any of the above, permanently | `git revert <sha>` on a branch from `origin/main`, pull request, `bash scripts/pr-merge.sh <n>` | permanent |
| The train | another merge would re-create the deleted policy | `gh workflow disable renovate-next.yaml`, then `gh workflow enable renovate-next.yaml` after the revert merges | the revert |
| Cilium | not changed by this spec; a Cilium fault is handled by [cilium-upgrades](../cilium-upgrades/) and `kubectl -n kube-system rollout undo ds/cilium` | | |
| Talos and the API server | not reachable by a pod policy; a fault there is `talos-ops` (re-apply the previous config from the etcd snapshot's era) | | |

Tested once (task 2) on a scratch namespace that is not in git: a client and
a server pod that pass the Kyverno baseline policies, a copy of the switch
with ingress `true`, the connection dropped (`hubble observe --verdict
DROPPED`), the policy deleted, the connection restored, the time from delete
to the first successful connection measured, the namespace deleted.

## The flip, step by step

1. Gate: quote `netpol:ready_to_enforce` (or the direct query before task 1)
   and the residual list; list the namespace's CronJobs and hook Jobs and
   their last run in the window.
2. Lockout check (L1, L2) and the soak of the previous flip (D11).
3. Silence the namespace (D15) for a used app.
4. Merge with `bash scripts/pr-merge.sh <n>`.
5. Wait for `network-policies` to sync the new revision; `cilium-dbg
   endpoint list` in an agent on each node shows the direction enforced for
   the namespace's endpoints.
6. Checks of Requirement 7.2 for 30 minutes, exercising the app (log in,
   open a page, for egress also the OIDC login and one outbound fetch).
7. D12 where the namespace has a Cluster.
8. Lockout check again; expire the silence; comment the results on the pull
   request; tick the task.
9. On any legitimate drop: break-glass, hold the train, revert, re-enable the
   train, write what was missing into the allow-list pull request that
   follows.

## Components

| Component | Change | Task |
| --- | --- | --- |
| `platform/kube-prometheus-stack/routes/netpol.yaml` | `netpol.ready` every 2 minutes; the namespace list grows with each new allow-list | 1, 3, 20, 23, 26, 29 |
| `tests/prometheus/netpol_test.yaml` | the off-grid case; new namespaces | 1, 3, 20, 23, 26, 29 |
| `docs/runbooks/netpol-enforcement.md` | new: break-glass per layer, the flip procedure, the scratch test | 2 |
| `infrastructure/network-policies/<nn>-<ns>.yaml` | new allow-lists `40-books`, `70-home`, `80-backup-verify`, `85-keycloak`, `88-monitoring`; residual decisions as rules or intended-drop comments | 3, 5, 11, 13, 16, 20, 23, 26, 29 |
| `infrastructure/network-policies/90-enforcement.yaml` | one value per flip; new switch blocks; the header's rollout section brought to this spec | 3, 20, 23, 26, 29 and every flip |
| `infrastructure/network-policies/kustomization.yaml` | the new files; the "Not covered" comment | 3, 20, 23, 26, 29 |
| `docs/networking.md` | "Network policy": what is enforced; the readiness interval | 1, 2 and every flip |
| `deploy/` | rendered by `task render` | every task |

## Risks

- **Split-horizon DNS.** The OIDC clients reach `auth.lilalala.com` through
  the WAN address (`world`); if a resolver ever answers with the Gateway's
  LAN address, egress needs `ingress`, `host`, `remote-node` on 443
  (`20-immich.yaml` has the alternative). The egress checks include a fresh
  OIDC login for that reason.
- **A flow seen only monthly.** Covered by D1's same-peer rule or by waiting.
- **A chart upgrade moves a port.** Allow-lists inside a namespace use no
  `toPorts` where the chart owns the ports; Prometheus scrapes would go quiet,
  which `TargetDown` reports.
- **The deleted switch comes back.** Any merge re-creates it (D6); the train
  hold covers Renovate, and the runner merges nothing else until the revert.
