# Pod Security: break-glass and flip

Pod Security admission (PSA) enforces one level per namespace, set by the
`pod-security.kubernetes.io/enforce` label in
[`infrastructure/namespaces/namespaces.yaml`](../../infrastructure/namespaces/namespaces.yaml)
(synced by the Argo CD Application `namespaces`). The rollout order and gates
are in the spec [pod-security-restricted](../../.kiro/specs/pod-security-restricted/).

PSA judges a Pod when it is created. A flip does not touch running Pods; it
rejects Pods created later (a rollout, a node drain, a CronJob run, an
operator's Job) that fail the level. A rejection shows as a `FailedCreate`
event naming PodSecurity, a rollout or Job that does not start, and
[PodSecurityEnforceDenied](alerts/PodSecurityEnforceDenied.md).

Everything below needs only the admin kubeconfig (client certificate) on the
LAN, except the git steps, which need `gh` and a clone. It does not depend on
Keycloak, the Gateway or Tailscale.

## Preconditions

```sh
export KUBECONFIG=<admin-kubeconfig>
kubectl --request-timeout=20s get --raw /readyz; echo
kubectl auth whoami -o jsonpath='{.status.userInfo.username}'; echo
kubectl auth can-i '*' '*'
```

Expected: `ok`, `admin`, `yes`. Anything else: fix access first
([cold-start.md](cold-start.md)).

## Break-glass: Pods rejected after a flip

Find the namespace:

```sh
kubectl get events -A --field-selector reason=FailedCreate --sort-by=.lastTimestamp | grep -i podsecurity | tail
```

Expected: lines in one namespace with `violates PodSecurity "restricted:latest"`.

1. Stop Argo CD from putting the label back, for the `namespaces`
   Application only:

   ```sh
   kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile=true
   ```

   Expected: `application.argoproj.io/namespaces annotated`. The parent
   `layer-infrastructure` does not remove an annotation it does not manage;
   `namespaces` stops reconciling (its `status.reconciledAt` stays put).

2. Put the namespace back to `baseline`:

   ```sh
   kubectl label --overwrite namespace <ns> pod-security.kubernetes.io/enforce=baseline
   ```

   Expected: `namespace/<ns> labeled`. PSA reads the label at the next Pod
   creation; the controllers' retries then succeed
   (`kubectl -n <ns> get pods`).

Both steps take under a minute.

### Hold every merge

1. Stop the Renovate train:

   ```sh
   gh workflow disable renovate-next.yaml -R ned-si/homelab
   ```

   Expected: `✓ Disabled renovate-next`.

2. Turn GitHub auto-merge off on every open pull request that has it:

   ```sh
   held=$(gh pr list -R ned-si/homelab --state open --json number,autoMergeRequest \
     --jq '.[] | select(.autoMergeRequest != null) | .number')
   echo "held: $held"
   for n in $held; do gh pr merge "$n" -R ned-si/homelab --disable-auto; done
   ```

   Write the `held:` numbers down.

3. Tell every other runner (agent runs, `scripts/pr-merge.sh` loops) to stop
   merging, or stop it.

### Revert

1. On a branch from `origin/main`, revert the flip (Conventional Commits:
   `pr-metadata` rejects git's default `Revert "..."`):

   ```sh
   git fetch origin
   git worktree add -b revert/psa-<ns> ../revert-psa-<ns> origin/main
   git -C ../revert-psa-<ns> revert --no-commit <sha-of-the-flip>
   git -C ../revert-psa-<ns> commit -m "revert(namespaces): <ns> back to Pod Security baseline"
   git -C ../revert-psa-<ns> push -u origin revert/psa-<ns>
   gh pr create -R ned-si/homelab --head revert/psa-<ns> \
     --title "revert(namespaces): <ns> back to Pod Security baseline" \
     --body "$(printf '## Summary\nReverts #<flip-pr>: <what was rejected>.\n\n## Tested\nBreak-glass applied at <time>.\n\n## Blocked\nNothing.\n\nSpec: pod-security-restricted#<task>\n')"
   bash scripts/pr-merge.sh <pr>
   ```

   Expected: `pr-merge.sh` ends with the pull request merged.

2. After the revert is on `main`, let Argo CD reconcile again:

   ```sh
   kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile-
   kubectl -n argo get application namespaces -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
   kubectl get namespace <ns> -L pod-security.kubernetes.io/enforce
   ```

   Expected: `Synced Healthy` within a minute, and `baseline` in the label
   column.

### Release the hold

```sh
gh workflow enable renovate-next.yaml -R ned-si/homelab
for n in <held-numbers>; do gh pr merge "$n" -R ned-si/homelab --auto --squash; done
```

Expected: `✓ Enabled renovate-next`, and auto-merge on again for the pull
requests held.

## Break-glass: Kyverno in Deny (#1021)

For a Kyverno policy moved to Deny that rejects something it should not.
The webhooks fail open (`forceFailurePolicyIgnore`), so this is only for a
policy that answers and denies.

```sh
kubectl -n argo annotate application kyverno-policies argocd.argoproj.io/skip-reconcile=true
kubectl patch validatingpolicy <name> --type merge -p '{"spec":{"validationActions":["Audit"]}}'
```

Expected: `annotated`, then `validatingpolicy.policies.kyverno.io/<name>
patched`; the next admission of the rejected object passes. Then hold, revert
the Deny change as above, and remove the annotation from `kyverno-policies`
once the revert has synced. Tested in #1021's first pull request.

## Flip one namespace

One pull request sets one namespace's `enforce` label to `restricted`
(plus its header line in `namespaces.yaml` and `deploy/`). Merge Monday to
Friday, 09:00 to 16:59 Zurich (spec D8).

1. **Gate.**

   ```sh
   date -u
   scripts/psa-readiness.sh <ns>
   ```

   Expected: `G1 ok`, two `G2 ok`, `G3 ok   <n> pod templates: no PodSecurity
   warning`, then `READY` (exit 0). Anything else: the gate is closed; the
   namespace stays where it is.

2. **Pull request.** The body quotes the readiness output with its time, the
   Pods operators build in the namespace (G4: CloudNativePG instances and
   Jobs, tuppr Jobs) with how each was checked, and `## Rollback` with the
   `git revert` and the two break-glass commands. Its `ci` is green (G5:
   `scripts/ci/kyverno.sh` blocks the restricted set in the namespace).

3. **Lockout check** ([Preconditions](#preconditions), and the talosconfig):

   ```sh
   export TALOSCONFIG=<talosconfig>
   talosctl -n 192.168.1.247,192.168.1.238,192.168.1.239,192.168.1.240 version --short | grep -E 'NODE|Tag'
   ```

   Expected: four `NODE:` lines, each with the Talos `Tag:` of
   `talos/talconfig.yaml`. Comment the output on the pull request.

4. **Silence** the namespace (a real denial still pages, the alert has no
   namespace label):

   ```sh
   scripts/maintenance-silence.sh <ns> 1h "PSA enforce <ns>, PR #<n>"
   ```

5. **Merge:** `bash scripts/pr-merge.sh <n>`.

6. **Prove it is enforced** within 10 minutes of the sync:

   ```sh
   kubectl get namespace <ns> -L pod-security.kubernetes.io/enforce
   kubectl -n <ns> create --dry-run=server -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: {name: psa-probe}
   spec:
     containers: [{name: probe, image: registry.k8s.io/pause:3.10}]
   EOF
   ```

   Expected: `restricted` in the label column, then `Error from server
   (Forbidden): ... violates PodSecurity "restricted:latest": ...`.

7. **Watch for 30 minutes:**

   ```sh
   scripts/psa-readiness.sh <ns>
   kubectl -n argo get application namespaces <app> -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status
   curl -s -m 10 -o /dev/null -w '%{http_code}\n' https://<host>.lilalala.com/
   kubectl -n <ns> get events --field-selector reason=FailedCreate
   kubectl -n <ns> get pods
   kubectl get --raw '/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=false' |
     jq -r '.[] | "\(.labels.alertname) \(.labels.action // "-")"'
   ```

   Expected: `READY`; `Synced Healthy` for both; the route's usual status
   (`200`, or `302` to the login); no `FailedCreate` naming PodSecurity; Pod
   ages unchanged; only `Watchdog` (and alerts that were firing before).
   A rejected Pod: [break-glass](#break-glass-pods-rejected-after-a-flip).

8. **Close.** Lockout check again, expire the silence
   (`scripts/maintenance-silence.sh --expire <id>`), comment steps 6 and 7 on
   the pull request. Within 26 hours, check that each CronJob of the
   namespace ran once and succeeded (`kubectl -n <ns> get cronjob,job`), or
   say why not (a monthly schedule, with its G3 result), in a second comment.

## Test the break-glass

With the admin kubeconfig only, before the first flip.

```sh
kubectl create namespace psa-breakglass-test
kubectl label namespace psa-breakglass-test pod-security.kubernetes.io/enforce=restricted
cat > /tmp/psa-probe.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: psa-breakglass-probe}
spec:
  containers: [{name: probe, image: registry.k8s.io/pause:3.10}]
EOF
kubectl -n psa-breakglass-test create --dry-run=server -f /tmp/psa-probe.yaml
```

Expected: `Error from server (Forbidden): ... violates PodSecurity
"restricted:latest": allowPrivilegeEscalation != false ...`. Then:

```sh
kubectl label --overwrite namespace psa-breakglass-test pod-security.kubernetes.io/enforce=baseline
kubectl -n psa-breakglass-test create --dry-run=server -f /tmp/psa-probe.yaml
kubectl delete namespace psa-breakglass-test
```

Expected: a `Warning: would violate PodSecurity "restricted:latest"` (from the
`warn` default), then `pod/psa-breakglass-probe created (server dry run)`.

On the `namespaces` Application:

```sh
kubectl -n argo get application namespaces layer-infrastructure -o custom-columns=N:.metadata.name,R:.status.reconciledAt
kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile=true
# wait until layer-infrastructure shows a newer reconciledAt (about 3 minutes)
kubectl -n argo get application namespaces layer-infrastructure -o custom-columns=N:.metadata.name,R:.status.reconciledAt
kubectl -n argo get application namespaces -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}'; echo
kubectl -n argo annotate application namespaces argocd.argoproj.io/skip-reconcile-
```

Expected: `layer-infrastructure` reconciles, `namespaces` keeps its old
`reconciledAt`, the annotation still reads `true`; after the removal
`namespaces` reconciles again within seconds.
