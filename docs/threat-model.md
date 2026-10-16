# Threat model

STRIDE-lite: for each asset, what losing or leaking it costs; for each trust
boundary, the threats that matter there (Spoofing, Tampering, Repudiation,
Information disclosure, Denial of service, Elevation of privilege), the
control in place, the residual risk and the planned change. Planned changes
are tracked in [roadmap.md](roadmap.md). Review this page whenever an entry
point, a credential or an admission path is added or removed.

## Assets

| Asset | Where | Lost | Leaked | Protection |
| --- | --- | --- | --- | --- |
| Photos and videos (Immich originals) | PVC `immich-data` on the NAS | irreplaceable | private family data | restic to S3 and to the NAS, restore rehearsed ([backups.md](backups.md)); Keycloak login |
| Documents (Paperless, Seafile, Syncthing) | iSCSI PVCs on the NAS | hard to replace | private, some official papers | nightly restic to S3; Keycloak login (Paperless, Seafile) |
| age private key | the Mac, the password manager, Secret `argo/sops-age` | every sealed secret must be recreated | every secret in git, including history, is readable | three copies only, mode 600 on the Mac ([secrets.md](secrets.md#the-key)) |
| `talosconfig` | the Mac, the password manager | regenerated from `talos/talsecret.sops.yaml` | full control of every node: reset, upgrade, read machine configs and their keys | mTLS client certificate, role `os:admin`; Talos API reachable from the LAN only |
| Admin kubeconfig | the Mac, the password manager | regenerated with `talosctl kubeconfig` | `cluster-admin` (group `system:masters`); cannot be revoked short of a CA rotation | client certificate; API VIP `192.168.1.11` reachable from the LAN only |
| Supporting credentials | SOPS files ([secrets.md](secrets.md#layout)) | recreated at their source | per credential: DNS (Cloudflare), storage (TrueNAS API key), backups (S3 keys, `RESTIC_PASSWORD`), the auto-rollback GitHub token | sealed in git, rotation steps per credential |
| Write access to `ned-si/homelab` | GitHub | none | `main` is production: a merge deploys | signed commits, required `ci` check, linear history, admins included |

## Trust boundaries

### Internet to the Gateway (80 and 443 on `192.168.1.254`)

- Threats: S (credential stuffing on Keycloak), I (an app's own unauthenticated
  endpoints), D (floods), E (a vulnerable app).
- Control: TLS with the Let's Encrypt wildcard; port 80 only redirects. Immich,
  Mealie, Paperless, Seafile, Grafana and Argo CD log in through Keycloak.
  Plex and Jellyfin keep their own login (their TV apps cannot use SSO), and
  so do the *arr UIs under `theater.lilalala.com/arr/<app>`. PSA `restricted`
  on the `gateway` namespace. DAST (ZAP) runs against the public names.
- Residual: any realm user reaches every Keycloak app; the *arr UIs and the
  Syncthing GUI rely on logins configured inside each app, not in git; no
  security response headers; no brute-force settings in git; no rate limit at
  the Gateway.
- Planned: oauth2-proxy in front of the *arr UIs (`apps/theater/sso.yaml`,
  written, not deployed); per-app access groups enforced at Keycloak; security
  headers on every HTTPRoute with DAST green; Keycloak brute-force protection
  and OTP for the platform clients; default-deny network policies.

### Internet to Syncthing (22000 TCP and UDP on `192.168.1.201`)

- Threats: S (an unknown device), T and I (sync data), D.
- Control: Syncthing's protocol is TLS with mutual device-ID authentication;
  only devices added in the GUI exchange data. The pod has no other public
  port.
- Residual: a Syncthing protocol vulnerability is reachable from the internet;
  a compromised peer device can push deletions to every peer (versioning is
  per folder, in the GUI).
- Planned: the `syncthing` network policy (ingress from `world` on 22000 only),
  non-root under `restricted` PSA.

### Internet to qBittorrent (50000 TCP on `192.168.1.200`)

- Threats: E (a parser bug in the BitTorrent client), I (the swarm sees the WAN
  address), D.
- Control: only the peer port is forwarded; the web UI has no HTTPRoute.
- Residual: an untrusted protocol from the whole internet into a pod in
  `theater`, which also holds the *arr apps and the media share; the pod may
  run as root today.
- Planned: the `theater` network policy, then non-root and resource limits per
  app. Not to be confused with the Talos API, also port 50000, which is not
  forwarded.

### Supply chain: Renovate and GitHub Actions to `main`

- Threats: T (a compromised upstream image, chart or action), E (a workflow
  that runs untrusted code with a write token), R (unsigned changes).
- Control: Renovate (hosted app) opens pull requests that pass the same `ci`
  check as any other and automerge; auto-rollback reverts a broken deploy.
  Actions are pinned by SHA (enforced by the repository setting), the default
  workflow token is read-only, `renovate-render` runs only on Renovate's own
  branches and never with `pull_request_target`. Commits on `main` are signed.
  gitleaks and the Trivy gate run in CI; GitHub secret scanning has push
  protection.
- Residual: no app image is pinned by digest and no signature is verified, so
  a re-pushed tag reaches the cluster on the next pull; automerge trusts CI to
  catch a malicious update, which it does not look for.
- SLSA: this repository builds no artifacts, so it applies SLSA as a consumer
  only: verify upstream provenance and signatures where they are published.
- Planned: digest pins through Renovate; signature verification in Kyverno
  (Audit first) for publishers that sign; a weekly SBOM and CVE scan of the
  running images; OpenSSF Scorecard and CodeQL.

### Argo CD repo-server and KSOPS

- Threats: E (a kustomize exec plugin runs code from the repository), I (the
  repo-server mounts the age key).
- Control: only the three `*/secrets` directories are built by kustomize; every
  other app is pre-rendered into `deploy/`. Writing to `main` already requires
  the protections above. Argo CD AppProjects enumerate destinations.
- Residual: exec plugins are enabled for every kustomize build on the
  repo-server, so a commit that reaches `main` with a malicious generator can
  read the age key ([secrets.md](secrets.md#how-argo-cd-decrypts)); the local
  Argo CD admin account is still enabled beside SSO.
- Planned: disable the local admin account; a per-plugin sidecar only if the
  repository ever gets a second author.

### The LAN

- Threats: S and E from any device on the flat home network, which reaches the
  Talos API (50000 on each node), the Kubernetes API, the NAS (iSCSI, NFS, web
  UI, SSH) and the Turing Pi BMC.
- Control: the Talos and Kubernetes APIs require client certificates; the router
  forwards only the three ports above. Kubernetes Secrets are encrypted at
  rest and the apiserver audit log is on.
- Residual: one flat network with consumer devices on it; the BMC and the NAS
  web UI are reachable by anything on the LAN; the media NFS export is open to
  the whole LAN and the backups export (the NAS copy of the photo library) to
  the whole subnet ([runbooks/nfs-hardening.md](runbooks/nfs-hardening.md));
  the audit log stays on each control plane's eMMC.
- Planned: NFS exports scoped to the node addresses; Kubernetes API login
  through Keycloak OIDC with the admin certificate kept as break-glass;
  central logs including the audit log; SELinux enforcing on Talos.

### The phone over a VPN

- Today: Tailscale ([remote-access.md](remote-access.md)). The operator runs
  in the cluster with no inbound port and no subnet router; the Kubernetes API
  is reachable over the tailnet through its API server proxy, which
  impersonates the tailnet identity. The tailnet policy is in git
  (`bootstrap/tailscale/policy.hujson`). The Talos API stays LAN-only.
- Threats: S and E through a lost or stolen phone that is logged in to the
  tailnet. The phone holds no cluster credential: the proxy maps the tailnet
  login to the group `tailnet-admins`. Removing the device in the admin
  console revokes it.
- Planned: the tailnet policy applied from git by CI; a reduced talosconfig on the phone
  (`os:operator`), never the `os:admin` one.

## Accepted, not planned

- Disk encryption of the Talos `STATE` and `EPHEMERAL` partitions. The RK1
  boards have no TPM, so the key would be derived from the node itself
  (`nodeID`) or stored next to the disk: low value against someone holding the
  board, and one more way to fail at boot. Recommended against.
- No Secure Boot: not available on the RK1.
- `workloadIsolation: false` on Talos: democratic-csi needs the host `iscsid`
  ([talos.md](talos.md)).

## Why it is like this

- STRIDE per boundary, not per component: a one-person homelab has few entry
  points and many components, and the boundaries are where a control either
  exists or does not. Rejected: a full data-flow-diagram model, which would rot
  faster than it is read.
- Residual risks are listed with their planned change, so this page doubles as
  the security backlog's reason for existing.
