# The *arr apps cannot reach qBittorrent

**Status: diagnosis is a strong hypothesis, not confirmed.** It was derived from
reading the manifests and the qBittorrent changelog, with no access to the
cluster. Verify with step 1 before acting on the rest.

## The short version

Nothing about the network broke. qBittorrent stopped accepting the password the
*arr apps had saved.

## Why

The old manifest ran:

```yaml
image: ghcr.io/hotio/qbittorrent:latest
imagePullPolicy: Always
```

`Always` + `latest` means **every pod restart was an unreviewed upgrade**. Over a
year of restarts, qBittorrent crossed version 4.6.1, which removed the
`admin` / `adminadmin` default credentials. Since then, when the WebUI password
is unset, qBittorrent **generates a random temporary password on every start** and
prints it to the container log.

Sonarr, Radarr and Lidarr still had `adminadmin` saved as their download-client
credential. Every API call started returning `401`, and the *arr UIs report that
as the client being unavailable — which reads like a connectivity problem.

A second change from the same era can produce the same symptom independently:
4.6 enabled **Host header validation** by default, so requests arriving with an
unexpected `Host` are rejected.

## Step 1 — confirm it

```sh
kubectl -n theater logs deploy/qbittorrent | grep -i -A2 'password'
```

If you see a line about a temporary password having been generated, the diagnosis
holds. Also check what version is actually running:

```sh
kubectl -n theater get deploy qbittorrent \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Cross-check that the failures are authentication, not routing:

```sh
# From inside a *arr pod -- should return 403/401, NOT a timeout or DNS error.
kubectl -n theater exec deploy/sonarr -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://qbittorrent:8080/api/v2/app/version
```

A `401`/`403` confirms auth. A timeout or `could not resolve host` means it really
is networking, and this runbook does not apply — go to `cilium-debug` below.

## Step 2 — set a real password

This is the one step that cannot be expressed as a manifest. qBittorrent stores
its WebUI password as a PBKDF2 hash inside `/config/qBittorrent.conf`, and
exposes no environment variable to set it.

1. Read the temporary password from the log (step 1).
2. Open `https://qbittorrent.lilalala.com`, log in as `admin` with it.
3. **Tools → Options → Web UI**, set a permanent password.
4. Store it somewhere durable — a password manager. It is not in this repo,
   because qBittorrent gives us no way to inject it.

## Step 3 — update each *arr app

For Sonarr, Radarr and Lidarr:

**Settings → Download Clients → qBittorrent**

| Field | Value |
|---|---|
| Host | `qbittorrent` |
| Port | `8080` |
| Username | `admin` |
| Password | the password from step 2 |
| Use SSL | off |

`qbittorrent` (the bare Service name) works because all of these run in the
`theater` namespace. Do **not** point them at `qbittorrent.lilalala.com` — that
sends internal traffic out through the Gateway and back, and is what tends to
trip Host-header validation.

Use **Test** before saving.

## Step 4 — if it is still 401 after a correct password

Then it is the Host header. Add the internal name to qBittorrent's allow-list:

**Tools → Options → Web UI → uncheck "Validate Host header"**, or better, leave
validation on and add the Service names to the allowed domains list:

```
qbittorrent
qbittorrent.theater
qbittorrent.theater.svc.cluster.local
qbittorrent.lilalala.com
```

An alternative that removes credentials from the loop entirely is qBittorrent's
subnet allow-list (**Web UI → Bypass authentication for clients in whitelisted
IP subnets**) set to the pod CIDR. Note that "bypass for localhost" does **not**
help in Kubernetes — traffic arrives from pod IPs, never from loopback.

## What changed in the repo to stop this recurring

- `image: ghcr.io/hotio/qbittorrent:release-5.2.3` — an explicit, immutable tag.
- `imagePullPolicy: IfNotPresent` — a restart is no longer an upgrade.
- Renovate groups the whole `theater` stack (`groupName: theater stack`,
  `automerge: false`), so qBittorrent and the *arr apps are only ever bumped
  together, in a PR you have to read.
- Readiness and liveness probes, so a wedged WebUI reports unhealthy instead of
  looking fine.

The underlying lesson is the one worth keeping: `:latest` with
`imagePullPolicy: Always` converts every unrelated restart into an unreviewed
upgrade, and the failure surfaces months later as something that looks unrelated.

## cilium-debug

If step 1 pointed at real connectivity problems:

```sh
# Is the Service resolving and are there endpoints?
kubectl -n theater get svc,endpointslice -l app.kubernetes.io/name=qbittorrent

# Watch flows between the two pods.
kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg monitor --related-to $(kubectl -n theater get pod \
    -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}')
```

Hubble is enabled in `infrastructure/cilium/values.yaml`, so
`hubble observe --namespace theater` is usually faster than reading manifests.
