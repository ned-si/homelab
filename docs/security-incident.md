# Committed credentials: inventory and position

Every credential listed here was committed to this repository **in plaintext** and
is present in the git history. All of them are compromised.

Values are referenced by file and key name only — they are not reproduced here,
because that would just move the leak into a new file.

## The position, in one table

| Credential | Action |
|---|---|
| NAS SSH private key (row 1) | **replace before the cluster works.** Not deferrable |
| TrueNAS API key (row 2) | **replace before the cluster works.** Not deferrable |
| Cloudflare API token (row 3) | **replace.** Not LAN-scoped |
| Rows 4–8: LAN-only application passwords and OIDC client secrets | **carried forward at their current values. Rotation deferred by decision, 2026-08-28** |
| Plex claim token (row 9) | nothing. Claim tokens expire in ~4 minutes; long dead |
| The git history | **will be rewritten, at the end of the migration** |

`scripts/secrets-inventory.sh` is the tool that moves the deferred values into
sealed files, and its header is the source of truth for the decision below. Where
this document and that header disagree, the header wins.

## Why this matters even for a private repo

Private is not the same as secret. These values were exposed to:

- every machine that has ever cloned the repo, including any old laptop or CI runner
- GitHub's storage and backups, and any GitHub App ever authorised on the repo
  (Renovate has read access to the whole tree)
- anyone who was ever added as a collaborator
- any future accidental visibility change

One of them is materially worse than the rest: **an OpenSSH private key for
`root` on the storage server**. That is not an application password, it is
filesystem-level access to every dataset the NAS holds, including all backups.

## Inventory

Ordered by severity.

| # | What | Where it was | Blast radius |
|---|------|--------------|--------------|
| 1 | OpenSSH **private key**, `root@truenas` | `iac/truenas-iscsi.yaml` → `driver.config.sshConnection.privateKey` | Root shell on the NAS. Full read/write/delete on every dataset and snapshot. |
| 2 | TrueNAS API key | `iac/truenas-iscsi.yaml` → `driver.config.httpConnection.apiKey` | Full TrueNAS API. Create/destroy zvols and shares. |
| 3 | Cloudflare API token | `kubernetes/applications/cert-manager/cf-api-token-secret.yaml` and `.../external-dns/cf-api-token-secret.yaml` (**same token, two copies**) | Edit DNS for `lilalala.com`. Enables domain takeover and therefore issuing valid certificates for any subdomain. |
| 4 | Keycloak bootstrap admin password | `kubernetes/applications/keycloak/keycloak.yaml` → `KC_BOOTSTRAP_ADMIN_PASSWORD` | Admin of the identity provider. Grants access to every app that federates to it. |
| 5 | MariaDB root password | `kubernetes/applications/seafile/mariadb-deploy.yaml` → `MARIADB_ROOT_PASSWORD`, duplicated in `seafile-deploy.yaml` → `DB_ROOT_PASSWD` | Full control of the Seafile database. |
| 6 | Seafile admin password | `kubernetes/applications/seafile/seafile-deploy.yaml` → `SEAFILE_ADMIN_PASSWORD` | Admin of the file-sharing service. |
| 7 | Paperless admin password | `kubernetes/applications/paperless/paperless-deploy.yaml` → `PAPERLESS_ADMIN_PASSWORD` | Admin of the document archive. |
| 8 | OIDC client secrets ×4 | Grafana (`kube-prom-stack.yaml`), Immich (`immich/immich.yaml`), Mealie (`mealie-deploy.yaml`), Paperless (inside `PAPERLESS_SOCIALACCOUNT_PROVIDERS`) | Impersonate the client to Keycloak; depending on flow, obtain tokens for users. |
| 9 | Plex claim token | `kubernetes/applications/plex/plex-deploy.yaml` → `PLEX_CLAIM` | **Low.** Claim tokens expire after ~4 minutes. Long dead. Rotate nothing; just stop committing it. |

### One more, by omission

`PAPERLESS_SECRET_KEY` was **never set**, so Paperless ran on the default Django
signing key shipped in its source. That key is public. Anyone who knew it could
forge session cookies and password-reset tokens for the document archive. It is
set from a Secret now (`apps/secrets/paperless-secrets.sops.yaml.example`), and
generating it counts as remediation, not hardening.

## Rotation of the LAN-only credentials is deferred

Rows 4–8 are re-encrypted with SOPS and kept at their current values. This is a
decision recorded on **2026-08-28**, not an oversight and not a TODO.

It is **conditional**. It holds because of these facts, all true today:

- **Single operator.** Nobody else has a clone, and no collaborator has ever been
  added.
- **Every affected service is reachable only from the LAN or from behind
  Keycloak.** The credentials grant nothing to someone who cannot already reach the
  network.
- **Every value is recorded in Bitwarden**, so rotation is a decision that can be
  taken later at leisure rather than a recovery operation.
- **The repository is private, and the history rewrite is scheduled** — at the end
  of the migration, deliberately. See below.

**Any of the following invalidates it, and then rotation comes first:**

- the repository becoming public, forked, or gaining a collaborator
- any of these services becoming reachable from the internet without
  authentication in front of it
- a GitHub App or CI runner with read access to the tree being compromised
  (Renovate has read access to the whole repository)
- evidence that any of the values has been used from an address that is not the
  operator's

### The three that are not covered by it

Because none of them is a LAN-only application password.

- **The NAS SSH private key and the TrueNAS API key** (rows 1 and 2) grant
  filesystem-level access to every dataset, including the backups. Replacement is
  not a rotation task here: it is a prerequisite of the driver working at all,
  because `infrastructure/secrets/democratic-csi-iscsi.sops.yaml.example` already
  requires a **new** keypair and a **non-root** account.
- **The Cloudflare API token** (row 3) edits public DNS for the zone, from
  anywhere, and therefore enables issuing valid certificates for any subdomain.

## Remediation order

Do steps 1–3 now; they do not require the cluster and can be done from anywhere.
Steps 4–6 are the deferred set — the procedures are recorded so that whenever the
decision above is revisited, or one of its conditions breaks, nobody has to work
them out under pressure.

### 1. The NAS SSH key — first, and not optional

```sh
# On the TrueNAS box, as root:
#   remove the leaked public key from root's authorized_keys
vi /root/.ssh/authorized_keys

# Verify the key no longer works from anywhere:
ssh -i /path/to/leaked/key root@<nas>   # must be refused
```

Then create a **dedicated, non-root** account for democratic-csi rather than
restoring root access:

```sh
# On TrueNAS: create user `democratic-csi`, then grant it only what the
# driver needs -- passwordless sudo for zfs/zpool:
#   democratic-csi ALL=(ALL) NOPASSWD: /usr/local/sbin/zfs, /usr/local/sbin/zpool

# Generate a fresh keypair scoped to this use only:
ssh-keygen -t ed25519 -C 'democratic-csi@homelab' -f ./democratic-csi
```

Put the new private key into
`infrastructure/secrets/democratic-csi-iscsi.sops.yaml` and seal it.

### 2. TrueNAS API key

Revoke the old key in the TrueNAS UI (Credentials → API Keys). Create a new one.
While you are there, note that the old config set `allowInsecure: true` against
an `https` endpoint, which silently disabled certificate verification — the new
template sets it to `false`.

### 3. Cloudflare token

Revoke the old token in the Cloudflare dashboard. Create **two** new tokens,
not one, each scoped to the `lilalala.com` zone with only:

- Zone → Zone → Read
- Zone → DNS → Edit

One for cert-manager, one for external-dns, so either can be revoked
independently. The old setup used a single token pasted into two files.

### 4. Keycloak, and everything downstream of it

*Deferred. Recorded for when it is not.*

Keycloak has to come before the OIDC clients, because rotating a client secret
means editing it in Keycloak first.

1. Change the admin password in the Keycloak admin console. Note that
   `KC_BOOTSTRAP_ADMIN_PASSWORD` only applies to an **empty** database — editing
   the Secret does not rotate an existing admin account.
2. For each of `grafana`, `immich`, `mealie`, `paperless`: Clients → *client* →
   Credentials → **Regenerate** the secret, then put the new value in the
   corresponding sealed file.

### 5. Seafile / MariaDB

*Deferred. Recorded for when it is not.*

`MARIADB_ROOT_PASSWORD` only takes effect on an empty datadir, so on a live
database rotate it in SQL and then update the Secret:

```sh
kubectl -n seafile exec deploy/mariadb -- \
  mariadb -uroot -p'<OLD>' -e "SET PASSWORD FOR 'root'@'%' = PASSWORD('<NEW>');"
```

Same pattern for the Seafile admin password: change it in the Seafile web UI,
then update `apps/secrets/seafile-admin.sops.yaml` to match.

### 6. Paperless

`PAPERLESS_SECRET_KEY` is **not** deferred — it was never set at all, so there is
no old value to carry forward. Generate it (`openssl rand -base64 48`). Changing
the signing key invalidates all existing sessions, which is the desired outcome.

The admin password is deferred with the rest of rows 4–8.

## The history will be rewritten, at the end of the migration

Not "if", and not now. The timing is the decision.

**Why it happens at all:** the values are carried forward rather than rotated, so
the history is the only place they can be removed from.

**Why not now:** a rewrite changes every commit hash. That invalidates the
`deployed` tag Argo CD tracks — every `Application` in `clusters/homelab/` resolves
a revision that no longer exists — and it breaks every existing clone, at the
moment the cluster is least stable. See
[ADR 0001](adr/0001-deploy-by-moving-a-git-tag.md).

**When it happens:** after the cutover in [migration-plan.md](migration-plan.md) is
complete and the cluster has been carrying real traffic on the new hierarchy for
long enough that a rebuild is not on the table.

**What to expect from it:** `git filter-repo` or BFG orphans the old objects on
GitHub until garbage collection, which for a fork or a cached view may be never. So
treat the rewrite as tidying, not as remediation: it is not what makes the values
safe. What makes them tolerable is the set of conditions above.

Afterwards, re-tag `deployed` at the rewritten commit and re-run
`task bootstrap:apply` so the root Application resolves again.

## Preventing a recurrence

1. **`task secrets:leak-check`** — five checks, and the important one is newer than
   this incident: it catches **a credential as a literal value anywhere**, not only
   inside a `kind: Secret`. `env:` entries with a literal `value:`, a
   `client_secret:` key in a Helm values file, an inline literal in a ConfigMap.
   That is the shape of **six of the nine credentials below** — the Keycloak
   bootstrap admin password, the MariaDB root password (twice), the Paperless admin
   password, the Seafile admin password and the four OIDC client secrets. A check
   that only understood Secret objects saw none of them. Its scope is everything
   Argo syncs plus the sources it renders from, and it deliberately includes
   `*.example` templates, because a template is where a real credential gets pasted
   by accident.
2. **`scripts/secrets-check.sh`** and **`scripts/placeholder-check.sh`** — the
   other two gates. See [secrets.md](secrets.md#the-three-checks-around-this).
3. **`.gitignore`** covers `*.key`, `*.pem`, `.env*`, `*.tfvars`, kubeconfigs and
   the `.decrypted/` scratch directory.
4. **Database passwords no longer exist as artefacts.** CloudNativePG generates
   them into `<cluster>-app` Secrets, so for Postgres there is nothing to leak,
   encrypted or otherwise. That is why only OIDC clients, bootstrap admins and the
   MariaDB root password appear under `*/secrets/`.

See [secrets.md](secrets.md) for the day-to-day workflow.
