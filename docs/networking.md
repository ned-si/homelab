# Networking

One flat LAN, one public entrypoint (the shared Gateway on `192.168.1.254`),
two other forwarded ports. The address table is in the README's
[Networking](../README.md#networking) section.

## LAN and router

- LAN `192.168.1.0/24`, the only subnet: LoadBalancer IPs are LAN addresses,
  not a separate range, so the router needs no route to reach them. The ISP
  router (Sunrise Connect Box 3 Fiber,
  `192.168.1.1`) is the gateway, the DHCP server (pool `.50`-`.199`) and the DNS
  forwarder. The TP-Link Decos are access points only.
- The router cannot reserve addresses outside its pool and has no static
  routes. Every infrastructure address is therefore set on the device itself:
  the four nodes in their Talos machine configs
  ([`talos/talconfig.yaml`](../talos/talconfig.yaml), `nodes[].networkInterfaces`),
  the NAS on its `igb0` port. Everything static lives outside the DHCP pool.
- The router's DNS forwarder answers NXDOMAIN for bare names such as
  `kubernetes`.
- NAT loopback works: public names resolve to the WAN IP and answer from inside
  the house.
- Port forwards:

  | Port | Target | What |
  | --- | --- | --- |
  | 80, 443 TCP | `192.168.1.254` | every public hostname (the shared Gateway) |
  | 22000 TCP and UDP | `192.168.1.201` | Syncthing sync protocol |
  | 50000 TCP | `192.168.1.200` | qBittorrent seeding |

- The WAN address is dynamic. Its only copy in git is `--default-targets` in
  `infrastructure/external-dns/values.yaml`. Re-check it after a router reboot:

  ```sh
  curl -s -4 -m 10 https://ifconfig.me; echo
  grep default-targets infrastructure/external-dns/values.yaml
  ```

  Expected: the same address twice. If they differ, follow
  [wan-ip-change.md](runbooks/wan-ip-change.md).
- The Turing Pi 2 BMC takes a DHCP address (currently `192.168.1.194`, the
  address the `lan-icmp` Probe pings in
  `platform/blackbox-exporter/probes/lan.yaml`); reach it as `turingpi.local`. Its
  slots Node 1 to Node 4 hold `homelab-cp-1`, `homelab-cp-2`, `homelab-cp-3`
  and `homelab-w-1`, in that order
  ([node-power-cycle.md](runbooks/node-power-cycle.md)).

## Kubernetes API VIP

Talos holds `192.168.1.11:6443` itself: `vip.ip` on each control plane's
interface in [`talos/talconfig.yaml`](../talos/talconfig.yaml). One control
plane, elected through etcd, carries the address and answers ARP for it; when
it goes down, another takes it within seconds. Without etcd quorum there is no
VIP. `talosctl` talks to the node IPs, not the VIP
([talos.md](talos.md#nodes)).

```sh
export TALOSCONFIG=talos/clusterconfig/talosconfig   # after task talos:genconfig
talosctl -n 192.168.1.247,192.168.1.238,192.168.1.239 get addresses | grep 192.168.1.11
```

Expected: one line, on the control plane that holds the VIP.

## LoadBalancer IPs

Cilium LB-IPAM hands out LoadBalancer addresses from two pools without
selectors (`infrastructure/cilium/ip-pools.yaml`):

| Pool | Range | Who |
| --- | --- | --- |
| `pool-1` | `192.168.1.254/32` | the shared Gateway |
| `pool-2` | `192.168.1.200`-`.227` | every other LoadBalancer Service |

Addresses the router forwards to are pinned with the `lbipam.cilium.io/ips`
annotation: `.254` on the Gateway (through `spec.infrastructure.annotations`),
`.200` on `theater/qbittorrent-seed`, `.201` on `syncthing/syncthing-protocol`.

Cilium L2 announcements answer ARP for these addresses
(`infrastructure/cilium/l2-announcement-policy.yaml`: every node, LoadBalancer
IPs only), one lease per Service. The address is on no node interface; the
lease holder answers for it.

With `externalTrafficPolicy: Cluster` and kube-proxy replacement, any node that
answers forwards correctly, so a holder change is not a fault. L2
announcements do not work with `externalTrafficPolicy: Local`; no Service here
sets it.

```sh
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Expected: `gateway/cilium-gateway-shared` on `192.168.1.254`,
`theater/qbittorrent-seed` on `192.168.1.200`, `syncthing/syncthing-protocol` on
`192.168.1.201`.

## Gateway

Cilium implements the Gateway API (GatewayClass `cilium`, experimental-channel
CRDs at the version in `infrastructure/gateway-api/kustomization.yaml`, from
the `gateway-api` Application). One shared
Gateway serves every public hostname (`infrastructure/gateway/`):

```
router 80/443 -> 192.168.1.254 = Service gateway/cilium-gateway-shared
  Gateway gateway/shared
    :80  listener http  -> HTTPRoute gateway/https-redirect -> 301 to https
    :443 listener https -> one HTTPRoute per hostname, in the app's namespace
    TLS: one wildcard certificate, *.lilalala.com (Secret wildcard-lilalala-tls)
```

| Hostname | HTTPRoute | Backend |
| --- | --- | --- |
| `argo` | `argo/argocd` | `argocd-server:80` (Argo CD runs `server.insecure: true`) |
| `auth` | `keycloak/keycloak` | Keycloak |
| `grafana` | `monitoring/grafana` | Grafana |
| `media` | `immich/immich` | Immich |
| `theater` | `theater/theater` | `/` Plex, `/arr/<app>` Sonarr, Radarr, Lidarr, Prowlarr |
| `cinema` | `theater/jellyfin` | Jellyfin |
| `archive` | `paperless/paperless` | Paperless-ngx |
| `cook` | `mealie/mealie` | Mealie |
| `syncthing` | `syncthing/syncthing` | Syncthing UI |

- Every route sets `parentRefs` with `sectionName: https`. Without it the route
  also answers on plain HTTP and skips the redirect.
- Every route sets `timeouts.request: 0s`, which removes Envoy's default 15 s
  route timeout (streams, uploads). Envoy streams request bodies, so uploads have
  no size limit.
- The redirect's `Location` carries `:443` (`https://<host>:443/`), because
  Cilium sets the port explicitly. Browsers treat it as the same URL.
- Every rule of every route on the `https` listener sets security headers (see
  below); CI rule `route-security-headers` requires at least HSTS and
  `X-Content-Type-Options`.

### Security headers

Each rule carries a `ResponseHeaderModifier` filter with `set`, which
replaces the header the app sends. A header the app already sets with an equal
or stricter value is left out, so the app's value stays.

| Header | Value |
| --- | --- |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |
| `X-Content-Type-Options` | `nosniff` |
| `Permissions-Policy` | `camera=(), microphone=(), payment=(), usb=()` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `X-Frame-Options` | `SAMEORIGIN` |
| `Content-Security-Policy` | `frame-ancestors 'self'; base-uri 'self'; object-src 'none'` |

The CSP only restricts framing, `<base>` and plugins, so it cannot break an
app's scripts or styles. Per host, what the app keeps:

| Host | Left to the app |
| --- | --- |
| `argo`, `ebooks` | CSP, `X-Frame-Options` |
| `audiobooks` | CSP, Referrer-Policy |
| `archive` | Referrer-Policy (`same-origin`), `X-Frame-Options` |
| `auth` | CSP, `X-Frame-Options`, Referrer-Policy: Keycloak sets them per page, and its `login-status-iframe` must stay frameable |
| `grafana` | `X-Frame-Options` (`deny`); the CSP has `frame-ancestors 'none'` |
| `home` | Referrer-Policy, `X-Frame-Options`, Permissions-Policy (Assist uses the microphone) |
| `syncthing` | `X-Frame-Options` |
| `theater` `/arr/qbittorrent` | CSP, Referrer-Policy |

```sh
STRICT_HEADERS=1 scripts/tls-check.sh
```

Expected: `tls-check passed`. The weekly `dast` workflow runs the same check.

There is no ingress controller and no `Ingress` object in the cluster.

```sh
kubectl -n gateway get gateway shared
kubectl get httproute -A
```

Expected: `PROGRAMMED True` with address `192.168.1.254`, then 11 routes (the
ten above plus `gateway/https-redirect`). A route that exists but serves 404 has
almost always failed to attach: read `Accepted` and `ResolvedRefs` in
`kubectl -n <ns> get httproute <name> -o yaml`.

## DNS

external-dns (chart version in `clusters/homelab/infrastructure/external-dns.yaml`),
provider Cloudflare, policy `upsert-only`
(it creates and updates records, never deletes them), TXT registry with the
default owner. Its only source is `gateway-httproute`. Every record is an A
record to the single `--default-targets` address. The wildcard redirect route
opts out with `external-dns.alpha.kubernetes.io/controller: none`; CI requires
that annotation on any wildcard route.

Records for removed hostnames stay in Cloudflare until deleted by hand.

## Certificates

cert-manager (chart version in `clusters/homelab/infrastructure/cert-manager.yaml`),
ClusterIssuer `letsencrypt`, DNS-01 through Cloudflare
(token in Secret `cert-manager/cloudflare-api-token-secret`). The Gateway uses
one `Certificate`, `gateway/wildcard-lilalala`, for `*.lilalala.com`; no listener
serves the apex, so it is not on the certificate
(`infrastructure/gateway/certificate.yaml`). DNS-01 needs no inbound port 80.

```sh
kubectl -n gateway get certificate wildcard-lilalala
```

Expected: `READY True`.

## Network policy

`infrastructure/network-policies/` holds a `CiliumNetworkPolicy` set per app
namespace. It is written and not enabled: its Application file is not in the
infrastructure layer. Every policy ships with
`enableDefaultDeny: {ingress: false, egress: false}`; enforcement is opt-in per
namespace in `90-enforcement.yaml`, which also documents the procedure.

NFS and iSCSI are mounted by the kubelet and `iscsid` in the host network
namespace, so a pod policy never sees that traffic. The NAS export allow-list is
what limits it ([runbooks/nfs-hardening.md](runbooks/nfs-hardening.md)).

## Metrics

The Cilium agents export datapath metrics (`cilium_*`, port 9962) and Hubble
flow metrics (`hubble_*`, port 9965); Envoy, which serves the Gateway,
exports `envoy_*` on 9964 and the operator `cilium_operator_*` on 9963.
Prometheus scrapes them through the PodMonitors in
`platform/kube-prometheus-stack/routes/cilium-monitors.yaml`.

| Hubble metric | Labels |
| --- | --- |
| `hubble_flows_processed_total` | type, subtype, verdict, source, destination |
| `hubble_drop_total` | reason, protocol, source, destination |
| `hubble_tcp_flags_total` | flag, family, source, destination |
| `hubble_icmp_total` | type, family, source, destination |
| `hubble_http_requests_total`, `hubble_http_request_duration_seconds` | method, protocol, status, reporter, source, destination |

`source` and `destination` are the namespace, or the reserved identity
(`world`, `host`, `remote-node`, ...) for endpoints outside a namespace. HTTP
metrics cover traffic through Envoy, which today is the Gateway. Hubble DNS
metrics are off: they need Cilium's DNS proxy, which only runs with an FQDN
policy; CoreDNS's metrics cover DNS.

```sh
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=count%20by%20(job)%20(up%7Bjob%3D~%22.*cilium.*%22%7D%3D%3D1)' |
  jq -r '.data.result[] | "\(.metric.job) \(.value[1])"'
```

Expected: `monitoring/cilium-agent 8` (two endpoints on four nodes),
`monitoring/cilium-envoy 4`, `monitoring/cilium-operator` with one per
operator replica.

## Debugging

Hubble runs inside each Cilium agent; the relay is not deployed. Read flows on
the node that runs the pod:

```sh
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system exec <cilium-pod-on-that-node> -c cilium-agent -- \
  hubble observe --namespace theater --last 50
kubectl -n kube-system exec <cilium-pod-on-that-node> -c cilium-agent -- \
  hubble observe --verdict DROPPED --last 50
```

## Why it is like this

- One shared Gateway on Cilium, replacing ingress-nginx (cited as ADR 0007 and
  ADR 0011 in code comments). ingress-nginx is retired upstream, Cilium was
  already the CNI and ships a Gateway API controller, and Gateway API routes
  live next to each app. The Gateway holds `.254`, the single address the
  router forwards 80 and 443 to. Rejected: another ingress controller, which
  keeps a second data plane beside Cilium.
- The WAN IP in exactly one place: CI rule `wan-ip-single-source`. Two copies
  drift after the next ISP address change.
- Static addresses on the devices, not DHCP reservations: the router cannot
  reserve outside its pool.
- The API VIP from Talos, not kube-vip: it is part of the machine config in
  git instead of a hand-written static pod per control plane. Cilium L2
  announcements are the only LoadBalancer announcer.
