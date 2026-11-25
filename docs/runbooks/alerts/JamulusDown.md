# JamulusDown

`warning`, `action: review`: no notification, listed on the Homelab / Alerts dashboard. Rule: [`platform/kube-prometheus-stack/routes/jamulus-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/jamulus-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The Jamulus server on `192.168.1.202:41124` has not answered a protocol
ping for 15 minutes, or nothing reports on it. `jamulus-probe` (Deployment
in `monitoring`, `platform/jamulus-probe/exporter.py`) sends one ping per
Prometheus scrape, every 30 seconds, through the LoadBalancer address. When
the probe itself is down, `jamulus_up` has no series and the alert fires
the same way. Nobody can play while the server does not answer; sessions
are by appointment, so check it before the next one.

## Confirm

```sh
q 'jamulus_up'
kubectl -n jamulus get pods,svc
kubectl -n monitoring get pods -l app.kubernetes.io/name=jamulus-probe
python3 platform/jamulus-probe/exporter.py --once 192.168.1.202:41124
```

Expected while it fires: `jamulus_up` 0 or no line at all, and `--once`
prints `down <reason>` and exits 1. When `--once` prints
`up clients=<n> rtt=<s>s` from the Mac while `jamulus_up` stays 0, the
server works and the probe's path to it does not (step 3).

## Fix

1. The server. Read the pod's state and log:

   ```sh
   kubectl -n jamulus get pods -o wide
   kubectl -n jamulus logs deploy/jamulus --tail=50
   kubectl -n jamulus get events --sort-by=.lastTimestamp | tail -20
   ```

   | Seen | Meaning | Next |
   | --- | --- | --- |
   | `ImagePullBackOff` | the image digest cannot be pulled | the pull row in [design, Error handling](../../../.kiro/specs/self-hosted-jamulus/design.md#error-handling); revert the last `homelab-jamulus` digest bump |
   | `CrashLoopBackOff` | the server exits at start | the log names the argument or the port; revert the last change to `apps/jamulus/` |
   | Running, not Ready | the server does not echo `jamulus-ping` | `kubectl -n jamulus rollout restart deploy/jamulus` |

2. The address. The Service must hold `192.168.1.202`:

   ```sh
   kubectl -n jamulus get svc jamulus -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
   ```

   Expected: `192.168.1.202`. Empty: the address left LB-IPAM's pool
   ([networking.md](../../networking.md#loadbalancer-ips)).

3. The probe. Read its log, then the policy verdicts of its flows (hubble
   CLI as in [networking.md](../../networking.md#hubble)):

   ```sh
   kubectl -n monitoring logs deploy/jamulus-probe --tail=20
   kubectl -n kube-system port-forward svc/hubble-relay 4245:80 > /dev/null 2>&1 &
   HPF=$!
   hubble observe --server localhost:4245 --namespace jamulus --port 41124 --last 20
   kill "$HPF"
   ```

   Expected: a JSON line `target down` with its `reason` (`timeout`,
   `port unreachable`, or the defect of a bad reply). Dropped flows from
   `jamulus-probe` point at the `jamulus-probe` rules in
   `infrastructure/network-policies/58-jamulus.yaml` and `88-monitoring.yaml`.
   A probe pod that is not Running: `kubectl -n monitoring rollout restart
   deploy/jamulus-probe`.

## Resolved when

`jamulus_up{target="192.168.1.202:41124"}` is 1; the alert clears at the
next evaluation.

## Links

- [`apps/jamulus/`](../../../apps/jamulus/)
- [`platform/jamulus-probe/`](../../../platform/jamulus-probe/)
- [design: Probe](../../../.kiro/specs/self-hosted-jamulus/design.md#probe)
