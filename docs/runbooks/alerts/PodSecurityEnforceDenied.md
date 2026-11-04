# PodSecurityEnforceDenied

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/kyverno-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/kyverno-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Pod Security admission (PSA) rejected more than 5 Pods in 30 minutes, in
enforce mode. A controller or an operator keeps trying to create a Pod that
its namespace's `pod-security.kubernetes.io/enforce` level does not admit.
Running Pods are not affected; the rejected ones never start. Usual causes:
a flip to `restricted` that missed a Pod, or a tuppr, CloudNativePG or
Barman Cloud plugin release that builds different Pods
([spec pod-security-restricted](../../../.kiro/specs/pod-security-restricted/design.md), D15).
The metric has no namespace label: the events name it.

## Confirm

```sh
q 'sum(increase(pod_security_evaluations_total{decision="deny",mode="enforce",resource="pod"}[30m]))'
kubectl get events -A --field-selector reason=FailedCreate --sort-by=.lastTimestamp | grep -i podsecurity | tail -10
kubectl get ns -L pod-security.kubernetes.io/enforce
```

Expected while it fires: a count above 5, then `FailedCreate` events in one
namespace with `violates PodSecurity "<level>:latest"` and the controls that
fail (for a CloudNativePG Pod, the event is on the Cluster or its Job; for
tuppr, on the upgrade Job in `system-upgrade`).

## Fix

1. Stop Argo CD from putting the label back, for the `namespaces`
   Application only:

   ```sh
   kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile=true
   ```

2. Put the namespace back to `baseline`:

   ```sh
   kubectl label --overwrite namespace <namespace> pod-security.kubernetes.io/enforce=baseline
   ```

   The controllers' next retry succeeds; check with
   `kubectl -n <namespace> get pods`.
3. Hold merges (disable `renovate-next`, auto-merge off on open pull
   requests), then revert the flip or the release in git with
   `scripts/pr-merge.sh`.
4. After the revert has synced:

   ```sh
   kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile-
   kubectl -n argo get application namespaces
   ```

   Expected: `Synced`, and the namespace's label as in git.

## Resolved when

No new `FailedCreate` event names PodSecurity; the alert clears once the
30-minute window holds 5 rejections or fewer.

## Links

- [`infrastructure/namespaces/namespaces.yaml`](../../../infrastructure/namespaces/namespaces.yaml): the levels per namespace
