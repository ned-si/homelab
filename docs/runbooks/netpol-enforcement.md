# Network policy enforcement: break-glass and flip

Default-deny is switched on per namespace and direction by the
`enforce-default-deny` CiliumNetworkPolicy of each namespace in
[`infrastructure/network-policies/90-enforcement.yaml`](../../infrastructure/network-policies/90-enforcement.yaml)
(the switch). What is enforced today is listed in
[networking.md](../networking.md#network-policy). The rollout order and gates
are in the spec [netpol-default-deny](../../.kiro/specs/netpol-default-deny/).

Everything below needs only the admin kubeconfig (client certificate) on the
LAN, except the git steps, which need `gh` and a clone. It does not depend on
Keycloak, the Gateway, Argo CD or Tailscale.

## Preconditions

```sh
export KUBECONFIG=<admin-kubeconfig>
kubectl --request-timeout=20s get --raw /readyz; echo
kubectl auth whoami -o jsonpath='{.status.userInfo.username} {.status.userInfo.groups}'; echo
```

Expected: `ok`, then `admin ["system:masters","system:authenticated"]`.
Anything else: fix access first ([cold-start.md](cold-start.md)); nothing
here works without it.

## Break-glass

### The switch: an app lost a flow after a flip

```sh
kubectl -n <ns> delete ciliumnetworkpolicy enforce-default-deny
```

Expected: `ciliumnetworkpolicy.cilium.io "enforce-default-deny" deleted from
<ns> namespace`. The remaining allow-lists are default-allow, so Cilium puts
the wildcard-allow rule back: flows resume within 2 seconds, with no pod or
agent restart. Check the app (its public URL, or the failing Job again).

### Every policy of a namespace: a wrong allow-list rule

An `ingressDeny` or `egressDeny` rule drops traffic even with every switch
`false`. Remove every policy of the namespace:

```sh
kubectl -n <ns> delete ciliumnetworkpolicy --all
```

Expected: one `deleted` line per policy; flows resume within 2 seconds.

### How long a delete lasts

The Application `network-policies` has `selfHeal: false`
([clusters/homelab/infrastructure/network-policies.yaml](../../clusters/homelab/infrastructure/network-policies.yaml)),
so Argo CD leaves the deleted object alone and shows `OutOfSync`. Any new
revision of `main` syncs the Application and re-creates it. So, right after
the delete, hold every merge and land the revert.

### Hold every merge

1. Stop the Renovate train:

   ```sh
   gh workflow disable renovate-next.yaml -R ned-si/homelab
   ```

   Expected: `✓ Disabled renovate-next`.

2. Turn GitHub auto-merge off on every open pull request that has it (the
   train turns it on for its candidates; disabling the workflow does not stop
   a pull request that is up to date and running `ci`):

   ```sh
   held=$(gh pr list -R ned-si/homelab --state open --json number,autoMergeRequest \
     --jq '.[] | select(.autoMergeRequest != null) | .number')
   echo "held: $held"
   for n in $held; do gh pr merge "$n" -R ned-si/homelab --disable-auto; done
   ```

   Write the `held:` numbers down. Run the `gh pr list` line again: expected
   no number.

3. Tell every other runner (agent runs, `scripts/pr-merge.sh` loops) to stop
   merging, or stop it.

### Revert

1. On a branch from `origin/main`, revert the flip. The commit and the title
   follow Conventional Commits (`pr-metadata` rejects git's default
   `Revert "..."`):

   ```sh
   git fetch origin
   git worktree add -b revert/netpol-<ns>-<direction> ../revert-netpol-<ns> origin/main
   git -C ../revert-netpol-<ns> revert --no-commit <sha-of-the-flip>
   git -C ../revert-netpol-<ns> commit -m "revert(network): <ns> <direction> default-deny off"
   git -C ../revert-netpol-<ns> push -u origin revert/netpol-<ns>-<direction>
   gh pr create -R ned-si/homelab --head revert/netpol-<ns>-<direction> \
     --title "revert(network): <ns> <direction> default-deny off" \
     --body "$(printf '## Summary\nReverts #<flip-pr>: <what was dropped>.\n\n## Tested\nBreak-glass applied at <time>.\n\n## Blocked\nNothing.\n\nSpec: netpol-default-deny#<task>\n')"
   bash scripts/pr-merge.sh <pr>
   ```

   Expected: `pr-merge.sh` ends with the pull request merged.

2. If another merge lands before the revert, wait for its sync, then check
   the switch and delete it again:

   ```sh
   kubectl -n argo get application network-policies -o jsonpath='{.status.sync.revision} {.status.sync.status}'; echo
   git rev-parse origin/main
   kubectl -n <ns> get ciliumnetworkpolicy enforce-default-deny
   ```

   When the revision equals `origin/main` and the switch exists, run the
   switch delete above again.

3. After the revert has synced, check the live value:

   ```sh
   kubectl -n <ns> get ciliumnetworkpolicy enforce-default-deny -o jsonpath='{.spec.enableDefaultDeny}'; echo
   ```

   Expected: `{"egress":false,"ingress":false}`.

### Release the hold

```sh
gh workflow enable renovate-next.yaml -R ned-si/homelab
for n in <held-numbers>; do gh pr merge "$n" -R ned-si/homelab --auto --squash; done
```

Expected: `✓ Enabled renovate-next`, and auto-merge on again for the pull
requests noted in step 2 of the hold. The train turns it back on for
Renovate's own pull requests at its next run.

## Flip one namespace and direction

One pull request changes one value in `90-enforcement.yaml` from `false` to
`true`, plus `deploy/`. The pull request body carries the gate and a
`## Rollback` section with the exact `git revert <sha>` and the switch delete
for the namespace. Prometheus queries below go through the API server:

```sh
q() { kubectl --request-timeout=20s get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -r '.data.result[] | "\(.metric | del(.__name__) | tostring) \(.value[1])"'; }
```

1. **Gate.** Readiness and the presence query (the spec, Requirement 2):

   ```sh
   q 'netpol:ready_to_enforce{namespace="<ns>", direction="<direction>"}'
   q 'max by (source_namespace, source, destination) (max_over_time(hubble_policy_verdicts_total{match="all", direction="ingress", destination_namespace="<ns>"}[7d]))'
   ```

   Expected: `1`, and no series from the presence query (for egress:
   `direction="egress"`, `source_namespace="<ns>"`, `destination_namespace`
   in the `by`). A `0` or a series: every series needs a decision (an allow
   rule or an intended drop) before the flip. List the namespace's CronJobs
   and Argo CD hook Jobs with their last run, and every peer seen in 7 days
   with its match type:

   ```sh
   kubectl -n <ns> get cronjob,job
   q 'max by (source, destination, match) (max_over_time(hubble_policy_verdicts_total{direction="ingress", destination_namespace="<ns>"}[7d]))'
   ```

   Expected: each Job's workload (`source` for egress, `destination` for
   ingress; for egress use `source_namespace="<ns>"`) appears only with a
   match other than `all`. A Job that ran but has no row proves nothing.

   Record each node's policy revision as the baseline:

   ```sh
   for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
     echo "$p $(kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg policy get | grep '^Revision')"
   done
   ```

   Expected: one `pod/cilium-<id> Revision: <n>` line per node (4).

2. **Lockout check and soak.** Run [Preconditions](#preconditions) and:

   ```sh
   export TALOSCONFIG=<talosconfig>
   talosctl -n 192.168.1.247,192.168.1.238,192.168.1.239,192.168.1.240 version | grep -E 'NODE:|Tag:'
   ```

   Expected: four `NODE:` lines, each with the Talos `Tag:` of
   `talos/talconfig.yaml`. The previous flip has run for 24 hours; before an
   egress flip, the namespace's nightly backup has succeeded since.

3. **Silence** the namespace for a used app (never `Watchdog`):

   ```sh
   scripts/maintenance-silence.sh <ns> 2h "netpol flip <ns> <direction>, PR #<n>"
   ```

   Expected: the silence ID.

4. **Merge:** `bash scripts/pr-merge.sh <n>`.

5. **Prove it is enforced** once `network-policies` shows the merge commit
   (`kubectl -n argo get application network-policies -o jsonpath='{.status.sync.revision}'`):

   ```sh
   kubectl -n <ns> get ciliumnetworkpolicy enforce-default-deny \
     -o jsonpath='{.spec.enableDefaultDeny.<direction>} {.status.conditions[?(@.type=="Valid")].status}'; echo
   ```

   Expected: `true True`. Run the revision loop of step 1 again: every node's
   `Revision` is higher than the baseline. Within 10 minutes the wildcard
   verdicts stop while the others continue:

   ```sh
   q 'sum(rate(hubble_policy_verdicts_total{match="all", direction="<direction>", destination_namespace="<ns>"}[5m]))'
   q 'netpol:verdicts:rate5m{namespace="<ns>", direction="<direction>"}'
   ```

   Expected: `0` for the first (for egress: `source_namespace="<ns>"`), a
   value above 0 for the second.

6. **Watch for 30 minutes** while using the app (log in, open a page; for
   egress also a fresh OIDC login and one outbound fetch):

   ```sh
   curl -s -m 10 -o /dev/null -w '%{http_code}\n' https://<host>.lilalala.com/
   kubectl -n argo get application <app> -o jsonpath='{.status.health.status}'; echo
   kubectl get --raw '/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=false' |
     jq -r '.[] | "\(.labels.alertname) \(.labels.action // "-") \(.labels.namespace // "-")"'
   q 'max_over_time(hubble_drop_total{reason=~"POLICY_DENIED|POLICY_DENY", destination="<ns>"}[30m])'
   ```

   Expected: the app's usual status code (`200`, or `302` to the login),
   `Healthy`, only `Watchdog` (and alerts that were firing before), and no
   drop series (for egress: `source="<ns>"`). A drop series is a dropped flow:
   see what it is live, on the node of the pod involved:

   ```sh
   kubectl -n <ns> get pod -o wide
   kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=<node> -o name
   kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- hubble observe --namespace <ns> --verdict DROPPED -f
   ```

   A policy drop reads `policy-verdict:none INGRESS DENIED` (or `EGRESS`) and
   `Policy denied DROPPED`; in `-o json` its `drop_reason_desc` is
   `POLICY_DENIED` (`POLICY_DENY` for an explicit deny rule). The agent keeps
   only its last 4,095 flows, a few seconds on a busy node, so follow it
   (`-f`) rather than reading back. A legitimate flow dropped:
   [break-glass](#the-switch-an-app-lost-a-flow-after-a-flip), hold, revert.

7. **Databases.** For `immich` and every namespace with a CloudNativePG
   Cluster, the operator's webhook still answers and every collector is up:

   ```sh
   kubectl apply --dry-run=server -f deploy/apps/<app>/resources/cluster-<name>.yaml
   q 'cnpg_collector_up'
   ```

   Expected: `cluster.postgresql.cnpg.io/<name> configured (server dry run)`
   (or `unchanged`), and `1` for each of the 8 Clusters.

8. **Close.** Run the lockout check of step 2 again, expire the silence
   (`scripts/maintenance-silence.sh --expire <id>`), comment the results of
   steps 5 to 7 on the pull request, and tick the spec task with its number.

## Test the break-glass

On a scratch namespace that is not in git, with the admin kubeconfig only.
Once before the first flip, and again after a Cilium minor upgrade.

```sh
kubectl create namespace netpol-scratch
kubectl -n netpol-scratch apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: server, labels: {app: server}}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: server
      image: registry.k8s.io/e2e-test-images/agnhost:2.62.2
      args: ["netexec", "--http-port=8080", "--udp-port=-1"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
---
apiVersion: v1
kind: Service
metadata: {name: server}
spec: {selector: {app: server}, ports: [{port: 8080}]}
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {app: client}}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: client
      image: curlimages/curl:8.23.0
      command:
        - /bin/sh
        - -c
        - |
          while true; do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://server:8080/hostname) || code=000
            echo "$code"
            sleep 0.2
          done
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
EOF
kubectl -n netpol-scratch wait --for=condition=Ready pod --all --timeout=180s
sleep 8; kubectl -n netpol-scratch logs client --since=5s | sort | uniq -c
```

Expected: only `200` lines. Enforce ingress with a copy of the switch:

```sh
kubectl -n netpol-scratch apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: enforce-default-deny}
spec:
  endpointSelector: {}
  enableDefaultDeny: {ingress: true, egress: false}
  ingress: [{fromEntities: [host, remote-node]}]
  egress:
    - toEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}}]
      toPorts: [{ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}]}]
EOF
sleep 10; kubectl -n netpol-scratch logs client --since=5s | sort | uniq -c
```

Expected: only `000` lines, and on the server's node
`hubble observe --namespace netpol-scratch --verdict DROPPED --last 2`
(step 6 above) shows `Policy denied DROPPED` from `netpol-scratch/client` to
`netpol-scratch/server:8080`. Now the break-glass, timed:

```sh
date -u +%T; kubectl -n netpol-scratch delete ciliumnetworkpolicy enforce-default-deny
sleep 3; kubectl -n netpol-scratch logs client --timestamps --since=4s
```

Expected: `200` lines again, the first within 2 seconds of the delete. Repeat
the apply and use `kubectl -n netpol-scratch delete ciliumnetworkpolicy --all`
instead: same result. Clean up:

```sh
kubectl delete namespace netpol-scratch
```

Expected: `namespace "netpol-scratch" deleted`. The `hubble_drop_total`
series of the test stay on that node's agent until it restarts; they name
`netpol-scratch` only.
