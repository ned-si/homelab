# The *arr apps cannot reach qBittorrent

**Status: root-caused and FIXED on 2026-07-31 against the live cluster.**

An earlier revision of this document blamed the qBittorrent 4.6.1 credential
change. **That was wrong.** The password was never the problem. The real cause is
below, and it is more interesting.

## What actually happened

A **stale `ipc-socket`** in qBittorrent's config directory made every start abort
silently after about two seconds. s6 restarted it forever inside the container.
Because the Deployment had **no readiness or liveness probe**, Kubernetes reported
the pod `Running 1/1` with `0` restarts, kept an endpoint in the Service, and
routed traffic to a process that was not listening.

The *arr apps got TCP connection-refused, which they surface as "download client
unavailable" — a message that reads like an auth or network fault.

```
/config/config/ipc-socket    srwx------  0  Apr 19 09:45
```

Dated **19 April**. qBittorrent uses that socket for single-instance detection.
It was left behind by an unclean shutdown — almost certainly the node reboot or
power event that day — and its presence made every subsequent start bail out.

## The evidence, in order

Worth recording because each step eliminated a plausible wrong answer.

```sh
# 1. The pod looks perfectly healthy. This is the trap.
kubectl -n theater get pods
#   qbittorrent-cfdbd5f4d-6fzrx   1/1   Running   0   79d

# 2. But nothing is listening.
kubectl -n theater exec deploy/qbittorrent -- ss -lntp
#   (empty table)

# 3. And Sonarr cannot connect at all -- 000, not 401.
kubectl -n theater exec deploy/sonarr -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://qbittorrent:8080/api/v2/app/version
#   000        <- connection refused, NOT an auth failure
```

`000` is what killed the password theory. A credential problem returns `401` or
`403`; you have to be talking to something first.

```sh
# 4. The process exists, but is only ever a couple of seconds old.
kubectl -n theater exec deploy/qbittorrent -- ps -eo pid,etime,comm | grep qbittorrent-nox
#   4005671  0:02  qbittorrent-nox      <- sample 1
#   (absent)                            <- sample 2, four seconds later

# 5. The container log had 61 lines and had not grown in 79 days: s6's own
#    startup chatter, and no qBittorrent banner. It never got far enough to log.

# 6. Decisive test: run the SAME binary against a COPY of the config.
#    It started perfectly. So neither the binary nor the config was at fault --
#    it was something else in the profile directory.
```

That left the runtime artefacts, and `ipc-socket` was three months stale.

### A false lead worth flagging

`pgrep -f qbittorrent-nox` appears to show a rapidly changing PID. It does not —
`-f` matches the full command line, which includes the `sh -c 'pgrep -f
qbittorrent-nox'` wrapper itself, so it reports a new PID every time regardless.
Use `ps -eo pid,etime,comm | grep` instead.

## The fix

```sh
# Move the stale runtime artefacts aside rather than deleting them.
kubectl -n theater exec deploy/qbittorrent -- sh -c '
  cd /config/config
  mkdir -p /config/kiro-quarantine
  mv ipc-socket lockfile /config/kiro-quarantine/ 2>/dev/null
'

kubectl -n theater rollout restart deploy/qbittorrent
```

Both are runtime artefacts, recreated on every start. Nothing is lost.

### Result

```
WebUI will be started shortly after internal preparations. Please wait...
******** Information ********
To control qBittorrent, access the WebUI at: http://localhost:8080
```

```sh
kubectl -n theater exec deploy/qbittorrent -- ss -lntp
#   LISTEN 0 50   *:8080          <- serving
#   LISTEN 0 30   *:50000         <- torrent port

# Sonarr, authenticated:
#   login              -> 204
#   /api/v2/app/version -> 200   v5.2.3
#   transfer/info       -> downloading at ~57 MB/s
```

And the check that actually matters — asking each *arr to test its own client:

```sh
curl -X POST -H "X-Api-Key: $KEY" \
  http://localhost:8989/arr/sonarr/api/v3/downloadclient/testall
#   [{"id":1,"isValid":true,"validationFailures":[]}]
```

Sonarr and Radarr both valid, no health warnings anywhere. The saved credentials
were correct the whole time.

Note the API path includes `/arr/sonarr` — the apps run with `URLBASE` set. A
call to `/api/v3/...` returns `307`, which is easy to mistake for a broken API.

## Why it went unnoticed for three months

This is the part worth fixing permanently.

| Gap | Consequence |
|---|---|
| **No readiness probe** | A pod with no listener stayed `Ready`, so the Service kept routing to it. |
| **No liveness probe** | Kubernetes never restarted the container, so the container-level restart count stayed at `0` and looked healthy. |
| **`:latest` + `imagePullPolicy: Always`** | The running version drifted silently. During this very incident the restart pulled 5.2.0 → 5.2.3 — an unreviewed upgrade in the middle of debugging. |
| **No alerting on *arr health** | The apps knew their download client was unavailable and nobody was told. |

The manifests in this repo close the first three:

- `readinessProbe` on `/` and a `livenessProbe` on the port, so a non-listening
  process is reported unhealthy and then restarted
- `image: ghcr.io/hotio/qbittorrent:release-5.2.3` pinned, tracked by Renovate
- `imagePullPolicy: IfNotPresent`, so a restart is no longer an upgrade

The probe is the important one. It converts this failure from "silent for three
months" into "CrashLoopBackOff within two minutes".

## Still outstanding

`transfer/info` reports `"connection_status":"firewalled"`. The WebUI works and
downloads run, but the listen port is not reachable from the internet, so
seeding is crippled.

Check that the router forwards **TCP+UDP 50000** to the `qbittorrent-peer`
LoadBalancer address:

```sh
kubectl -n theater get svc qbittorrent-peer
#   EXTERNAL-IP 192.168.2.1
```

The Service is named `qbittorrent-peer`; `qbittorrent` is the ClusterIP for the
WebUI and has no external address.

Note that address is on `192.168.2.0/24` while the LAN is `192.168.1.0/24` — the
`services` LB pool is deliberately a separate range so it cannot collide with the
node addresses, which means **the router needs a static route for it** as well as
the port forward. That is the most likely cause of `firewalled`. See
[networking.md](../networking.md#loadbalancer-ips).

This needs re-doing after any move: see
[restart-after-move.md](restart-after-move.md).

## If it happens again

Symptom to look for: pod `Ready` but `ss -lntp` empty. With the probes now in
place you should instead see `CrashLoopBackOff`, and:

```sh
kubectl -n theater logs deploy/qbittorrent --previous
ls -la /config/config/          # look for a stale ipc-socket / lockfile
```

The general lesson: **an unclean shutdown can leave a lock artefact that makes a
process refuse to start, and without a probe Kubernetes will report that as
healthy indefinitely.** The same pattern applies to any single-instance app with
a lockfile on a persistent volume.
