# Threat model

STRIDE-lite: for each asset, what losing or leaking it costs; for each trust
boundary, the threats that matter there (Spoofing, Tampering, Repudiation,
Information disclosure, Denial of service, Elevation of privilege), the
control in place, the residual risk and the planned change. Planned changes
are tracked in [roadmap.md](roadmap.md). Review this page whenever an entry
point, a credential or an admission path is added or removed. The argument
that these controls meet the project's security requirements is in
[assurance-case.md](assurance-case.md).

## Assets

| Asset | Where | Lost | Leaked | Protection |
| --- | --- | --- | --- | --- |
| Photos and videos (Immich originals) | PVC `immich-data` on the NAS | irreplaceable | private family data | restic to S3 and to the NAS, restore rehearsed ([backups.md](backups.md)); Keycloak login |
| Documents (Paperless) | iSCSI PVCs `paperless-media`, `paperless-data`, `paperless-export` on the NAS | hard to replace | private: official, financial and medical papers | nightly restic to S3 of a consistent database copy, the files and a plain-file export, restored into a throwaway Paperless every month ([paperless.md](paperless.md#backups-export-and-restore)); Keycloak login, then one editor and view-only readers, the `private` tag hiding a document from them. Residual: the `automation` API token (a Paperless superuser) reads and changes every document through the public `https://archive.lilalala.com/api/`, so a leaked token works from the internet until it is deleted ([secrets.md](secrets.md#rotating-a-credential)); the `canary` API token (Secret `paperless-canary`, no group) can add, view and delete documents through the same public `/api/`, which limits it to its own pages but lets a leaked copy upload files from the internet until it is deleted; egress from the `paperless` namespace is not enforced while its allow-list is in audit mode (#709), and the allow-list itself permits HTTPS to the whole internet (OIDC, S3), so a compromised pod can send documents out |
| Synced files (Syncthing) | iSCSI PVCs on the NAS | hard to replace | private | nightly restic to S3; Keycloak login (the Syncthing GUI) |
| age private key | the Mac, the password manager, Secret `argo/sops-age` | every sealed secret must be recreated | every secret in git, including history, is readable | three copies only, mode 600 on the Mac ([secrets.md](secrets.md#the-key)) |
| `talosconfig` | the Mac, the password manager | regenerated from `talos/talsecret.sops.yaml` | full control of every node: reset, upgrade, read machine configs and their keys | mTLS client certificate, role `os:admin`; Talos API reachable from the LAN and, for the tailnet owner and admins, over the tailnet (`tag:talos`, TCP 50000) |
| Admin kubeconfig | the Mac, the password manager | regenerated with `talosctl kubeconfig` | `cluster-admin` (group `system:masters`); cannot be revoked short of a CA rotation | client certificate; API VIP `192.168.1.11` reachable from the LAN only |
| Supporting credentials | SOPS files ([secrets.md](secrets.md#layout)) | recreated at their source | per credential: DNS (Cloudflare), storage (TrueNAS API key), backups (S3 keys, `RESTIC_PASSWORD`), the auto-rollback GitHub token | sealed in git, rotation steps per credential |
| Write access to `ned-si/homelab` | GitHub | none | `main` is production: a merge deploys | signed commits, required `ci` check, linear history, admins included |

## Trust boundaries

### Internet to the Gateway (80 and 443 on `192.168.1.254`)

- Threats: S (credential stuffing on Keycloak), I (an app's own unauthenticated
  endpoints), D (floods), E (a vulnerable app).
- Control: TLS with the Let's Encrypt wildcard; port 80 only redirects. Immich,
  Mealie, Paperless, Grafana and Argo CD log in through Keycloak, and the
  Syncthing GUI sits behind an oauth2-proxy for group `admins`; members of
  `admins` and the Keycloak admin (realm `master`) need a TOTP code after the
  password ([keycloak-otp.md](runbooks/keycloak-otp.md)). Both Keycloak
  realms run brute-force detection and allow no password grant.
  The *arr UIs, Bazarr and LazyLibrarian under
  `theater.lilalala.com/arr/<app>` sit behind an oauth2-proxy for groups
  `admins` or `TheaterAdmins` (`apps/theater/sso.yaml`), their only login;
  qBittorrent keeps its form login behind the same proxy. Plex and Jellyfin
  keep their own login (their TV apps cannot use SSO). The public dashboard
  `homelab.nedsi.io` has no login: its web pod holds no Secret and no token,
  answers only `GET` and `HEAD` and has no egress; it takes figures only on
  its push port 9465, from the collector pod (enforced network policy), each
  signed with the Ed25519 key in the Secret `homelab-dashboard-push` and
  checked against the public keys in the ConfigMap
  `homelab-dashboard-push-pubkey`. Every HTTPRoute sets
  security response headers. PSA `restricted` on the `gateway` namespace.
  Ingress and egress default-deny network policies in every application
  namespace ([networking.md](networking.md)). DAST (ZAP) runs against the
  public names.
- Residual: any realm user reaches every Keycloak app except the proxied
  ones; Plex and Jellyfin logins are configured inside each app, not in git;
  no rate limit at the Gateway; a leaked push key lets a pod that can reach
  port 9465 publish false figures until the key is rotated
  ([homelab-dashboard design](../.kiro/specs/homelab-dashboard/design.md#push-receiver)).
- Planned: per-app access groups enforced at Keycloak.

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

### Internet to Jamulus (41124 UDP on `192.168.1.202`)

The router forwards the port only while the operator keeps the rule for
remote players; without it, only the LAN reaches the server.

- Threats: S (anyone who knows host and port joins, under any name, with no
  login), I (the mix can be heard; the player list, with name, country,
  city, instrument and skill, and the server version can be read without
  joining and without a log line, through `CLM_REQ_CONN_CLIENTS_LIST` and
  `CLM_REQ_VERSION_AND_OS`), D (the 8 channels filled, which locks the band
  out; the home uplink flooded; the server used as a UDP reflector against
  a spoofed source, with a client list larger than the request), E (a
  parser bug in the server).
- Control: not registered in any directory (no `--directoryaddress`,
  checked by `tests/test_jamulus.py`); the non-default port 41124, the only
  admitted ingress; 8 channels; the JSON-RPC API off and no admin
  interface over UDP. The pod runs as UID 65532 with a read-only root, no
  capabilities, no ServiceAccount token, no Secret and no volume but a
  16 MiB `/tmp`, under PSA `restricted` and Tetragon; enforced egress
  allows only cluster DNS, so it reaches no other app, LAN host or cluster
  API, and requests to send to a third address (`CLM_SEND_EMPTY_MESSAGE`)
  are dropped. Each audio connection is logged to SigNoz. The router rule
  is the operator's switch.
- Residual: Jamulus has no password, allow-list or rate limit, and host
  and port are public in this repository, so the server is open to anyone
  while the router rule exists; the non-default port only stops untargeted
  scans of 22124. Reading the player list or the version leaves no log
  line, and with `externalTrafficPolicy: Cluster` a logged address can be
  a node address.
- Planned: none. If strangers show up, the fallback is the tailnet only
  (a Tailscale-exposed Service) instead of the router rule.

### Supply chain: Renovate and GitHub Actions to `main`

- Threats: T (a compromised upstream image, chart or action), E (a workflow
  that runs untrusted code with a write token), R (unsigned changes).
- Control: Renovate (hosted app) opens pull requests that pass the same `ci`
  check as any other and automerge; auto-rollback reverts a broken deploy.
  Actions are pinned by SHA (enforced by the repository setting), the default
  workflow token is read-only, `renovate-render` runs only on Renovate's own
  branches and never with `pull_request_target`. Commits on `main` are signed.
  gitleaks and the Trivy gate run in CI; GitHub secret scanning has push
  protection. The repo-policy parsers are fuzzed with Atheris on every change
  to them and nightly (workflow `fuzz`).
- Control (images): every image the repository names in its manifests and
  Helm values is pinned by digest (`repo-policy` rule `image-digest`), so a
  tag re-pushed upstream arrives as a Renovate pull request, not on the next
  pull. Upstream charts are pinned by version. Three images are built here (site,
  dashboard, Jamulus) at SLSA Build L2: GitHub-hosted builds with signed
  provenance, signed keyless with cosign, their identities in
  `ci/image-signers.yaml`. Kyverno `verify-own-images` checks the signature
  and the provenance of every `ghcr.io/ned-si/*` image in the cluster. The
  weekly `image-provenance` workflow lists which upstream images are signed
  and by whom; trivy-operator rescans every running image daily
  ([observability.md](observability.md)). OpenSSF Scorecard and CodeQL run
  on `main` (workflows `scorecard` and `codeql`).
- Residual: `verify-own-images` is in Audit, fail-open, so an unsigned image
  is reported, not refused; most upstream images publish no signature, so
  their digest proves only that the bytes did not change since Renovate saw
  them; images that an upstream chart sets from its own defaults (Argo CD,
  cert-manager, Grafana, Prometheus, external-dns, the CSI sidecars and
  others, listed as "not checked" in `ci/image-signers.yaml`) carry only the
  chart's tag, which `image-digest` cannot see, so a tag re-pushed upstream
  reaches a node on its next pull; automerge trusts CI to catch a malicious update, which it does not
  look for.
- Planned: signature verification enforced for the own images, then for the
  upstream publishers that sign (#725,
  [image-provenance](../.kiro/specs/image-provenance/)).

### Argo CD repo-server and KSOPS

- Threats: E (a kustomize exec plugin runs code from the repository), I (the
  repo-server mounts the age key).
- Control: only the three `*/secrets` directories are built by kustomize; every
  other app is pre-rendered into `deploy/`. Writing to `main` already requires
  the protections above. Argo CD AppProjects enumerate destinations.
- Residual: exec plugins are enabled for every kustomize build on the
  repo-server, so a commit that reaches `main` with a malicious generator can
  read the age key ([secrets.md](secrets.md#how-argo-cd-decrypts)). Argo CD
  `role:admin` (groups `admins` and `ArgoCDAdmins`, behind OTP) can sync to
  any destination, so it is effectively cluster-admin; the local admin
  account is disabled, SSO only.
- Planned: a per-plugin sidecar only if the repository ever gets a second
  author.

### The LAN

- Threats: S and E from any device on the flat home network, which reaches the
  Talos API (50000 on each node), the Kubernetes API, the NAS (iSCSI, NFS, web
  UI, SSH) and the Turing Pi BMC.
- Control: the Talos and Kubernetes APIs require client certificates; the router
  forwards only the three ports above. Kubernetes Secrets are encrypted at
  rest and the apiserver audit log is on.
- Control (NAS, TrueNAS SCALE): both NFS exports and every iSCSI target
  accept only the four node addresses (`nas-iscsi-guard` resets a target
  that differs, [observability.md](observability.md#nas-metrics)); the web
  UI redirects HTTP to HTTPS and sends HSTS; the SMB share accepts
  `192.168.1.0/24` only, and only the SMB user `nedsi` gets into its
  folders: a guest can connect but the dataset's ACL gives it no access
  ([runbooks/nfs-hardening.md](runbooks/nfs-hardening.md)).
- Residual: one flat network with consumer devices on it; the BMC and the NAS
  web UI are reachable by anything on the LAN; the SMB share stays on for the
  household's Windows and macOS machines; NFS and iSCSI trust the client's
  address, which any LAN device can spoof; the audit log stays on each
  control plane's eMMC.
- Control (pods): no pod reaches the NAS except the CSI controller, the
  TrueNAS exporter and the blackbox probes
  (`infrastructure/network-policies/95-nas-egress.yaml`): pod traffic leaves
  with the node's address, so the export allow-lists alone would admit any
  pod (pentest 2026-11-10, P1).
- Planned: the NAS clients off the deprecated REST API (#1490); Kubernetes API login
  through Keycloak OIDC with the admin certificate kept as break-glass;
  central logs including the audit log; SELinux enforcing on Talos, which
  needs every CSI volume labelled first
  ([decisions.md](decisions.md#selinux-labels-on-csi-volumes); `immich-data`
  is still unlabelled by choice).

### The phone over a VPN

- Today: Tailscale ([remote-access.md](remote-access.md)). The operator runs
  in the cluster with no inbound port and no subnet router; the Kubernetes API
  is reachable over the tailnet through its API server proxy, which
  impersonates the tailnet identity. The tailnet policy is in git
  (`bootstrap/tailscale/policy.hujson`). The Talos API is on the tailnet
  through each node's Tailscale extension, for the owner and admins on TCP
  50000 only, and still needs the `talosconfig` certificate.
- Threats: S and E through a lost or stolen phone that is logged in to the
  tailnet. The phone holds no cluster credential: the proxy maps the tailnet
  login to the group `tailnet-admins`. Removing the device in the admin
  console revokes it.
- The tailnet policy is applied from git by CI
  (`.github/workflows/tailscale-policy.yaml`).
- Residual: a lost or stolen owner or admin phone reaches the Kubernetes API
  proxy as `tailnet-admins` (cluster-admin) until the operator removes the device in the
  admin console. The stolen-session pentest pass cannot reproduce it with its
  `tag:pentest` node ([runbook](pentest/runbooks/stolen-session.md)).
- Planned: a reduced talosconfig on the phone
  (`os:operator`), never the `os:admin` one.

## Controls mapped to frameworks

Each admission control traces to published frameworks;
`tests/test_security_controls.py` fails when a policy has no mapping, a
mapping names no policy, or an ID is malformed.

| Boundary | Control | Mapping |
| --- | --- | --- |
| Every workload (admission and posture) | Kyverno: the upstream Pod Security Standards baseline and restricted, ten upstream best-practices policies, the homelab `require-probes` ([testing.md](testing.md)) | [controls.yaml](../policies/kyverno/upstream/controls.yaml): CIS Kubernetes Benchmark section 5, NIST SP 800-190 section 4, NSA/CISA Kubernetes Hardening Guide, NIST CSF 2.0 |
| Every workload (Pod Security admission) | `enforce: restricted` in the platform and admin namespaces plus `home` and `system-upgrade`; `baseline` or `privileged` elsewhere, each with its reason in the header of [namespaces.yaml](../infrastructure/namespaces/namespaces.yaml); `scripts/ci/kyverno.sh` blocks what a `restricted` namespace would reject; the alert `PodSecurityEnforceDenied` pages on a denial ([runbooks/pod-security.md](runbooks/pod-security.md)) | same file |
| Supply chain: Renovate to `main` | `disallow-latest-tag`, `check-deprecated-apis`, and the `image-digest` rule of `scripts/ci/repo_policy.py` | same file |

Inside a workload, a compromised app process runs with the profile of
[architecture.md](architecture.md#admission-policy-kyverno): non-root where the
image allows it, otherwise root with three to six capabilities, never privilege
escalation, seccomp `RuntimeDefault`, and no ServiceAccount token. Kyverno
denies at admission what would weaken it (the 16 baseline policies) and a pod
without probes (`require-probes`); `require-requests-limits` stays in Audit until #1406, so a container without
limits is reported, not refused. What is left, root in the Immich server, Plex,
Calibre-Web and the media apps on NFS (#1407) and a token in two SigNoz chart
Pods, is in `ci/pod-hardening-gaps.txt` with its reason.

CIS sections 1 to 4 (control plane, etcd, kubelet and their files) are set by
Talos, not re-implemented here.

Wave 4 baseline (2026-10-16, over `deploy/`; workloads installed from Helm
charts are not in `deploy/`): the restricted policies report 65 results on 23
workloads. The baseline policies report one workload,
`monitoring/lan-inventory` (host network, added capabilities).

| Namespace | Restricted results | Workloads |
| --- | --- | --- |
| theater | 33 | 9 |
| paperless | 6 | 2 |
| books | 5 | 3 |
| immich | 4 | 2 |
| keycloak | 3 | 1 |
| mealie | 3 | 1 |
| monitoring | 3 | 1 |
| syncthing | 3 | 1 |
| kube-system | 3 | 1 |
| backup-verify | 1 | 1 |
| system-upgrade | 1 | 1 |

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
