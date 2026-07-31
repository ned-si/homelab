# Secrets

Encrypted with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key. Encrypted files live in git;
the key does not.

## Why this approach

Requirements were: no plaintext in git, real GitOps (git stays the source of
truth), and workable offline without a cloud secret manager.

| Option | Why not |
|---|---|
| Sealed Secrets | Encrypting needs the cluster's public cert. You cannot prepare secrets before the cluster exists, which is exactly the situation during a rebuild. |
| External Secrets Operator + backend | Needs a secret manager to run (Vault/OpenBao/Infisical) plus bootstrap credentials for it — a chicken-and-egg problem and another service to keep alive. Bitwarden's Secrets Manager is a separate paid product. |
| **SOPS + age** | One key, generated locally, works offline, git remains the source of truth. Chosen. |

The cost is one moving part in Argo CD: KSOPS, a kustomize plugin that decrypts
at render time. See [Argo CD integration](#how-argo-cd-decrypts) below.

## One-time setup

```sh
task tools        # sops, age, kustomize, kubeconform, helm, yq
task secrets:keygen      # generates the identity and writes its public key into .sops.yaml
```

`task secrets:keygen` prints the private key. **Back it up to your password manager
immediately.** It is the only thing that can decrypt this repository:

- lose it → every secret must be recreated from scratch
- leak it → every secret in git history is readable

It is written to `~/.config/sops/age/keys.txt` with mode 600 and is never
committed (`.gitignore` covers `*.key`, `age.agekey`, `keys.txt`).

Then seed it into the cluster, which is what lets Argo CD decrypt:

```sh
export TF_VAR_sops_age_key="$(cat ~/.config/sops/age/keys.txt)"
task bootstrap:apply
```

## Creating a secret

Every secret ships as a `.example` template that documents what the value is,
how to generate it, and whether the old one is compromised.

```sh
cd infrastructure/secrets
cp cloudflare-cert-manager.sops.yaml.example cloudflare-cert-manager.sops.yaml
$EDITOR cloudflare-cert-manager.sops.yaml          # put the real value in

cd -
task secrets:seal -- infrastructure/secrets/cloudflare-cert-manager.sops.yaml
task secrets:leak-check                                    # confirm it is actually encrypted
```

Then list it in that directory's `secret-generator.yaml` so KSOPS picks it up —
this step is easy to forget and the symptom is a Secret that simply never
appears.

## Editing an existing secret

```sh
task secrets:edit -- platform/secrets/keycloak-admin.sops.yaml
```

`sops` decrypts to a temp file, opens `$EDITOR`, and re-encrypts on save. Never
decrypt in place and re-encrypt by hand; that is how a plaintext file gets
committed.

## Layout

Secrets are grouped per layer, not per app:

```
infrastructure/secrets/    cloudflare tokens, democratic-csi driver config
platform/secrets/          keycloak admin, grafana OIDC
apps/secrets/              immich config, mealie/paperless OIDC, seafile
```

One `secrets-*` Application per layer, syncing at wave `-25` — after namespaces
exist, before anything mounts a Secret. Each decrypted file declares its own
`metadata.namespace`, so one Application seeds several namespaces.

Grouping per layer rather than per app means only three directories use the
kustomize plugin. Everything else renders with plain `kustomize build`, which
keeps the repo debuggable.

### What is deliberately NOT here

**Postgres passwords.** CloudNativePG generates them into `<cluster>-app`
Secrets. They never enter git in any form, not even encrypted. There is nothing
to rotate, leak, or forget. Only credentials defined by an external system —
OIDC clients, bootstrap admins, the MariaDB root password — need to be managed
here.

## How Argo CD decrypts

Three pieces, all configured in `bootstrap/`:

1. **The key.** `bootstrap/main.tf` creates the `sops-age` Secret in the `argocd`
   namespace from `TF_VAR_sops_age_key`.
2. **The tooling.** `bootstrap/argocd-values.yaml` runs an init container
   (`viaductoss/ksops`) that copies the `ksops` and `kustomize` binaries into the
   repo-server, mounts the age key at `/sops-age/keys.txt`, and points
   `SOPS_AGE_KEY_FILE` at it.
3. **The flag.** `configs.cm.kustomize.buildOptions:
   "--enable-alpha-plugins --enable-exec"`. KSOPS is a kustomize *exec* plugin
   and kustomize refuses to run one without both flags.

### Security implication, stated plainly

That flag enables exec plugins for **every** kustomize build the repo-server
performs, not just the secret directories. Any kustomization in this repo could
execute a binary present in the repo-server image.

That is acceptable here because this is a single-operator repo where the only
author is the cluster owner. It would **not** be acceptable in a shared or
multi-tenant cluster — there, scope it with a per-plugin CMP sidecar instead.

This is the integration path KSOPS documents for the Argo CD Helm chart.

## Local rendering

`kubectl kustomize` cannot run exec plugins, so it cannot render the secret
directories. Use real `kustomize` via the Makefile:

```sh
task build      # renders everything, secrets stay encrypted in git
task secrets:decrypt    # writes plaintext into .decrypted/ (git-ignored) for inspection
```

`scripts/render-check.sh` validates everything `kubectl kustomize` can handle and
tells you what it skipped.

## Failure modes

| Symptom | Cause |
|---|---|
| Secret never appears, Application otherwise Synced | File not listed in `secret-generator.yaml` |
| `no key could decrypt the data` | `sops-age` Secret missing, wrong key, or `SOPS_AGE_KEY_FILE` wrong |
| Encrypted files render as nothing, no error | `kustomize.buildOptions` missing the two flags |
| `unable to load exec plugin` | KSOPS/kustomize version mismatch — the init container must override the repo-server's own `kustomize` binary |
| `Degraded` on a `secrets-*` Application on first run | Expected. The real `.sops.yaml` files do not exist yet. |
| `task secrets:seal --` fails with no matching creation rule | `.sops.yaml` still contains `REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` — run `task secrets:keygen` |

## Adding a second key

To let a second machine (or a recovery key) decrypt, add its public key to the
`age:` list in `.sops.yaml`, then re-encrypt existing files to the new recipient
set:

```sh
sops updatekeys infrastructure/secrets/cloudflare-cert-manager.sops.yaml
```

`updatekeys` must be run per file; adding a recipient to `.sops.yaml` does not
retroactively re-encrypt anything.
