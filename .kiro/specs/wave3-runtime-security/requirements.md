# Requirements: wave 3 runtime security (Kyverno audit, Tetragon observe)

## Introduction

The cluster has no admission policy and no runtime detection. Kyverno runs in CI only
(`scripts/ci/kyverno.sh` over `deploy/`), Pod Security `restricted` is enforced in a few
namespaces, and nothing watches what containers do once they run. This feature puts
Kyverno in the cluster in Audit mode with the upstream Pod Security Standards (restricted)
and best-practice policies, shows their reports on the Security dashboard, adds Tetragon in
observe mode with upstream library policies, and pages only on the detections that mean a
container is trying to take the node. It also hardens the Keycloak realm in code, so the
new admin UIs and the existing platform clients sit behind brute-force protection and OTP.

Every control comes from an existing framework and an upstream library: no homelab-written
rule where upstream has one. Wave 4 moves the policies from Audit to Deny; this feature
blocks nothing.

Non-goals:
- Any Deny or enforcement: no Kyverno `Deny`, no Tetragon `Sigkill`/`Override`, no PSA
  label changes.
- Image signature verification and SBOMs (wave 4).
- Mutating or generating policies.
- The Talos API server audit policy and SELinux enforcing (wave 5).
- Network policy (spec `wave3-network-logs`).
- A policy or runtime UI (Policy Reporter UI, Tetragon UI): Grafana is the view.

## Glossary

- **Vendored policy**: an upstream policy file copied unchanged into this repository at a
  pinned upstream commit.
- **Expected finding**: a policy result that is correct and accepted, such as the
  privileged democratic-csi node pods, declared as a Kyverno `PolicyException`.
- **Critical detection**: a Tetragon event class mapped to MITRE ATT&CK T1611 (Escape to
  Host), T1068 (Exploitation for Privilege Escalation) or T1547.006 (Kernel Modules and
  Extensions), or an unexpected BPF program load (T1014, Rootkit).
- **Platform client**: a Keycloak client listed in `platform_clients`
  (`platform/keycloak/realm/platform.conf`).

## Requirements

### Requirement 1: Kyverno in the cluster, audit only

**User story:** As the operator, I want the cluster to report every workload that breaks
the Pod Security Standards or upstream best practices, so that wave 4 can enforce them
knowing exactly what would break.

#### Acceptance criteria

1. THE cluster SHALL run Kyverno as an Argo CD Application in the infrastructure layer,
   chart and images digest-pinned and tracked by Renovate.
2. THE in-cluster policies SHALL be the upstream `kyverno/policies` sets
   `pod-security-vpol/baseline`, `pod-security-vpol/restricted` and a listed subset of
   `best-practices-vpol`, vendored unchanged at one pinned upstream commit that Renovate
   tracks.
3. EVERY in-cluster policy SHALL use `validationActions: [Audit]`.
4. THE homelab policies that duplicate an upstream one (`disallow-latest-tag`,
   `disallow-privileged`, `require-probes`, `require-resources`) SHALL be replaced by the
   upstream equivalent once CI shows the same or a superset of findings over `deploy/`.
5. CI SHALL evaluate the same vendored files over `deploy/`; the policies CI treats as
   blocking SHALL stay blocking in CI.
6. WHEN Kyverno is down or not yet started (cold start), THE creation of pods SHALL NOT
   wait on or fail because of Kyverno.
7. Kyverno's own pods SHALL pass Pod Security `restricted`, have requests, memory limits
   and probes, and log as JSON.

### Requirement 2: Reports on the Security dashboard

**User story:** As the operator, I want the audit results on the Security dashboard, so
that I see the posture without reading custom resources.

#### Acceptance criteria

1. THE cluster SHALL hold policy reports for every namespace, refreshed by background scans
   at least every hour.
2. Expected findings SHALL be `PolicyException` objects in git, each with a reason
   annotation, so that a failing result means an unexpected one.
3. THE Homelab / Security dashboard SHALL show failing results by policy and by namespace,
   the failing resources, the number of exceptions and the age of the newest report.
4. THE report metrics SHALL come from components already running (kube-state-metrics and
   Kyverno's own metrics), not a new exporter.
5. Audit results SHALL NOT notify.

### Requirement 3: Controls mapped to frameworks

**User story:** As a reader of the public repo, I want each control traced to a published
framework, so that the security posture is checkable rather than asserted.

#### Acceptance criteria

1. EACH in-cluster Kyverno policy SHALL map to at least one of: a CIS Kubernetes Benchmark
   section 5 control, a NIST SP 800-190 countermeasure (section 4), a section of the
   NSA/CISA Kubernetes Hardening Guide; and to a NIST CSF 2.0 subcategory.
2. EACH Tetragon policy SHALL map to one MITRE ATT&CK technique ID (from the Containers
   matrix where the technique exists there) and to NIST CSF 2.0 DE.CM-09.
3. IF a policy has no mapping entry, a mapping entry names a missing policy, or an ID is
   malformed, THEN CI SHALL fail.
4. `docs/threat-model.md` SHALL list the controls per trust boundary and link the mapping
   files.

### Requirement 4: Tetragon in observe mode

**User story:** As the operator, I want process and kernel events from every node, so that
an attack inside a container leaves a trace and the worst of it pages.

#### Acceptance criteria

1. THE cluster SHALL run Tetragon on all four nodes, chart and images digest-pinned and
   tracked by Renovate, with requests and memory limits.
2. THE tracing policies SHALL be upstream library policies (`cilium/tetragon`
   `examples/policylibrary`) vendored unchanged at a pinned commit that Renovate tracks.
3. IF any tracing policy contains an enforcement action (`Sigkill`, `Override`, `Signal`,
   `NotifyEnforcer`), THEN CI SHALL fail.
4. Tetragon SHALL export events as JSON to stdout with an allowlist of event types, so
   that the log pipeline can collect them; the export file SHALL be size-bounded and not
   on the eMMC.
5. Tetragon metrics SHALL be scraped with a bounded label set (namespace, workload,
   binary, policy), not per pod.
6. Allowlists of known-good actors (Cilium and Tetragon loading BPF, Talos loading modules
   at boot, the democratic-csi node plugin) SHALL live in the alert rules, not in edited
   copies of the upstream policies.

### Requirement 5: Page only on critical detections

**User story:** As the operator, I want my phone to ring only when a container is trying to
take the node, so that runtime detection does not become noise.

#### Acceptance criteria

1. WHEN a critical detection occurs outside the allowlists, THE system SHALL fire an alert
   with `severity: critical`, `category: security`, `action: human` and a
   `mitre_technique` label.
2. Other detections (shell or binary execution in a container, execution from `/tmp`,
   fileless execution, shared-library loading) SHALL show on the Security dashboard and
   SHALL NOT be alerts.
3. WHEN the Tetragon agent is missing on a node for 30 minutes, or the newest Kyverno
   report is older than 3 hours, THE system SHALL fire an `action: human` warning
   (monitoring went blind).
4. EACH alert SHALL have promtool tests that include an allowlisted event that must not
   fire, a runbook section in `docs/runbooks/alerts.md`, and a line in
   `tests/alertmanager/routes.txt`.
5. ONE root cause SHALL send one notification (grouped by alert name, as today).

### Requirement 6: Keycloak hardening in code

**User story:** As the operator, I want the realm to resist password guessing and require a
second factor for the clients that are cluster-admin in practice, so that one leaked
password is not enough.

#### Acceptance criteria

1. THE realm code SHALL turn on brute-force detection (`bruteForceProtected`) with a
   failure factor, wait increment and maximum wait in line with NIST SP 800-63B rate
   limiting, and no permanent lockout.
2. Platform clients SHALL require OTP: a user without OTP configured is asked to set it up
   at the next login, not locked out.
3. THE new admin UI clients of spec `wave3-network-logs` (`hubble`, `signoz`) SHALL be
   platform clients gated to the group `admins` (`access.conf`).
4. EVERY client SHALL have `directAccessGrantsEnabled=false` unless listed with a reason;
   the PostSync job SHALL read it back and fail otherwise.
5. `tests/bash/test_keycloak_realm.sh` SHALL cover 1 to 4.
