---
kind: change
status: active
created: 2026-11-25
issue: 1702
---
# Requirements: self-hosted-jamulus

## Introduction

[Jamulus](https://jamulus.io) (GPL-2.0) lets musicians play together live
from different places: each player's client sends audio to one server,
which mixes it and sends the mix back with low latency. The operator wants
one for the household and friends, self-hosted and free (#1702). He chose a
central server over SonoBus, which is peer to peer, because the cluster can
host the server and every player then needs only one connection.

This spec runs a Jamulus server as a new app, `jamulus`, held to the
practices of the other apps: an image built and signed by our CI, a
hardened pod under Pod Security `restricted`, an enforced network policy, a
pinned LoadBalancer address, a public name in DNS, a probe with a
non-paging alert, logs in SigNoz, a pentest scope entry and documentation.

Jamulus has no user authentication. The exposure is therefore a decision
of this spec: an unlisted server on a non-default port with a channel cap,
reachable on the LAN at once, and from the internet only while the
operator keeps a router rule for it
([design, Exposure](design.md#exposure)).

Non-goals are listed under [Out of scope](#out-of-scope).

## Glossary

- **Server**: the Jamulus server process, `jamulus-headless`, in the pod
  `jamulus` of namespace `jamulus`.
- **Client**: the Jamulus desktop or mobile app a player connects with, by
  host and port.
- **Jamulus port**: UDP `41124`, the one port the server listens on, the
  Service exposes and the router forwards
  ([design, Port](design.md#port)).
- **LoadBalancer address**: `192.168.1.202`, from the Cilium pool
  `pool-2`, pinned on the Service.
- **Public name**: `jam.lilalala.com`, an A record to the WAN address.
- **Router rule**: the Sunrise Connect Box port forward of UDP 41124 to
  `192.168.1.202`, set by the operator only when remote players are wanted
  ([design, Operator steps](design.md#operator-steps)).
- **Protocol ping**: a Jamulus connectionless message
  `CLM_PING_MS` (1001) or `CLM_PING_MS_WITHNUMCLIENTS` (1002), which the
  server answers to any sender without a session.
- **Probe**: the exporter `jamulus-probe` in namespace `monitoring`, which
  sends a protocol ping on every scrape.
- **Own image**: `ghcr.io/ned-si/homelab-jamulus`, built by
  `.github/workflows/jamulus-publish.yaml`.

## Requirement 1: The image

**User story:** As the operator, I want a Jamulus image I can trust and
that updates itself, since no official one exists.

1. THE image SHALL be `ghcr.io/ned-si/homelab-jamulus`, built in
   `jamulus/` by `.github/workflows/jamulus-publish.yaml` on `main`, for
   `linux/arm64` and `linux/amd64`, from the `jamulus-headless` package of
   the upstream release, installed from the release's signed apt
   repository and verified against the committed upstream release key
   (fingerprint `1FC2EFC5F88868F6FC6A06398E8516F926E4AD0E`).
2. THE workflow SHALL push the index with BuildKit SBOM and provenance
   attestations, a signed SLSA provenance (`attest-build-provenance`), and
   a keyless cosign signature by its own identity, verify the signature,
   and only then tag the digest `:main`.
3. THE image SHALL run as UID and GID `65532` with a read-only root
   filesystem, and SHALL contain `jamulus-ping`, a protocol ping for the
   pod's probes and the PostSync smoke.
4. EVERY pull request touching `jamulus/` SHALL build the `linux/amd64`
   image inside `ci` and run it as the cluster does (read-only, non-root,
   all capabilities dropped); `jamulus-ping` SHALL get an answer from it.
5. Renovate SHALL update the Jamulus release (stable tags `rX_Y_Z` only),
   the base image digest, and deploy each new `:main` digest at once, like
   the dashboard image.
6. THE Kyverno policy `verify-own-images` SHALL bind the image to the
   `jamulus-publish` identity on `main`, and `ci/image-signers.yaml` SHALL
   list that identity, so the CI gate on own images covers it.

## Requirement 2: The app

**User story:** As the operator, I want Jamulus to run like every other
app: in git, hardened, with nothing it does not need.

1. THE app SHALL be `apps/jamulus`, Application `jamulus` in project
   `apps`, namespace `jamulus` declared with Pod Security `restricted` for
   `enforce`, `warn` and `audit`.
2. THE Deployment SHALL run one replica, strategy `Recreate`, with the
   own image pinned by digest, no ServiceAccount token, `runAsNonRoot`,
   seccomp `RuntimeDefault`, no privilege escalation, all capabilities
   dropped, a read-only root filesystem, an `emptyDir` at `/tmp` as its
   only volume, and CPU and memory requests and a memory limit.
3. THE server SHALL start with `--server --nogui --port 41124
   --numchannels 8 --fastupdate --discononquit` and with no directory,
   recording, JSON-RPC, HTML status or log-file option.
4. THE readiness and liveness probes SHALL be `jamulus-ping` against the
   server inside the pod; a PostSync Job SHALL ping the Service and fail
   the sync when the server does not answer.

## Requirement 3: The network

**User story:** As the operator, I want the server to accept only Jamulus
traffic and to reach nothing.

1. THE Service `jamulus/jamulus` SHALL be a `LoadBalancer` with
   `lbipam.cilium.io/ips: "192.168.1.202"`, one port UDP 41124,
   `allocateLoadBalancerNodePorts: false` and `externalTrafficPolicy:
   Cluster`.
2. THE namespace SHALL be enforced from the start in both directions in
   `infrastructure/network-policies/90-enforcement.yaml`.
3. THE allow-list SHALL admit to the server only UDP 41124, from `world`,
   `host` and `remote-node` (players, through SNAT), from the probe and
   from the PostSync Job; the server SHALL get no egress rule beyond the
   switch's cluster DNS.

## Requirement 4: Exposure

**User story:** As the operator, I want remote players to join when I
choose, and nobody to reach anything else through Jamulus.

1. THE server SHALL never register with a directory: none of
   `--directoryaddress`, `-e`, `--centralserver`, `--directoryserver`,
   `--directoryfile`, `--serverinfo` or `-o` in its arguments.
2. THE public path SHALL exist only while the router rule exists; without
   it, the server answers on the LAN only.
3. THE docs SHALL state what a stranger who learns the host and port can
   do (join, listen to the mix, play into it, chat, fill the 8 channels,
   flood the uplink, read the player list without joining, reflect UDP to
   third parties), that host and port are public in this repository so
   the server is open to anyone while the router rule exists, and that
   the pod reaches nothing else, and SHALL
   record the tailnet-only alternative and why it is not the default.

## Requirement 5: DNS

**User story:** As a player, I want to connect to a name, not an address.

1. external-dns SHALL publish `jam.lilalala.com` as an A record to the
   `--default-targets` address, DNS only (not proxied), from the
   annotation `external-dns.alpha.kubernetes.io/hostname` on the Service,
   with policy `upsert-only` unchanged.
2. ONLY `LoadBalancer` Services carrying that annotation SHALL publish
   records through the new source.

## Requirement 6: Observability

**User story:** As the operator, I want to know within days when the
server stops answering, without being paged.

1. THE probe SHALL send a protocol ping to `192.168.1.202:41124` on every
   scrape and export `jamulus_up`, `jamulus_ping_seconds` and
   `jamulus_clients`, labelled `target`.
2. `JamulusDown` SHALL fire when the probe gets no answer, or reports
   nothing, for 15 minutes, with `action: review` and a runbook; it SHALL
   reach the `null` receiver, never ntfy.
3. THE server's log lines SHALL reach SigNoz through the Vector DaemonSet,
   with no app-specific configuration.
4. Jamulus SHALL carry no SLO (the decision and its reason in
   `docs/sre.md`).
5. `python3 platform/jamulus-probe/exporter.py --once <host:port>` SHALL
   run the same ping from the Mac or a CI runner and exit 0 on an answer,
   1 otherwise.

## Requirement 7: Security review

**User story:** As the operator, I want the new open port inside the
pentest programme and the threat model.

1. `docs/pentest/scope.yaml` SHALL list `192.168.1.202` UDP 41124
   (`jam.lilalala.com`) under `forwarded_ports`, `mode: active`, noting
   that it is forwarded only while the router rule exists.
2. THE external pentest SHALL send one protocol ping to the WAN address on
   UDP 41124 and report "answers" or "no answer" in its summary without
   failing; any answer that is not a Jamulus reply is a finding.
3. `docs/threat-model.md` SHALL gain the boundary "Internet to Jamulus
   (41124 UDP on `192.168.1.202`)" with threats, controls and residuals.

## Requirement 8: Documentation

**User story:** As someone who was not there, I want to connect, operate
and reason about the server from the docs alone.

1. `docs/jamulus.md` SHALL say how to connect (LAN and internet), what the
   server allows, the router rule, the exposure trade-off, and end with
   "Why it is like this".
2. `docs/runbooks/jamulus.md` SHALL cover opening and closing the router
   rule, checking the server, a restart, an upgrade and what to do on
   abuse; `docs/runbooks/alerts/JamulusDown.md` SHALL cover the alert.
3. THE README services table and address table, `docs/networking.md`
   (LoadBalancer table, port-forward table, DNS sources),
   `docs/observability.md` (the exporter), the steering `product.md` and
   `structure.md`, and the area spec `media-home` SHALL include Jamulus.
4. THE tech radar SHALL list Jamulus (platform, `trial`, `moved: new`) and
   SonoBus (platform, `hold`, `moved: new`, the reason the central server
   won).

## Non-functional requirements

- Cost: nothing paid. GitHub-hosted runners and GHCR are free for a public
  repository.
- Bandwidth: at most 8 players at up to 906 kbit/s each way each (stereo,
  high quality, 64-sample frames; 684 kbit/s mono), under 8 Mbit/s each
  way on the home line. The per-player figures are the client's "Audio
  Stream Rate", computed by upstream `CChannel::GetUploadRateKbps` in
  3.12.6 (codec bytes, sequence number and 77 bytes of headers per frame);
  no session was played to read them from a client
  ([docs/jamulus.md](../../../docs/jamulus.md#connect)).
- Repository is public: no player names or addresses in git.

## Acceptance criteria

1. After the publish run, the `:main` index of
   `ghcr.io/ned-si/homelab-jamulus` lists `linux/amd64` and
   `linux/arm64`; `gh attestation verify
   oci://ghcr.io/ned-si/homelab-jamulus@<digest> --owner ned-si` passes;
   the run's log shows `cosign verify` with the `jamulus-publish`
   identity. [1.1, 1.2]
2. A pull request touching `jamulus/` runs the `jamulus` job in `ci`, which
   fails when the image does not answer `jamulus-ping` or prints a version
   other than the pinned one. [1.4]
3. `kubectl -n jamulus get deploy jamulus` shows 1/1 ready; the
   namespace has the three `restricted` labels; the PostSync Job
   `jamulus-smoke` succeeded; the `jamulus` policy report has `pass` and no
   `fail` for `verify-own-images` and for the baseline policies. [1.6, 2]
4. `kubectl -n jamulus get svc jamulus` shows `192.168.1.202`, port
   `41124/UDP` and no node port; from the Mac on the LAN, a protocol ping
   to `192.168.1.202:41124` gets the 13-byte echo. [3.1]
5. `tests/test_jamulus.py` passes: the port is 41124 in the Deployment
   arguments, the Service, the allow-list, the probe target and the
   `jamulus-ping` default; the Deployment arguments are exactly
   `--server --nogui --port 41124 --numchannels 8 --fastupdate
   --discononquit`, so no directory, recording, JSON-RPC, HTML status or
   log-file option; the Service has no node ports. [2.3, 3, 4.1]
6. `jamulus_up{target="192.168.1.202:41124"}` is 1 and `JamulusDown` is
   inactive; the promtool test fires `JamulusDown` after 15 minutes of
   `jamulus_up` 0 and of no series; `tests/alertmanager/routes.txt` routes
   it to `null`. [6.1, 6.2]
7. `vector_log_events_total{namespace="jamulus"}` increases after the
   server starts. [6.3]
8. `dig +short jam.lilalala.com @1.1.1.1` returns the `--default-targets`
   address and `dig +short TXT a-jam.lilalala.com @1.1.1.1` names
   `service/jamulus/jamulus`. [5]
9. `scripts/pentest-scope-check.sh` passes with the new entry; the
   external runbook names 41124. [7]
10. `https://techradar.nedsi.io/` lists Jamulus and SonoBus; the docs'
    links resolve in CI. [8]

## Out of scope

- A Jamulus directory, a registered server, server-side recording and the
  JSON-RPC API.
- Authentication: Jamulus has none, and no proxy can add it to its UDP
  protocol.
- The tailnet-only exposure: recorded as the alternative, not built.
- A Grafana dashboard for Jamulus: the Explore view of the three metrics is
  enough for one server.
- Moving the base image to Debian 13: a one-line change when wanted,
  gated by the same CI smoke test.
- The stale wildcard record `*.lilalala.com` found while checking DNS: its
  own issue ([design, Found on the way](design.md#found-on-the-way)).

## Decided defaults

| Topic | Default | Reason |
| --- | --- | --- |
| Image | Built by our CI from upstream's signed `jamulus-headless` .deb, `ghcr.io/ned-si/homelab-jamulus` | No official image: the `jamulussoftware` Docker Hub organisation has no repository, the upstream repository has no Dockerfile, and `ghcr.io/jamulussoftware/jamulus` gives no anonymous token. Upstream does publish signed arm64 and amd64 .deb packages per release ([design, Image](design.md#image)) |
| Base image | `debian:bookworm-slim`, pinned by digest | The upstream .deb is built on Ubuntu 22.04 against Qt 5; Debian 12 ships those libraries under the same names, and a maintained community image installs the same package on it for both architectures |
| Port | UDP 41124 end to end (server, Service, router) | Off the default 22124, the port a scan for Jamulus servers tries first; one number everywhere keeps logs, policy and probes readable ([design, Port](design.md#port)). The brief's exposure item (a non-default port) takes precedence over the 22124 in its network item; every later step and report uses 41124 |
| LoadBalancer address | `192.168.1.202` | The next free address of `pool-2` (`.200` and `.201` are pinned); no answer to ping or ARP on 2026-11-25 |
| Public name | `jam.lilalala.com` | An everyday word for a household service, on the household domain |
| Exposure | Unlisted, LAN at once, internet only through the router rule the operator sets when remote players are wanted | The safest option that still lets friends join from home; the tailnet makes every friend install and join Tailscale and adds a proxy hop to a latency-bound protocol ([design, Exposure](design.md#exposure)) |
| Channel cap | 8 | A band plus guests; it bounds what one stranger can take (channels, CPU, uplink) |
| Fast update | On (`--fastupdate`, 64-sample frames) | Lower latency for clients that support it; the RK3588 and the fibre line have the headroom for 8 players |
| Rate limits | None exist | Jamulus 3.12.6 has no rate-limit or allow-list option (its `--listfilter` is for directories), and Cilium cannot rate-limit ingress per source; the channel cap and the router rule are the controls |
| DNS | external-dns `service` source, LoadBalancer Services with the hostname annotation only | The brief asks for an external-dns record; a Service annotation keeps it next to the address it names ([design, DNS](design.md#dns)) |
| Probe | A stdlib Python exporter in `monitoring`, like `usage-exporter` | blackbox-exporter has no UDP prober, and only a protocol ping shows the server answers ([design, Probe](design.md#probe)) |
| Alert | `JamulusDown`, `action: review`, after 15 minutes | Sessions are by appointment; a page at night for an idle jam server is noise |
| SLO | None | Availability is measured by `blackbox-public`, which has no UDP prober, and the public path exists only while the operator keeps the router rule, so a public figure would measure his switch. Sessions are by appointment; `JamulusDown` (review) is the signal |
| Pod probes | Exec `jamulus-ping` (bash `/dev/udp`) | The server speaks UDP only; Kyverno `require-probes` needs both probes; the JSON-RPC TCP port would add a control API to reach |
| Radar | Jamulus `trial`, SonoBus `hold` | Jamulus is new here; SonoBus was considered and set aside for the central server |
| Merge | Each task merges after its review round and is checked live (operator, 2026-11-24: no approval pauses) | Same as the other specs |
