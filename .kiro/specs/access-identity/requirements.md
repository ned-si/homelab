# Requirements: access-identity (as-is)

## Introduction

One Keycloak realm (`homelab`) signs users into every app that supports
OIDC; groups decide who reaches which app. Operators reach the cluster from
outside the house over Tailscale only. Secrets live in git, SOPS-encrypted to
one age key. This spec records that behaviour. Detail:
[docs/architecture.md](../../../docs/architecture.md#sessions),
[docs/remote-access.md](../../../docs/remote-access.md),
[docs/secrets.md](../../../docs/secrets.md),
[docs/threat-model.md](../../../docs/threat-model.md).

Non-goals:
- User accounts and group membership in git: they stay in the Keycloak admin
  console, so the public repo holds no names.

## Requirements

### Requirement 1: The realm is code

**User story:** As the operator, I want the realm settings in git and checked
on every sync, so that a console click cannot drift them silently.

#### Acceptance criteria

1. WHEN the `keycloak` Application syncs, THE PostSync Job
   `keycloak-realm-settings` SHALL write every value in
   `platform/keycloak/realm/*.conf` and read it back; a mismatch fails the
   sync. (`kubectl -n keycloak logs job/keycloak-realm-settings`: `ok` lines,
   no `FAIL`; `tests/bash/test_keycloak_realm.sh`)
2. THE app clients SHALL have exact redirect URIs. (`clients.conf`)

### Requirement 2: Per-app access by group

**User story:** As the operator, I want a new user to reach nothing until I
put them in a group, and a group to reach only its apps.

#### Acceptance criteria

1. FOR each client in `access.conf`, THE realm SHALL grant the client role
   `access` to exactly the listed groups and bind the client to its own
   browser and direct-grant flows that deny everyone else.
   (`apply.sh`, read back by `keycloak-realm-settings`)
2. WHEN a user outside the groups opens an app, even with an SSO session for
   another app, THE system SHALL show "Access denied". (the check runs after
   the cookie)
3. THE Argo CD local admin SHALL be off. (`admin.enabled: false` in `bootstrap/argocd-values.yaml`)

### Requirement 3: Long sessions for users, short for the platform

**User story:** As a household member, I want to log in once per device; as
the operator, I want platform tools to ask again every 12 hours.

#### Acceptance criteria

1. THE realm SHALL keep SSO sessions 30 d idle / 365 d max and offline
   sessions 365 d idle. (`sessions.conf`, read back)
2. WHEN a platform client (`argocd`, `grafana-oauth`, `headlamp`, the
   `security-admin-console`) requests ACR `platform` and the last password
   login is older than 12 h, THE realm SHALL ask for the password again.
   (`platform.conf`, flow `browser-loa`)
3. THE user apps SHALL keep their own sessions for about a year (Mealie,
   Paperless, the theater proxy) or without expiry (Immich).
   (table in [architecture.md](../../../docs/architecture.md#sessions))

### Requirement 4: Remote access without open ports

**User story:** As the operator, I want `kubectl` and a cluster UI from
anywhere, with nothing new exposed on the router.

#### Acceptance criteria

1. THE Tailscale operator SHALL run the Kubernetes API proxy in auth mode,
   mapping tailnet identity to the group `tailnet-admins` (cluster-admin); a
   device without a grant SHALL be denied. (`platform/tailscale-operator/resources/rbac.yaml`;
   `kubectl auth whoami` over the tailnet)
2. WHEN `bootstrap/tailscale/policy.hujson` changes, THE workflow
   `tailscale-policy` SHALL test it on the pull request and apply it on
   merge; a rejected policy fails and posts to ntfy.
3. THE Headlamp UI SHALL be served only at `https://headlamp.lilalala.com`
   on the shared Gateway, only to Keycloak group `admins`, and SHALL read
   without Secrets, exec or writes; an unauthenticated request SHALL get a
   302 to Keycloak. (`platform/headlamp/resources/`: HTTPRoute,
   `headlamp-sso`, RBAC, default-deny CiliumNetworkPolicies)
5. EVERY web UI SHALL be a public HTTPRoute behind Keycloak and group
   gating; `kubectl` and `talosctl` SHALL NOT be reachable through the
   Gateway. ([decisions.md](../../../docs/decisions.md#uis-public-behind-sso-cluster-apis-on-the-tailnet))
4. THE exit nodes `home-exit-0` and `home-exit-1` SHALL route members'
   internet traffic only (`autogroup:internet`), not the LAN or the cluster.
   (`platform/tailscale-operator/resources/exit-node.yaml`, `policy.hujson`)
5. THE Talos API SHALL be reachable over the tailnet by the owner and admins
   only, on TCP 50000 to `tag:talos`, and never from the internet; `tag:talos`
   SHALL reach nothing. (`policy.hujson`; platform-talos Requirement 5)

### Requirement 5: Secrets never in plaintext, never too old

**User story:** As the operator of a public repo, I want no secret readable
in git and every credential rotated on a schedule.

#### Acceptance criteria

1. EVERY Secret in git SHALL be a SOPS file encrypted to the age key, with no
   literal credential anywhere Argo CD syncs. (`scripts/leak-check.sh`,
   `scripts/secrets-check.sh`, `scripts/placeholder-check.sh`, gitleaks,
   GitHub push protection)
2. EVERY `*.sops.yaml` SHALL have one row in `ci/secret-rotation.tsv` with a
   class (`api-token` 180 d, `credential` 365 d, `static`).
   (`secret_rotation.py coverage` in repo-policy; `tests/test_secret_rotation.py`)
3. WHEN a row passes its period, THE weekly workflow `secret-age` SHALL fail
   and post to ntfy. (`secret_rotation.py age`)
4. THE automation credentials SHALL be read-only: ServiceAccount
   `agent-readonly` (no Secrets, no exec), Argo CD account `agent`
   (`role:readonly`), Grafana service account `agent-readonly` (Viewer).
   (`platform/agent-access/rbac.yaml`, `kubectl auth can-i get secrets -A` = `no`)
5. THE trivy ExposedSecretReports SHALL be readable by cluster admins only:
   no ClusterRole granting them SHALL aggregate into `view`, `edit` or
   `cluster-reader`. (MutatingAdmissionPolicy
   `exposed-secret-reports-admin-only`; `kubectl auth can-i list
   exposedsecretreports.aquasecurity.github.io -A
   --as=system:serviceaccount:headlamp:headlamp` = `no`, same for
   `kube-system:agent-readonly`)

### Requirement 6: A hardened public edge

**User story:** As the operator, I want every public route to send security
headers and the edge scanned weekly.

#### Acceptance criteria

1. EVERY rule of an HTTPRoute on the Gateway's `https` listener SHALL set the
   security response headers. (repo-policy `route-security-headers`)
2. THE weekly `dast` workflow SHALL fail on any HIGH ZAP alert without an
   IGNORE row (with its reason) in `.zap/rules.tsv`, and on a missing
   security header. (`scripts/dast-zap.sh`; `scripts/tls-check.sh` with
   `STRICT_HEADERS=1`)
3. THE namespaces that pass Pod Security `restricted` SHALL enforce it.
   (`infrastructure/namespaces/namespaces.yaml`)
