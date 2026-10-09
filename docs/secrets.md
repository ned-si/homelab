# Secrets

Every credential the cluster needs is a SOPS-encrypted file in git, encrypted to
one age key. Argo CD decrypts them at sync time with KSOPS. The private key has
exactly three copies, listed below: the Mac that runs this repository, the
password manager and the Secret `argo/sops-age`.

## The key

- Public key (recipient): the `age:` entries in `.sops.yaml`.
- Private key: `~/.config/sops/age/keys.txt` on the Mac (mode 600), the
  password manager, and `argo/sops-age` (key `keys.txt`), mounted into the
  repo-server at `/sops-age/keys.txt`.

Lose it and every secret must be recreated; leak it and every secret in git,
including history, is readable. Check that the three copies agree:

```sh
age-keygen -y ~/.config/sops/age/keys.txt
grep -o 'age1[0-9a-z]*' .sops.yaml | sort -u
kubectl -n argo get secret sops-age -o jsonpath='{.data.keys\.txt}' | base64 -d | age-keygen -y
```

Expected: the same `age1...` public key three times, and nothing else.

## Layout

| Directory | Files (`*.sops.yaml`) | Application |
| --- | --- | --- |
| `infrastructure/secrets/` | `cloudflare-cert-manager`, `cloudflare-external-dns`, `democratic-csi-iscsi` | `secrets-infrastructure` (wave -25) |
| `platform/secrets/` | `keycloak-admin`, `grafana-oidc`, `s3-backup`, `alertmanager-notify`, `argocd-notifications` | `secrets-platform` (wave -25) |
| `apps/secrets/` | `immich-config`, `mealie-oidc`, `paperless-secrets`, `plex-claim`, `recyclarr-api-keys`, `seafile-admin`, `seafile-db`, `theater-sso` | `secrets-apps` (wave -25) |

Each file is a Kubernetes Secret with its own `metadata.namespace`; only
`data`/`stringData` values are encrypted (`.sops.yaml`), so names and namespaces
stay readable in a diff. Each has a `.example` template next to it that says
what the value is and how to generate it. Each directory's
`secret-generator.yaml` lists the files KSOPS decrypts.

These three directories are the only ones Argo CD builds with kustomize, and
the only ones not rendered into `deploy/`: rendering them would write plaintext.

Not here, on purpose: PostgreSQL passwords. CloudNativePG generates them into
`<cluster>-app` Secrets, so they never exist in git in any form. Also not here:
the Argo CD Keycloak client secret (key `oidc.keycloak.clientSecret` of
`argo/argocd-secret`, set by hand, see [bootstrap.md](bootstrap.md)).

## Everyday work

Edit a sealed file (decrypts to a temp file, opens `$EDITOR`, re-encrypts on
save):

```sh
task secrets:edit -- platform/secrets/keycloak-admin.sops.yaml
```

Never decrypt in place and re-encrypt by hand: that is how plaintext gets
committed. Never edit a sealed file in a text editor either: the SOPS MAC covers
every value, so even a metadata change makes the whole file fail to decrypt, at
Argo CD sync time.

Add a new secret:

```sh
cp apps/secrets/<name>.sops.yaml.example apps/secrets/<name>.sops.yaml
$EDITOR apps/secrets/<name>.sops.yaml          # real values
task secrets:seal -- apps/secrets/<name>.sops.yaml
task secrets:leak-check
```

Then add `- ./<name>.sops.yaml` to that directory's `secret-generator.yaml`.
Seal first, list second: a listed file that does not exist fails the whole
`secrets-<layer>` Application and every Secret in it.

Bulk sealing: `task secrets:seal:all` fills every template from
`secrets.local.env` (git-ignored, plaintext, mode 600, kept only on the Mac) and
proves each file decrypts. Keep the password manager as the record of every
value; `secrets.local.env` is a working file.

## Rotating a credential

The general pattern: create the new value at its source, put it in the sealed
file, merge, let Argo CD sync, restart the consumer if it reads the value only
at start, prove the new value works and the old one is refused, then record the
new value in the password manager.

| Credential | Source of truth | Sealed file, key | Notes |
| --- | --- | --- | --- |
| Keycloak admin | Keycloak master realm (`kcadm.sh set-password`) | `platform/secrets/keycloak-admin.sops.yaml`, `password` | `KC_BOOTSTRAP_ADMIN_PASSWORD` only applies to an empty database: change the user in Keycloak first, then bump `kubectl.kubernetes.io/restartedAt` in `platform/keycloak/deployment.yaml` |
| OIDC client secrets (Grafana, Immich, Mealie, Paperless) | Keycloak, Clients, *client*, Credentials, Regenerate | `grafana-oidc`, `immich-config` (inside `immich-config.yaml`), `mealie-oidc`, `paperless-secrets` (`PAPERLESS_SOCIALACCOUNT_PROVIDERS`) | Immich has no automated sync: `argocd app sync immich` after the merge |
| Argo CD OIDC client secret | Keycloak client `argocd` | not in git: `argo/argocd-secret`, `oidc.keycloak.clientSecret` | patch the Secret, restart `argocd-server` |
| Paperless admin | `manage.py changepassword` in the pod | `paperless-secrets`, `PAPERLESS_ADMIN_PASSWORD` | |
| Seafile admin | Seafile web UI or `reset-admin` | `seafile-admin`, `SEAFILE_ADMIN_PASSWORD` | |
| Seafile MariaDB root | SQL: `ALTER USER 'root'@'%' ...` (dump first) | `seafile-db`, `root-password` | `MARIADB_ROOT_PASSWORD` only applies to an empty datadir; change SQL first ([runbook](runbooks/seafile-mariadb-upgrade.md#rotating-the-root-password)) |
| TrueNAS API key | TrueNAS UI, API Keys | `democratic-csi-iscsi`, `apiKey` in `driver-config-file.yaml` | restart the democratic-csi controller and node pods, test a volume attach, then delete the old key |
| TrueNAS SSH key | new keypair, public key on the NAS | `democratic-csi-iscsi`, `privateKey` | remove the old public key from the NAS afterwards |
| Cloudflare tokens | Cloudflare dashboard: one token per consumer, Zone Read + DNS Edit on `lilalala.com` only | `cloudflare-cert-manager`, `cloudflare-external-dns`, `api-token` | check external-dns logs and a certificate renewal, then revoke the old token |
| Automatic rollback GitHub token | GitHub, fine-grained token, `ned-si/homelab` only, Contents + Pull requests + Issues read and write | `platform/secrets/argocd-notifications.sops.yaml`, `github-token`, and the Actions secret `AUTO_ROLLBACK_TOKEN` | the same value in both places; see [decisions.md](decisions.md#automatic-rollback) |
| S3 backup keys, `RESTIC_PASSWORD` | `bootstrap/aws-backup` outputs | `platform/secrets/s3-backup.sops.yaml` | the same `RESTIC_PASSWORD` in every namespace; changing it needs `restic key add` on every repository first |

## Rotating the age key

Two-phase, so Argo CD can always decrypt:

1. Generate a new identity and add it next to the old one, locally and in the
   cluster:

   ```sh
   age-keygen -o /tmp/new-age.txt
   cat /tmp/new-age.txt >> ~/.config/sops/age/keys.txt
   kubectl -n argo create secret generic sops-age \
     --from-file=keys.txt="$HOME/.config/sops/age/keys.txt" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

   Wait until the repo-server sees both (`/sops-age/keys.txt` updates in place
   within about a minute).
2. Add the new public key to both `age:` lists in `.sops.yaml`, run
   `sops updatekeys -y <file>` on every `*.sops.yaml`, merge, and check every
   `secrets-*` Application syncs.
3. Remove the old public key from `.sops.yaml`, `sops updatekeys -y` every file
   again, merge, check the syncs.
4. Remove the old identity from `~/.config/sops/age/keys.txt` and from
   `argo/sops-age` (same `kubectl apply` as step 1), store the new private key
   in the password manager, delete `/tmp/new-age.txt`.

Re-encrypting to a new key does not protect values already readable with the
old key in git history: rotate the credentials themselves if the old key leaked.

## How Argo CD decrypts

- `bootstrap/argocd-values.yaml` adds an init container (`viaductoss/ksops`)
  that installs `ksops` into the repo-server, mounts `sops-age`, and sets
  `SOPS_AGE_KEY_FILE=/sops-age/keys.txt`.
- `configs.cm.kustomize.buildOptions: --enable-alpha-plugins --enable-exec`,
  because KSOPS is a kustomize exec plugin.

That flag enables exec plugins for every kustomize build on the repo-server.
Pre-rendering everything else into `deploy/` limits it to the three `*/secrets`
directories. The rest of the exposure is accepted for a repository with one
author; a shared cluster would need a per-plugin CMP sidecar instead.

## Checks

None needs the age key, so all run in CI and pre-commit:

- `scripts/leak-check.sh` (`task secrets:leak-check`): no `*.sops.yaml` without
  a SOPS envelope, no private-key armour, no age secret key, no plaintext
  `kind: Secret` payload, and no credential as a literal value anywhere Argo CD
  syncs or renders from (an `env` literal, a `client_secret:` in Helm values),
  including the `.example` templates.
- `scripts/secrets-check.sh` (`task lint:secrets`, strict in CI): every file a
  KSOPS generator lists exists and is sealed. A missing file would otherwise
  pass every other check and stall a whole layer.
- `scripts/placeholder-check.sh` (`task lint:placeholders`): no `REPLACE-ME`,
  `CHANGEME` and similar in anything Argo CD syncs; deferrals go in
  `scripts/placeholder-allowlist.tsv`, each with the command that removes it.
- gitleaks on every pull request, and GitHub secret scanning with push
  protection on the repository.

## Failure modes

| Symptom | Cause |
| --- | --- |
| Secret never appears, Application Synced | file not listed in `secret-generator.yaml` |
| `no key could decrypt the data` | `sops-age` missing or holding the wrong key, or `SOPS_AGE_KEY_FILE` wrong |
| A whole layer stuck at its first wave | a `secrets-*` Application cannot render; `scripts/secrets-check.sh` names the file |
| `MAC mismatch` | a sealed file was edited outside `sops` |
| `failed to load age identities` on macOS with the key present | sops looks in `~/Library/Application Support/sops/age/keys.txt` on macOS; the `secrets:*` tasks source `scripts/lib/sops-age.sh`, which points it at `~/.config/sops/age/keys.txt` |

## Exposure history

Before the repository became public, its history held plaintext credentials
(NAS root SSH key and API key, Cloudflare token, application admin passwords,
OIDC client secrets). They were moved into SOPS, the values still in use were
rotated or retired, and the history was rewritten; the owner tracks the
remaining items privately. GitHub keeps old commits reachable through
pull-request refs, so treat anything that was ever committed in plaintext as
public.

## Why it is like this

- SOPS with age: secrets can be prepared before the cluster exists (a rebuild),
  git stays the source of truth, and nothing else has to run. Rejected: Sealed
  Secrets (needs the cluster's certificate to encrypt), External Secrets plus a
  vault (another always-on service and its own bootstrap secret; a sealed vault
  after every power cut blocks the cluster).
- One key for the cluster: one person administers it. A second recipient (a
  recovery key) is one more `age:` entry and `sops updatekeys`.
- Grouped per layer, not per app: three exec-plugin directories instead of one
  per app.
