# Networking

Current state (2026-10-04) and the Gateway API plan. Addresses are in the
README's [Networking](../README.md#networking) table.

## LAN and router

- One LAN, `192.168.1.0/24`. The ISP router (Sunrise Connect Box 3 Fiber,
  `192.168.1.1`) is gateway, DHCP server (pool `.50`-`.199`) and DNS forwarder.
  The TP-Link Decos are access points only. There is no `192.168.2.0/24`.
- The router cannot reserve addresses outside its pool and has no static routes,
  so every infrastructure address is set on the device: the four nodes in
  `/etc/netplan/01-homelab-static.yaml` (cloud-init networking disabled), the
  NAS on its `igb0` port. NAT loopback works, so public names resolve and answer
  from inside the house.
- Port forwards:

  | Port | Target | What |
  |---|---|---|
  | 80, 443 TCP | `192.168.1.254` | every public hostname (the shared Gateway) |
  | 22000 TCP + UDP | `192.168.1.201` | Syncthing sync protocol, so phones sync from anywhere |
  | 50000 TCP | `192.168.1.200` | qBittorrent seeding |

- The WAN address is dynamic. It is set once, as `--default-targets` in
  `infrastructure/external-dns/values.yaml` (and in the legacy external-dns
  Application while that tree runs); re-check it after a router reboot.

## Kubernetes API VIP

kube-vip v0.8.5 runs as a static pod on each control plane and holds
`192.168.1.11:6443`. Its image has no `/etc/nsswitch.conf`, so Go resolved
`kubernetes` through DNS and failed on the router's NXDOMAIN; the host's
`/etc/nsswitch.conf` is mounted read-only into
`/etc/kubernetes/manifests/kube-vip.yaml` on all three control planes (fixed
2026-10-03, originals in `/root/kube-vip.yaml.bak-*`). Re-check the mount after
every `kubeadm upgrade`.

## LoadBalancer IPs

Cilium LB-IPAM hands out LoadBalancer addresses from two pools without
selectors (`infrastructure/cilium/ip-pools.yaml`):

| Pool | Range | Who |
|---|---|---|
| `pool-1` | `192.168.1.254/32` | the shared Gateway |
| `pool-2` | `192.168.1.200`-`.227` | every other LoadBalancer Service |

Addresses that something depends on are pinned on the Service with the
`lbipam.cilium.io/ips` annotation: `.200` qbittorrent-seed, `.201`
syncthing-protocol, `.203` ingress-nginx (no public role, until removed),
`.254` the Gateway.
LB-IPAM keeps an allocation that matches the request, so adding a pin equal to
the current address moves nothing.

Two announcers answer ARP for these addresses, and both are live:

- Cilium L2 announcements (`infrastructure/cilium/l2-announcement-policy.yaml`:
  every node, LoadBalancer IPs only), one lease per Service;
- kube-vip with `svc_enable=true`, which binds every LoadBalancer IP on its lease
  holder and records it in the Service annotation `kube-vip.io/vipHost`.

With `externalTrafficPolicy: Cluster` and kube-proxy replacement, any node that
answers forwards correctly, so a holder change is not a fault. Choosing one of
the two is on the [roadmap](roadmap.md). L2 announcements do not work with
`externalTrafficPolicy: Local`; no Service here sets it.

## Gateway

The Gateway API, implemented by Cilium (already the CNI; Cilium 1.17, Gateway
API v1.2 CRDs, GatewayClass `cilium`), serves the ten public hostnames. It
replaces ingress-nginx (chart 4.11.3, retired upstream), which still runs on
`.203` with its ten Ingresses but receives no public traffic until it is
removed.

The shared Gateway (`infrastructure/gateway/`):

```
        router 80/443 -> .254
   Gateway `shared` (namespace gateway)
     :80  listener -> HTTPRoute https-redirect -> 301 to https
     :443 listener -> one HTTPRoute per hostname, in the app's namespace
     TLS terminated with one wildcard certificate (*.lilalala.com, DNS-01)
```

- Every route has `parentRefs: shared/https` (`sectionName: https` matters:
  without it a route also answers on plain HTTP and skips the redirect) and
  `timeouts.request: 0s`, which disables Envoy's default 15 s route timeout
  (streams, uploads). Envoy streams request bodies, so Immich uploads have no
  size limit.
- Theater mirrors the Ingress paths: `/` -> Plex, `/arr/<app>` -> each *arr app
  (they run with URL base `/arr/<app>`).
- Argo CD's route targets `argocd-server:80` and works once Argo CD runs with
  `server.insecure: true` (its own change); until then the legacy Ingress
  serves it.

- The redirect's `Location` carries `:443` (`https://<host>:443/`): Cilium
  sets the port explicitly. Same URL; the smoke suite compares URLs without
  default ports.

Sequence (ADR 0007): parallel run on `.202`, proven per hostname with
`curl --resolve <host>:443:192.168.1.202 https://<host>/`; then one change
swapped the pins (ingress-nginx `.254` -> `.203`, Gateway `.202` -> `.254`), so
the router forwards stay valid; revert = swap back. ingress-nginx and its
Ingresses are removed afterwards, in their own change.

## DNS

external-dns v0.15.0, Cloudflare, `policy: upsert-only` (never deletes), TXT
registry with the default owner. Sources: `service`, `ingress` and, in the
layered tree, `gateway-httproute`. Every record points at the single
`--default-targets` address. The redirect route opts out with
`external-dns.alpha.kubernetes.io/controller: none` (v0.15.0 has no `exclude`
annotation); CI requires that on any wildcard route.

## Certificates

cert-manager v1.15.0, ClusterIssuer `letsencrypt`, DNS-01 through Cloudflare.
Today every Ingress has its own certificate; the Gateway uses one wildcard
`Certificate` (`*.lilalala.com` and the apex). DNS-01 works without inbound
port 80, so renewals keep working while the router is being changed.

## Network policy

`infrastructure/network-policies/` is written but not enabled (not in any
layer). Every policy ships with `enableDefaultDeny: {ingress: false, egress:
false}`; enforcement is opt-in per namespace in `90-enforcement.yaml`, which is
also the runbook. NFS and iSCSI are mounted by the kubelet and `iscsid` in the
host network namespace, so a policy never sees that traffic.

## Debugging

```sh
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
hubble observe --server localhost:4245 --namespace theater --follow
hubble observe --server localhost:4245 --verdict DROPPED

kubectl -n gateway get gateway shared -o wide
kubectl get httproute -A
kubectl -n theater get httproute theater -o yaml | yq '.status'
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

A route that renders but serves 404 has almost always failed to attach: check
`Accepted` and `ResolvedRefs` in its status.
