# Networking

## Why Ingress is gone

The Kubernetes project **archived ingress-nginx in March 2026**. Best-effort
maintenance ended, the repository is read-only, and there will be no further
releases — including no security patches. Roughly half of cloud-native
deployments were still using it at the time.

So this is not a modernisation for its own sake. Running it means running an
internet-facing reverse proxy that will never be patched again.

The replacement is **Gateway API**, implemented by **Cilium** — which is already
the CNI here, so there is no separate ingress controller Deployment at all.

## The shape of it

```
        internet
           │
           │  router forwards 80/443
           ▼
   192.168.1.254            ← LoadBalancer IP from the `gateway` pool,
   (Gateway `shared`)          announced on the LAN by Cilium L2
           │
   ┌───────┴────────┐
   │  :80 listener  │──→ HTTPRoute `https-redirect`  →  301 to https
   │ :443 listener  │──→ every application HTTPRoute
   └────────────────┘
     TLS terminated here with one wildcard cert (*.lilalala.com)
```

One Gateway, one certificate, one address. Each application contributes an
`HTTPRoute` in its own namespace.

## What each app no longer has to carry

Under Ingress, every single service repeated four things:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt
  external-dns.alpha.kubernetes.io/target: <the WAN IP, pasted into every file>
  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
  nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
```

All four are now properties of the Gateway, so an `HTTPRoute` is just a hostname
and a backend:

```yaml
spec:
  parentRefs:
    - name: shared
      namespace: gateway
      sectionName: https
  hostnames: [sonarr.lilalala.com]
  rules:
    - backendRefs:
        - name: sonarr
          port: 8989
```

The practical win: **no HTTPRoute and no application manifest carries the WAN IP.**
It is a single annotation on the Gateway. That matters immediately, because it
changes when you move house.

Two copies of the value are functional, not one: the source in
`infrastructure/gateway/gateway.yaml` and the rendered
`deploy/infrastructure/gateway/manifests.yaml`, which is the one Argo CD actually
reads. Editing the source without `task render` changes nothing in the cluster and
fails CI. `grep -rn` for the address also finds it in explanatory comments in
`infrastructure/external-dns/values.yaml` and `platform/keycloak/httproute.yaml`
and in this documentation; those are inert, and they are worth updating at the same
time so a future reader is not misled by a stale one.

### Two details worth knowing

- **`sectionName: https` is not optional.** Omit it and the route attaches to
  *both* listeners, so it answers on plain HTTP too and bypasses the redirect.
- **There is no `force-ssl-redirect` annotation.** The redirect is modelled as an
  `HTTPRoute` with a `RequestRedirect` filter attached to the `:80` listener
  (`infrastructure/gateway/http-redirect.yaml`). One route covers every hostname.
- **No `proxy-body-size` equivalent is needed.** Cilium streams request bodies
  rather than buffering to a limit, so large uploads work untuned. If uploads fail
  at a size boundary, suspect Cloudflare (100MB on the free plan) — which is part
  of why `--cloudflare-proxied=false` is set.

## DNS

external-dns uses the `gateway-httproute` source: it reads hostnames from
HTTPRoutes and takes the address from the parent Gateway.

The address comes from the `external-dns.alpha.kubernetes.io/target` annotation on
the **Gateway**. That annotation is only honoured there — external-dns
deliberately ignores it on HTTPRoute
([external-dns#4056](https://github.com/kubernetes-sigs/external-dns/issues/4056)).
Which is convenient: it is *why* no route has to carry the address.

Records are owned via `txtOwnerId: homelab` and `txtPrefix: k8s-`, with
`policy: sync` so external-dns cleans up after itself. `upsert-only` would leave
stale records behind after the move.

## Hostnames

There is no hostname list in this document, on purpose. Ask the manifests:

```sh
scripts/published-hostnames.sh
```

It derives the list from `spec.hostnames` on every HTTPRoute in `deploy/`, which
is what the Gateway actually terminates TLS for, and it is the single source the
TLS check and the DAST workflow both consume. Three hand-maintained copies of that
list used to exist and already disagreed with each other.

Two things it will not show you, because they are not HTTPRoutes:

- **Syncthing's sync protocol** and **qBittorrent's peer port** are raw TCP/UDP on
  LoadBalancer addresses from the `services` pool. No hostname, no TLS
  termination, and they need router port forwards rather than DNS.
- `*.lilalala.com`, which is the Gateway listener's SNI and the hostname of the
  `https-redirect` route. Not a name you can connect to.

Each *arr app has its own subdomain, served at `/`. The alternative — paths under
`theater.lilalala.com/arr/<app>` — forces each app to run with a `URLBASE`, which
breaks anything generating absolute URLs and makes every API path in a runbook
wrong by a prefix.

## LoadBalancer IPs

Two Cilium pools, gated by a label selector so a stray Service cannot claim the
address the whole site depends on:

| Pool | Range | Who |
|---|---|---|
| `gateway` | `192.168.1.254/32` | the shared Gateway, only |
| `services` | `192.168.2.0/24` | non-HTTP: Syncthing sync (`.0`), qBittorrent peer port (`.1`) |

Claim from a pool with `homelab.lilalala.com/lb-pool: <pool>` as a **label** on the
Service. The Gateway does it through `spec.infrastructure.labels`, which Cilium
propagates onto the Service it generates.

**The `services` pool is a separate /24, not a slice of the LAN, and that is the
whole point.** A slice of `192.168.1.0/24` was rejected because any range large
enough to be useful collides with the node addresses — `192.168.1.240-249` would
have overlapped `homelab-w-1` (.240) and `homelab-cp-1` (.247), handing a
LoadBalancer a node's own IP. `infrastructure/cilium/ip-pools.yaml` records that,
and the node addresses, next to the values.

The cost is that **the router must actually route `192.168.2.0/24` to the LAN
segment**, and the port forwards must target addresses in it. qBittorrent currently
reports `connection_status: firewalled`, which is the symptom of that route or
forward being absent — see
[runbooks/arr-qbittorrent.md](runbooks/arr-qbittorrent.md).

### The L2 announcement trap

L2 announcements are **incompatible with `externalTrafficPolicy: Local`** — IPs get
announced from nodes that have no backing pod, and traffic there is silently
dropped. No Service in this repo sets it, and the old README's note about removing
it was correct.

Also: announcements only work from interfaces matching the `interfaces` regex in
`infrastructure/cilium/l2-announcement-policy.yaml`. Verify the actual NIC names:

```sh
kubectl -n kube-system exec ds/cilium -- ip -br link
```

## Certificates

One wildcard `Certificate` for `*.lilalala.com` plus the apex, issued by
`letsencrypt` via **DNS-01**. DNS-01 rather than HTTP-01 for two reasons: it is the
only solver that can issue a wildcard, and it does not need inbound port 80 — so
renewals keep working while the router is being reconfigured. Which is exactly the
situation during a house move.

**While bringing the cluster up, point `issuerRef.name` at `letsencrypt-staging`
first.** Production Let's Encrypt allows 50 certificates per registered domain per
week and a misconfigured solver burns that fast. Switch to `letsencrypt` once you
see `Ready=True`.

## Moving house: checklist

In order.

1. **Find the new LAN subnet and pick the addresses.** They must sit inside the
   subnet but outside the router's DHCP range — otherwise the router will
   eventually lease one to a laptop and you will spend an evening on
   "intermittent" outages.

2. **Update the site-specific files.** The authoritative list is
   `grep -rn SITE-SPECIFIC` and the map is in
   [architecture.md](architecture.md#site-specific-values). Note the TrueNAS
   address appears in **three** manifests plus the encrypted democratic-csi
   secret, and both LB pool ranges must land inside the new subnet and outside
   DHCP.

3. **Check the NIC name** before assuming the L2 policy still matches
   (`ip -br link`, above).

4. **Re-render.** `task render`. Argo CD reads `deploy/`, so a source edit alone
   does nothing.

5. **Re-point the router**: forward 80/443 to the Gateway address, 22000 TCP+UDP
   to the Syncthing address, the qBittorrent peer port, and add the static route
   for the `services` pool's /24.

6. **Commit, then move the `deployed` tag.** external-dns rewrites every Cloudflare
   record from the Gateway annotation. Merging to `main` alone does not deploy —
   see [ADR 0001](adr/0001-deploy-by-moving-a-git-tag.md).

7. **Re-tighten the NFS export** to the new node addresses — see
   [runbooks/nfs-hardening.md](runbooks/nfs-hardening.md).

If the new connection has a **dynamic** WAN address, set the target annotation to a
hostname maintained by the router's own DDNS and let external-dns manage a CNAME at
it, rather than editing the file on every lease change.

For the full physical bring-up sequence, use
[runbooks/restart-after-move.md](runbooks/restart-after-move.md); this list is only
the network re-addressing.

## Network policy

`infrastructure/network-policies/` covers six application namespaces. **Syncing it
changes no traffic** — every policy ships with
`enableDefaultDeny: {ingress: false, egress: false}`, so it contributes an
allow-list without putting anything into default-deny.

Enforcement is opt-in per namespace, per direction, by flipping one `false` to
`true` in **`infrastructure/network-policies/90-enforcement.yaml`**. There is no
other switch, and that file is the runbook: rollout order, the Cilium semantics it
depends on, the drop-debugging commands, and the one-command emergency revert.
Read it rather than this page — it is not summarised here because a summary is how
a safety switch gets described wrongly.

Two limits worth knowing before you start:

- NFS and iSCSI are mounted by the kubelet and `iscsid` in the **host** network
  namespace, so a `CiliumNetworkPolicy` never sees that traffic. Enforcement stops
  a *pod* reaching the NAS, not a *node*.
- The platform namespaces (cert-manager, external-dns, gateway, democratic-csi,
  cnpg-system, monitoring, keycloak, backup-verify, kube-system, argocd) have no
  policies and stay allow-all. That is the intended starting point, not an
  oversight.

## Debugging

Hubble is enabled, which is usually faster than reading manifests:

```sh
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
hubble observe --server localhost:4245 --namespace theater --follow
hubble observe --server localhost:4245 --verdict DROPPED

# From the datapath, when Hubble itself is what you suspect. Run it against the
# agent on the node hosting the pod.
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium monitor --type drop
```

A `DROPPED` verdict of `Policy denied` / `DENIED_BY_POLICY` means a rule is missing
from `infrastructure/network-policies/`. `Stale or unroutable IP` and
`Unsupported L3 protocol` are not policy problems and adding rules will not fix
them.

Gateway and route status:

```sh
kubectl -n gateway get gateway shared -o wide
kubectl get httproute -A
# Did the route actually attach? Look at status.parents[].conditions
kubectl -n theater get httproute sonarr -o yaml | yq '.status'
```

A route that renders fine but serves 404 has almost always failed to attach —
check `Accepted` and `ResolvedRefs` in that status block.
