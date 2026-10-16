# Runtime security

What checks workloads inside the cluster. The threats and the backlog are in
[threat-model.md](threat-model.md); the checks CI runs before a merge are in
[testing.md](testing.md).

| Layer | Component | Mode | Where it shows |
| --- | --- | --- | --- |
| Admission and existing resources | Kyverno ValidatingPolicies | Audit: reports, never blocks | PolicyReports, Homelab / Security, row "Admission policies" |

## Admission (Kyverno)

Kyverno 1.19 (Application `kyverno`, namespace `kyverno`,
`infrastructure/kyverno/values.yaml`) runs the admission controller and the
reports controller. The reports controller rescans every existing resource
once an hour. Every result lands in a PolicyReport per resource; policy-reporter
(Application `policy-reporter`) exports the failing ones as
`policy_report_result`.

The policies (Application `kyverno-policies`,
`infrastructure/kyverno-policies/kustomization.yaml`) come from two places,
and none is written here:

| Source | Policies |
| --- | --- |
| `policies/kyverno/` (the CI policies, the same files) | `disallow-latest-tag`, `disallow-privileged`, `require-resources`, `require-probes` |
| [kyverno/policies](https://github.com/kyverno/policies), pinned commit, `pod-security-vpol/baseline` | every Pod Security Standards baseline check but `disallow-privileged-containers` (covered by `disallow-privileged`) |
| the same, `pod-security-vpol/restricted` | every Pod Security Standards restricted check |
| the same, `best-practices-vpol` | `disallow-default-namespace`, `require-ro-rootfs` |

Each policy's `policies.kyverno.io/category` annotation names the controls it
checks: the Pod Security Standards level, the CIS Kubernetes Benchmark
recommendation (5.2.x, 5.7.x), the NIST SP 800-190 countermeasure section
(4.x) and the NSA/CISA Kubernetes Hardening Guide topic. The dashboard groups
by it.

Fail-safe settings, so Kyverno can never stop a cold start:

- every policy is `validationActions: [Audit]` and `failurePolicy: Ignore`;
- every Kyverno webhook fails open (`forceFailurePolicyIgnore`);
- the webhooks skip `kube-system`, `argo`, `cilium`, `kyverno`, `tailscale`
  and `talos`;
- both Applications are the last waves of the infrastructure layer (35, 36).

Look at the findings:

```sh
kubectl get policyreports -A
kubectl -n <namespace> get policyreport -o wide
```

`policyreports` lists one report per resource with PASS, FAIL, WARN, ERROR and
SKIP counts; `-o yaml` on one report shows the policy and message per result.

Change a policy: edit the kustomization (upstream policies are only patched
there, never copied), `task render`, PR. A new upstream commit of
kyverno/policies arrives as a Renovate PR.

## Why it is like this

- Audit before Deny: the cluster has never been checked against Pod Security
  restricted, and a Deny policy with violations would stop a pod from
  restarting. A policy moves to Deny on its own, once its reports are clean.
  Rejected: Deny from the start with exceptions per workload.
- Upstream policies only, patched rather than copied: the library tracks the
  Pod Security Standards, and a Renovate PR is easier to review than a
  hand-maintained copy. Rejected: writing the rules here.
- Webhooks, not native ValidatingAdmissionPolicies: the namespace exclusions
  and the reports work the same for every policy. Both fail open, so neither
  can block a cold start.
- policy-reporter for metrics: Kyverno's own metrics count evaluations, not
  the current state of the reports.
