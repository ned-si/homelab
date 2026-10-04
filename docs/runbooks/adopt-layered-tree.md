# Adopt the layered tree

How the cluster moves from the legacy root `all-apps` (flat tree under
`kubernetes/applications/`) to the layered tree (`clusters/homelab/root.yaml`
and everything below it), app by app, without two roots ever writing the same
object.

Time: about 15 minutes per app, plus a soak. Nothing here is urgent: until a step
runs, `all-apps` keeps running everything exactly as before.

## Rules

- **One writer per object.** An app moves in one PR that removes it from
  `kubernetes/applications/` and makes its leaf the owner. Merging that PR is
  safe because `all-apps` has `prune` off: the objects stay, it just stops
  writing them.
- **Diff before every sync.** `argocd app diff <leaf>` must show only the
  classes in [Expected differences](#expected-differences). Anything else
  stops the move for that app.
- **The data never moves.** No step deletes or recreates a PVC, PV, CNPG
  Cluster, StatefulSet or Namespace. The photo library PVC `immich/immich-data`
  is not in any leaf at all.
- **Smoke after every sync:** `scripts/smoke.sh` (read-only). A failure means
  roll back that app (below) and stop.

## Before the first app

1. Argo CD 2.14 with KSOPS on the repo-server (the `secrets-*` leaves decrypt
   SOPS at render time). KSOPS is its own change to
   `bootstrap/argocd-values.yaml`, applied with `helm upgrade`.
2. The cutover component (`clusters/homelab/components/cutover`) is in all three
   layer kustomizations: every leaf renders without `automated`, so creating it
   syncs nothing.
3. Remove the six legacy child Applications from git and from the cluster, in one
   PR plus one command, because the layers create Applications with the same
   names (`cert-manager`, `cnpg`, `external-dns`, `immich`,
   `kube-prometheus-stack`, `nginx`):

   ```sh
   # PR: delete kubernetes/applications/{cert-manager/cert-manager.yaml,
   #     cloudnative-pg.yaml,external-dns/external-dns.yaml,immich/immich.yaml,
   #     kube-prom-stack.yaml,ingress-nginx.yaml}; merge with CI green.
   # They carry no finalizer, so deleting them deletes nothing they manage:
   for a in cert-manager cnpg external-dns immich kube-prometheus-stack nginx; do
     kubectl -n argo get application "$a" -o jsonpath='{.metadata.finalizers}{"\n"}'  # must be empty
     kubectl -n argo delete application "$a"
   done
   ```

4. Apply the root once: `kubectl apply -f clusters/homelab/root.yaml`. The layers
   create every leaf Application, OutOfSync and not syncing.

## Per app

1. PR: remove the app's manifests from `kubernetes/applications/` (none for the
   six chart apps, done above). CI green, merge. `all-apps` stays Synced/Healthy.
2. `argocd app diff <leaf>`; classify every difference.
3. `argocd app sync <leaf>`; wait for Healthy.
4. Smoke suite, plus the app's own check (its hostname answers through the
   public name; for Immich the asset count is not lower than before).
5. When every leaf of a layer is adopted and has soaked, remove the cutover
   component from that layer's kustomization (one PR per layer). From then on
   the leaves auto-sync with `prune: true` (data objects are guarded by
   `Delete=false,Prune=false`).

Suggested order: `namespaces`, `secrets-*`, `cilium-config`, `gateway-api`,
`cert-manager`, `cert-manager-issuers`, `external-dns`, `nginx`,
`legacy-ingress`, `gateway`, `cnpg`, `keycloak`, `kube-prometheus-stack`, then
the apps, `immich` last. `cilium` and `democratic-csi` are never synced: they
stay helm-CLI releases.

## Expected differences

From the read-only server-side diff of every leaf against the cluster
(2026-10-04):

| Class | Example |
|---|---|
| tracking | `argocd.argoproj.io/instance` label `all-apps` (or the old child) becomes the leaf name |
| data guard | `argocd.argoproj.io/sync-options: Delete=false,Prune=false` added to PVCs, CNPG Clusters, the syncthing StatefulSet, Namespaces |
| PSA labels | `pod-security.kubernetes.io/warn` and `/audit` added to existing Namespaces |
| secret reference | an inline credential becomes `secretKeyRef` to a SOPS Secret with the same value; one restart (mealie, paperless, seafile, mariadb, keycloak, plex, Grafana, Immich config file) |
| LB pin | `lbipam.cilium.io/ips: 192.168.1.254` on the ingress-nginx Service (equals its current address) |
| new | HTTPRoutes, the Gateway and its Certificate, `iscsi-retain`, the `gateway` Namespace, suspended Recyclarr |
| hooks | chart hook Jobs and their RBAC (ingress-nginx admission, cert-manager startupapicheck, kube-prometheus-stack admission, Grafana test) that Argo CD runs on each sync |
| render environment | the kube-prometheus-stack operator ClusterRole's `discovery.k8s.io` rule, which the chart only renders when the cluster serves that API (Argo CD passes it; the offline render does not) |

Immich keeps client-side apply for the first sync: its objects were last
applied client-side, and a server-side apply would keep the old ConfigMap
volume source next to the new Secret one and fail validation. Delete the
ConfigMap `immich/immich-immich-config` by hand after the sync.

## Roll back one app

1. Revert the app's PR (its manifests return to `kubernetes/applications/`);
   merge with CI green. `all-apps` writes the legacy spec again.
2. For a chart app, re-apply its legacy child Application from the reverted
   commit: `git show <sha>:kubernetes/applications/<file> | kubectl apply -f -`.
3. Smoke suite.

## Finish

When every app is adopted: delete `all-apps` (no finalizer, so nothing
cascades), replace `bootstrap/root-app.yaml` with the root of the layered tree,
and drop `kubernetes/applications/` and `iac/` from git.
