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
  external-dns.alpha.kubernetes.io/target: 188.155.74.203   # the WAN IP!
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

The practical win: **the WAN IP existed in a dozen files and now exists in one**
(`infrastructure/gateway/gateway.yaml`). That matters immediately, because it
changes when you move house.

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
Which is convenient: it is *why* there is a single copy of the WAN IP.

Records are owned via `txtOwnerId: homelab` and `txtPrefix: k8s-`, with
`policy: sync` so external-dns cleans up after itself. `upsert-only` would leave
stale records behind after the move.

## Hostnames

| Hostname | Service |
|---|---|
| `argo` | Argo CD |
| `auth` | Keycloak |
| `grafana` | Grafana |
| `theater` | Plex |
| `cinema` | Jellyfin |
| `sonarr` / `radarr` / `lidarr` / `prowlarr` | *arr apps |
| `qbittorrent` | qBittorrent WebUI |
| `media` | Immich |
| `archive` | Paperless |
| `cook` | Mealie |
| `drive` | Seafile |
| `syncthing` | Syncthing UI |
| `sync` | Syncthing protocol (LoadBalancer, not the Gateway) |

**Changed from the old setup:** the *arr apps were served as paths under
`theater.lilalala.com/arr/<app>`, which forced each one to run with a `URLBASE`
and broke anything generating absolute URLs. They now have their own subdomains,
which the wildcard certificate already covers. Update your bookmarks.

## LoadBalancer IPs

Two Cilium pools, gated by a label selector so a stray Service cannot claim the
address the whole site depends on:

| Pool | Range | Who |
|---|---|---|
| `gateway` | `192.168.1.254/32` | the shared Gateway, only |
| `services` | `192.168.1.240-249` | non-HTTP: Syncthing sync, qBittorrent peer port |

Claim from a pool with `homelab.lilalala.com/lb-pool: <pool>` as a **label** on the
Service. The Gateway does it through `spec.infrastructure.labels`, which Cilium
propagates onto the Service it generates.

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

2. **Update the four site-specific files:**

   | File | Value |
   |---|---|
   | `infrastructure/cilium/ip-pools.yaml` | both pool ranges |
   | `infrastructure/cilium/values.yaml` | `k8sServiceHost` (API VIP) |
   | `infrastructure/nfs-storage/nfs-volumes.yaml` | TrueNAS address |
   | `infrastructure/gateway/gateway.yaml` | **the WAN IP** |

   Also `bootstrap/terraform.tfvars` (`api_server_ip`) and the L2 policy's
   `interfaces` regex if the NICs are named differently.

3. **Check the NIC name** before assuming the L2 policy still matches
   (`ip -br link`, above).

4. **Re-point the router**: forward 80/443 to the Gateway address, 22000 TCP+UDP
   to the Syncthing address, and the qBittorrent peer port.

5. **Commit.** external-dns rewrites every Cloudflare record from the Gateway
   annotation. Nothing else needs touching.

6. **Re-tighten the NFS export** to the new node addresses — see
   [runbooks/nfs-hardening.md](runbooks/nfs-hardening.md).

If the new connection has a **dynamic** WAN address, replace the target annotation
with a DDNS setup rather than editing the file on every lease change.

## Debugging

Hubble is enabled, which is usually faster than reading manifests:

```sh
cilium hubble port-forward &
hubble observe --namespace theater --follow
hubble observe --verdict DROPPED
```

Gateway and route status:

```sh
kubectl -n gateway get gateway shared -o wide
kubectl get httproute -A
# Did the route actually attach? Look at status.parents[].conditions
kubectl -n theater get httproute sonarr -o yaml | yq '.status'
```

A route that renders fine but serves 404 has almost always failed to attach —
check `Accepted` and `ResolvedRefs` in that status block.
