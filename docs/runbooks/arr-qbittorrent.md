# The *arr apps cannot reach qBittorrent

Symptom: Sonarr, Radarr, Lidarr or Prowlarr report "download client
unavailable", and the `theater/qbittorrent` pod is `0/1` (NotReady) with its
restart count rising, until `KubePodCrashLooping` fires.

Cause, every time so far: a stale `/config/config/ipc-socket` (and sometimes
`lockfile`) left by an unclean shutdown. qBittorrent uses the socket for
single-instance detection, so every start exits after about two seconds; s6
restarts it inside the container. The readiness probe on `:8080` marks the pod
NotReady, the liveness probe restarts the container, and the socket on the
volume survives the restart, so the restarts repeat.

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

The image is pinned by digest (`ghcr.io/hotio/qbittorrent`, Renovate), so a
restart is never an unreviewed upgrade. Readiness and liveness probes on
`:8080` turn this fault from a silent outage into a NotReady pod and then
`KubePodCrashLooping`; they do not clear it, because the socket is on the
volume. The container keeps `KILL`, `SETGID` and `SETUID` so that s6 can stop
qBittorrent cleanly on a pod delete instead of the runtime killing it after
the grace period, which is what leaves the socket behind.

The same failure applies to any single-instance app with a lock file on a
persistent volume: after a power loss, check the listener, not the pod status.
