# HomelabNASDown

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-watch.yaml`](../../../platform/kube-prometheus-stack/routes/nas-watch.yaml),
evaluated by the `nas-watch` Prometheus, which has no volume on the NAS
([observability.md](../../observability.md#nas-watch)).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The cluster has not reached the NAS (`192.168.1.228`) on `instance` for 10
minutes: port 443 (TrueNAS API, which democratic-csi needs), 2049 (NFS,
media and local backups) or 3260 (iSCSI, every PVC). Every app with a volume
is down or about to be, and so are Keycloak and the main Prometheus.

## Confirm

From the Mac, on the LAN:

```sh
ping -c3 192.168.1.228
for p in 443 2049 3260; do printf 'NAS :%-5s ' "$p"; nc -z -G 3 -w 3 192.168.1.228 "$p" && echo open || echo CLOSED; done
```

Expected while it fires: no ping reply, or a port `CLOSED`.

## Fix

1. No ping, and the NAS is dark (no fan, no power LED): it does not power on
   by itself after a power loss. Press its power button. Wait about 5
   minutes and rerun the checks.
2. No ping, and the NAS is on: check its network cable is in the `B8:28`
   port of the Digitus card and the basement switch has link and power. A
   switch power-cycle is safe. If the link is fine, the NAS is hung (it can
   freeze at a power dip with its fans and LEDs on, postmortem
   [2026-11-15](../../postmortems/2026-11-15-nas-hung.md)): hold its power
   button until it turns off, press it again, and rerun the checks after
   about 5 minutes.
3. Ping answers but a port is `CLOSED`: in the web UI
   (`https://192.168.1.228`) start the NFS or iSCSI service and check pool
   `homelab` is ONLINE.
4. Once the ports are open, the cluster recovers on its own within about 10
   minutes. Then clean up what does not retry:
   - delete pods still stuck in `ContainerCreating`, `Unknown` or
     `CrashLoopBackOff`
     ([cold-start.md: The NAS does not start by itself](../cold-start.md#the-nas-does-not-start-by-itself-after-a-power-loss));
   - re-run each CronJob whose last run failed while the NAS was down
     (`kubectl -n <ns> create job --from=cronjob/<cronjob> <cronjob>-manual`;
     backups only when the last success is over 24 hours old), then delete
     its failed Jobs to clear `KubeJobFailed`;
   - delete a failed Argo CD hook Job (`kubectl -n <ns> delete job <job>`);
     Argo CD recreates it on the next sync.

## Resolved when

All three ports answer, the `nas-watch` Prometheus shows `1` for each, and
`kubectl get pods -A | grep -Ev 'Running|Completed'` is empty within 15
minutes:

```sh
kubectl --request-timeout=10s get --raw \
  '/api/v1/namespaces/monitoring/pods/prometheus-nas-watch-0:9090/proxy/api/v1/query?query=probe_success' \
  | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
```

Expected: `192.168.1.228:443 1`, `192.168.1.228:2049 1`, `192.168.1.228:3260 1`.

## Links

- [cold-start.md: NAS first, alone](../cold-start.md#step-2-nas-first-alone)
- [sre.md: Toil register](../../sre.md#toil-register) (the power button)
