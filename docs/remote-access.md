# Remote access

The cluster is on the tailnet `ned-si.github` through the Tailscale
Kubernetes operator. Nothing extra is published on the router or the
internet: the operator and its proxies dial out to Tailscale.

| Tailnet host | What | Who |
| --- | --- | --- |
| `tailscale-operator` | Kubernetes API server proxy (`kubectl`, k9s) | owner and admins of the tailnet, as `tailnet-admins` (cluster-admin) |
| `headlamp` | Headlamp, read-only Kubernetes web UI | tailnet members, then Keycloak group `admins` |
| `home-exit-0`, `home-exit-1` | exit nodes: internet through the home connection | tailnet members |

The public hostnames (`*.lilalala.com`) stay as they are; which admin UIs
become tailnet-only is a later decision.

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
official chart, version and image digest pinned. Tailnet only: a Tailscale
Ingress, no HTTPRoute on the public Gateway.

```text
phone --tailnet--> Ingress proxy (tailscale) --> headlamp-sso (oauth2-proxy) --> headlamp
```

- Login: the oauth2-proxy `headlamp-sso` with the Keycloak client `headlamp`
  (realm code: `proxy_clients`, `platform_clients`, `access.conf`). Only the
  group `admins` gets in; as a platform client, a login older than 12 hours
  is asked again.
- Rights: Headlamp uses its own ServiceAccount for every user
  (`-unsafe-use-service-account-token`, `-proxy-auth`): `view` plus
  `headlamp-read` (nodes, storage, CRDs). It can list pods, read logs and
  events; it cannot read Secrets, exec, or change anything. Changes go
  through git, or `kubectl` over the API proxy.
- Network: CiliumNetworkPolicies with default-deny ingress. Only the Ingress
  proxies reach `headlamp-sso`, and only `headlamp-sso` reaches Headlamp,
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
  capability `impersonate: groups: [tailnet-admins]`.

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
2. Browser: the tailnet hosts above, by their full name
   `https://<host>.<tailnet>.ts.net`. Headlamp: open
   `https://headlamp.<tailnet>.ts.net`, log in with Keycloak, then Workloads →
   Pods → a pod → Logs, and Cluster → Events. Add it to the home screen
   (browser menu → Add to Home screen).
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

`talosctl` needs the Talos API, which is LAN-only: at home only.

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
- Argo CD and Grafana stay on their public hostnames only. Each has a single
  external URL for its Keycloak redirect (`url` in argocd-cm, Grafana
  `root_url`), so a tailnet hostname next to the public one would bounce the
  login back to the public host. Making them tailnet-only means moving that
  URL and removing the HTTPRoute, one app at a time.
- The policy job has its own OAuth client rather than a Policy File scope
  on the operator's: a leaked operator credential cannot rewrite the policy.
