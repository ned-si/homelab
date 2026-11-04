---
kind: change
status: active
created: 2026-11-04
issue: 709
---
# Requirements: netpol-default-deny

## Introduction

The CiliumNetworkPolicy allow-lists in `infrastructure/network-policies/`
cover `immich`, `mealie`, `paperless`, `syncthing` and `theater`. They are
synced but block nothing: every policy, and every switch in
`90-enforcement.yaml`, sets `enableDefaultDeny: {ingress: false, egress:
false}`. Since the end of October the would-be drops of each namespace and
direction are recorded (`platform/kube-prometheus-stack/routes/netpol.yaml`,
[networking.md](../../../docs/networking.md#would-be-drops)). This spec turns
default-deny on, one namespace and one direction per pull request, from that
data, without ever cutting the operator off the cluster and with a tested way
back at every step.

Audit, then enforce: a namespace and direction is first audited (the
allow-lists synced default-allow, the would-be drops counted for 7 days), and
only then enforced (its switch flipped to `true`). No namespace skips the
audit, including the ones that get their first allow-list here.

Issue [#709](https://github.com/ned-si/homelab/issues/709); it continues task 7
of [wave3-network-logs](../wave3-network-logs/tasks.md). The decisions below
were delegated to the agent by the operator (2026-11-03: "go ahead with the
whole Security implementation/hardening. Just make sure you never lock
yourself out of the cluster and you always have a way to fix a change in case
it goes wrong."); each is in [design.md](design.md#decisions) with its reason.

Non-goals:
- `kube-system`, `argo` and the Cilium agents (decision D9). The agents and the
  API server run in the host network, which pod policy does not select anyway.
- The platform namespaces `tailscale`, `kyverno`, `cert-manager`,
  `external-dns`, `gateway`, `democratic-csi`, `logging`, `signoz`,
  `tetragon`, `trivy-system`, `system-upgrade`, `metrics-server`,
  `kubelet-serving-cert-approver`, `headlamp`, `hubble` (decision D10; issue
  #1011).
- Auto-rollback of a flip (decision D8; issue #1012).
- The Cilium host firewall, a CiliumClusterwideNetworkPolicy,
  `policyEnforcementMode`, `policyAuditMode`, FQDN policies, WireGuard (#710).
- Changing what an application does on the network. A flow that has to stop
  is a decision recorded per namespace (Requirement 3), not a refactor.

## Glossary

- **Allow-list**: a CiliumNetworkPolicy with real rules and
  `enableDefaultDeny: {ingress: false, egress: false}`: it allows, it denies
  nothing.
- **Switch**: the `enforce-default-deny` CiliumNetworkPolicy of a namespace in
  `90-enforcement.yaml`; one `true` in it turns default-deny on for that
  namespace and direction.
- **Flip**: the pull request that sets one switch value from `false` to
  `true`.
- **Would-be drop**: a connection no allow-list rule covers (Hubble policy
  verdict `match="all"`); dropped once its namespace and direction are
  enforced.
- **Intended drop**: a would-be drop the namespace's policy file names as
  meant to be dropped, with its peer, port when known, and reason.
- **Break-glass**: the steps that undo a flip in minutes with the admin
  kubeconfig alone, before the git revert lands.
- **Soak**: the time a flip runs before the next flip starts.

## Requirements

### Requirement 1: A readiness signal that can be queried

**User story:** As the operator, I want the "ready to enforce" series to
return a value whenever I query it, so the gate is a number and not a
hand-written query.

#### Acceptance criteria

1. THE recording rules `netpol:would_drop:increase7d` and
   `netpol:ready_to_enforce` SHALL be evaluated at an interval below the
   Prometheus lookback delta (5m), so an instant query at any time returns
   them. (promtool test with an evaluation time off the old 15-minute grid,
   `tests/prometheus/netpol_test.yaml`)
2. THE Network dashboard panels that read them SHALL show a value at every
   point of their range. (`tests/test_dashboards.py` stays green; the panel
   checked once after the merge)
3. UNTIL 1.1 is merged, THE gate SHALL use the direct query
   `avg_over_time(netpol:would_drop:rate5m[7d]) * 604800` per namespace and
   direction, with `count_over_time(netpol:verdicts:rate5m[7d])` showing 7
   days of verdicts. (stated in each flip pull request)

### Requirement 2: A gate per namespace and direction

**User story:** As the operator, I want a namespace and direction enforced
only when the data says nothing legitimate is dropped, so enforcement does not
become an outage.

#### Acceptance criteria

1. A flip SHALL be opened only WHEN, for its namespace and direction,
   `netpol:ready_to_enforce` is 1, OR every remaining would-be drop of the last
   7 days is an intended drop (Requirement 3). (the flip pull request quotes
   the query, its value and the time)
2. THE 7-day window SHALL include at least one run of every CronJob and Argo
   CD hook Job (`presync-backup`, `postsync-smoke`) of the namespace, or,
   for a monthly CronJob, show that the same policy selects it and that it
   reaches the same peers and ports as a Job that ran (decision D1), and
   SHALL start no earlier than the last merged change that added a workload,
   a CronJob or an outbound dependency in that namespace (decision D13).
   (the flip pull request lists the Jobs and their last run)
3. WHEN the metric has no port for a would-be drop, THE flip pull request
   SHALL name the port from `scripts/netpol-observe.sh <namespace>` (live
   relay events) or say it was not seen live.

### Requirement 3: Every residual would-be drop decided

**User story:** As the operator, I want every uncovered flow either allowed
with a reason or dropped with a reason, so nothing is dropped by accident.

#### Acceptance criteria

1. EACH would-be drop seen in the 7-day window SHALL become either an allow
   rule, with a comment naming the source file or flow evidence, or an
   intended drop, listed in a comment in that namespace's policy file with
   peer, port and reason. (review of the allow-list pull request)
2. AN allow-list change SHALL be its own pull request, merged before the
   flip, and SHALL restart the 7-day window only for flows it newly covers,
   not for flows already matched. (the flip pull request shows the rule's
   flows at `match` other than `all`)

### Requirement 4: Order and granularity

**User story:** As the operator, I want enforcement to grow one small step
at a time, the least risky first, so a mistake costs one app for a few
minutes.

#### Acceptance criteria

1. ONE flip SHALL change one switch value: one namespace, one direction.
   (review: the diff of `90-enforcement.yaml` is one line, plus `deploy/`)
2. Ingress SHALL be enforced before egress in each namespace.
3. THE namespaces SHALL be enforced in this order, each when its gate opens:
   `paperless`, `mealie`, `books`, `syncthing`, `immich`, `theater`, `home`,
   `backup-verify`, `keycloak`, `monitoring` (decision D4). A namespace whose
   gate is not open SHALL NOT hold back the next one, except that `keycloak`
   and `monitoring` come after every application namespace.
4. `books`, `home`, `backup-verify`, `keycloak` and `monitoring` SHALL get an
   allow-list file, a switch and their name in the recording rules' namespace
   list in one pull request each, and SHALL then be audited for 7 days before
   their first flip.
5. THE next flip SHALL NOT start before the previous one has soaked for 24
   hours, and for an egress flip until after that namespace's nightly backup
   has succeeded. (the next flip pull request links the previous one and the
   backup result)
6. A flip SHALL NOT be merged within 24 hours of a per-app hardening pull
   request (#726) or a Pod Security pull request (#724) for the same
   namespace.

### Requirement 5: Lockout invariants

**User story:** As the operator, I want no network policy change to cut me,
the control plane or the delivery path off, so I can always fix what broke.

#### Acceptance criteria

1. THE admin kubeconfig (client certificate, API VIP `192.168.1.11:6443` on the
   LAN) and `talosctl` to the four node IPs SHALL answer before and after
   every merge of this spec: `kubectl --request-timeout=20s get --raw /readyz`
   returns `ok`, `talosctl version` answers on all four nodes. (the flip pull
   request and its after-sync comment)
2. NO pull request of this spec SHALL create or change a policy in
   `kube-system`, `argo`, `tailscale`, `kyverno`, `cert-manager`,
   `external-dns`, `gateway` or `democratic-csi`, or touch
   `infrastructure/cilium/`, the Talos config or the tailnet policy. (review
   of the diff)
3. EVERY switch SHALL keep its two base rules: ingress from `host` and
   `remote-node` (kubelet probes, API server webhooks) and egress to
   `kube-dns` on 53 UDP and TCP. (review; a repo-policy check if a task adds
   one)
4. THE CloudNativePG paths SHALL stay allowed in every namespace with a
   Cluster: the operator in `immich` to every instance on 8000 and 5432 and to
   `kube-apiserver` on 6443, the API server to the operator's webhook, and
   each instance to `kube-apiserver` on 6443 and to S3 on 443. (checked
   after each flip of `immich` or of a namespace with a Cluster:
   `kubectl apply --dry-run=server` of that namespace's rendered Cluster
   object passes the webhook, and `cnpg_collector_up` stays 1)
5. THE Argo CD hook Jobs of a namespace SHALL be covered before its egress
   flip (Requirement 2.2).
6. THE break-glass SHALL depend on nothing but the admin kubeconfig over the
   LAN: not on Keycloak, the Gateway, Argo CD, Tailscale or GitHub.

### Requirement 6: A way back for every layer

**User story:** As the operator, I want each flip undone in minutes by a
documented, tested procedure, so a mistake is an incident and not an outage.

#### Acceptance criteria

1. A runbook `docs/runbooks/netpol-enforcement.md` SHALL give, with
   copy-paste commands and the expected output, the break-glass per layer:
   the switch (delete `enforce-default-deny` in the namespace), all policies
   of a namespace (`kubectl -n <ns> delete ciliumnetworkpolicy --all`), the
   git revert through `scripts/pr-merge.sh`, and holding the Renovate train
   while the revert is pending. (repo-policy runbook link check)
2. THE break-glass SHALL be tested live once before the first flip, on a
   scratch namespace that is not in git, and the result (drop seen, delete,
   flow restored, time taken) recorded in the runbook's pull request.
3. EVERY flip pull request SHALL carry a `## Rollback` section with the exact
   `git revert` and the break-glass command for its namespace.
4. WHEN a flip drops a legitimate flow, THE runner SHALL apply the break-glass
   at once and merge the revert before any other change to `main`.

### Requirement 7: Each flip watched

**User story:** As the operator, I want each flip checked against the app's
users, so a broken path is caught in minutes rather than by the household.

#### Acceptance criteria

1. BEFORE a flip of a used application merges, THE runner SHALL set a
   maintenance silence for that namespace only
   (`scripts/maintenance-silence.sh <namespace> 2h "<PR>"`) and expire it when
   the checks pass.
2. AFTER the sync, THE runner SHALL check and record: the switch in force
   (`cilium-dbg endpoint list` shows the direction `Enabled` with default-deny
   for the namespace's endpoints), the public route answers (`curl -m 10` on
   its hostname, the expected status), the Application `Healthy`, no new
   `action: human` alert, and no `DENIED_BY_POLICY` drop of a legitimate flow
   in `hubble observe --namespace <ns> --verdict DROPPED` over 30 minutes
   while the app is exercised.
3. Used-application flips SHALL run Monday to Friday, 09:00 to 16:59
   Europe/Zurich, unless the brief of the run explicitly lifts that window
   (decision D7). `paperless` flips may run at any time while nobody uses
   Paperless.

### Requirement 8: Documentation follows the state

1. `docs/networking.md` ("Network policy") and the header of
   `90-enforcement.yaml` SHALL list the enforced namespaces and directions as
   they are after each flip. (the flip pull request)
2. THE last task SHALL update the area spec
   [access-identity](../access-identity/) or `docs/threat-model.md` where they
   describe the network boundary.
