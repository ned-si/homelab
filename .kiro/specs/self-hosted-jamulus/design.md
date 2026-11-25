# Design: self-hosted-jamulus

## Overview

A new app, `jamulus`, runs the upstream `jamulus-headless` server in one
hardened pod. Our CI builds the image `ghcr.io/ned-si/homelab-jamulus`
from the upstream release's signed .deb packages, for arm64 and amd64,
and signs it keyless like the site and dashboard images; Kyverno checks
the signature in Audit and the CI gate blocks an unsigned digest. The pod
listens on UDP 41124 behind a Cilium LoadBalancer Service pinned to
`192.168.1.202`, in a namespace enforced from the start: UDP 41124 in,
nothing out but cluster DNS. external-dns publishes `jam.lilalala.com`
from an annotation on the Service. A small exporter in `monitoring` sends a
Jamulus protocol ping on every scrape and feeds a non-paging alert. The
server is unlisted and capped at 8 channels; it answers the LAN at once and
the internet only while the operator keeps a router port forward for it.

Stack, fixed by this design: the upstream Jamulus 3.12.6 headless package
on `debian:bookworm-slim`; GitHub Actions with BuildKit, QEMU, cosign and
`attest-build-provenance` (the pins of `dashboard-publish.yaml`); Kustomize
manifests rendered into `deploy/`; Cilium LB-IPAM, L2 announcements and
`CiliumNetworkPolicy`; external-dns 1.24.0 (chart) with Cloudflare; a
stdlib Python 3 exporter on the pinned `python:3.15.2-alpine3.24` image
of the other exporters; Prometheus rules with promtool tests; pytest; bash
for `jamulus-ping` and the CI scripts.

## Image

Decided here, 2026-11-25, after checking every source:

| Source | Finding | Verdict |
| --- | --- | --- |
| Official image | Docker Hub `jamulussoftware/` has no repository; the `jamulussoftware/jamulus` repository has no Dockerfile; `ghcr.io/jamulussoftware/jamulus` returns 403 to an anonymous token request | None exists |
| `grundic/jamulus` (most pulled) | amd64 only, last push 2022-08-13 (3.9.0) | Unmaintained, no arm64 |
| `dtinth/jamulus` | arm64 and amd64, 3.12.6 pushed 2026-11-24, cosign-signed; installs the upstream .deb on `debian:oldstable-slim` | Maintained, but one person's build and signing identity |
| Upstream release `r3_12_6` | `jamulus-headless_3.12.6_ubuntu_arm64.deb` and `_amd64.deb` in a per-release apt repository (`InRelease`, `Release`, `Packages`) signed by the Jamulus release key `1FC2EFC5F88868F6FC6A06398E8516F926E4AD0E` (RSA 4096, expires 2030-07-26); built on Ubuntu 22.04 against Qt 5 | The bytes to trust |

So we build our own: the upstream package, verified by apt against the
committed key, in an image we sign. This gives the image the signer
identity, SBOM and provenance our policies already read, and no third
party sits between upstream and the cluster.

The base is `debian:bookworm-slim`, pinned by digest. The package depends
on `libqt5core5a`, `libqt5network5`, `libqt5xml5` and `libc6 (>= 2.29)`;
Debian 12 ships these under those names (glibc 2.36), and `dtinth/jamulus`
proves the install on both architectures. Debian 13 renamed the Qt 5
libraries (`libqt5core5t64`), which most likely still satisfies the
dependency but is unproven; moving is a later one-line change, gated by
the same smoke test. Debian 12 has LTS support until 2028-06-30.

### Files

| Path | Holds |
| --- | --- |
| `jamulus/Dockerfile` | The image ([below](#dockerfile)) |
| `jamulus/jamulus-release-key.asc` | The upstream key, a byte copy of the release's `key.asc` |
| `jamulus/jamulus-ping` | The protocol ping in bash ([below](#jamulus-ping)) |
| `scripts/ci/jamulus-smoke.sh` | Runs an image as the cluster does and pings it; used by `ci` and the publish workflow |
| `scripts/ci/jamulus-check.sh` | The `ci` entry point: exits early with `checked=false` unless the change touches `jamulus/`, `scripts/ci/jamulus-*.sh` or `platform/jamulus-probe/`; otherwise builds `linux/amd64` with `--load` and runs the smoke |
| `.github/workflows/jamulus-publish.yaml` | Build, attest, sign, tag `:main` ([below](#publishing)) |

### Dockerfile

```dockerfile
# The Jamulus server image (docs/jamulus.md), built by
# .github/workflows/jamulus-publish.yaml from the upstream release's signed
# apt repository. Renovate updates JAMULUS_TAG (stable rX_Y_Z only).
FROM debian:bookworm-slim@sha256:<digest>
ARG JAMULUS_TAG=r3_12_6
COPY jamulus-release-key.asc /etc/apt/keyrings/jamulus.asc
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    echo "deb [signed-by=/etc/apt/keyrings/jamulus.asc] https://github.com/jamulussoftware/jamulus/releases/download/${JAMULUS_TAG}/ ./" \
      > /etc/apt/sources.list.d/jamulus.list; \
    apt-get update; \
    version=$(echo "${JAMULUS_TAG#r}" | tr _ .); \
    apt-get install -y --no-install-recommends "jamulus-headless=${version}"; \
    rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 jamulus-ping /usr/local/bin/jamulus-ping
ENV HOME=/tmp
USER 65532:65532
EXPOSE 41124/udp
ENTRYPOINT ["/usr/bin/jamulus-headless"]
CMD ["--server", "--nogui", "--port", "41124"]
```

apt refuses the repository when `InRelease` is not signed by the committed
key, so a changed or expired upstream key fails the build instead of
installing unverified bytes. The default `CMD` is a safe unregistered
server; the Deployment passes the full arguments. Trivy's Dockerfile checks
pass: a non-root `USER`, `--no-install-recommends`, update and install in
one `RUN`, no `latest`.

### jamulus-ping

The server answers a connectionless `CLM_PING_MS` (message 1001) from any
sender with the same message ([upstream
`src/protocol.cpp`](https://github.com/jamulussoftware/jamulus/blob/r3_12_6/src/protocol.cpp)).
A frame is little-endian: tag `0x0000` (2 bytes), message id (2), counter
(1, 0 for connectionless messages), body length (2), body, CRC (2). The CRC
is CRC-16 with polynomial `0x1021`, initial value `0xFFFF`, output
inverted, MSB first (CRC-16/GENIBUS; check value `0xD64E` for
`123456789`, computed from upstream's `CCRC`). With a timestamp of 0 the
request is constant and the reply is byte-identical:

```
00 00 e9 03 00 04 00 00 00 00 00 6f 60
```

`jamulus-ping [host] [port]` (defaults `127.0.0.1`, `41124`) validates the
port (digits, 1-65535, else exit 2), opens `/dev/udp/<host>/<port>` on fd 3
(bash resolves a name), writes the 13 bytes with `printf '%b'`, reads the
reply with `timeout 2 head -c 13 <&3` (head reads the whole datagram; a
byte-wise `read` would drop the leading NULs), hex-encodes it with `od` and
exits 0 only on the exact echo, 1 otherwise. bash, coreutils `timeout`,
`head` and `od` are in the Debian base.

### Publishing

`jamulus-publish.yaml` copies `dashboard-publish.yaml` step for step, with
these differences:

- Trigger: push to `main` on `jamulus/**`,
  `scripts/ci/jamulus-smoke.sh` and the workflow itself, plus
  `workflow_dispatch`. `IMAGE: ghcr.io/ned-si/homelab-jamulus`.
- No Go setup. The smoke step builds `linux/amd64` with `--load` and runs
  `scripts/ci/jamulus-smoke.sh jamulus:smoke` before anything is pushed.
- `docker/setup-qemu-action` (the pinned SHA of the dashboard workflow)
  runs before the multi-platform build: the arm64 `RUN apt-get` executes
  under emulation, unlike the dashboard's cross-compiled Go.
- The index check runs `docker run --rm --platform linux/arm64
  "$IMAGE@$DIGEST" --version` and requires the version derived from
  `JAMULUS_TAG`.
- The cosign identity is
  `https://github.com/ned-si/homelab/.github/workflows/jamulus-publish.yaml@refs/heads/main`;
  the ntfy failure title is `jamulus-publish failed`.

`scripts/ci/jamulus-smoke.sh <image>`:

1. `docker run --rm <image> --version` contains the pinned version.
2. `docker run -d --name jamulus --read-only --tmpfs /tmp --user
   65532:65532 --cap-drop ALL --security-opt no-new-privileges -p
   127.0.0.1:41124:41124/udp <image> --server --nogui --port 41124
   --numchannels 8 --fastupdate --discononquit`.
3. Within 20 s, `docker exec jamulus jamulus-ping` exits 0.
4. From task 3: `python3 platform/jamulus-probe/exporter.py --once
   127.0.0.1:41124` exits 0 and prints `clients=0`.
5. Print `docker logs jamulus`, remove the container, exit with the first
   failure's code.

### CI, signing and Renovate

- `ci.yaml`: a job `jamulus` (ubuntu-26.04, 15 min, `contents: read`,
  checkout with `fetch-depth: 2`, `scripts/ci/jamulus-check.sh`), added to
  the `ci` job's `needs` and to its loop.
- `ci/image-signers.yaml`: `ghcr.io/ned-si/homelab-jamulus` with issuer
  `https://token.actions.githubusercontent.com` and the subject above.
- `infrastructure/kyverno-policies/verify-own-images.yaml`: an attestor
  `jamulus` with that identity and the validation
  `images.containers.filter(i, i.startsWith('ghcr.io/ned-si/homelab-jamulus')).all(i, verifyImageSignatures(i, [attestors.jamulus]) > 0)`;
  the header comment names `jamulus-publish`. `task render`.
- `.github/renovate.json5`:
  - a custom manager for `jamulus/Dockerfile`:

    ```json5
    {
      customType: 'regex',
      description: 'The Jamulus release in jamulus/Dockerfile (stable rX_Y_Z only)',
      managerFilePatterns: ['/^jamulus/Dockerfile$/'],
      matchStrings: ['ARG JAMULUS_TAG=(?<currentValue>r\\d+_\\d+_\\d+)\\n'],
      depNameTemplate: 'jamulussoftware/jamulus',
      datasourceTemplate: 'github-releases',
      versioningTemplate: 'regex:^r(?<major>\\d+)_(?<minor>\\d+)_(?<patch>\\d+)$',
    }
    ```

    Beta tags (`r4_0_0beta4`) do not match and are never offered. A
    release update automerges on green `ci`, which builds and pings the
    new image.
  - a package rule "Deploy each new Jamulus image at once":
    `ghcr.io/ned-si/homelab-jamulus`, `digest`, group `homelab-jamulus`,
    `automerge: true`, `minimumReleaseAge: '0 days'`, next to the
    dashboard's.
  - The `FROM` digest is the `dockerfile` manager's, in the `image
    digests` group.

## The app

| Path | Holds |
| --- | --- |
| `infrastructure/namespaces/namespaces.yaml` | Namespace `jamulus`, `restricted` for `enforce`, `warn`, `audit`, `Delete=false,Prune=false`; added to the header's `restricted` list |
| `clusters/homelab/bootstrap/project-apps.yaml` | Destination namespace `jamulus` |
| `clusters/homelab/apps/jamulus.yaml` | Application `jamulus`, project `apps`, path `deploy/apps/jamulus`, sync options and retry as `homelab-dashboard.yaml`; listed in `clusters/homelab/apps/kustomization.yaml` |
| `apps/jamulus/kustomization.yaml` | `namespace: jamulus`; `serviceaccount.yaml`, `deployment.yaml`, `service.yaml`, `smoke.yaml` |
| `apps/jamulus/serviceaccount.yaml` | ServiceAccount `jamulus`, `automountServiceAccountToken: false` |
| `apps/jamulus/deployment.yaml` | The server ([below](#deployment)) |
| `apps/jamulus/service.yaml` | The LoadBalancer ([Network](#network)) |
| `apps/jamulus/smoke.yaml` | PostSync Job `jamulus-smoke` ([below](#postsync-smoke)) |
| `scripts/ci/repo_policy.py` | `"jamulus"` in `APP_NAMESPACES`, sorted after `"immich"`, so `pod-hardening` accepts the Application and checks probes, seccomp, privilege escalation, capabilities, non-root and the token |
| `ci/kind-workloads.txt` | `deploy/apps/jamulus/serviceaccount-jamulus.yaml` and `deploy/apps/jamulus/deployment-jamulus.yaml`: stateless, no Secret, so `preprod` boots it on kind |
| `tests/test_jamulus.py` | The consistency tests ([Testing](#testing)) |

### Deployment

- `replicas: 1`, `strategy: Recreate` (a session lives in one process; two
  servers behind one address would split players), `revisionHistoryLimit:
  3`, labels `app.kubernetes.io/name: jamulus`.
- Pod: `serviceAccountName: jamulus`, `automountServiceAccountToken:
  false`, `securityContext` `runAsNonRoot: true`, `runAsUser: 65532`,
  `runAsGroup: 65532`, `seccompProfile: RuntimeDefault`;
  `terminationGracePeriodSeconds: 10` (with `--discononquit`, clients are
  told to disconnect at once).
- Container `jamulus`: the image, with its Renovate comment, as
  `ghcr.io/ned-si/homelab-jamulus:main@sha256:<digest of the first
  publish run>`; `args: ["--server", "--nogui", "--port", "41124",
  "--numchannels", "8", "--fastupdate", "--discononquit"]`; port
  `jamulus` 41124/UDP; `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`; `/tmp` from
  an `emptyDir` with `sizeLimit: 16Mi`; requests `cpu: 100m`, `memory:
  64Mi`, limit `memory: 256Mi` (no CPU limit, as the other apps).
- Probes, both `exec: ["jamulus-ping"]`, `timeoutSeconds: 5`: readiness
  every 10 s, failure threshold 3; liveness every 20 s, failure threshold
  6, so a restart takes two minutes without an answer, by which time any
  session is already lost.

The headless server loads and saves no settings file (upstream
`src/main.cpp` does so only with the GUI) and logs to the console, so the
read-only root needs nothing more than `/tmp` for Qt.

### PostSync smoke

The shared `components/postsync-smoke` only speaks HTTP, so the app has its
own hook with the same contract, `apps/jamulus/smoke.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: jamulus-smoke
  labels: {app.kubernetes.io/name: jamulus-smoke}
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "10"
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    metadata:
      labels: {app.kubernetes.io/name: jamulus-smoke}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: smoke
          # renovate: datasource=docker depName=ghcr.io/ned-si/homelab-jamulus
          image: ghcr.io/ned-si/homelab-jamulus:main@sha256:<same digest as the Deployment>
          command: [bash, -c, 'for i in 1 2 3 4 5 6; do jamulus-ping jamulus 41124 && exit 0; sleep 5; done; exit 1']
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 32Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
```

The label is what the `jamulus` ingress rule and the `jamulus-smoke`
policy select; `automountServiceAccountToken: false` is what
`pod-hardening` requires of a default-ServiceAccount pod. A failure fails
the sync, and auto-rollback reverts the merge.

## Port

UDP 41124 everywhere: the server's `--port`, the container port, the
Service port and target, the policy, the probe target and the router rule.
22124 is the Jamulus default (`DEFAULT_PORT_NUMBER` in upstream
`src/global.h`), so it is what a scan for Jamulus servers tries first.
Moving off it hides the server from those scans and from nothing else; the
cost is that players type the port (`jam.lilalala.com:41124`), once, since
the client keeps its history. Keeping one number end to end, rather than
mapping 41124 outside to 22124 inside, keeps logs, policies and probes
readable. 41124 appears nowhere else in the repository.

## Network

The Service `jamulus/jamulus`:

```yaml
metadata:
  annotations:
    lbipam.cilium.io/ips: "192.168.1.202"
    # From task 4:
    external-dns.alpha.kubernetes.io/hostname: jam.lilalala.com
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  externalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/name: jamulus
  ports:
    - name: jamulus
      protocol: UDP
      port: 41124
      targetPort: jamulus
```

`192.168.1.202` is the next free address of `pool-2`: live on 2026-11-25,
the pool had 26 of 28 addresses free, the only pinned ones are `.200` and
`.201`, and `.202` answered neither ping nor ARP from the Mac. Cilium L2
announcements answer ARP for it from one node; kube-proxy replacement
forwards to the pod from any node, which needs `externalTrafficPolicy:
Cluster` ([networking.md](../../../docs/networking.md#loadbalancer-ips)).
`allocateLoadBalancerNodePorts: false` keeps the port off the four node
addresses: the L2 path needs no node port, while a default LoadBalancer
gets one on every node (`syncthing-protocol` has 30324 and 30709).

Policies:

| File | Policy | Rules |
| --- | --- | --- |
| `infrastructure/network-policies/58-jamulus.yaml` (new, in the kustomization after `56-homelab-dashboard.yaml`) | `jamulus` (selector `app.kubernetes.io/name: jamulus`) | Ingress UDP 41124 from entities `world`, `host`, `remote-node` (players from the LAN and the internet; `host` and `remote-node` when the announcing node SNATs to another node's pod), from `app.kubernetes.io/name: jamulus-smoke`, and, from task 3, from `{io.kubernetes.pod.namespace: monitoring, app.kubernetes.io/name: jamulus-probe}`. No egress rule |
| same file | `jamulus-smoke` | Egress UDP 41124 to `app.kubernetes.io/name: jamulus` |
| `infrastructure/network-policies/90-enforcement.yaml` | `enforce-default-deny` in `jamulus` | `ingress: true`, `egress: true`, the standard kubelet and DNS rules; enforced from the start, like `website` |
| `infrastructure/network-policies/88-monitoring.yaml` (task 3) | `jamulus-probe` | Egress UDP 41124 to `{io.kubernetes.pod.namespace: jamulus, app.kubernetes.io/name: jamulus}` |

The probe targets the LoadBalancer address. Socket LB is off for pods
(`bpf-lb-sock: false`, `bpf-lb-sock-hostns-only: true`); the probe pod's
BPF program translates the LoadBalancer address to the Jamulus pod per
packet, before the egress policy, so both policies see pod identities.
The probe therefore proves the pod and the Service only: `scripts/smoke.sh`
item 9 checks the binding and the ARP holder of `.202`, the Mac ping of
tasks 2 and 4 checks the LAN path, and the pentest ping step the internet
path. Replies to admitted players need no egress rule: Cilium's
connection tracking passes them. The server opens no connection of its
own (no directory), so the switch's cluster DNS rule is its whole egress.

## Exposure

Jamulus 3.12.6 has no password, no user accounts, no allow-list and no
rate limit (its options are listed in upstream `src/main.cpp`;
`--listfilter` applies to directories). Cilium cannot rate-limit ingress
per source either. What is left to decide is who can reach the port.

| Option | Who reaches it | For | Against |
| --- | --- | --- | --- |
| **Unlisted, LAN at once, internet through the router rule when wanted** (chosen) | The LAN always; the internet while the rule exists | Remote friends join with the plain client; the operator opens and closes it in the router; nothing is listed | No authentication: anyone who learns host and port can join while the rule exists |
| Tailnet only (a Tailscale-exposed Service) | Tailnet members and nodes shared with them | Nothing on the internet | Every friend installs Tailscale and joins or accepts a share; the operator proxy pod adds a hop, and a DERP relay when no direct path exists adds tens of milliseconds to a protocol that needs low latency |
| Registered in a public directory | Anyone | Discoverable | Strangers by design |
| LAN only, never forwarded | The house | No exposure | Defeats the purpose: players are in different places |

The chosen option keeps every control that exists: no directory
registration (`--directoryaddress` and its aliases absent, checked by
`tests/test_jamulus.py`), the non-default port, 8 channels, UDP 41124 as
the only admitted port, a pod that reaches nothing, and the router rule as
the operator's switch. The tailnet stays the fallback if strangers show up.

What someone who learns `jam.lilalala.com:41124` can do while the rule
exists:

- Join without a login, under any name, and hear the mix of everyone
  connected; play or make noise into it; send chat messages; see the
  other players' names.
- Take channels until the cap of 8, which locks the band out.
- Flood UDP at the WAN address, which fills the home uplink for the whole
  household.
- Exploit a parsing bug in the server, if one exists: they land in a pod
  running as UID 65532 with a read-only root, no capabilities, no
  ServiceAccount token, no Secret, no volume but a 16 MiB `/tmp`, and no
  egress except cluster DNS, under Tetragon's runtime detections. From
  there they reach no other app, no LAN host, no cluster API.
- Without joining and without a log line: read who is connected (name,
  country, city, instrument, skill) and the server version, with
  `CLM_REQ_CONN_CLIENTS_LIST` and `CLM_REQ_VERSION_AND_OS` (upstream
  `src/server.h`, lines 363-383, answers them to any sender without a
  session).
- Use the server as a UDP reflector: a request with a spoofed source is
  answered to that source, and the client list is larger than the request.
  This lasts only while the router rule exists. Requests that ask the
  server to send to a third address (`CLM_SEND_EMPTY_MESSAGE`) are new
  flows, which the enforced egress drops.

Host and port are public in this repository, so the server is open to
anyone while the rule exists. The non-default port only stops untargeted
scans of 22124.

They cannot reach any other service, read any household data or change
the server's configuration: Jamulus has no admin interface over UDP, and
the JSON-RPC API is off.

The server logs each audio connection (`<time>, <address>, connected
(<n>)`) to the console, so SigNoz keeps who joined; reading the player
list or the version leaves no line. With `externalTrafficPolicy: Cluster`
the logged address is a node address when the announcing node forwards to
a pod on another node.

## DNS

external-dns's only source is `gateway-httproute`, which reads HTTPRoutes.
Jamulus is raw UDP on its own LoadBalancer, so it has no HTTPRoute.

| Option | For | Against |
| --- | --- | --- |
| **The `service` source, LoadBalancer Services only, with the hostname annotation** (chosen) | The name sits on the Service it names; `--force-default-targets` replaces the LAN address with the WAN address, as it does for the Gateway (it applies to every source); upsert-only unchanged | external-dns also watches Services (its chart adds the RBAC) |
| A placeholder HTTPRoute for `jam.lilalala.com` | No external-dns change | The Gateway would answer HTTPS on a name that is not a website, and the route would join the DAST and probe lists |
| A `DNSEndpoint` (`crd` source) | Explicit record | A new CRD for one record, and the target would copy the WAN address (repo-policy `wan-ip-single-source`) |
| A CNAME by hand in Cloudflare, like the `nedsi.io` apex | Nothing in the cluster | Not managed by external-dns |

`infrastructure/external-dns/values.yaml`: `sources: [gateway-httproute,
service]` and `--service-type-filter=LoadBalancer` in `extraArgs`. A
LoadBalancer Service publishes only with the annotation (no
`--fqdn-template`); the three existing ones carry none, so they publish
nothing. The record is DNS only because `--cloudflare-proxied` is not set.
The TXT registry record is `a-jam.lilalala.com`, owner
`service/jamulus/jamulus`. `scripts/published-hostnames.sh` keeps listing
HTTPRoute names only; its header comment names `jam.lilalala.com` next to
`sync.lilalala.com` as raw UDP on a LoadBalancer.

Clients connect to `jam.lilalala.com:41124`. Without the router rule the
name still resolves (to the WAN address) but nothing answers; on the LAN,
players then use `192.168.1.202:41124`. With the rule, the name works from
the LAN too through NAT loopback (verified for TCP; task 4 checks UDP when
the rule exists).

## Probe

blackbox-exporter has no UDP prober (http, tcp, dns, icmp, grpc), and a
TCP or JSON-RPC check would not show that the UDP server answers. The
probe is therefore a stdlib Python exporter on the pattern of
`platform/usage-exporter`:

| Path | Holds |
| --- | --- |
| `platform/jamulus-probe/exporter.py` | The exporter and the `--once` CLI |
| `platform/jamulus-probe/deployment.yaml` | ServiceAccount (no token), Deployment, Service `metrics` 9174, ServiceMonitor (`release: kube-prometheus-stack`, interval 30 s, timeout 10 s) |
| `platform/jamulus-probe/kustomization.yaml` | `namespace: monitoring`, `configMapGenerator` for `exporter.py` |
| `clusters/homelab/platform/jamulus-probe.yaml` | Application `jamulus-probe`, project `platform`, sync wave 20, as `usage-exporter.yaml`; listed in that layer's kustomization |
| `tests/test_jamulus_probe.py` | Unit and in-process tests ([Testing](#testing)) |

The Deployment copies `usage-exporter`'s: one replica, the pinned
`python:3.15.2-alpine3.24` image with its Renovate comment, `python3 -u
/app/exporter.py`, UID 65534, read-only root, all capabilities dropped,
seccomp `RuntimeDefault`, `/healthz` readiness and liveness, requests
`cpu: 5m`, `memory: 32Mi`, limit `memory: 64Mi`. Environment: `TARGETS:
192.168.1.202:41124`, `PORT: "9174"`.

On each `GET /metrics` it pings every target with
`CLM_PING_MS_WITHNUMCLIENTS` (1002): body `<uint32 ms><uint8 0>`, so the
server answers with its connected-client count in the fifth byte. A
connected UDP socket per target, 1 s timeout, up to 3 attempts. A reply
counts only when it is 14 bytes, tag 0, id 1002, length 5 and its CRC
matches. Output:

```
# HELP jamulus_up 1 when the server answered a protocol ping during this scrape.
# TYPE jamulus_up gauge
jamulus_up{target="192.168.1.202:41124"} 1
# HELP jamulus_ping_seconds Round trip of the answered ping.
# TYPE jamulus_ping_seconds gauge
jamulus_ping_seconds{target="192.168.1.202:41124"} 0.002
# HELP jamulus_clients Clients connected, as the server reports.
# TYPE jamulus_clients gauge
jamulus_clients{target="192.168.1.202:41124"} 0
```

`jamulus_ping_seconds` and `jamulus_clients` appear only while
`jamulus_up` is 1. `--once <host:port>` pings once (same attempts), prints
`up clients=<n> rtt=<s>s` or `down <reason>`, and exits 0 or 1; it runs
on the Mac (`python3`), in the smoke script and in the external pentest.
Logs are JSON lines on stdout, as the other exporters: one `info` at start
with the targets, one `warning` when a target goes from up to down (with
the reason), one `info` when it comes back; nothing per scrape.

`tests/test_jamulus.py` checks that the bytes in `jamulus-ping` equal the
exporter's encoding of message 1001 with timestamp 0, so the two
implementations cannot drift.

## Alert

`platform/kube-prometheus-stack/routes/jamulus-alerts.yaml`, listed in
that directory's kustomization:

```yaml
- alert: JamulusDown
  expr: |
    jamulus_up{target="192.168.1.202:41124"} == 0
    or absent(jamulus_up{target="192.168.1.202:41124"})
  for: 15m
  labels:
    severity: warning
    action: review
  annotations:
    runbook_url: https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/JamulusDown.md
    summary: "Jamulus at {{ $labels.target }} has not answered a ping for 15 minutes"
```

`absent()` keeps the `target` label from the equality matcher, so both
branches name the target, and a dead probe fires the same alert. In the
same pull request, as `docs/sre.md` requires for a new ALERT:
`tests/prometheus/jamulus_test.yaml` (down 15 min fires, 14 min does not,
no series fires, up stays quiet), the line `null alertname=JamulusDown
severity=warning target=192.168.1.202:41124` in
`tests/alertmanager/routes.txt`, `docs/runbooks/alerts/JamulusDown.md`,
the row in the alerts index `docs/runbooks/alerts/README.md`, and in
`docs/sre.md` a review-table row "Used by appointment; checked before a
session | `JamulusDown`" and the sentence: "Jamulus carries no SLO:
availability is measured by `blackbox-public`, which has no UDP prober,
and the public path exists only while the operator keeps the router rule,
so a public figure would measure his switch. Sessions are by appointment;
`JamulusDown` (review) is the signal."

`ArgoCDAppStillProgressing` and `ArgoCDAppStillDegraded` cover the app as
they cover every app in project `apps`: they page when a deploy is stuck
or broken and auto-rollback did not fix it. That is a failed change, not
the server being down.

## Logs

Vector's DaemonSet ships every pod's console to SigNoz with no namespace
filter (`platform/vector/values.yaml`), so the server's start-up lines and
connection lines arrive without configuration.
`vector_log_events_total{namespace="jamulus"}` counts them.

## Pentest and threat model

- `docs/pentest/scope.yaml`, `in_scope.forwarded_ports`: `host:
  192.168.1.202`, `hostname: jam.lilalala.com`, `ports: [41124/udp]`,
  `service: Jamulus server`, `mode: active`, and a comment that the router
  forwards it only while the operator keeps the rule. `active` because a
  protocol ping and a client session harm nothing; denial of service stays
  out of scope. `scripts/pentest-scope-check.sh` needs no change: its
  passive list and the TCP port list of `pentest-external.yaml` are
  untouched.
- `.github/workflows/pentest-external.yaml`: after the TCP scan, a step
  runs `python3 platform/jamulus-probe/exporter.py --once
  "$WAN:41124"` and writes `Jamulus 41124/udp: answers` or `no answer` to
  the step summary; it never fails the job.
- `docs/pentest/runbooks/external.md`: a row "Jamulus | the ping step in
  `pentest-external.yaml` on 41124/udp | answers only while the router
  rule exists; anything but a Jamulus reply is a finding";
  `scripts/ci/repo_policy.py` adds `"41124"` to that runbook's required
  terms in `PENTEST_RUNBOOKS`.
- `docs/threat-model.md`: "Internet to Jamulus (41124 UDP on
  `192.168.1.202`)": threats S (anyone can join), I (the mix can be
  heard; the player list and the version can be read without joining and
  without a log line), D (channels filled, uplink flooded, the server used
  as a UDP reflector against third parties), E (a parser bug); controls
  and residuals as in [Exposure](#exposure). The residual states that host
  and port are public in this repository, so the server is open to anyone
  while the router rule exists, and that the non-default port only stops
  untargeted scans of 22124.

## Docs

| File | Change |
| --- | --- |
| `docs/jamulus.md` (new) | How to connect (client download, `jam.lilalala.com:41124` or `192.168.1.202:41124` on the LAN), the settings, the router rule, what a stranger can do (the full list in [Exposure](#exposure), reading the player list and reflection included), the alert, Why it is like this (central server over SonoBus; own image; port; exposure over tailnet) |
| `docs/runbooks/jamulus.md` (new) | Open the router rule for a session, close it, check the server (`--once`, logs), restart (`kubectl -n jamulus rollout restart deploy/jamulus`, run by the operator), upgrade (Renovate; a failing build; a changed upstream key: replace `jamulus/jamulus-release-key.asc` only after the new fingerprint is confirmed through a second channel, such as the jamulus.io Linux install page or an upstream signed commit or announcement, never from the failing release alone, and put the fingerprint in the PR body), abuse (close the rule, then the tailnet option) |
| `docs/networking.md` | LoadBalancer table and "Expected" line with `.202` (task 2); the policy count in Network policy, from `kubectl get cnp -A \| grep -v -E 'headlamp\|hubble' \| wc -l` after the sync (task 2 adds three policies, task 3 one); the port-forward table row "41124 UDP, `192.168.1.202`, Jamulus, only while remote players are wanted" and the DNS sources (task 4) |
| `README.md` | Address table row `192.168.1.202` (task 2); services table row "Jamulus, Playing music together live, `jamulus`, `jam` (UDP 41124 on `.202`), No (no login in Jamulus)"; docs index link (task 6) |
| `docs/observability.md` | The `jamulus-probe` exporter row (task 3) |
| `techradar/entries.yaml` and the rendered `apps/website/techradar/` | Jamulus: platform, `trial`, `moved: new`, "Rehearsing together from different places, unlisted on the home line.", link `docs/jamulus.md`. SonoBus: platform, `hold`, `moved: new`, "Peer to peer: each player sends to every other; a central server suits the cluster.", link `#1702`. `updated` to the day |
| `.kiro/steering/product.md` | "Music" row in Services by area: Jamulus |
| `.kiro/steering/structure.md` | `jamulus/` row in the repository map |
| `.kiro/specs/media-home/` | Jamulus in the introduction and as a ticked history task with this spec |

## Operator steps

After task 1's first publish run, make the package public (GHCR creates
it private, and the cluster pulls without credentials):

1. Open `https://github.com/users/ned-si/packages/container/homelab-jamulus/settings`.
2. Danger Zone, "Change visibility", choose Public, type
   `homelab-jamulus`, confirm.

Check: `curl -s -o /dev/null -w '%{http_code}\n'
'https://ghcr.io/token?scope=repository:ned-si/homelab-jamulus:pull'`
prints `200` (`403` while private or absent). Until it does, task 2 does
not start: the run sends the parent a `warning` naming this step, and if
it is still `403` at the cutoff it records tasks 2-6 as open, blocked on
the operator step.

Only if remote players are wanted, the router rule on the Sunrise Connect
Box 3 Fiber. The labels come from the 80/443 rules the operator created
on 2026-10-02.

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
4. From the Mac, `python3 platform/jamulus-probe/exporter.py --once
   jam.lilalala.com:41124` prints `up clients=<n> ...` only if the router
   loops UDP back. That is unverified, so a `down` from the Mac alone is
   no failure; step 3 is the check.

To end remote access, delete the rule (or disable it if the page offers
that). Expected: the phone check no longer connects. Players on the LAN
keep `192.168.1.202:41124`.

## Error handling

| Operation | Failure | Recoverable? | What happens, who sees it |
| --- | --- | --- | --- |
| Image build (PR or publish) | apt rejects `InRelease` (key changed or expired 2030-07-26), the package or arm64 build is missing, Debian mirror down | Recoverable by a fix or a re-run | Build fails; `ci` red on a PR; on `main` nothing is pushed, the running image stays, ntfy low priority ("jamulus-publish failed"), quiet-hours delay |
| Smoke | Server does not answer within 20 s, wrong version, exits under read-only or non-root | Recoverable by a fix | Job fails with the container log printed; nothing pushed |
| Push, attest, sign, verify | Registry or Sigstore error, verify mismatch | Re-run | No `:main` tag, nothing deployed; ntfy low priority |
| Pull in the cluster | Package still private, digest unsigned | Recoverable | Pull: `ImagePullBackOff`, Application Progressing, `ArgoCDAppStillProgressing` pages after 1 h; prevented by the anonymous token check before task 2. Unsigned: the CI gate fails the PR; Kyverno (Audit) reports `fail` |
| Server start | Bad argument, port in use | Fatal for that revision | Container exits, CrashLoopBackOff, Degraded, auto-rollback reverts after 5 min; a failed revert pages `ArgoCDAppStillDegraded` |
| Readiness or liveness ping | No echo | Recoverable | Not Ready: no endpoint, players cannot connect; 2 min without an echo restarts the container; INFO `PodNotReady` |
| PostSync smoke | No echo through the Service in 6 tries | Fatal for that sync | Sync failed, auto-rollback reverts the merge; `kubectl -n jamulus logs job/jamulus-smoke` |
| LoadBalancer address | `.202` taken by a LAN device | Recoverable by a fix (free the address or pin another one) | LB-IPAM still assigns it and the in-cluster probe stays up, while LAN players reach the other device; `scripts/smoke.sh` item 9 and the Mac ping of tasks 2 and 4 show the conflict |
| LoadBalancer address | `.202` outside the pool after a pool change | Recoverable by a fix | Service stays pending, Application Progressing, `ArgoCDAppStillProgressing` after 1 h; `JamulusDown` after 15 min |
| Exporter start | `TARGETS` or `PORT` invalid | Fatal for that revision | Logs `error` with the bad value, exits 1, CrashLoopBackOff, auto-rollback |
| Exporter ping | Timeout, ICMP port unreachable, wrong or corrupt reply | Recoverable | `jamulus_up` 0 for that scrape; `warning` log once on the transition; `JamulusDown` after 15 min |
| Scrape | Exporter down or unreachable | Recoverable | No `jamulus_up` series, the `absent()` branch fires `JamulusDown` after 15 min |
| external-dns | Cloudflare API error, record not created | Recoverable, retried each cycle | Logged by external-dns at `error`; the task 4 check catches it (the stale wildcard still resolves the name meanwhile) |
| Router rule | Missing or wrong (TCP, wrong IP) | Operator fixes | Remote players get no answer; the external pentest's ping line says "no answer"; LAN players are unaffected |
| Abuse while the rule exists | Strangers join or flood | Operator acts | Seen as unknown names in the client, `jamulus_clients` up, connection lines in SigNoz; the runbook's first step is to disable the rule |

## Input validation

| Input | Rules | On failure |
| --- | --- | --- |
| UDP datagrams to the server | Parsed by upstream Jamulus; only UDP 41124 reaches it (policy and Service); at most 8 channels | Upstream drops malformed frames (CRC, length); beyond 8 the server answers "server full" |
| `TARGETS` (exporter) | Required; 1 to 8 comma-separated `host:port`; host an IPv4 literal or a hostname of at most 253 characters (`[A-Za-z0-9.-]`); port an integer 1-65535 | Exit 1 with an `error` log naming the entry |
| `PORT` (exporter) | Optional, default 9174, integer 1024-65535 | Exit 1 with an `error` log |
| Exporter HTTP requests | `GET /metrics`, `GET /healthz`; nothing else | 404 for another path, 405 for another method |
| Ping replies (exporter) | From the connected peer only; exactly 14 bytes; tag 0; id 1002; length 5; CRC | Counted as no answer for that attempt; reason in the transition log |
| `--once` argument | One `host:port`, same rules as a `TARGETS` entry | Exit 2 with a usage line |
| `jamulus-ping` arguments | Host any string bash accepts in `/dev/udp`; port digits, 1-65535 | Exit 2 with a message on stderr; an unresolvable host exits 1 |
| `JAMULUS_TAG` (Renovate) | `^r\d+_\d+_\d+$`; betas never match | Not offered; a malformed hand edit fails the build (no such apt repository) |

## Invariants

| Invariant | Owner | Why there |
| --- | --- | --- |
| The server never registers with a directory | The Deployment arguments; `tests/test_jamulus.py` fails on any directory or server-info option | The only place the server learns it; CI is the gate |
| Only UDP 41124 reaches the pod | The Service ports and the `jamulus` allow-list under the enforced switch | Cilium enforces at the pod, whatever path the packet took |
| The pod opens no connection | The enforced egress switch (DNS only) | Namespace-wide, so it also covers any future container |
| One port number in every place | `tests/test_jamulus.py` across Deployment, Service, policy, probe target and `jamulus-ping` | A mismatch breaks silently otherwise (the pod Ready, players unanswered) |
| No node ports | `allocateLoadBalancerNodePorts: false`, checked by the same test | The API server would otherwise allocate them |
| The image comes from `jamulus-publish` on `main` | CI gate `--gate-own` (blocks), Kyverno `verify-own-images` (Audit, reports) | The gate stops it before merge; Kyverno shows what runs |
| The installed bytes are upstream's | apt with the committed key | The only point where the .deb enters |
| Remote access only by the operator's choice | The router rule | The one control outside the repository, by design |

## Testing

- Unit (pytest, `tests/test_jamulus_probe.py`): CRC check value `0xD64E`;
  the encodings of 1001 and 1002 with timestamp 0 against the bytes in
  this design; reply validation (good, bad CRC, wrong id, short, wrong
  length, wrong tag); `TARGETS` and `PORT` parsing; the metrics text for
  up and down; HTTP routing (200, 404, 405).
- In-process integration (same file): a thread with a UDP socket that
  answers like the server (and one that stays silent, one that answers
  garbage); `--once` exits 0, 1, 1; a scrape shows `jamulus_up` 1, 0, 0.
- Consistency (`tests/test_jamulus.py`, over `deploy/`): the invariants
  above; the Deployment `args` equal exactly `["--server", "--nogui",
  "--port", "41124", "--numchannels", "8", "--fastupdate",
  "--discononquit"]`, which rules out every forbidden option of
  Requirement 2.3 (directory, recording, JSON-RPC, HTML status, log file),
  with the explicit directory-option check kept for its error message;
  and the `jamulus-ping` bytes equal the exporter's encoding.
- Image (CI job `jamulus` and the publish workflow): the real server, run
  read-only and non-root, answers `jamulus-ping` and, from task 3,
  `--once`.
- Rules: promtool (`tests/prometheus/jamulus_test.yaml`), Alertmanager
  routes (`routes.txt`), repo-policy `alert-runbooks` and `alert-tests`.
- Pre-production: `preprod` boots the Deployment on kind; Ready means the
  exec ping answered.
- Live, read-only, per task ([tasks.md](tasks.md)).

## Found on the way

`*.lilalala.com` has an A record in Cloudflare: `dig +short
zz-nothere-8812.lilalala.com @1.1.1.1` returns the WAN address, and
`a-*.lilalala.com` holds the TXT `external-dns/resource=httproute/gateway/https-redirect`.
external-dns created it before the redirect route opted out with
`controller: none`, and upsert-only never removes it, although
`http-redirect.yaml` says the annotation keeps the wildcard out of
Cloudflare. Every name, `jam.lilalala.com` included, resolves today
because of it. It is not this spec's job: an issue, opened in task 1's
run, to delete it by hand and document the step.

`platform/vuln-enrich/enrich.py` marks as exposed only namespaces behind
an HTTPRoute (`vuln_namespace_exposed`), so the internet-reachable
`jamulus`, like `syncthing` and `theater` through their LoadBalancers,
will not rank as exposed. A second issue, opened in task 1's run:
"vuln-enrich: count namespaces behind a forwarded LoadBalancer as
exposed".
