# PodStuckNotRunningLongTerm

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A container of `namespace/pod` has been unable to start for 6 hours, waiting
in `reason`: `ErrImagePull`, `ImagePullBackOff`, `InvalidImageName`,
`CreateContainerConfigError` or `CreateContainerError`. Restarts do not fix
these; the 15-minute version (`PodStuckNotRunning`) did not page.

## Confirm

```sh
kubectl -n <namespace> get pod <pod> -o wide
kubectl -n <namespace> describe pod <pod> | sed -n '/^Events:/,$p'
kubectl -n <namespace> get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}: {.state}{"\n"}{end}'
```

Expected while it fires: the container's `state.waiting` with the reason and
a message. Read `state`, not `lastState`.

## Fix

- `ErrImagePull`, `ImagePullBackOff`, `InvalidImageName`: the tag or digest
  does not exist, or the registry refuses. Check the reference in git
  (`grep -rn '<image>' apps platform infrastructure`) and fix it or revert
  the change that set it.
- `CreateContainerConfigError`: a Secret, ConfigMap or key the pod references
  is missing. `kubectl -n <namespace> get secret,configmap` and compare with
  the pod spec; a sealed Secret that still holds a `PENDING-*` sentinel needs
  its value ([secrets.md](../../secrets.md#everyday-work)).
- `CreateContainerError`: often a stale containerd name reservation after a
  node restart (the message says `name is reserved`). Delete the pod; its
  controller recreates it: `kubectl -n <namespace> delete pod <pod>`.

## Resolved when

The pod is `Running` and Ready (`kubectl -n <namespace> get pod`), and the
alert clears.

## Links

- [observability.md: When something looks healthy and is not](../../observability.md#when-something-looks-healthy-and-is-not)
- [PodStuckNotRunning rule](../../../platform/kube-prometheus-stack/routes/alerts.yaml)
