# KyvernoDenied

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/kyverno-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

One Kyverno policy in Deny rejected more than 5 requests in 30 minutes. A
controller or an operator keeps trying to create an object (usually a Pod)
that the policy does not admit; it retries with back-off, so it passes 5
within minutes, while one rejected dry run does not. Running Pods are not
affected; the rejected ones never start. Usual causes: a policy moved to
Deny that missed a workload, or a chart or operator release (CloudNativePG,
tuppr, Barman Cloud plugin) that builds different Pods
([spec per-app-hardening](../../../.kiro/specs/per-app-hardening/design.md),
requirement 7).
The label `name` is the webhook, `vpol.validate.kyverno.svc-ignore-finegrained-<policy>`:
the part after `finegrained-` is the policy. The metric has no namespace
label, so a namespace silence does not mute this page: the events name it.

## Confirm

```sh
q 'sum by (name) (increase(apiserver_admission_webhook_rejection_count{name=~"vpol\\.validate\\.kyverno\\.svc.*",error_type="no_error"}[30m]))'
kubectl get events -A --field-selector reason=FailedCreate --sort-by=.lastTimestamp | grep -i kyverno | tail -10
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=30m | grep -i '<policy>' | tail -10
kubectl get validatingpolicy <policy> -o jsonpath='{.spec.validationActions}{"\n"}'
```

Expected while it fires: a count above 5 for one `name`, then `FailedCreate`
events on the object's controller (ReplicaSet, StatefulSet, Job, or the
CloudNativePG Cluster) with `admission webhook "vpol.validate.kyverno.svc-ignore-finegrained-<policy>" denied the request`
and the policy's message; the admission controller's log names the same
resource when there is no event (an object created directly, not by a
controller). The policy shows `["Deny"]`.

## Fix

1. Run the [Kyverno break-glass](../pod-security.md#break-glass-kyverno-in-deny-1021)
   for that policy:

   ```sh
   kubectl -n argo annotate application kyverno-policies argocd.argoproj.io/skip-reconcile=true
   kubectl patch validatingpolicy <policy> --type merge -p '{"spec":{"validationActions":["Audit"]}}'
   ```

   Expected: `annotated`, then `validatingpolicy.policies.kyverno.io/<policy>
   patched`. The controller's next retry succeeds; check with
   `kubectl -n <namespace> get pods`.
2. Hold merges (disable `renovate-next`, auto-merge off on open pull
   requests), then revert the Deny change or the release in git with
   `scripts/pr-merge.sh`.
3. After the revert has synced:

   ```sh
   kubectl -n argo annotate application kyverno-policies argocd.argoproj.io/skip-reconcile-
   kubectl -n argo get application kyverno-policies
   ```

   Expected: `Synced`, and the policy's `validationActions` as in git.

## Resolved when

No new `FailedCreate` event names the Kyverno webhook; the alert clears once
the 30-minute window holds 5 rejections or fewer for every policy.

## Links

- [pod-security.md](../pod-security.md#break-glass-kyverno-in-deny-1021): the Kyverno break-glass, the merge hold, the revert
- [`policies/kyverno/`](../../../policies/kyverno/): the policies and their actions
- [PodSecurityEnforceDenied](PodSecurityEnforceDenied.md): the same page for Pod Security admission
