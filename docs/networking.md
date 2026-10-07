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
  the four nodes in `/etc/netplan/01-homelab-static.yaml` (cloud-init networking
  disabled), the NAS on its `igb0` port. Everything static lives outside the
  DHCP pool.
- The router's DNS forwarder answers NXDOMAIN for bare names such as
  `kubernetes`. Anything that must resolve a short name needs `/etc/hosts`
  first (see [kube-vip](#kubernetes-api-vip)).
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

  Expected: the same address twice. If they differ, change the values file in a
  pull request; external-dns updates every record after the merge syncs.

## Kubernetes API VIP

kube-vip v1.2.4 runs as a static pod on each control plane
(`/etc/kubernetes/manifests/kube-vip.yaml`, written by hand; the full manifest
is in [runbooks/node-replacement.md](runbooks/node-replacement.md#kube-vip-manifest)) and holds
`192.168.1.11:6443` with ARP and leader election (lease `plndr-cp-lock`).

The kube-vip image has no `/etc/nsswitch.conf`, so Go asks DNS before
`/etc/hosts` for `kubernetes` and stops on the router's NXDOMAIN. Each control
plane's manifest therefore mounts the host's `/etc/nsswitch.conf` read-only.
`kubeadm upgrade` does not rewrite that manifest; check the mount after every
upgrade:

```sh
for h in 192.168.1.247 192.168.1.238 192.168.1.239; do
  printf '%s ' "$h"
  ssh -o ConnectTimeout=5 -o BatchMode=yes nedsi@"$h" \
    'sudo -n grep -c nsswitch /etc/kubernetes/manifests/kube-vip.yaml'
done
```

Expected: `4` after each address (the volume and its mount). `0` means the fix
is gone and the VIP fails after the next kube-vip restart. Add it back with
`sudo -e /etc/kubernetes/manifests/kube-vip.yaml` (the kubelet restarts the pod
on save):

```yaml
# append to spec.containers[0].volumeMounts
- mountPath: /etc/nsswitch.conf
  name: nsswitch
  readOnly: true
# append to spec.volumes
- name: nsswitch
  hostPath:
    path: /etc/nsswitch.conf
    type: File
```

`/root/kube-vip.yaml.bak-*` on each control plane are the manifests from before
this fix, kept for reference.

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

Two announcers answer ARP for these addresses:

- Cilium L2 announcements (`infrastructure/cilium/l2-announcement-policy.yaml`:
  every node, LoadBalancer IPs only), one lease per Service;
- kube-vip with `svc_enable=true`, which binds every LoadBalancer IP on its
  lease holder (lease `plndr-svcs-lock`) and records it in the Service
  annotation `kube-vip.io/vipHost`.

With `externalTrafficPolicy: Cluster` and kube-proxy replacement, any node that
answers forwards correctly, so a holder change is not a fault. Choosing one
announcer is on the [roadmap](roadmap.md). L2 announcements do not work with
`externalTrafficPolicy: Local`; no Service here sets it.

```sh
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Expected: `gateway/cilium-gateway-shared` on `192.168.1.254`,
`theater/qbittorrent-seed` on `192.168.1.200`, `syncthing/syncthing-protocol` on
`192.168.1.201`.

## Gateway

Cilium implements the Gateway API (GatewayClass `cilium`, Gateway API v1.2
CRDs, experimental channel, capped with Cilium below 1.18 by the node kernel, from the `gateway-api` Application). One shared
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
| `drive` | `seafile/seafile` | Seafile |
| `syncthing` | `syncthing/syncthing` | Syncthing UI |

- Every route sets `parentRefs` with `sectionName: https`. Without it the route
  also answers on plain HTTP and skips the redirect.
- Every route sets `timeouts.request: 0s`, which removes Envoy's default 15 s
  route timeout (streams, uploads). Envoy streams request bodies, so uploads have
  no size limit.
- The redirect's `Location` carries `:443` (`https://<host>:443/`), because
  Cilium sets the port explicitly. Browsers treat it as the same URL.

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
