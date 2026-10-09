#!/usr/bin/env bash
# Extract every credential that was committed in plaintext, and write a crib
# sheet mapping each one to the sealed file it now belongs in.
#
# WHY THIS SCRIPT READS FROM GIT RATHER THAN CONTAINING THE VALUES
#   This script is tracked. If the values were embedded here, the leak would just
#   move to a new file. Instead it reads them out of the pre-restructure commit
#   at runtime and writes them to a git-ignored output file.
#
# OUTPUT: secrets-to-encrypt.local.md  (git-ignored, chmod 600)
#
# Usage:
#   ./scripts/secrets-inventory.sh [git-ref]
#
# `git-ref` defaults to `origin/main`, i.e. the tree as it was before this
# restructure. Pass a commit if origin/main has already moved on.
#
# ---------------------------------------------------------------------------
# DECISION: THE LEAKED CREDENTIALS ARE CARRIED FORWARD, NOT ROTATED.
# Recorded 2026-08-28. Owner's decision, not an oversight, and not a TODO.
#
# The nine credentials inventoried below are re-encrypted with SOPS and kept at their current values. Rotation is
# deferred; the git history is scrubbed once the migration is finished. This
# script exists to move the values into sealed files, not to change them.
#
# The whole point of writing this down is that the decision is CONDITIONAL. It
# holds because of the following facts, all of which are true today:
#
#   - Single operator. There is nobody else with a clone, and no collaborator has
#     ever been added.
#   - Every affected service is reachable only from the LAN or from behind
#     Keycloak. The credentials grant nothing to someone who cannot already reach
#     the network.
#   - Every value is recorded in Bitwarden, so rotation is a decision that can be
#     taken later at leisure rather than a recovery operation.
#   - The repository is private, and the history rewrite is scheduled -- at the
#     END of the migration, deliberately, because rewriting history mid-migration
#     invalidates the `deployed` tag that Argo CD tracks and breaks every existing
#     clone at the moment the cluster is least stable.
#
# ANY OF THE FOLLOWING INVALIDATES IT, and then rotation comes first:
#
#   - the repository becoming public, forked, or gaining a collaborator
#   - any of these services becoming reachable from the internet without
#     authentication in front of it
#   - a GitHub App or CI runner with read access to the tree being compromised
#     (Renovate has read access to the whole repository)
#   - evidence that any of the values has been used from an address that is not
#     the operator's
#
# TWO EXCEPTIONS THAT ARE NOT COVERED BY THIS DECISION, because they are not
# LAN-only application passwords:
#
#   - the OpenSSH private key for root@truenas and the TrueNAS API key.
#     These grant filesystem-level
#     access to every dataset including the backups, and
#     infrastructure/secrets/democratic-csi-iscsi.sops.yaml.example already
#     requires a NEW keypair and a non-root account, so the replacement is a
#     prerequisite of the driver working at all rather than a rotation task.
#   - the Cloudflare API token. It is not LAN-scoped: it edits public DNS
#     for the zone, from anywhere, and therefore enables issuing valid
#     certificates for any subdomain.
#
# ---------------------------------------------------------------------------
# SC2016 IS DISABLED FILE-WIDE, AND THAT IS THE RIGHT CALL HERE.
#
# This script's entire output is Markdown, and Markdown uses backticks for code
# spans. Single-quoted `echo 'a `literal` b'` is therefore the correct quoting on
# almost every line: the point is that nothing expands. shellcheck's "expressions
# don't expand in single quotes" is true and irrelevant sixty times over, and
# sixty inline suppressions would bury the two or three lines where a missing
# expansion WOULD be a bug.
#
# The alternative -- switching to double quotes and escaping every backtick --
# would introduce exactly the class of bug the warning is about, in reverse.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

REF="${1:-origin/main}"
OUT="secrets-to-encrypt.local.md"

if ! git rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
  echo "error: git ref '$REF' not found." >&2
  echo "Try:  $0 main        or      $0 <commit-sha>" >&2
  exit 1
fi

# Refuse to write if the output would somehow be tracked.
if git ls-files --error-unmatch "$OUT" >/dev/null 2>&1; then
  echo "error: $OUT is TRACKED by git. Untrack it before continuing:" >&2
  echo "    git rm --cached $OUT" >&2
  exit 1
fi
if ! git check-ignore -q "$OUT" 2>/dev/null; then
  echo "error: $OUT is not covered by .gitignore. Refusing to write a plaintext" >&2
  echo "       secret file that could be committed. Add it to .gitignore first." >&2
  exit 1
fi

show() { git show "$REF:$1" 2>/dev/null; }

# Pull a scalar `key: value` out of a file, first match wins, quotes stripped.
scalar() {
  show "$1" | grep -m1 -E "^[[:space:]]*(- name: )?${2}:?[[:space:]]" >/dev/null 2>&1 || true
  show "$1" \
    | grep -m1 -E "^[[:space:]]*${2}:[[:space:]]*" \
    | sed -E "s/^[[:space:]]*${2}:[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*#.*$//" \
    || true
}

# Pull the `value:` that follows `- name: <ENVVAR>` in a Deployment env block.
envvar() {
  show "$1" \
    | grep -A1 -E "^[[:space:]]*-[[:space:]]*name:[[:space:]]*${2}[[:space:]]*$" \
    | grep -m1 -E "^[[:space:]]*value:" \
    | sed -E "s/^[[:space:]]*value:[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//" \
    || true
}

# Extract an inclusive line range, used for the multi-line SSH key.
block() {
  show "$1" | sed -n "/$2/,/$3/p" | sed -E 's/^[[:space:]]{8}//'
}

umask 077
: >"$OUT"
chmod 600 "$OUT"

{
  cat <<'HEADER'
# Secrets to encrypt

Generated by `scripts/secrets-inventory.sh`. **Git-ignored — never commit this.**

Every value below was read out of the pre-restructure git history, and every one
of them is still live.

## These are not being rotated

Decided 2026-08-28. Carry them forward as-is: seal them at their current values
and move on. The conditions this rests on, and the events that would revoke it,
are recorded in the header of `scripts/secrets-inventory.sh` — read them there
rather than re-deriving them.

Two things in this file are NOT covered by that decision and do need new values,
because neither is a LAN-only application password: the **TrueNAS SSH key and API
key** (section 2), which are filesystem-level access to every dataset including
the backups, and the **Cloudflare API token** (section 1), which edits public DNS
from anywhere. The templates for both already require fresh values.

## How to use this

For each row: copy the value into the listed file, then seal it.

```sh
cp <template>.example <template>            # drop the .example suffix
$EDITOR <template>                          # paste the value
task secrets:seal -- <template>
```

Or do the whole lot at once, once every file is filled in:

```sh
task secrets:seal:all
task secrets:leak-check
```

## Before you finish

- [ ] `task secrets:leak-check` passes
- [ ] `git status` shows no `*.sops.yaml` that lacks a `sops:` block
- [ ] **delete this file** once the sealed versions exist
- [ ] every value above is in Bitwarden — this is what makes the no-rotation
      decision reversible later instead of a one-way door
- [ ] scrub the history, AFTER the migration is finished, not during it. A rewrite
      changes every commit hash, which invalidates the `deployed` tag Argo CD
      tracks and breaks every existing clone; doing that while the cluster is
      still being brought up turns one problem into two

---

HEADER

  # ---------------------------------------------------------------------------
  echo '## 1. Cloudflare API token'
  echo
  echo 'One token was used for both cert-manager and external-dns. The templates'
  echo 'expect two so they can be revoked independently, but the same value works'
  echo 'in both for now.'
  echo
  echo 'Files:'
  echo '  `infrastructure/secrets/cloudflare-cert-manager.sops.yaml`  key: `api-token`'
  echo '  `infrastructure/secrets/cloudflare-external-dns.sops.yaml`  key: `api-token`'
  echo
  echo '```'
  scalar kubernetes/applications/cert-manager/cf-api-token-secret.yaml 'api-token'
  echo '```'
  echo

  # ---------------------------------------------------------------------------
  echo '## 2. TrueNAS / democratic-csi'
  echo
  echo 'File: `infrastructure/secrets/democratic-csi-iscsi.sops.yaml`'
  echo
  echo 'The whole driver config goes under the `driver-config-file.yaml` key. The'
  echo 'template already contains the non-secret structure; paste these two in.'
  echo
  echo '### API key (`httpConnection.apiKey`)'
  echo '```'
  scalar iac/truenas-iscsi.yaml 'apiKey'
  echo '```'
  echo
  echo '### SSH private key (`sshConnection.privateKey`)'
  echo
  echo 'NOTE: the old config used `username: root`. The template says'
  echo '`democratic-csi`. If you keep this key as-is, set the username back to'
  echo '`root` or the driver cannot log in.'
  echo
  echo '```'
  block iac/truenas-iscsi.yaml 'BEGIN OPENSSH PRIVATE KEY' 'END OPENSSH PRIVATE KEY'
  echo '```'
  echo

  # ---------------------------------------------------------------------------
  echo '## 3. Keycloak bootstrap admin'
  echo
  echo 'File: `platform/secrets/keycloak-admin.sops.yaml`'
  echo
  echo '| key | value |'
  echo '|---|---|'
  echo "| \`username\` | \`$(envvar kubernetes/applications/keycloak/keycloak.yaml 'KC_BOOTSTRAP_ADMIN_USERNAME')\` |"
  echo "| \`password\` | \`$(envvar kubernetes/applications/keycloak/keycloak.yaml 'KC_BOOTSTRAP_ADMIN_PASSWORD')\` |"
  echo
  echo 'Only applies to an EMPTY Keycloak database. If Keycloak already has an'
  echo 'admin user, this value is inert and the real password is whatever is in'
  echo 'the admin console.'
  echo

  # ---------------------------------------------------------------------------
  echo '## 4. Grafana OIDC client secret'
  echo
  echo 'File: `platform/secrets/grafana-oidc.sops.yaml`'
  echo 'Key:  `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`'
  echo
  echo '```'
  scalar kubernetes/applications/kube-prom-stack.yaml 'client_secret'
  echo '```'
  echo
  echo 'CAUTION: the old Keycloak client was named `grafana-oauth`, but'
  echo '`platform/kube-prometheus-stack/values.yaml` now sets `client_id: grafana`.'
  echo 'Either rename the client in Keycloak or change the values file back, or'
  echo 'login will fail with `invalid_client` regardless of the secret.'
  echo

  # ---------------------------------------------------------------------------
  echo '## 5. Immich OIDC client secret'
  echo
  echo 'File: `apps/secrets/immich-config.sops.yaml`'
  echo 'Location: `oauth.clientSecret` inside the `immich-config.json` blob'
  echo
  echo '```'
  scalar kubernetes/applications/immich/immich.yaml 'clientSecret'
  echo '```'
  echo

  # ---------------------------------------------------------------------------
  echo '## 6. Mealie OIDC client secret'
  echo
  echo 'File: `apps/secrets/mealie-oidc.sops.yaml`'
  echo 'Key:  `OIDC_CLIENT_SECRET`'
  echo
  echo '```'
  envvar kubernetes/applications/mealie/mealie-deploy.yaml 'OIDC_CLIENT_SECRET'
  echo '```'
  echo

  # ---------------------------------------------------------------------------
  echo '## 7. Paperless'
  echo
  echo 'File: `apps/secrets/paperless-secrets.sops.yaml`'
  echo
  echo '### `PAPERLESS_ADMIN_USER` / `PAPERLESS_ADMIN_PASSWORD`'
  echo '```'
  echo "user:     $(envvar kubernetes/applications/paperless/paperless-deploy.yaml 'PAPERLESS_ADMIN_USER')"
  echo "password: $(envvar kubernetes/applications/paperless/paperless-deploy.yaml 'PAPERLESS_ADMIN_PASSWORD')"
  echo '```'
  echo
  echo '### `PAPERLESS_SOCIALACCOUNT_PROVIDERS`'
  echo
  echo 'Paste this whole single-line JSON as the value. It already contains the'
  echo 'OIDC client secret.'
  echo
  echo '```'
  envvar kubernetes/applications/paperless/paperless-deploy.yaml 'PAPERLESS_SOCIALACCOUNT_PROVIDERS'
  echo '```'
  echo
  echo '### `PAPERLESS_SECRET_KEY` — MUST BE GENERATED, there is no old value'
  echo
  echo 'This was never set, so Paperless has been running on the public default'
  echo 'Django signing key. Generate one:'
  echo
  echo '```sh'
  echo 'openssl rand -base64 48'
  echo '```'
  echo
  echo 'Setting it invalidates existing sessions, which is the point.'
  echo

  # ---------------------------------------------------------------------------
  echo '## 8. Seafile'
  echo
  echo '### MariaDB root password'
  echo 'File: `apps/secrets/seafile-db.sops.yaml`  key: `root-password`'
  echo
  echo 'Read by BOTH the mariadb and seafile Deployments — one value, not two.'
  echo
  echo '```'
  envvar kubernetes/applications/seafile/seafile-deploy.yaml 'DB_ROOT_PASSWD'
  echo '```'
  echo
  echo '### Seafile admin'
  echo 'File: `apps/secrets/seafile-admin.sops.yaml`'
  echo
  echo '| key | value |'
  echo '|---|---|'
  echo "| \`SEAFILE_ADMIN_EMAIL\` | \`$(envvar kubernetes/applications/seafile/seafile-deploy.yaml 'SEAFILE_ADMIN_EMAIL')\` |"
  echo "| \`SEAFILE_ADMIN_PASSWORD\` | \`$(envvar kubernetes/applications/seafile/seafile-deploy.yaml 'SEAFILE_ADMIN_PASSWORD')\` |"
  echo

  # ---------------------------------------------------------------------------
  echo '## 9. Not needed any more'
  echo
  echo 'Listed so you do not go looking for a home for them.'
  echo
  echo '| Old value | Why it is gone |'
  echo '|---|---|'
  echo '| Every Postgres password | CloudNativePG generates them into `<cluster>-app` Secrets. Nothing to store. |'
  cat <<PLEX
| \`PLEX_CLAIM\` = \`$(envvar kubernetes/applications/plex/plex-deploy.yaml 'PLEX_CLAIM')\` | Claim tokens expire after ~4 minutes. Long dead. Only needed to claim a brand-new server. |
PLEX
  echo
  echo '## 10. Still to create from scratch'
  echo
  echo 'These have no old value and are not application secrets:'
  echo
  echo '- **age identity** — `task secrets:keygen`, then back it up.'
  echo '- **GitHub PAT** for Argo CD — `contents: read` on this repo only.'
  echo '  Export as `TF_VAR_git_token`.'
  echo
  echo '### S3 backup credentials — SAVE ALL SIX TO BITWARDEN'
  echo
  echo 'Created by `scripts/tofu.sh bootstrap/aws-backup apply`. Read each with'
  echo '`scripts/tofu.sh bootstrap/aws-backup output -raw <name>` (the `tofu output`'
  echo 'below is shorthand for that).'
  echo
  echo '| Bitwarden entry | Where it comes from | Used by |'
  echo '|---|---|---|'
  echo '| `homelab / AWS backup writer — key id` | `tofu output -raw backup_access_key_id` | barman + restic CronJobs |'
  echo '| `homelab / AWS backup writer — secret` | `tofu output -raw backup_secret_access_key` | same |'
  echo '| `homelab / AWS backup verifier — key id` | `tofu output -raw verify_access_key_id` | read-only restore drills |'
  echo '| `homelab / AWS backup verifier — secret` | `tofu output -raw verify_secret_access_key` | same |'
  echo '| `homelab / RESTIC_PASSWORD` | `openssl rand -base64 48` | encrypts the restic repositories |'
  echo '| `homelab / TOFU_STATE_PASSPHRASE` | `secrets.local.env` | encrypts every OpenTofu state in S3 |'
  echo
  echo 'The first four go into `platform/secrets/s3-backup.sops.yaml`, which needs'
  echo 'BOTH key spellings: `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY` for barman and'
  echo '`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for restic. The two tools'
  echo 'disagree about naming and neither is configurable.'
  echo
  echo '**`RESTIC_PASSWORD` is not recoverable.** Lose it and every file backup is'
  echo 'permanently unreadable, including by you. Store it beside the age key, and'
  echo 'not only in this cluster.'
  echo
  echo '**`TOFU_STATE_PASSPHRASE` is not recoverable either.** The module state'
  echo '(both secret keys) lives in s3://ned-si-homelab-tofu-state, encrypted by'
  echo 'OpenTofu with it; without it that state is unreadable. See docs/bootstrap.md.'
  echo
  echo '### AWS account itself'
  echo
  echo '- [ ] **root password rotated** and **MFA enabled**. The root console'
  echo '      password was shared in a chat transcript.'
  echo '- [ ] no root access keys exist (`aws iam list-access-keys` as root, or'
  echo '      check the console security credentials page)'
  echo '- [ ] an admin IAM user exists for you, so `tofu apply` never needs root'
  echo
} >>"$OUT"

echo "Wrote $OUT (mode 600, git-ignored)."
echo
echo "It contains LIVE credentials in plaintext. Delete it once the sealed files"
echo "exist:  rm $OUT"
