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

**Seal first, add the line second, and never the other way round.** KSOPS resolves
every file in that list at render time, so a reference to a file that does not
exist fails the *whole* `secrets-<layer>` Application — taking every other secret
in that layer down with it. `scripts/secrets-check.sh` is the check for exactly
this.

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
kustomize plugin. Everything else is pre-rendered into `deploy/` and needs no
plugin at all, which is what keeps `--enable-exec` from applying to the whole
repo. See [architecture.md](./architecture.md#deploy-rendered-manifests).

**These three directories are the only ones Argo CD builds itself, and the only
ones not present in `deploy/`.** `scripts/render-deploy.sh` refuses to render
them, because rendering means decrypting and the output would be plaintext
Secrets in git.

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
performs, not just the secret directories. Any kustomization it builds could
execute a binary present in the repo-server image.

The setting itself is global and cannot be scoped. What *can* be scoped is how
much it applies to, and that is one of the reasons `deploy/` exists: every other
Application syncs pre-rendered plain YAML, so the repo-server builds only these
three directories instead of every kustomization in the repo. Same flag, a
fraction of the surface. See
[architecture.md](./architecture.md#deploy-rendered-manifests).

The remaining exposure is accepted because this is a single-operator repo whose
only author is the cluster owner. In a shared or multi-tenant cluster it would
not be — there, scope it with a per-plugin CMP sidecar instead.

This is the integration path KSOPS documents for the Argo CD Helm chart.

## Local rendering

`kubectl kustomize` cannot run exec plugins, so it cannot render the secret
directories. Use real `kustomize`:

```sh
task build      # renders everything, secrets stay encrypted in git
task secrets:decrypt    # writes plaintext into .decrypted/ (git-ignored) for inspection
```

`scripts/render-check.sh` renders everything `kubectl kustomize` can handle and
lists what it skipped. It is a **read-only diagnostic** — "which directory is
broken" — not a gate. The gate is `render-deploy.sh --check`, which renders, writes
and diffs, and is what CI runs.

## The three checks around this

None of them needs the age key, which is why all three run in CI.

**`scripts/leak-check.sh`** — refuses unencrypted secret material: a `*.sops.yaml`
without a SOPS envelope, PEM private-key armour, an age secret key, a plaintext
`kind: Secret` payload, and filenames that should never be tracked.

Plus the one that matters most, because it catches the shape the others miss: **a
credential as a literal value anywhere**, not only inside a Secret object. An
`env:` entry with a literal `value:`, a `client_secret:` key in a Helm values file,
a literal in a ConfigMap. Six of the nine credentials in
[security-incident.md](security-incident.md) had exactly that shape and none looked
like a `kind: Secret`. Its scope is everything Argo syncs plus the sources it
renders from, and it deliberately includes `*.example` templates — a template is
where a real credential gets pasted by accident. `docs/` and `*.md` are deliberately
out of scope: Argo never syncs a markdown file.

**`scripts/secrets-check.sh`** — asserts every file the three KSOPS generators
reference exists and carries a SOPS envelope. Nothing else can: the render scripts
hard-skip `*/secrets`, kubeconform validates `deploy/` which excludes them by
construction, and `leak-check.sh` only checks files that exist — so a missing file
passes everything and stalls a whole layer at its first wave.

**Blocking.** The script itself still defaults to warn-only so a fresh clone with no
sealed files is usable, but all three callers — pre-commit, `task lint:secrets` and
CI — set `SECRETS_CHECK_STRICT=1`. All twelve sealed files exist, so a missing or
unsealed one is a regression.

**`scripts/placeholder-check.sh`** — fails on `REPLACE-ME`, `REPLACE_WITH`,
`CHANGEME` and similar in anything Argo syncs. A placeholder is not a syntax error:
`homelab-backups-REPLACE-ME` is well-formed YAML, validates against the schema,
renders deterministically and contains no secret, so every other check passes on it
— and the first backup would have written to a bucket that does not exist.

Deferrals go in **`scripts/placeholder-allowlist.tsv`**: tab-separated, and **every
entry must name the command that removes it**. An entry with no reason is rejected;
one that matches nothing is reported as stale. It is the escape hatch, not the off
switch.

```sh
task secrets:leak-check     # scripts/leak-check.sh
task lint:secrets           # scripts/secrets-check.sh   (fatal)
task lint:placeholders      # scripts/placeholder-check.sh
task lint                   # all of the above, plus yaml and tofu
```

## Failure modes

| Symptom | Cause |
|---|---|
| Secret never appears, Application otherwise Synced | File not listed in `secret-generator.yaml` |
| `no key could decrypt the data` | `sops-age` Secret missing, wrong key, or `SOPS_AGE_KEY_FILE` wrong |
| Encrypted files render as nothing, no error | `kustomize.buildOptions` missing the two flags |
| `unable to load exec plugin` | KSOPS/kustomize version mismatch — the init container must override the repo-server's own `kustomize` binary |
| A whole layer stuck at its first wave | A `secrets-*` Application cannot render. `scripts/secrets-check.sh` names the file. |
| `task secrets:seal --` fails with no matching creation rule | `.sops.yaml` still contains `REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` — run `task secrets:keygen` |
| `failed to load age identities` on **macOS**, key present at `~/.config/sops/age/keys.txt` | sops resolves the default identity path to `~/Library/Application Support/sops/age/keys.txt` on darwin. Source `scripts/lib/sops-age.sh` — every `secrets:*` task already does. Note **encryption still works**, so this only shows up on the first decrypt. |

## Adding a second key

To let a second machine (or a recovery key) decrypt, add its public key to the
`age:` list in `.sops.yaml`, then re-encrypt existing files to the new recipient
set:

```sh
sops updatekeys infrastructure/secrets/cloudflare-cert-manager.sops.yaml
```

`updatekeys` must be run per file; adding a recipient to `.sops.yaml` does not
retroactively re-encrypt anything.
