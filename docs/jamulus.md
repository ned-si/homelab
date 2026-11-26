# Jamulus

A [Jamulus](https://jamulus.io) server (GPL-2.0) for playing music
together live from different places: each player's client sends its audio
to the server, which mixes it and sends every player the mix back with low
latency. Namespace `jamulus`, manifests in `apps/jamulus/`, Argo CD
Application `jamulus`, image `ghcr.io/ned-si/homelab-jamulus` built from
`jamulus/`. Operating it: [runbooks/jamulus.md](runbooks/jamulus.md).

| What | Value |
| --- | --- |
| Address from the house | `192.168.1.202:41124`, always |
| Address from outside | `jam.lilalala.com:41124`, only while the [router rule](#from-outside-the-house) exists |
| Protocol | UDP 41124, nothing else |
| Players | 8 at most; the ninth gets "server full" |
| Login | none: Jamulus has no accounts or passwords |
| Directory | none: the server is not listed anywhere |

## Connect

1. Install the client from [jamulus.io](https://jamulus.io) (Windows,
   macOS, Linux). Upstream's advice holds: wired network rather than
   Wi-Fi, wired headphones, and an audio interface if you have one.
2. Open Settings, My Profile, and set an alias and an instrument. Anyone
   who can reach the server reads these, with country, city and skill, so
   leave out what you would not share.
3. In Settings, Audio/Network Setup: Buffer Delay 64 samples if the sound
   card allows it (128 otherwise), Jitter Buffer on Auto, Audio Channels
   Mono (or Mono-in/Stereo-out), Audio Quality Normal or High.
4. Connect, type the server address (table above) in Server Address,
   Connect. Expected: the mixer shows your channel and everyone else's.
   The client keeps the address in its history.

Bandwidth per player, each way, as the client's "Audio Stream Rate" shows
it with 64-sample buffers (upstream `CChannel::GetUploadRateKbps`, release
3.12.6):

| Audio Quality | Mono | Stereo |
| --- | --- | --- |
| Normal | 600 kbit/s | 678 kbit/s |
| High | 684 kbit/s | 906 kbit/s |

The server sends each player its mix at the rate that player chose, so the
home line carries the sum of the players' rates in each direction: under
8 Mbit/s each way with 8 players. Larger buffers lower the rate and add
latency.

## What the server runs

`apps/jamulus/deployment.yaml` starts `jamulus-headless` with exactly
these arguments (`tests/test_jamulus.py` fails on any other):

| Argument | Effect |
| --- | --- |
| `--server --nogui` | Headless server |
| `--port 41124` | The one UDP port |
| `--numchannels 8` | At most 8 players |
| `--fastupdate` | 64-sample frames for clients that use them: lower latency |
| `--discononquit` | Clients are told to disconnect when the server stops |

No directory, no recording, no JSON-RPC API, no HTML status page, no log
file. The pod runs as UID 65532 with a read-only root filesystem, no
capabilities, no ServiceAccount token, no volume but a 16 MiB `/tmp`, under
Pod Security `restricted`. The namespace's network policy is enforced: only
UDP 41124 comes in, and nothing goes out but cluster DNS
(`infrastructure/network-policies/58-jamulus.yaml`).

The Service `jamulus/jamulus` is a LoadBalancer pinned to `192.168.1.202`,
without node ports ([networking.md](networking.md#loadbalancer-ips)).

## From outside the house

Players outside the LAN reach the server only while the operator keeps a
port forward on the router: UDP 41124 to `192.168.1.202`. It is off by
default. Open it for a session, close it afterwards:
[runbooks/jamulus.md](runbooks/jamulus.md#1-open-the-server-to-the-internet).
`jam.lilalala.com` resolves to the WAN address whether the rule exists or
not; without it, nothing answers there.

## What a stranger can do

Host and port are public in this repository, so while the router rule
exists anyone can use the server. Someone who knows `jam.lilalala.com:41124`
can:

- Join without a login, under any name, hear the mix of everyone
  connected, play or make noise into it, send chat messages, and see the
  other players' names.
- Take channels until the cap of 8, which locks the band out.
- Flood UDP at the WAN address, which fills the home uplink for the whole
  household.
- Without joining and without a log line: read who is connected (alias,
  country, city, instrument, skill) and the server version.
- Use the server as a UDP reflector: a request with a spoofed source is
  answered to that source, and the player list is larger than the request.
- Exploit a parsing bug in the server, if one exists. They would land in
  the pod above, which reaches no other app, no LAN host and no cluster API.

They cannot read household data or change the server's configuration:
Jamulus has no admin interface over UDP. The port 41124 instead of the
default 22124 only stops scans that try the default. Threats, controls and
residuals: [threat-model.md](threat-model.md#internet-to-jamulus-41124-udp-on-1921681202).
On abuse: [runbooks/jamulus.md](runbooks/jamulus.md#6-abuse).

## Monitoring

- `jamulus-probe` in `monitoring` sends a Jamulus protocol ping to
  `192.168.1.202:41124` on every scrape and exports `jamulus_up`,
  `jamulus_ping_seconds` and `jamulus_clients`
  ([observability.md](observability.md)).
- `JamulusDown` (`action: review`, no notification) fires after 15 minutes
  without an answer ([runbook](runbooks/alerts/JamulusDown.md)).
- No SLO: sessions are by appointment and the public path exists only while
  the router rule does ([sre.md](sre.md)).
- The server logs each audio connection (`<time>, <address>, connected
  (<n>)`) to the console; Vector ships it to SigNoz
  (`k8s.namespace.name = jamulus`). Reading the player list leaves no line.

## Image and upgrades

No official image exists. `.github/workflows/jamulus-publish.yaml` builds
`jamulus/Dockerfile`: the upstream `jamulus-headless` package from the
release's apt repository, verified against the committed upstream key
`jamulus/jamulus-release-key.asc` (fingerprint
`1FC2EFC5F88868F6FC6A06398E8516F926E4AD0E`, expires 2030-07-26), on
`debian:bookworm-slim`, for arm64 and amd64. The workflow signs the image
keyless and attaches SLSA provenance; Kyverno's `verify-own-images` and the
CI gate check both. Renovate offers new stable releases (`rX_Y_Z`, never
betas) and the new image digests, and automerges them on green `ci`, whose
`jamulus` job builds the image and pings it
([testing.md](testing.md)).

## Why it is like this

- A central server over SonoBus: SonoBus is peer to peer, so every player
  sends to every other and the upload grows with each player. With a
  server in the cluster, each player keeps one connection.
- Our own image: none is official, the maintained community image is one
  person's build and signing identity, and upstream publishes signed .deb
  packages. Building from those puts no third party between upstream and
  the cluster and gives the image the signature and provenance our policies
  read.
- Port 41124, not the default 22124: it hides the server from scans for
  Jamulus servers and costs players typing the port once. One number end
  to end keeps logs, policies and probes readable.
- Unlisted, the LAN always, the internet through the router rule: friends
  join with the plain client, and the operator decides when the port is
  open. Rejected: the tailnet only, which makes every friend install
  Tailscale and adds a proxy hop, and possibly a relay, to a protocol that
  needs low latency. It stays the fallback if strangers show up.
- Design and alternatives in full:
  [spec self-hosted-jamulus](../.kiro/specs/self-hosted-jamulus/design.md).
