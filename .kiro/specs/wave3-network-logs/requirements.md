# Requirements: wave 3 network visibility and logs (Hubble, policy audit, SigNoz trial)

## Introduction

The cluster is close to default-allow on the network and has no log store. No
CiliumNetworkPolicy outside `headlamp` is live: the allow-lists in
`infrastructure/network-policies/` are not in any layer, cover six application namespaces,
and were written from the repo rather than from observed traffic. Hubble runs in the agents
with metrics, but relay and UI are off, so flows can only be read from inside an agent.
Logs exist only as container and Talos logs on each node.

This feature turns on Hubble relay and UI behind Keycloak, writes allow-lists for every
namespace from observed flows and shows, without enforcing anything, what each would drop.
It also runs the 14-day SigNoz trial: Vector ships structured pod and Talos logs over OTLP
to SigNoz, whose UI is behind Keycloak, whose metadata is backed up and whose telemetry is
disposable. Wave 4 flips namespaces to default-deny one at a time, using the "ready to
enforce" signal this feature produces.

Non-goals:
- Enforcing any new policy: every allow-list ships with `enableDefaultDeny` false; the
  policies already enforced (Headlamp, the Argo CD chart's NetworkPolicies) stay as they are.
- The Cilium host firewall, node policies, WireGuard or a service mesh.
- Traces from applications, Envoy or Hubble (later sources for the same OTLP path).
- The Talos API server audit policy and shipping the audit log (wave 5).
- Paging from logs or from SigNoz alerts; paging stays in Prometheus and Alertmanager.
- The Loki fallback itself (only its trigger and the switch are specified).

## Glossary

- **Allow-list**: a CiliumNetworkPolicy with real rules in both directions and
  `enableDefaultDeny: {ingress: false, egress: false}`: it allows, it denies nothing.
- **Would-be drop**: a flow to or from a pod selected by an allow-list that no rule of the
  allow-list allows; it would be dropped once the namespace is switched to default-deny.
- **Ready to enforce**: a namespace and direction with zero would-be drops over 7 days.
- **Trial**: 14 days from the day SigNoz first receives logs from every required source.
- **Admin UI**: served by an HTTPRoute on the shared Gateway (`<name>.lilalala.com`, the
  route security headers of #465), behind an oauth2-proxy with a Keycloak platform client
  gated to the group `admins`, like Argo CD and Grafana. Operator decision 2026-10-16:
  every UI is public behind Keycloak; only the Kubernetes API proxy and talosctl stay
  tailnet-only ("behind a VPN is not more secure than SSO and group gating").

## Requirements

### Requirement 1: Hubble relay and UI behind Keycloak

**User story:** As the operator, I want to see live flows from the phone or the Mac,
behind the same login as the other admin UIs, so that I can debug traffic and policies
anywhere.

#### Acceptance criteria

1. THE Cilium release SHALL run Hubble relay and Hubble UI, with requests, memory limits,
   probes and digest-pinned images.
2. THE Hubble UI SHALL be reachable only at `https://hubble.lilalala.com`, an admin UI
   (glossary), with no tailnet Ingress.
3. ACCESS to the UI SHALL require a Keycloak login through an oauth2-proxy with the
   client `hubble`, a platform client gated to the group `admins`.
4. CiliumNetworkPolicies with default-deny ingress SHALL allow only the shared Gateway
   (`reserved:ingress`) to reach the oauth2-proxy, only the oauth2-proxy to reach Hubble UI, and only
   Hubble UI and the listed in-cluster consumers to reach Hubble relay.
5. AN Argo CD sync of the Cilium Application SHALL NOT rotate Hubble certificates.
6. IF enabling relay or UI restarts the Cilium agents, THEN the change SHALL be preceded by
   a maintenance silence and land alone.

### Requirement 2: Allow-lists from observed flows, not enforced

**User story:** As the operator, I want each namespace's allow-list to describe what the
namespace really does, so that switching on default-deny later breaks nothing.

#### Acceptance criteria

1. THE `network-policies` Application SHALL be part of the infrastructure layer, with
   every enforcement switch in `90-enforcement.yaml` false.
2. EVERY namespace with workloads, except `kube-system` and `democratic-csi` (host-network
   pods that pod policy does not see), SHALL have an allow-list for ingress and egress.
3. EACH allow-list SHALL be derived by a deterministic script from at least 7 days of
   observed flows, and each rule SHALL carry a comment naming the flow it covers.
4. THE allow-lists SHALL cover: DNS; kubelet probes from the host; the Gateway
   (`reserved:ingress`) to each backend; OIDC and other calls through the public names
   (via the Gateway's identity); Prometheus scrapes into every namespace; `backup-verify`
   to the CNPG primaries (5432) in every namespace of
   `platform/backup-verify/scripts/postgres-targets.txt`, to S3, to the API server and to
   its Pushgateway; the Tailscale Ingress proxies to their backends and to the tailnet
   control plane and DERP; the Tailscale operator to the API server; the exit node to
   the internet; the exporters to their sources (Immich and Jellyfin, the NAS API, the
   LAN, GitHub, AWS, CISA KEV and FIRST EPSS); CNPG instance managers to the API server;
   inter-app traffic (the theater apps among themselves, Immich server, machine learning
   and database, Home Assistant, Mosquitto and Zigbee2MQTT, the books apps).
5. THE observation SHALL NOT disable or weaken any policy that is enforced today.

### Requirement 3: Would-be drops visible

**User story:** As the operator, I want to see what each allow-list would drop and when a
namespace is ready to enforce, so that wave 4 flips are decided by data, not by hope.

#### Acceptance criteria

1. THE system SHALL record would-be drops per namespace and direction from Cilium's own
   policy evaluation, as `netpol:would_drop:rate5m{namespace, direction}` and
   `netpol:would_drop:increase7d{namespace, direction}`.
2. THE Homelab / Network dashboard SHALL show would-be drops by namespace and direction,
   the top source/destination/port tuples, and "ready to enforce" per namespace and
   direction.
3. Would-be drops SHALL NOT notify.
4. IF Cilium's verdicts cannot tell an allow-list match from the synthesized allow-all,
   THEN would-be drops SHALL come from flow logs, as specified in the design, and not from
   cluster-wide policy audit mode.

### Requirement 4: Structured logs over OTLP

**User story:** As the operator, I want pod and node logs as structured, queryable events
in one place, so that I can ask questions across fields instead of grepping one node.

#### Acceptance criteria

1. A Vector agent SHALL run on every node and collect every pod's container logs and the
   Talos service and kernel logs of its node.
2. Vector SHALL parse JSON and logfmt lines into fields, keep any other line as a message,
   and mark it `parse_failed=true`.
3. Vector SHALL ship every event over OTLP to the SigNoz collector and to nothing else.
4. Vector SHALL buffer in memory with a bounded size and SHALL NOT write buffers to the
   eMMC.
5. THE Talos machine configuration SHALL send service logs and kernel logs as JSON to the
   Vector agent on the same node; the change SHALL go through `talos/` and
   `task talos:apply`, after an etcd snapshot.
6. Vector SHALL export its own metrics (events in and out, errors, discarded events,
   buffer size, parse failures by source) to Prometheus.
7. THE Tetragon events of spec `wave3-runtime-security` and the flow logs of Requirement 3
   (if used) SHALL use the same agent.

### Requirement 5: SigNoz behind Keycloak

**User story:** As the operator, I want a log and trace store I can query from the phone,
behind the same login as the other admin UIs, so that the trial tests the real daily use.

#### Acceptance criteria

1. THE cluster SHALL run SigNoz Community Edition with a single ClickHouse replica, a
   single Keeper or ZooKeeper replica and its OTel collector, each with requests, memory
   limits, probes and digest-pinned images tracked by Renovate.
2. THE SigNoz UI SHALL be reachable only at `https://signoz.lilalala.com`, an admin UI
   (glossary), behind an oauth2-proxy with the client `signoz`, a platform client gated to the group `admins`,
   and SigNoz's own admin login (credentials in SOPS).
3. THE OTLP receiver SHALL accept traffic only from the Vector agents (CiliumNetworkPolicy
   with default-deny ingress).
4. Retention SHALL be 15 days for logs and 7 days for traces; SigNoz SHALL store no
   metrics.
5. EACH SigNoz namespace SHALL enforce Pod Security `restricted` where a server-side dry
   run passes, else `baseline`, with the reason in `namespaces.yaml`.
6. SigNoz components SHALL log as JSON where they support it.

### Requirement 6: Metadata backed up, telemetry disposable

**User story:** As the operator, I want to keep saved views, dashboards and users if
SigNoz is rebuilt, and not pay for backing up logs, so that a rebuild costs minutes.

#### Acceptance criteria

1. THE SigNoz metadata store SHALL be backed up nightly to S3 with the restic CronJob
   pattern of the repo (pending guard, `ci/active-cronjobs.txt`, `ci/guard-modes.txt`).
2. THE backup SHALL count as a backup target of the freshness SLO in spec
   `wave3-reliability`, and a failed backup Job SHALL page through the existing
   `KubeJobFailed` route.
3. ClickHouse data SHALL NOT be backed up, and `docs/backups.md` SHALL list it under "What
   is not backed up" with the reason.
4. A restore of the metadata into a scratch SigNoz SHALL be rehearsed once and written in
   `docs/backups.md`.

### Requirement 7: A deterministic trial gate

**User story:** As the operator, I want the trial to end with a pass or fail computed from
numbers, so that keeping SigNoz is not a matter of taste.

#### Acceptance criteria

1. `docs/observability.md` SHALL record the trial start date, end date (start plus 14
   days) and the thresholds below.
2. THE trial SHALL pass only if, over its 14 days: ClickHouse working-set memory p95 is
   below 6 GiB with no OOM kill and no restart other than an upgrade; ClickHouse volume
   growth is below 2 GiB a day and the projection at the configured retention is below 70%
   of the volume; every required source (pods, Talos services, Talos kernel) delivers
   events and under 1% of events have `parse_failed=true`; Vector shows no sustained
   buffer growth and no discarded events; the UI loads from the phone over the tailnet.
3. Recording rules SHALL compute each threshold and `signoz_trial:pass`, shown on a
   dashboard panel.
4. WHEN the trial ends and passes, THE docs SHALL drop the word "trial" and the end date.
5. WHEN the trial ends and fails, THE run SHALL remove SigNoz and record the Loki
   fallback in `docs/observability.md` ("Why it is like this"); Vector stays, only its
   sink changes.
6. WHEN the Vector agent discards events or the SigNoz collector is absent for one hour,
   THE system SHALL fire an `action: human` warning (logs went blind), with promtool
   tests, a runbook section and a `routes.txt` line.

### Requirement 8: SigNoz login

**User story:** As the operator, I want to log in to SigNoz with my Google account if
SigNoz allows it, and with exactly one known identity either way, so that the second
login behind Keycloak is not a password nobody remembers and no stranger gets an account.

#### Acceptance criteria

1. THE Keycloak gate of Requirement 5.2 (oauth2-proxy `signoz-sso`, group `admins`)
   SHALL stay in front of SigNoz whatever SigNoz's own login method is.
2. WHEN SigNoz setup has completed, THE register endpoint SHALL refuse a new
   organisation or user, and new users SHALL join only by invite or by the login method
   of criterion 4.
3. THE SigNoz admin user's email SHALL be the operator's real login identity (the
   address of his Keycloak user and Google account), so that a later SSO login maps to
   that user instead of creating a second one.
4. WHERE the operator's Google account belongs to a Google Workspace domain he
   controls, THE SigNoz organisation SHALL have one authenticated domain, that domain,
   with the Google method, an OAuth client used by SigNoz only, `Enforce SSO` on and
   VIEWER as the default role of a just-in-time user.
5. IF the operator's Google account is a personal `gmail.com` account, THEN SigNoz SHALL
   NOT have a Google authenticated domain, and SigNoz's login SHALL stay the local
   password of criterion 3, stored in SOPS.
6. THE password login SHALL stay reachable as break-glass (`/login?password=Y`) with the
   SOPS password, and the runbook SHALL say so.
7. THE OAuth client secret, if any, SHALL be stored in SOPS and set in SigNoz only
   through its API or UI (SigNoz keeps it in the backed-up metadata store, Requirement 6).
8. WHEN the login method changes, THE run SHALL check it with a real login: a Keycloak
   member of `admins` reaches SigNoz and lands as ADMIN under the email of criterion 3; a
   Keycloak user outside `admins` is refused before SigNoz.
