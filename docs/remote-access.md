# Remote access

Web UIs are public on the shared Gateway behind Keycloak, gated by group;
`kubectl` and `talosctl` go through the tailnet only
([decisions.md](decisions.md#uis-public-behind-sso-cluster-apis-on-the-tailnet)).
The cluster is on the tailnet `ned-si.github` through the Tailscale
Kubernetes operator. Nothing extra is published on the router for it: the
operator and its proxies dial out to Tailscale.

| Public host | What | Who |
| --- | --- | --- |
| `headlamp.lilalala.com` | Headlamp, read-only Kubernetes web UI | Keycloak group `admins` |

| Tailnet host | What | Who |
| --- | --- | --- |
| `tailscale-operator` | Kubernetes API server proxy (`kubectl`, k9s) | owner and admins of the tailnet, as `tailnet-admins` (cluster-admin) |
| `home-exit-0`, `home-exit-1` | exit nodes: internet through the home connection | tailnet members |
| `talos-cp-1` … `talos-cp-3`, `talos-w-1` | the Talos API of each node (`talosctl`), port 50000 | owner and admins of the tailnet, then the `talosconfig` client certificate |

## How it works

- `platform/tailscale-operator` (Argo CD app `tailscale-operator`, namespace
  `tailscale`): the official chart, versions and image digests pinned in
  `values.yaml`. Every pod passes Pod Security `restricted`.
- OAuth client: admin console, Settings → Trust credentials. Scopes Devices
  Core write, Auth Keys write, Services write; tag `tag:k8s-operator`. Sealed
  in `platform/secrets/tailscale-operator.sops.yaml` (Secret
  `tailscale/operator-oauth`).
- API server proxy, in the operator pod, auth mode. It drops the client's
  credentials and impersonates the tailnet user with the groups the tailnet
  policy grants. `tailnet-admins` is bound to `cluster-admin` in
  `platform/tailscale-operator/resources/rbac.yaml`. A device without a grant
  is denied.
- Tailscale Ingress (class `tailscale`): one proxy pod per Ingress, tagged
  `tag:k8s`, HTTPS on `https://<host>.<tailnet>.ts.net` with a Let's Encrypt
  certificate. Proxies use the ProxyClass `restricted` (userspace mode, no
  privileges).

## Headlamp

`platform/headlamp` (Argo CD app `headlamp`, namespace `headlamp`): the
official chart, version and image digest pinned. One URL,
`https://headlamp.lilalala.com`: an HTTPRoute on the shared Gateway with the
security headers, published by external-dns, scanned by the weekly DAST.

```text
browser --443--> Gateway (HTTPRoute headlamp) --> headlamp-sso (oauth2-proxy) --> headlamp
```

- Login: the oauth2-proxy `headlamp-sso` with the Keycloak client `headlamp`
  (realm code: `proxy_clients`, `platform_clients`, `access.conf`). Only the
  group `admins` gets in; as a platform client, a login older than 12 hours
  is asked again.
- Rights: Headlamp uses its own ServiceAccount for every user
  (`-unsafe-use-service-account-token`, `-proxy-auth`): `view` plus
  `headlamp-read` (nodes, storage, CRDs). It can list pods, read logs and
  events; it cannot read Secrets, exec, or change anything. `headlamp-read`
  aggregates every ClusterRole labelled
  `homelab.lilalala.com/aggregate-to-headlamp: "true"`
  (`platform/headlamp/resources/rbac.yaml`): Gateway API, Argo CD, CNPG,
  Cilium, cert-manager, tuppr, Prometheus Operator, policy and Trivy
  reports, Tailscale. To show a new CRD, add a labelled ClusterRole with
  get/list/watch. Changes go
  through git, or `kubectl` over the API proxy.
- Network: CiliumNetworkPolicies with default-deny ingress. Only the
  Gateway reaches `headlamp-sso`, and only `headlamp-sso` reaches Headlamp,
  which trusts the identity headers it receives.
- The proxy accepts an unverified email in the ID token
  (`insecureAllowUnverifiedEmail`): users are created by hand without email
  verification, and access is the group, never the email.
- When Keycloak is down, Headlamp is unavailable; use `kubectl`.

## Exit node

The Connector `home-exit` (`platform/tailscale-operator/resources/exit-node.yaml`)
runs two exit nodes, `home-exit-0` and `home-exit-1`, on different nodes when
they can be. Picking one sends the device's internet traffic out through the
home connection: the sites you visit see the home WAN IP.

- When: untrusted Wi-Fi (hotel, train, café), or a service that needs a Swiss
  IP. At home it adds nothing.
- Use it: Tailscale app → Exit node → `home-exit-0` (or `-1`). Turn it off
  the same way. On a Mac: `tailscale set --exit-node=home-exit-0`, and
  `tailscale set --exit-node=` to stop.
- Allow LAN access (a toggle next to the exit node in the app): keeps the
  local network you are on (a hotel printer, a Chromecast) reachable
  outside the tunnel. Leave it off on untrusted networks.
- It depends on the cluster: with both nodes down, the NAS or the router
  off, an exit-node device has no internet until you turn the exit node off.
- Scope: the policy grants `autogroup:internet` only. The home LAN and the
  cluster are not reachable through it; use the tailnet hosts above.
- `tag:exit` is auto-approved (`autoApprovers.exitNode`), so a new replica
  needs no click in the admin console.
- Pod Security: the operator gives Connector pods a privileged `sysctler`
  init container that no ProxyClass can remove, so the namespace `tailscale`
  enforces `privileged` (warn and audit stay `restricted`). The exit node's
  main container runs tailscaled in userspace mode, non-root, with no
  capabilities. No network policy covers `tailscale`, so its egress is open.

## Tailnet policy

`bootstrap/tailscale/policy.hujson` is the policy, in git. It replaces the
default allow-all:

- a member's own devices reach each other (as before);
- members reach `tag:k8s` (the Ingress proxies) on TCP 443 only;
- members use the exit nodes (`tag:exit`, auto-approved) for
  `autogroup:internet`;
- the owner and admins reach `tag:k8s-operator` on 443, with the Kubernetes
  capability `impersonate: groups: [tailnet-admins]`;
- the owner and admins reach `tag:talos` (the nodes) on TCP 50000 only;
  `tag:talos` reaches nothing.

Apply a change: edit the file in a pull request. The workflow
`.github/workflows/tailscale-policy.yaml` tests it against the tailnet on the
PR and applies it on merge to main; a rejected policy fails the run, posts to
ntfy, and the tailnet keeps the old one. Edits made in the admin console are
overwritten by the next apply.

The workflow uses its own OAuth client (admin console → Settings → Trust
credentials → Credential → OAuth, scope Policy File write), in the
repository secrets `TS_POLICY_OAUTH_CLIENT_ID` and `TS_POLICY_OAUTH_SECRET`.
Without them it skips with a notice; paste the file in Access controls →
JSON editor instead.

Tailnet settings this needs (admin console → DNS): MagicDNS on, HTTPS
Certificates on.

### Address range

The policy's `nodeAttrs` `ipPool` keeps every device in 100.96.0.0–
100.127.255.255 (minus the blocks Tailscale reserves). A corporate VPN client
on a member's laptop routes 100.72.0.0–100.95.255.255 into its own tunnel, so
a tailnet device in that range times out from that laptop while the others
work. The pool applies to new devices; an existing device keeps its address
until it is changed (admin console → Machines → the device → Edit IPv4, or
the API `POST /api/v2/device/<id>/ip`).

Check from the Mac that a tailnet address goes to Tailscale:

```sh
route -n get <tailnet-ip> | grep interface
```

Expected: the same `utunN` as `route -n get 100.100.100.100` (Tailscale's
DNS address).

## Mac

1. Install Tailscale and log in with the tailnet account: the app from
   tailscale.com/download, or the Homebrew CLI, whose daemon must run as a
   root service:

   ```sh
   brew install tailscale
   sudo brew services start tailscale
   sudo tailscale up
   tailscale status
   ```

   Expected: `tailscale status` lists this Mac and `tailscale-operator`.
   `dial unix /var/run/tailscaled.socket: no such file` means the daemon is
   not running.
2. Write the kubeconfig context (it adds `tailscale-operator.<tailnet>.ts.net`
   to `~/.kube/config` and switches to it):

   ```sh
   tailscale configure kubeconfig tailscale-operator
   kubectl get nodes
   ```

   Expected: the four nodes `Ready`. `kubectl auth whoami` shows your tailnet
   login and the group `tailnet-admins`. A `TLS handshake timeout` on the
   first request to a new tailnet host is its Let's Encrypt certificate
   being issued (up to a minute); run the command again.
3. Switch back to the LAN admin context with `kubectl config use-context
   <context>` when you need it; both work at home.

## Phone (Android, Pixel)

1. Tailscale app from the Play Store, log in, toggle it on.
2. Browser: Headlamp needs no tailnet: open `https://headlamp.lilalala.com`,
   log in with Keycloak, then Workloads → Pods → a pod → Logs, and Cluster →
   Events. Add it to the home screen (browser menu → Add to Home screen). The
   tailnet hosts above by their full name, `https://<host>.<tailnet>.ts.net`.
3. `kubectl`, k9s and `talosctl` in Termux (F-Droid build):

   ```sh
   pkg install kubectl k9s
   ```

   Copy the kubeconfig written on the Mac (step 2 above, only the
   `tailscale-operator` cluster, context and user; it holds no credential) to
   `~/.kube/config` in Termux, then `kubectl get nodes`. Termux uses the
   phone's Tailscale VPN, so the name resolves through MagicDNS.
4. Notifications: the ntfy app (alerts) and the GitHub app (pull requests).

iPhone: the same with the App Store Tailscale app. There is no Termux; a
kubeconfig-capable SSH or Kubernetes client app works the same way.

`talosctl` over the tailnet needs a `talosconfig`, which holds the `os:admin`
key: keep it off the phone until it has a reduced one
([access-identity](../.kiro/specs/access-identity/tasks.md), task 21).

## Talos API

The debugging path when Kubernetes itself is down: `talosctl` reaches every
node over the tailnet, from anywhere, with the same mTLS `talosconfig` as on
the LAN. Never on the internet: no port forward, and the tailnet policy
admits the owner and admins on TCP 50000 only.

- Each node runs the official `siderolabs/tailscale` system extension, in the
  Image Factory schematic of `talos/talconfig.yaml`. Its
  `ExtensionServiceConfig` (`extensionServices` per node) logs in as
  `talos-<node>` (`talos-cp-1`, `talos-cp-2`, `talos-cp-3`, `talos-w-1`) with
  `tag:talos`, once; the node key then stays in the extension's state on the
  EPHEMERAL partition. Nodes do not take MagicDNS or routes from the tailnet.
- Auth key: the operator's OAuth client secret (it owns `tag:talos`), with
  `?ephemeral=false&preauthorized=true`, sealed in `talos/talenv.sops.yaml`
  (`TS_OAUTH_SECRET`). talhelper substitutes it at `task talos:genconfig`;
  without the age key (CI, the drift check) a placeholder renders, and the
  drift check masks the line. Rotating the OAuth client means both
  `platform/secrets/tailscale-operator.sops.yaml` and this file; nodes already
  logged in keep working.
- apid's certificate carries `talos-<node>` and
  `talos-<node>.tail32a1fc.ts.net` (`certSANs`), so `talosctl` verifies it.
  Every node maps those names to the LAN addresses
  (`talos/patches/talosctl/tailnet-hosts.yaml`): a request for another node
  goes over the LAN from the endpoint.
- Kubernetes and etcd stay on the LAN (`talos/patches/node-ip.yaml`,
  `etcd-subnet.yaml`): the tailnet address never becomes a node or peer IP.

Mac, once: a context `homelab-ts` next to the LAN one in the same
`talosconfig`, with the tailnet names as endpoints (prints nothing secret):

```sh
f=~/homelab-backups/talos/talosconfig
yq '.contexts | keys' "$f"          # the LAN context, e.g. homelab
yq -i '.contexts["homelab-ts"] = .contexts["homelab"] |
  .contexts["homelab-ts"].endpoints = ["talos-cp-1.tail32a1fc.ts.net",
    "talos-cp-2.tail32a1fc.ts.net", "talos-cp-3.tail32a1fc.ts.net"]' "$f"
talosctl --talosconfig "$f" --context homelab-ts -n talos-w-1 version
talosctl --talosconfig "$f" --context homelab-ts -n talos-cp-3 health \
  --control-plane-nodes 192.168.1.247,192.168.1.238,192.168.1.239 \
  --worker-nodes 192.168.1.240
```

Expected: a `Server` block on `talosVersion`, and every health check `OK`
(`health` runs on the node, so it needs no Kubernetes access from the Mac).
Give `health` the LAN addresses: without them it takes each node's first
discovered address, which can be its tailnet one, and nodes do not reach
each other over the tailnet (`tag:talos` has no grant), so it times out.
For the same reason KubePrism lists the tailnet addresses as API endpoints
and skips them as unreachable; the LAN ones serve
([platform-talos](../.kiro/specs/platform-talos/tasks.md), task 20).
A node down: point `-e` and `-n` at a live one. With Tailscale itself down
on a node, use the LAN context or the BMC (`docs/runbooks/node-power-cycle.md`).

## Revoke a device

Admin console → Machines → the device → Remove. Its tailnet identity goes,
and with it every grant above. Nothing in the cluster holds a credential for
it.

## Why it is like this

- Tailscale operator rather than a subnet router or a port forward: no
  inbound port, per-device identity, and the API proxy maps that identity to
  RBAC, so a phone holds no long-lived cluster credential.
- Auth mode rather than `noauth`: with `noauth` every client needs its own
  Kubernetes token; auth mode reuses the tailnet login and policy.
- UIs are public behind Keycloak, the cluster APIs are tailnet-only
  ([decisions.md](decisions.md#uis-public-behind-sso-cluster-apis-on-the-tailnet)).
  Headlamp moved from its tailnet Ingress to the Gateway: one URL, the same
  login as Argo CD and Grafana, and no Tailscale app needed to read the
  cluster from a phone.
- The policy job has its own OAuth client rather than a Policy File scope
  on the operator's: a leaked operator credential cannot rewrite the policy.
- The Talos API on the tailnet rather than LAN-only: it is the way in when
  Kubernetes, and with it the operator's proxies, is down. The extension is
  on the host, independent of the cluster. Its exposure is the tailnet
  policy plus mTLS with the `os:admin` certificate.
- The OAuth client secret rather than a reusable auth key: no key that
  expires every 90 days. The cost: every node's machine config holds a
  secret that can mint `tag:k8s`, `tag:exit` and `tag:talos` keys, readable
  by `os:admin` (which already holds the cluster CAs).
