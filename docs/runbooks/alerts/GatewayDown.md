# GatewayDown

`critical`, pages, also during quiet hours. Rule: [`platform/kube-prometheus-stack/routes/outage-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/outage-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). The Kubernetes API does
not pass the Gateway, so `kubectl` works while this fires.

## What it means

Half or more of the public hostnames have failed their probe for 5 minutes.
That is the shared Gateway (`gateway/shared`, 192.168.1.254), Cilium's Envoy,
or the uplink, not one app. Incident it was written for:
[2026-10-23](../../postmortems/2026-10-23-gateway-cilium-xds.md).

## Confirm, top to bottom

Each step either looks fine or points one layer down.

1. The Gateway is accepted and its routes attached:

   ```sh
   kubectl get gateway -n gateway shared
   ```

   Expected: `PROGRAMMED True`. If not, `kubectl describe gateway -n gateway shared`.

2. It answers from inside the cluster (separates "outside" from "the proxy"):

   ```sh
   kubectl -n monitoring run curl --rm -it --restart=Never --image=curlimages/curl:8.23.0 -- \
     curl -skv -H 'Host: media.lilalala.com' https://cilium-gateway-shared.gateway.svc/
   ```

   - An HTTP status: the proxy works; the fault is outside (WAN IP, DNS,
     router). Check `dig +short media.lilalala.com` against the WAN IP
     ([runbook](../wan-ip-change.md)).
   - `Connection refused`: Envoy has no listener; go on.

3. Envoy gets its configuration from the agent:

   ```sh
   kubectl logs -n kube-system ds/cilium-envoy --since=1h | grep -iE 'warn|error'
   ```

   `unknown service envoy.service.listener.v3.ListenerDiscoveryService` means
   the agent and Envoy disagree on the xDS mode (`envoy.xdsMode` in
   `infrastructure/cilium/values.yaml`, `envoy-xds-mode` in `cilium-config`).

4. The agent is healthy and maps the IP:

   ```sh
   kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status
   kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg service list | grep 192.168.1.254
   ```

   Expected: controllers healthy, `192.168.1.254:443` mapped to an Envoy port.

5. What changed:

   ```sh
   kubectl get pods -n kube-system -l k8s-app=cilium-envoy
   git log origin/main --since=6.hours --oneline
   ```

   Cilium or Envoy pods younger than the outage point at the last Cilium merge.

## Fix

- A Cilium update: revert it with a PR (`revert: <title>`, signed, through
  CI). A patch update is reverted automatically; other Cilium changes are not
  (`scripts/ci/auto-rollback-decide.sh`).
- Outside the cluster: [wan-ip-change.md](../wan-ip-change.md), the router,
  the uplink.

## After

A postmortem ([sre.md](../../sre.md#postmortems)): this alert means every app
spent budget at once.
