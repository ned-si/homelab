# Jamulus

Open the Jamulus server to players outside the house and close it again,
check it, restart it, upgrade it, and react to abuse. What the server is
and how players connect: [jamulus.md](../jamulus.md). The alert:
[alerts/JamulusDown.md](alerts/JamulusDown.md).

Preconditions:

- For the router: a device on the LAN and the router's admin login.
- For the checks: a clone of this repository, `python3`, and `kubectl`
  over the tailnet ([remote-access.md](../remote-access.md)).

## 1. Open the server to the internet

Only when remote players are wanted. The labels come from the 80/443 rules
on the Sunrise Connect Box 3 Fiber.

1. Open `http://192.168.1.1`, sign in, open Port forwarding (the page that
   lists the 80 and 443 rules to `192.168.1.254`).
2. Create a new rule: local IP `192.168.1.202`; local start port `41124`,
   local end port `41124`; external start port `41124`, external end port
   `41124`; protocol UDP. Save it.
   Expected: the list shows it next to 80 and 443 to `.254`, 22000 to
   `.201` and 50000 to `.200`.
3. Check from outside the house: a phone on mobile data, Jamulus app,
   Connect, `jam.lilalala.com:41124`. Expected: connected, your name in
   the mixer.
4. From the Mac:

   ```sh
   python3 platform/jamulus-probe/exporter.py --once jam.lilalala.com:41124
   ```

   It prints `up clients=<n> ...` only if the router loops UDP back. That
   is unverified, so a `down` from the Mac alone is no failure; step 3 is
   the check.

If step 3 fails: check that the rule says UDP (not TCP) and
`192.168.1.202`, then run [3. Check the server](#3-check-the-server).

## 2. Close it

1. On the same router page, delete the rule (or disable it if the page
   offers that).
2. Check with the phone on mobile data as in step 1.3. Expected: the
   client no longer connects.

Players on the LAN keep `192.168.1.202:41124`.

## 3. Check the server

```sh
python3 platform/jamulus-probe/exporter.py --once 192.168.1.202:41124
```

Expected on the LAN: `up clients=<n> rtt=<s>s`, exit 0, where `<n>` is the
number of players connected. `down <reason>` and exit 1: follow
[alerts/JamulusDown.md](alerts/JamulusDown.md#fix).

```sh
kubectl -n jamulus get pods,svc
kubectl -n jamulus logs deploy/jamulus --tail=20
```

Expected: the pod `Running`, `1/1`; the Service on `192.168.1.202` with
`41124/UDP` and no node port; after the start-up banner, one line per
audio connection, `<time>, <address>, connected (<n>)`. Older lines are in
SigNoz, Logs, filter `k8s.namespace.name = jamulus`.

## 4. Restart

A restart drops every player; they reconnect from the client.

```sh
kubectl -n jamulus rollout restart deploy/jamulus
kubectl -n jamulus rollout status deploy/jamulus --timeout=120s
```

Expected: `deployment "jamulus" successfully rolled out`, then
[3. Check the server](#3-check-the-server) prints `up clients=0`.

## 5. Upgrade

Upgrades come through Renovate and need nothing by hand while they pass:

- A new stable release: Renovate changes `ARG JAMULUS_TAG` in
  `jamulus/Dockerfile`; the `jamulus` job in `ci` builds the image and
  pings it, and the PR automerges on green `ci`.
- After the merge, `jamulus-publish` builds, signs and tags the image;
  Renovate then bumps the digest in `apps/jamulus/deployment.yaml` and
  `apps/jamulus/smoke.yaml`, which deploys it. The PostSync Job
  `jamulus-smoke` pings the new server; a failure reverts the merge
  automatically.

A failing build: read the `jamulus` job's log on the PR (or the
`jamulus-publish` run on `main`; its failure also sends a low-priority
ntfy). The running image stays until a build passes.

- `apt` refuses the repository (`NO_PUBKEY`, `EXPKEYSIG` or "not signed"):
  upstream changed or renewed its release key. Replace
  `jamulus/jamulus-release-key.asc` only after the new fingerprint is
  confirmed through a second channel, such as the Linux install page on
  jamulus.io or an upstream signed commit or announcement, never from the
  failing release alone. Put the fingerprint in the PR body.
- `jamulus-headless` not found, or no arm64 package: the release does not
  ship the headless .deb for that architecture. Close the Renovate PR and
  wait for the next release.
- The smoke test does not get an echo: the new server fails read-only or
  non-root. The log printed by `scripts/ci/jamulus-smoke.sh` names the
  error; keep the current release until it is fixed.

## 6. Abuse

Unknown names in the mixer, `jamulus_clients` above the expected players,
or connection lines in SigNoz from unknown addresses:

1. Close the router rule ([2. Close it](#2-close-it)). Nobody outside the
   house reaches the server any more.
2. Restart the server ([4. Restart](#4-restart)) to drop whoever is still
   connected.
3. If it happens again, the next step is the tailnet-only option instead
   of the router rule ([jamulus.md](../jamulus.md#why-it-is-like-this)):
   open an issue for it.
