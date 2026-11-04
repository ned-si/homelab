---
kind: change
status: active
created: 2026-11-04
issue: 724
---
# Requirements: pod-security-restricted

## Introduction

Pod Security admission (PSA) enforces `restricted` in ten platform
namespaces today. The application namespaces enforce `baseline`: Talos sets
it as the default for every namespace without an `enforce` label, and
`infrastructure/namespaces/namespaces.yaml` sets `warn` and `audit` to the
level each namespace should reach. In Kyverno, the ten baseline policies and
six others run in Deny; the five restricted policies run in Audit
(`infrastructure/kyverno-policies/kustomization.yaml`).

This spec moves namespaces to `enforce: restricted`, one namespace per pull
request, once the live evaluation of their pods and pod templates is clean.
It also sets what has to hold before the first move: complete Kyverno
reports, a readiness check per namespace, a CI check that fails a change PSA
would reject, explicit `enforce` labels, and a tested break-glass.

Audit, then enforce: each namespace is first audited (the `warn` and `audit`
labels at `restricted`, the Kyverno restricted policies in Audit, the
readiness check), and only then enforced (its `enforce` label set to
`restricted`).

Issue [#724](https://github.com/ned-si/homelab/issues/724), from
gitops-delivery task 17b. The operator delegated the decisions on
2026-11-03: "go ahead with the whole Security implementation/hardening. Just
make sure you never lock yourself out of the cluster and you always have a
way to fix a change in case it goes wrong." Each decision is in
[design.md](design.md#decisions) with its reason and the alternatives
rejected.

Non-goals:
- Changing the security context of an application. That is the per-app
  hardening, [#726](https://github.com/ned-si/homelab/issues/726). The
  application namespaces it unblocks move to `restricted` under
  [#1020](https://github.com/ned-si/homelab/issues/1020), with this spec's
  procedure.
- Kyverno restricted policies in Deny. They stay in Audit here (decision D2);
  moving them is [#1021](https://github.com/ned-si/homelab/issues/1021),
  blocked by #726.
- `kube-system` (exempt from PSA in the Talos admission configuration), the
  privileged agents' namespaces (`democratic-csi`, `logging`, `monitoring`,
  `tailscale`, `tetragon`) and `cilium-secrets` (owned by Cilium, no pods).
- The unused namespaces `ingress` and `selinux-scratch`
  ([#1022](https://github.com/ned-si/homelab/issues/1022)).
- Shipping the API server audit log (decision D4).

## Glossary

- **Level**: a Pod Security Standard, `privileged`, `baseline` or
  `restricted`.
- **Enforce label**: `pod-security.kubernetes.io/enforce` on a Namespace.
  PSA rejects a Pod whose spec fails that level. It does not reject
  Deployments, StatefulSets, DaemonSets, Jobs or CronJobs; for those it only
  warns and audits.
- **Restricted set**: the five Kyverno policies of the restricted profile,
  `disallow-capabilities-strict`, `disallow-privilege-escalation`,
  `require-run-as-nonroot`, `restrict-seccomp-strict`,
  `restrict-volume-types`. Together with the baseline policies and
  `require-run-as-non-root-user` (both already in Deny) they check what PSA
  `restricted` checks.
- **Controller**: an object that creates Pods: Deployment, StatefulSet,
  DaemonSet, ReplicaSet, Job, CronJob, or an operator (CloudNativePG, tuppr)
  that creates Pods or Jobs from code.
- **Flip**: the pull request that sets one namespace's enforce label to
  `restricted`.
- **Gate**: the conditions of Requirement 2, all true for a namespace.
- **Break-glass**: the steps that undo a flip in minutes with the admin
  kubeconfig alone, before the git revert lands.

## Requirements

### Requirement 1: Complete Kyverno reports

**User story:** As the operator, I want every pod-security policy to report
on everything it matches, so the audit shows all findings.

#### Acceptance criteria

1. EVERY ValidatingPolicy that matches `pods/ephemeralcontainers` SHALL
   show `status.conditionStatus.ready: true`. On 2026-11-04 the 17 of them
   (the 16 pod-security policies and `disallow-latest-tag`) show `false`,
   with the condition `RBACPermissionsGranted` "missing permissions: get,
   list, watch pods/ephemeralcontainers". `check-deprecated-apis` is not
   ready for another reason (no read on PodSecurityPolicies, RuntimeClasses,
   FlowSchemas, PriorityLevelConfigurations and CSIStorageCapacities); it
   is a best-practice policy, not pod security, and is out of scope.
   (`kubectl get validatingpolicies -o json`, in the pull request and after
   the sync)
2. THE missing permission SHALL be granted through the Kyverno chart values
   (`infrastructure/kyverno/values.yaml`), read-only (`get`, `list`,
   `watch`), to the Kyverno controller whose ServiceAccount the condition
   checks, and to no other. (the rendered ClusterRole and a `kubectl auth
   can-i --as` for that ServiceAccount in the pull request)

### Requirement 2: A gate per namespace

**User story:** As the operator, I want a namespace enforced only when no
pod it runs or will run fails `restricted`, so a flip never stops an app
from starting.

#### Acceptance criteria

1. `scripts/psa-readiness.sh <namespace>` SHALL print `READY` and exit 0
   only WHEN all of these hold, and otherwise print each failing item and
   exit 1:
   1. G1: `kubectl label --dry-run=server --overwrite namespace <ns>
      pod-security.kubernetes.io/enforce=restricted` prints no warning;
   2. G2: the namespace's PolicyReports have no `fail` result of the
      restricted set, the baseline policies or
      `require-run-as-non-root-user` on a Pod, a Deployment, StatefulSet,
      DaemonSet, Job or CronJob, or a ReplicaSet with `spec.replicas` above
      0; and the reports are fresh (`KyvernoReportsStale` not firing);
   3. G3: for every controller in the namespace, including those scaled to
      0 and CronJobs between runs, a server dry-run create of a Pod with
      the controller's pod template returns no PodSecurity warning or error
      at `restricted`.
   (its bash test with a stubbed `kubectl`, `tests/bash/`)
2. THE script SHALL only read: every call is a `get`, a `list` or a
   `--dry-run=server`. (its test fails on any other verb)
3. THE flip pull request SHALL list, as G4, every Pod an operator creates
   from code in the namespace and how it was checked (the operator's source
   at the pinned version, or a server dry-run of an equivalent Pod).
4. THE flip pull request's `ci` SHALL be green, with the namespace in the
   checked set of Requirement 3 (G5).

### Requirement 3: CI fails a change PSA would reject

**User story:** As the operator, I want a pull request that would put a
non-restricted pod into an enforced namespace to fail CI, so the cluster
never meets a rollout that cannot start.

#### Acceptance criteria

1. `scripts/ci/kyverno.sh` SHALL treat a finding of the restricted set as
   blocking WHEN the object's namespace has
   `pod-security.kubernetes.io/enforce: restricted` in
   `infrastructure/namespaces/namespaces.yaml`, read from that file at run
   time, not from a second list. (a test with a fixture namespace and a
   failing Deployment)
2. THE check SHALL include the Helm-rendered objects of enforced namespaces
   that the Kyverno webhooks skip (`argo`), because PSA has no such
   exclusion. (the CI log names `argo` among the checked namespaces)
3. THE check SHALL pass on `main` at the time of its pull request, with the
   ten namespaces that enforce `restricted` today. (`ci` green)

### Requirement 4: The level of every namespace is in git

**User story:** As the operator, I want each namespace's enforced level
written in git, so a rebuild on another cluster enforces the same levels.

#### Acceptance criteria

1. EVERY Namespace in `infrastructure/namespaces/namespaces.yaml` SHALL have
   an `enforce`, a `warn` and an `audit` label, with `warn` and `audit` at
   the enforce level or stricter. (repo-policy rule `pod-security-labels`,
   with its test in `tests/test_repo_policy.py`)
2. THE namespaces that enforce `baseline` only through the Talos default
   (`backup-verify`, `books`, `theater`) SHALL get `enforce: baseline`,
   with no change in the cluster's behaviour. (a server dry-run of the
   label shows no warning, in the pull request)
3. THE header of `namespaces.yaml` SHALL state, per namespace below
   `restricted`, the reason, and link this spec.

### Requirement 5: A tested way back

**User story:** As the operator, I want to undo a flip in minutes without
waiting for CI, and to know that the steps work.

#### Acceptance criteria

1. `docs/runbooks/pod-security.md` SHALL give the break-glass of decision
   D7 with copy-paste commands and expected outputs, the merge hold, the
   revert, and the flip procedure of design.md. (the runbook)
2. THE break-glass SHALL be tested live before the first flip, with the
   admin kubeconfig only: on a scratch namespace (a non-compliant Pod
   rejected under `restricted`, admitted after the relabel), and on the
   `namespaces` Application (`skip-reconcile` set, the annotation still
   present after the parent layer's next reconcile, `status.reconciledAt`
   not advancing, then removed). (the test, with times and outputs, in the
   runbook's pull request)
3. THE Kyverno break-glass for #1021 SHALL be written in the same runbook
   and tested in #1021's first pull request.

### Requirement 6: One namespace per flip, in order

**User story:** As the operator, I want each flip small and reversible, so
a mistake affects one namespace.

#### Acceptance criteria

1. A flip SHALL change the enforce label of one namespace (plus `deploy/`
   and the `namespaces.yaml` header line), and nothing else. (the diff)
2. A flip SHALL be opened only WHEN its gate is open; its body SHALL quote
   the output of `scripts/psa-readiness.sh <ns>` with the time, the G4 list,
   and `## Rollback` with the exact `git revert` and the break-glass
   commands.
3. THE order SHALL be `home`, then `system-upgrade` (decision D5). A
   namespace whose gate is closed does not hold back the next.
4. A flip SHALL merge only Monday to Friday, 09:00 to 16:59 Zurich time
   (decision D8), and not after a run's own cut-off.

### Requirement 7: Each flip verified after the sync

**User story:** As the operator, I want proof that a flip is enforced and
broke nothing.

#### Acceptance criteria

1. WITHIN 10 minutes of the sync, THE namespace's live enforce label SHALL
   read `restricted`, and a server dry-run create of a Pod that fails
   `restricted` SHALL be rejected with `violates PodSecurity
   "restricted:latest"`. (commands and outputs in a pull request comment)
2. FOR 30 minutes after the sync: `scripts/psa-readiness.sh <ns>` prints
   `READY`; the `namespaces` Application and the namespace's Applications
   are Synced and Healthy; the namespace's public route answers as before;
   no `FailedCreate` event in the namespace names PodSecurity; no new
   alert with `action: human` fires; Hubble shows no new `POLICY_DENIED`
   drop for the namespace. (a pull request comment)
3. WITHIN 26 hours, EACH CronJob of the namespace SHALL have run once
   after the sync and succeeded, or the comment SHALL say why it did not
   run (a monthly schedule) and quote its G3 result. (a second comment)
4. THE admin kubeconfig (`kubectl auth whoami`: `admin`, `kubectl auth
   can-i '*' '*'`: `yes`) and the talosconfig (`talosctl version` answered
   by all four nodes) SHALL be checked before and after every merge of this
   spec. (each pull request's comments)

### Requirement 8: Nothing the cluster needs to run is blocked

**User story:** As the operator, I want this spec never to stop the cluster
from starting, syncing or upgrading.

#### Acceptance criteria

1. THIS spec SHALL NOT change the level of `kube-system`, `argo`, `kyverno`,
   `cilium-secrets`, `immich` (it runs the CloudNativePG operator for all
   eight databases) or any privileged namespace. (the diffs)
2. THIS spec SHALL NOT change the `validationActions`, `failurePolicy`,
   timeout or namespace exclusions of a Kyverno policy or webhook. (the
   diffs; `infrastructure/kyverno/values.yaml` keeps
   `forceFailurePolicyIgnore` and the excluded namespaces `kube-system`,
   `argo`, `cilium`, `kyverno`, `tailscale`)
3. A flip SHALL NOT touch a database, a volume or a running Pod: PSA judges
   only Pods created after the label changes. (the diff; Pod ages
   unchanged in the 30-minute comment)

### Requirement 9: Docs describe the result

#### Acceptance criteria

1. `docs/architecture.md` (admission policy), `docs/threat-model.md` and
   the `namespaces.yaml` header SHALL list each namespace's level and the
   reason for every namespace below `restricted`. (the close-out pull
   request)
2. THE spec SHALL be `done` with its `closed` date when its tasks are
   ticked, and #724 closed with links to #1020 and #1021.
