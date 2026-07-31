# Committed credentials: inventory and remediation

Every credential listed here was committed to this repository **in plaintext**
and is present in the git history. Rewriting history does not undo that, and
neither does this restructure. All of them must be treated as compromised and
rotated.

Values are referenced by file and key name only — they are not reproduced here,
because that would just move the leak into a new file.

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

## Remediation order

Do these in order. Steps 1–3 do not require the cluster and can be done from
anywhere, right now.

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

Keycloak has to come before the OIDC clients, because rotating a client secret
means editing it in Keycloak first.

1. Change the admin password in the Keycloak admin console. Note that
   `KC_BOOTSTRAP_ADMIN_PASSWORD` only applies to an **empty** database — editing
   the Secret does not rotate an existing admin account.
2. For each of `grafana`, `immich`, `mealie`, `paperless`: Clients → *client* →
   Credentials → **Regenerate** the secret, then put the new value in the
   corresponding sealed file.

### 5. Seafile / MariaDB

`MARIADB_ROOT_PASSWORD` only takes effect on an empty datadir, so on a live
database rotate it in SQL and then update the Secret:

```sh
kubectl -n seafile exec deploy/mariadb -- \
  mariadb -uroot -p'<OLD>' -e "SET PASSWORD FOR 'root'@'%' = PASSWORD('<NEW>');"
```

Same pattern for the Seafile admin password: change it in the Seafile web UI,
then update `apps/secrets/seafile-admin.sops.yaml` to match.

### 6. Paperless

Generate `PAPERLESS_SECRET_KEY` (`openssl rand -base64 48`) and a new admin
password. Changing the signing key invalidates all existing sessions, which is
the desired outcome.

## Should the history be rewritten?

Probably not worth it, and it does not achieve much.

- Rewriting with `git filter-repo` or BFG changes every commit hash, breaks
  every existing clone, and orphans the old objects on GitHub until garbage
  collection — which for a fork or a cached view may be never.
- It provides no security benefit **once the credentials are rotated**, and
  rotation is mandatory either way.
- It provides a false sense of cleanup if rotation is skipped.

So: rotate everything, leave history alone, and rely on the fact that the
rotated values are worthless. If you want the history clean for tidiness rather
than security, do it after rotation is confirmed, and understand that the old
values may still be retrievable from GitHub for some time.

## Preventing a recurrence

Three things now stand in the way:

1. **`task secrets:leak-check`** — refuses plaintext `stringData:`, private-key headers,
   age secret keys, and filenames that should never be tracked. Run it before
   committing; consider wiring it as a pre-commit hook.
2. **`.gitignore`** now covers `*.key`, `*.pem`, `.env*`, `*.tfvars`, kubeconfigs
   and the `.decrypted/` scratch directory.
3. **Database passwords no longer exist as artefacts.** CloudNativePG generates
   them into `<cluster>-app` Secrets, so for Postgres there is nothing to leak,
   encrypted or otherwise. That is why only OIDC clients, bootstrap admins and
   the MariaDB root password appear under `*/secrets/`.

See [secrets.md](secrets.md) for the day-to-day workflow.
