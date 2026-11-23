# HomelabDashboardSnapshotStale

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/homelab-dashboard-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/homelab-dashboard-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

No web pod of `homelab-dashboard` has accepted a snapshot for 48 hours, or a
web pod has run 48 hours without ever getting one. The collector
(`deploy/homelab-dashboard-collector`) builds a signed snapshot every minute
and pushes it to every web pod on port 9465; the web pod serves the last one
it accepted. The dashboard still answers, with old figures and a notice
under the title.

## Confirm

```sh
q 'homelab_dashboard_snapshot_age_seconds'
q 'sum by (result) (increase(homelab_dashboard_push_total[1h]))'
q 'sum by (reason) (increase(homelab_dashboard_push_rejected_total[1h]))'
q 'sum by (source) (increase(homelab_dashboard_collect_errors_total[1h]))'
kubectl -n homelab-dashboard get pods
```

Expected while it fires: an age above 172800 seconds (48 hours); no
`accepted` pushes in the last hour.

## Fix

1. Read the collector's log:

   ```sh
   kubectl -n homelab-dashboard logs deploy/homelab-dashboard-collector --since=1h | tail -50
   ```

   | Seen | Meaning | Next |
   | --- | --- | --- |
   | `push_total{result="rejected"}`, `push_rejected_total{reason="signature"}` | the web pods do not hold the public key of the collector's private key | compare `apps/homelab-dashboard/push-pubkey.yaml` with the key in `apps/secrets/homelab-dashboard-push.sops.yaml` (the rotation row in [secrets.md](../../secrets.md#rotating-a-credential)) |
   | `reason="replay"` | the collector's clock or a snapshot from the future | `kubectl -n homelab-dashboard rollout restart deploy/homelab-dashboard-web` |
   | `reason="schema"` or `"allowlist"`, or `source="validation"` | the collector builds a snapshot the schema refuses | a bug in the release: revert the last `homelab-dashboard` digest bump |
   | `push_total{result="error"}` | the collector cannot reach port 9465 | `infrastructure/network-policies/56-homelab-dashboard.yaml`; `kubectl -n homelab-dashboard get endpoints homelab-dashboard-web-push` |
   | `source="prometheus"` | Prometheus does not answer | `kubectl -n monitoring get pods`; the collector's 9090 rule in `infrastructure/network-policies/88-monitoring.yaml` |
   | `source="github"`, no push at all | the collector pushes only once it holds every block, and GitHub never answered | `homelab_dashboard_github_ratelimit_remaining`, `homelab_dashboard_github_token_valid`; a rejected token: the GitHub token row in [secrets.md](../../secrets.md#rotating-a-credential) |

2. Once the cause is fixed, restart the collector so it pushes at once:

   ```sh
   kubectl -n homelab-dashboard rollout restart deploy/homelab-dashboard-collector
   kubectl -n homelab-dashboard rollout status deploy/homelab-dashboard-collector --timeout=2m
   ```

   Expected: `deployment "homelab-dashboard-collector" successfully rolled out`,
   then `homelab_dashboard_snapshot_age_seconds` under 120 within two
   minutes.

## Resolved when

The age is under 48 hours for 30 minutes; the alert clears.

## Links

- [`apps/homelab-dashboard/`](../../../apps/homelab-dashboard/)
- [design: Pushing](../../../.kiro/specs/homelab-dashboard/design.md#pushing)
