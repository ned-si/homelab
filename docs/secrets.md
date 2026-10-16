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
| `platform/secrets/` | `keycloak-admin`, `grafana-oidc`, `s3-backup`, `alertmanager-notify`, `argocd-notifications`, `cnpg-backup-s3`, `usage-exporter`, `aws-exporter`, `keycloak-proxy-clients`, `tailscale-operator`, `headlamp-sso` | `secrets-platform` (wave -25) |
| `apps/secrets/` | `immich-config`, `mealie-oidc`, `paperless-secrets`, `plex-claim`, `recyclarr-api-keys`, `theater-sso` | `secrets-apps` (wave -25) |

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

## Read-only automation access

Tools that only inspect the platform (MCP servers, agents) get read-only
credentials that live outside the repository, under `~/homelab-backups/agent/`
(mode 600):

| Credential | Defined in | Grants |
| --- | --- | --- |
| Kubernetes ServiceAccount `kube-system/agent-readonly` | `platform/agent-access/rbac.yaml` | ClusterRole `view` plus read on nodes; no Secrets, no exec |
| Argo CD account `agent` (API key only) | `bootstrap/argocd-values.yaml`, `accounts.agent` | `role:readonly` |
| Grafana service account `agent-readonly` | Grafana API (Grafana has no service account provisioning); kept in `grafana.db` on PVC `monitoring/kube-prometheus-stack-grafana`, so it survives restarts | Viewer |

Build the Kubernetes kubeconfig from the token Secret (prints nothing):

```sh
token=$(kubectl -n kube-system get secret agent-readonly-token -o jsonpath='{.data.token}' | base64 -d)
out=~/homelab-backups/agent/kubeconfig-readonly
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/agent-ca.crt
KUBECONFIG=$out kubectl config set-cluster homelab --server=https://192.168.1.11:6443 --certificate-authority=/tmp/agent-ca.crt --embed-certs=true
KUBECONFIG=$out kubectl config set-credentials agent-readonly --token="$token"
KUBECONFIG=$out kubectl config set-context agent --cluster=homelab --user=agent-readonly
KUBECONFIG=$out kubectl config use-context agent
chmod 600 "$out"; rm /tmp/agent-ca.crt; unset token
KUBECONFIG=$out kubectl auth can-i get secrets -A
```

Expected: `no`. Argo CD token: `argocd account generate-token --account agent`
as an admin. Grafana token: Administration, Service accounts,
`agent-readonly`, Add token. Revoke by deleting the token Secret (Argo CD
recreates it with a new value), the Argo CD token
(`argocd account delete-token`) or the Grafana token.

## Rotation periods

Every sealed file has a row in `ci/secret-rotation.tsv`: its class and the
date its values were last set. The class sets how long a value may live:

| Class | Period | What |
| --- | --- | --- |
| `api-token` | 180 days | Keys and tokens for an outside system or the NAS: AWS IAM keys (`s3-backup`, `cnpg-backup-s3`, `aws-exporter`), Cloudflare, the GitHub token (`argocd-notifications`), TrueNAS (`democratic-csi-iscsi`), and `usage-exporter`, whose Jellyfin key is admin-level |
| `credential` | 365 days | Passwords, OIDC client secrets and app API keys inside the homelab |
| `static` | on compromise only | `talsecret` (the Talos PKI; rotating it is a CA rotation), `alertmanager-notify` (the ntfy topic and the heartbeat URL; a new topic means re-subscribing the phone), `plex-claim` (single use) |

Credentials outside git follow the same classes: the Actions secret
`AUTO_ROLLBACK_TOKEN` (the same value as `argocd-notifications`, so the same
row), `NTFY_TOPIC` (`static`), the Argo CD OIDC client secret, the NAS root
password and the DNS registrar and Cloudflare account logins (`credential`).
Nothing checks the last four; rotate them with their sealed neighbours.

Checks (dates only, never a value):

- `scripts/ci/secret_rotation.py coverage` (repo-policy, every pull request):
  every `*.sops.yaml` has exactly one row, no row is stale, classes and dates
  are valid.
- `scripts/ci/secret_rotation.py age` (workflow `secret-age`, Mondays 07:00
  UTC): any row past its period fails the run, and the failure posts to ntfy.
  Rows due within 30 days are listed in the run log.

Run both locally:

```sh
python3 scripts/ci/secret_rotation.py coverage
python3 scripts/ci/secret_rotation.py age
```

Expected: `secret-rotation <mode>: <n> row(s), 0 failure(s), ...` and exit 0.
After a rotation (below), set the file's date in `ci/secret-rotation.tsv` to
the day of the change, in the same pull request. A new sealed file gets its
row in the pull request that adds it.

## Rotating a credential

The general pattern: create the new value at its source, put it in the sealed
file, merge, let Argo CD sync, restart the consumer if it reads the value only
at start, prove the new value works and the old one is refused, then record the
new value in the password manager.

| Credential | Source of truth | Sealed file, key | Notes |
| --- | --- | --- | --- |
| Keycloak admin | Keycloak master realm (`kcadm.sh set-password`) | `platform/secrets/keycloak-admin.sops.yaml`, `password` | `KC_BOOTSTRAP_ADMIN_PASSWORD` only applies to an empty database: change the user in Keycloak first, then bump `kubectl.kubernetes.io/restartedAt` in `platform/keycloak/deployment.yaml` |
| OIDC client secrets (Grafana, Immich, Mealie, Paperless) | Keycloak, Clients, *client*, Credentials, Regenerate | `grafana-oidc`, `immich-config` (inside `immich-config.yaml`), `mealie-oidc`, `paperless-secrets` (`PAPERLESS_SOCIALACCOUNT_PROVIDERS`) | |
| Argo CD OIDC client secret | Keycloak client `argocd` | not in git: `argo/argocd-secret`, `oidc.keycloak.clientSecret` | patch the Secret, restart `argocd-server` |
| Paperless admin | `manage.py changepassword` in the pod | `paperless-secrets`, `PAPERLESS_ADMIN_PASSWORD` | |
| TrueNAS API key | TrueNAS UI, API Keys | `democratic-csi-iscsi`, `apiKey` in `driver-config-file.yaml` | restart the democratic-csi controller and node pods, test a volume attach, then delete the old key |
| TrueNAS SSH key | new keypair, public key on the NAS | `democratic-csi-iscsi`, `privateKey` | remove the old public key from the NAS afterwards |
| Cloudflare tokens | Cloudflare dashboard: one token per consumer, Zone Read + DNS Edit on `lilalala.com` only | `cloudflare-cert-manager`, `cloudflare-external-dns`, `api-token` | check external-dns logs and a certificate renewal, then revoke the old token |
| Automatic rollback GitHub token | GitHub, fine-grained token, `ned-si/homelab` only, Contents + Pull requests + Issues read and write | `platform/secrets/argocd-notifications.sops.yaml`, `github-token`, and the Actions secret `AUTO_ROLLBACK_TOKEN` | the same value in both places; see [decisions.md](decisions.md#automatic-rollback) |
| S3 backup keys, `RESTIC_PASSWORD` | `bootstrap/aws-backup` outputs | `platform/secrets/s3-backup.sops.yaml` | the same `RESTIC_PASSWORD` in every namespace; changing it needs `restic key add` on every repository first |
| Usage exporter keys (180 days) | Immich: Account Settings, API Keys, permission `server.statistics` only. Jellyfin: Dashboard, API Keys, app `usage-exporter`; Jellyfin keys cannot be scoped, so this one is admin-level | `platform/secrets/usage-exporter.sops.yaml`, `IMMICH_API_KEY`, `JELLYFIN_API_KEY`; `secrets.local.env` keys `USAGE_IMMICH_API_KEY`, `USAGE_JELLYFIN_API_KEY` | re-seal per the template; once `secrets-platform` has synced, bump `restartedAt` in `platform/usage-exporter/deployment.yaml` in a second pull request (in the same one the pod can restart before the Secret changes); check `usage_source_up` is 1, then delete the old key in the app. Only the exporter pod is allowed to Jellyfin by `jellyfin-usage` (`infrastructure/network-policies/15-theater-metrics.yaml`), which only binds once theater enforcement is on; Jellyfin is public at `cinema.lilalala.com`, so a leaked key works from anywhere until it is deleted |
| CNPG S3 key (IAM user `ned-si-homelab-backups-cnpg`) | `bootstrap/aws-backup` outputs `cnpg_access_key_id`, `cnpg_secret_access_key`; `secrets.local.env` keys `CNPG_S3_ACCESS_KEY_ID`, `CNPG_S3_SECRET_ACCESS_KEY` | `platform/secrets/cnpg-backup-s3.sops.yaml`, Secret `cnpg-backup-s3` (`ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`) in immich, keycloak, mealie, theater | rotate with a new `aws_iam_access_key`, re-seal, then check `ContinuousArchiving` on every cluster |

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
- Rotation age from a dated table in git, not from the cluster: a Secret's
  `creationTimestamp` (`kube_secret_created`) does not move when Argo CD
  updates its values, and `sops.lastmodified` moves on every re-seal, even with
  the same values. Rejected: an in-cluster Prometheus alert on Secret age.
- Grouped per layer, not per app: three exec-plugin directories instead of one
  per app.
