# HomelabNASDown

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/outage-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/outage-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The cluster has not reached the NAS (`192.168.1.228`) on `instance` for 10
minutes: port 3260 (iSCSI, every PVC) or 2049 (NFS, media and local
backups). Every app with a volume is down or about to be.

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
2. The NAS is on but does not answer: check its network cable is in the
   `B8:28` port of the Digitus card and the basement switch has link and
   power. A switch power-cycle is safe.
3. Ping answers but 2049 or 3260 is `CLOSED`: in the web UI
   (`https://192.168.1.228`) start the NFS or iSCSI service and check pool
   `homelab` is ONLINE.
4. Once the ports are open, the cluster recovers on its own within about 10
   minutes. Delete pods still stuck in `ContainerCreating`, `Unknown` or
   `CrashLoopBackOff` after that
   ([cold-start.md: The NAS does not start by itself](../cold-start.md#the-nas-does-not-start-by-itself-after-a-power-loss)).

## Resolved when

Both ports answer, `q 'probe_success{job="blackbox-internal", instance=~"192.168.1.228:.*"}'`
shows `1`, and `kubectl get pods -A | grep -Ev 'Running|Completed'` is empty
within 15 minutes.

## Links

- [cold-start.md: NAS first, alone](../cold-start.md#step-2-nas-first-alone)
- [sre.md: Toil register](../../sre.md#toil-register) (the power button)
