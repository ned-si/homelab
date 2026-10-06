# The *arr apps cannot reach qBittorrent

Symptom: Sonarr, Radarr, Lidarr or Prowlarr report "download client
unavailable", while the `theater/qbittorrent` pod is `Running 1/1` with no
restarts.

Cause, every time so far: a stale `/config/config/ipc-socket` (and sometimes
`lockfile`) left by an unclean shutdown. qBittorrent uses the socket for
single-instance detection, so every start exits after about two seconds; s6
restarts it inside the container forever. The Deployment has no readiness or
liveness probe, so Kubernetes keeps reporting the pod healthy and routing to a
process that is not listening.

## Diagnose

1. Is anything listening?

   ```sh
   kubectl -n theater exec deploy/qbittorrent -- sh -c \
     'ss -lntp 2>/dev/null || netstat -lnt 2>/dev/null || cat /proc/net/tcp'
   ```

   Healthy: a listener on `:8080` (WebUI) and `:50000` (torrents); in the
   `/proc/net/tcp` fallback, local addresses ending `:1F90` and `:C350`. An
   empty table is this fault.

2. Can Sonarr connect?

   ```sh
   kubectl -n theater exec deploy/sonarr -- \
     curl -s -o /dev/null -m 10 -w '%{http_code}\n' http://qbittorrent:8080/api/v2/app/version
   ```

   `200` is healthy. `000` is connection refused, which is this fault. `401` or
   `403` would be a credential problem, a different fault.

3. Is the socket there?

   ```sh
   kubectl -n theater exec deploy/qbittorrent -- ls -la /config/config
   ```

   An `ipc-socket` dated before the last restart confirms it.

`pgrep -f qbittorrent-nox` is misleading here: `-f` also matches the `sh -c`
wrapper, so it shows a new PID on every call. Use
`ps -eo pid,etime,comm | grep qbittorrent-nox` to see that the process is only
ever a few seconds old.

## Fix

```sh
kubectl -n theater exec deploy/qbittorrent -- sh -c \
  'mkdir -p /config/quarantine; mv -f /config/config/ipc-socket /config/config/lockfile /config/quarantine/ 2>/dev/null; ls /config/quarantine'
kubectl -n theater rollout restart deploy/qbittorrent
kubectl -n theater rollout status deploy/qbittorrent --timeout=5m
```

Both files are runtime artefacts that qBittorrent recreates on start; nothing is
lost. The Deployment uses `strategy: Recreate` on a `ReadWriteOnce` volume, so a
minute or two of silence from `rollout status` is normal.

Then re-run diagnose steps 1 and 2 (expected: listeners on `:8080` and
`:50000`, and `200`), and in each *arr app run Settings, Download Clients, Test
All. The apps run with a URL base (`/arr/<app>`), so their API is under
`/arr/<app>/api/...`; a call to `/api/...` returns `307`.

## Seeding

The torrent port is published by `theater/qbittorrent-seed` on
`192.168.1.200:50000/TCP`, and the router forwards 50000 TCP there. If
qBittorrent reports `firewalled`:

```sh
kubectl -n theater get svc qbittorrent-seed
```

Expected: `EXTERNAL-IP 192.168.1.200`. If it is, check the router's forward.

## Prevention

Not in place yet: qBittorrent runs `ghcr.io/hotio/qbittorrent:latest` with
`imagePullPolicy: Always` and no probes, at parity with what ran before the
layered tree. A readiness probe on `:8080` would turn this from a silent outage
into a visible `NotReady` pod, and a pinned tag would stop a restart from
being an unreviewed upgrade. Both are on the [roadmap](../roadmap.md).

The same failure applies to any single-instance app with a lock file on a
persistent volume: after a power loss, check the listener, not the pod status.
