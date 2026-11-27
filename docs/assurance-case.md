# Security assurance case

The claim: the security requirements below hold for the cluster this
repository deploys and for the code it builds. The argument is the threat
model, the design principles and the countermeasures to common weaknesses
in this page, each pointing at the file or check that implements it. What
does not hold yet is listed under [Known exceptions](#known-exceptions).

## Security requirements

Users of the services, and anyone reusing this repository, can expect:

- Every web UI on `*.lilalala.com` asks for a Keycloak login, through OIDC
  or an oauth2-proxy, with access by group; members of `admins` also need a
  TOTP code. Plex and Jellyfin keep their own login for their TV apps
  ([threat-model.md](threat-model.md#trust-boundaries)).
- HTTPS only: TLS 1.2 or 1.3 at the shared Gateway with a Let's Encrypt
  certificate, HSTS on every route, port 80 only redirecting
  ([networking.md](networking.md#security-headers)).
- Secrets in git only as SOPS ciphertext; gitleaks and GitHub push
  protection block plaintext ([secrets.md](secrets.md)).
- Every change to `main` is signed and passed the required `ci` check on a
  protected branch, administrators included.
- Every image is pinned by digest. The images built here are signed
  keyless by their own workflow, with SLSA provenance, and anyone can verify
  them ([architecture.md](architecture.md#first-party-code)).
- A reported vulnerability is handled as in
  [SECURITY.md](../SECURITY.md#handling-a-report).

They cannot expect:

- Protection against someone with physical access to the boards: no TPM, no
  disk encryption, no Secure Boot
  ([threat-model.md](threat-model.md#accepted-not-planned)).
- Encryption on the LAN for NAS storage (iSCSI and NFS) and for Jamulus audio,
  whose protocol has none.
- An unsigned image refused at admission: Kyverno `verify-own-images`
  reports an image without its signature or provenance but admits it, until
  the image-provenance work moves it to enforcement (#725).
- Availability above the 99.5% SLO ([sre.md](sre.md)).
- A bug bounty, or a response time shorter than [SECURITY.md](../SECURITY.md)
  states.

## Threat model and trust boundaries

[threat-model.md](threat-model.md) lists the assets, what losing or leaking
each costs, and per trust boundary (the Internet to the Gateway, Syncthing,
qBittorrent and Jamulus; the supply chain to `main`; the Argo CD
repo-server; the LAN; the phone over the tailnet) the STRIDE threats, the
control, the residual risk and the planned change. Its
[controls table](threat-model.md#controls-mapped-to-frameworks) maps the
admission policies to CIS, NIST and NSA/CISA guidance, checked by
`tests/test_security_controls.py`.

## Secure design principles

Saltzer and Schroeder's principles, as applied here:

| Principle | How | Where |
| --- | --- | --- |
| Economy of mechanism | One shared Gateway, no ingress controller, no service mesh; Talos, an OS with no shell or SSH; static sites with no JavaScript | [decisions.md](decisions.md#no-service-mesh), [talos.md](talos.md) |
| Fail-safe defaults | Kyverno baseline policies deny at admission; default-deny network policies per application namespace; workflow tokens start with `permissions: {}`; port 80 only redirects | `infrastructure/kyverno-policies/`, `infrastructure/network-policies/`, `.github/workflows/ci.yaml` |
| Complete mediation | Every UI request passes Keycloak or an oauth2-proxy; every pod passes Kyverno; every change passes `ci` on protected `main` | [architecture.md](architecture.md#admission-policy-kyverno) |
| Open design | The whole configuration is public; only keys are secret | this repository, [secrets.md](secrets.md) |
| Separation of privilege | Admin logins need a password and TOTP; a merge needs a signed commit and a green `ci`; decrypting needs the age key, which is not in git | [runbooks/keycloak-otp.md](runbooks/keycloak-otp.md), [secrets.md](secrets.md#the-key) |
| Least privilege | Read-only default workflow token, write scopes per job; no ServiceAccount token in app pods; capabilities dropped; external-dns upsert-only; access to each app by Keycloak group | `scripts/ci/repo_policy.py` (`pod-hardening`), [architecture.md](architecture.md#per-app-access) |
| Least common mechanism | One namespace, one network policy and one set of credentials per app; one PostgreSQL cluster per service | [architecture.md](architecture.md) |
| Psychological acceptability | One SSO login for every household app; updates and rollbacks need no one | [decisions.md](decisions.md#no-human-gates) |

## Common weaknesses countered

OWASP Top 10 (2021):

| Weakness | Control | Where |
| --- | --- | --- |
| A01 Broken access control | Keycloak groups per app; oauth2-proxy for apps without OIDC; the public dashboard answers only `GET` and `HEAD` | [threat-model.md](threat-model.md#trust-boundaries) |
| A02 Cryptographic failures | TLS 1.2+ and HSTS; WireGuard between nodes (`infrastructure/cilium/values.yaml`); SOPS with age; Ed25519 signatures on dashboard pushes | [secrets.md](secrets.md) |
| A03 Injection | Own Go code has no SQL and renders HTML with `html/template`; shell is shellcheck-clean; untrusted CI metadata reaches `run:` only through `env:` and is validated by `scripts/ci/check-title.sh` | `dashboard/internal/web/`, `techradar/internal/radar/page.go` |
| A04 Insecure design | A threat model per boundary; a change spec with a design and rejected alternatives for every multi-PR change | [threat-model.md](threat-model.md), [spec-driven-development.md](spec-driven-development.md) |
| A05 Security misconfiguration | Kyverno in CI and in the cluster, strict kubeconform, kube-linter, the Trivy config gate, `repo-policy`, security headers on every route | [testing.md](testing.md) |
| A06 Vulnerable and outdated components | Renovate, GitHub vulnerability alerts, `govulncheck`, trivy-operator on the running images | [dependencies.md](dependencies.md) |
| A07 Identification and authentication failures | Keycloak brute-force detection, no password grant, TOTP for admins | `platform/keycloak/realm/` |
| A08 Software and data integrity failures | Signed commits; actions pinned by SHA; images by digest; own images signed, with their signature and provenance checked by Kyverno `verify-own-images` (Audit); signed dashboard pushes | `infrastructure/kyverno-policies/verify-own-images.yaml` |
| A09 Security logging and monitoring failures | apiserver audit log; pod and Talos logs in SigNoz; Tetragon runtime detection; alerts that page through ntfy | [observability.md](observability.md) |
| A10 Server-side request forgery | Own code calls only configured URLs; the dashboard's web pod has no egress | [homelab-dashboard.md](homelab-dashboard.md) |

CI/CD risks (OWASP Top 10 CI/CD):

| Risk | Control |
| --- | --- |
| Insufficient flow control | Branch protection on `main`: required strict `ci`, signed commits, linear history, administrators included |
| Dependency chain abuse | `go.sum`; CI Python pinned with hashes (`--require-hashes`); tools pinned by version and checksum |
| Poisoned pipeline execution | No `pull_request_target`; untrusted metadata only through `env:`; `persist-credentials: false`; fork pull requests get no secrets |
| Insufficient credential hygiene | gitleaks and push protection; GitHub OIDC to AWS for OpenTofu, no long-lived cloud key in GitHub |
| Ungoverned third-party services | Every action pinned by SHA, enforced by the repository setting |

## Hardening

- Response headers on every HTTPS route: HSTS, `X-Content-Type-Options`,
  `Content-Security-Policy`, `Referrer-Policy`, `X-Frame-Options`,
  `Permissions-Policy`, checked by `repo-policy` rule
  `route-security-headers` ([networking.md](networking.md#security-headers)).
- Own images run as non-root: the dashboard on distroless `static:nonroot`,
  the site on `nginx-unprivileged`, Jamulus as UID 65532.
- Pods: seccomp `RuntimeDefault`, no privilege escalation, capabilities
  dropped, no ServiceAccount token, a read-only root where the app allows
  it. Exceptions are listed with their reason in
  `ci/pod-hardening-gaps.txt`.
- Pod Security levels, per namespace in
  `infrastructure/namespaces/namespaces.yaml`: `restricted` on the gateway,
  the controllers (Argo CD, cert-manager, external-dns, Kyverno, tuppr,
  Trivy, metrics-server, the kubelet certificate approver), the own images
  (website, dashboard, Jamulus), Headlamp, Hubble, `pentest` and `home`;
  `baseline` on Keycloak, SigNoz, `ingress`, `backup-verify` and most
  household apps (Immich, books, Mealie, Paperless, Syncthing, theater);
  `privileged` where node-level agents or proxies run (democratic-csi,
  monitoring, logging, Tetragon, Tailscale).
- Nodes: Talos, an immutable OS managed only through its mTLS API;
  Kubernetes Secrets encrypted at rest.

## Input validation

- Dashboard push: the Ed25519 signature is checked against the public keys
  first, then the body against `snapshot.schema.json`
  (`dashboard/internal/snapshot/`); `FuzzValidate` fuzzes the validator.
- Tech radar: `techradar check` rejects an invalid entry before rendering.
- `repo-policy` parsers: fuzzed with Atheris (workflow `fuzz`).

## Known exceptions

- The TrueNAS exporter and the iSCSI guard do not verify the NAS
  certificate, and send its API key over that connection (#1822).
- Python has no linter in pre-commit or CI (#1823).
- Image signatures are audited at admission, not enforced (#725).
- NAS storage traffic and Jamulus audio cross the LAN unencrypted (see
  [Security requirements](#security-requirements)).
- One maintainer, no successor arrangement yet
  ([GOVERNANCE.md](../GOVERNANCE.md#continuity)).

## Why it is like this

- One page that links instead of repeating: the controls live in the
  threat model and the topical docs, which change with the code; this page
  only argues that together they meet the requirements. Rejected: a
  standalone assurance document, which would go stale at the first change.
- The requirements state what is not protected as plainly as what is, so a
  reader can decide what to reuse.
