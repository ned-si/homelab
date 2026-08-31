#!/usr/bin/env bash
# Refuse to let unencrypted secret material reach a commit.
#
# A safety net, not a security control: it catches accidents, not a determined
# mistake. Run before committing, or wire it in as a pre-commit hook.
#
#   exit 0  clean
#   exit 1  something looks unencrypted
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SELF="scripts/leak-check.sh"

fail=0
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; fail=1; }
good() { printf '\033[32m%s\033[0m\n' "$*"; }

# Prefer the staged set, which is what a pre-commit hook cares about.
#
# Otherwise scan tracked files AND untracked-but-not-ignored files. `git ls-files`
# alone would miss a brand-new secret sitting in the working tree, which is
# exactly the moment you most want to be told -- a clean report on a tree
# containing an unstaged private key is worse than no report at all.
# `--exclude-standard` keeps .gitignore'd paths (the age key, kubeconfig,
# secrets-to-encrypt.local.md) out of scope, since those are meant to exist.
files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
scope="staged"
if [[ -z "$files" ]]; then
  files="$(git ls-files --cached --others --exclude-standard)"
  scope="tracked + untracked"
fi
echo "Scanning $scope files..."

# Files that legitimately contain the patterns we grep for:
#   *.example    templates showing the SHAPE of a secret, with placeholders
#   .sops.yaml   the SOPS CONFIG (recipients), not a secret. Note it matches the
#                *.sops.yaml glob by accident, hence the explicit exclusion.
#   docs/        prose that discusses these patterns
#   this script  contains the patterns as literals
#
# NOTE: this exemption applies to checks 1-3 only. Check 4 (inline credentials)
# uses its own, narrower scope -- see is_argo_synced() and the reasoning above it.
is_exempt() {
  case "$1" in
    *.example|.sops.yaml|docs/*|"$SELF") return 0 ;;
    *) return 1 ;;
  esac
}

# Scope for check 4: everything that ends up on the cluster, plus the sources it
# is rendered from so the report names the file a human would edit.
#
# `deploy/` is what Argo CD applies. The four source trees are where the value
# would have been written. `bootstrap/` configures Argo CD itself and holds the
# OpenTofu that seeds the age key, so a literal there is applied too.
#
# DELIBERATELY OUT OF SCOPE, and this is a decision rather than an oversight:
#
#   docs/ and *.md   Prose. docs/security-incident.md names every leaked variable
#                    and docs/backups.md contains shell snippets with
#                    `-p'<OLD>'`. Argo CD never syncs a markdown file, so a value
#                    there cannot reach the cluster -- and a check that fires on
#                    the document describing the incident is a check that gets an
#                    exclusion added to it within a week.
#
# NOT out of scope, unlike checks 1-3: `*.example`. Those files live inside the
# source trees below and check 4 sees them. That is on purpose. A template is
# exactly where a real credential gets pasted by accident -- you edit the copy,
# but the first thing you did was open the original -- and nothing else in the
# repo would notice. The placeholder guard in the awk program below is what keeps
# the shipped templates quiet: every one of them holds a `PUT_THE_..._HERE`-shaped
# value, and a value that is NOT placeholder-shaped in a template is a finding.
is_argo_synced() {
  case "$1" in
    apps/*|platform/*|infrastructure/*|clusters/*|deploy/*|bootstrap/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Secrets that legitimately appear in rendered output because they come from an
# UPSTREAM release bundle, not from this repo. Matched as <namespace>/<name>,
# with a trailing * because kustomize appends a content hash.
#
# Every entry needs a reason. If you cannot write one, it is not allowed.
is_allowed_secret() {
  case "$1" in
    # Barman Cloud plugin bundle. Holds a single key, SIDECAR_IMAGE, whose value
    # is a base64-encoded container image reference -- not a credential. Upstream
    # ships it as a Secret rather than a ConfigMap; that is their choice, not a
    # leak. Verify after a bundle bump with:
    #   grep -A4 'kind: Secret' deploy/platform/barman-cloud-plugin/manifests.yaml
    cnpg-system/plugin-barman-cloud-*) return 0 ;;
    *) return 1 ;;
  esac
}

# Same idea for check 4: a `<key>` in a `<file>` whose literal value is not a
# credential, where no general rule can tell. Matched as `<path>:<lowercase key>`.
#
# Every entry needs a reason. Keep this list SHORT -- if it grows past a handful,
# the rule in key_is_reference() is wrong and should be fixed instead.
is_allowed_inline() {
  case "$1" in
    # Vendored upstream bundle, not this repo's manifests:
    # platform/barman-cloud-plugin/kustomization.yaml pulls
    # plugin-barman-cloud v0.12.0's manifest.yaml. These two annotations tell
    # CloudNativePG which Secret holds the plugin's mTLS certificate; the values
    # are Secret NAMES (`barman-cloud-client-tls`, `barman-cloud-server-tls`),
    # created by the cert-manager Certificate in the same bundle.
    #
    # Re-verify after a bundle bump with:
    #   grep -n 'pluginClientSecret\|pluginServerSecret' \
    #     deploy/platform/barman-cloud-plugin/manifests.yaml
    deploy/platform/barman-cloud-plugin/manifests.yaml:cnpg.io/pluginclientsecret) return 0 ;;
    deploy/platform/barman-cloud-plugin/manifests.yaml:cnpg.io/pluginserversecret) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  is_exempt "$f" && continue

  # 1. Anything named *.sops.yaml must actually be encrypted.
  case "$f" in
    *.sops.yaml|*.sops.yml|*.sops.env)
      if ! grep -q '^sops:' "$f" && ! grep -q 'ENC\[AES256_GCM' "$f"; then
        bad "NOT ENCRYPTED: $f  (run: task secrets:seal -- $f)"
      fi
      continue    # an encrypted file legitimately contains 'stringData' etc.
      ;;
  esac

  # 2. Private key material must never appear in a non-exempt file.
  #
  # The PEM armour delimiters are required. Real key material always carries
  # them; the bare phrase "BEGIN OPENSSH PRIVATE KEY" also appears as a string
  # literal in scripts/secrets-inventory.sh, which extracts keys from an old git
  # ref. Matching on the phrase alone made this script fail on its own tooling.
  if grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" 2>/dev/null; then
    bad "PRIVATE KEY: $f"
  fi
  if grep -q 'AGE-SECRET-KEY-1' "$f" 2>/dev/null; then
    bad "AGE SECRET KEY: $f"
  fi

  # 3. A plaintext Kubernetes Secret payload. Only meaningful in YAML that is
  #    not SOPS-encrypted (encrypted files were skipped above).
  #
  #    This is PER YAML DOCUMENT, not per file. A naive per-file grep breaks on
  #    the rendered multi-document files in deploy/, where `kind: Secret` in one
  #    document and a `data:` key in an unrelated CRD schema in another look
  #    identical to a leaked Secret. Two false positives, both silenced by
  #    scoping to a single document and requiring `data:`/`stringData:` at zero
  #    indent -- which is where a Secret's payload always lives, and where a
  #    field inside a CRD's openAPIV3Schema never does.
  case "$f" in
    *.yaml|*.yml)
      offenders=$(awk '
        function flush() {
          if (is_secret && has_data) {
            printf "%s/%s\n", (ns == "" ? "-" : ns), (nm == "" ? "-" : nm)
          }
          is_secret = 0; has_data = 0; ns = ""; nm = ""; in_meta = 0
        }
        /^---[[:space:]]*$/ { flush(); next }
        /^kind:[[:space:]]*Secret[[:space:]]*$/ { is_secret = 1; next }
        /^(stringData|data):[[:space:]]*$/      { has_data = 1; next }
        /^metadata:[[:space:]]*$/               { in_meta = 1; next }
        /^[^[:space:]]/                         { in_meta = 0 }
        in_meta && /^[[:space:]]+name:[[:space:]]/      { nm = $2 }
        in_meta && /^[[:space:]]+namespace:[[:space:]]/ { ns = $2 }
        END { flush() }
      ' "$f" 2>/dev/null)

      for o in $offenders; do
        if is_allowed_secret "$o"; then
          continue
        fi
        bad "PLAINTEXT SECRET: $f  ($o -- should be a sealed *.sops.yaml)"
      done
      ;;
  esac
done <<<"$files"

# ---------------------------------------------------------------------------
# 4. A CREDENTIAL AS A LITERAL VALUE, ANYWHERE -- not just in a Secret object.
#
# WHY THIS EXISTS
#   Check 3 above only recognises a `kind: Secret` with a `data:`/`stringData:`
#   payload. Six of the nine credentials in docs/security-incident.md were not
#   that shape at all. They were:
#
#     KC_BOOTSTRAP_ADMIN_PASSWORD   an `env:` entry with a literal `value:`
#     MARIADB_ROOT_PASSWORD         same, and pasted a second time as DB_ROOT_PASSWD
#     PAPERLESS_ADMIN_PASSWORD      same
#     SEAFILE_ADMIN_PASSWORD        same
#     the OIDC client secrets       a `client_secret:` mapping key in Helm values,
#                                   and one buried in a JSON blob in an env value
#     PLEX_CLAIM                    same env shape
#
#   Every one of them was invisible to this script, which is why the script
#   reported clean while the repository was leaking. A ConfigMap and a Helm
#   values.yaml are just as applied as a Secret; only the kind differs.
#
# WHY awk AND NOT grep -P
#   BSD grep on macOS has no -P, and the shapes need two-line state anyway (an
#   `- name: X` followed by a `value: Y` on a later line, where an intervening
#   `valueFrom:` means the opposite conclusion). Perl-compatible lookahead is not
#   needed once tolower() is doing the case-insensitivity.
#
# HOW FALSE POSITIVES ARE AVOIDED. Each of these is a real construct in this repo
# and each one used to fire before it was excluded:
#
#   secretKeyRef / valueFrom   the correct pattern. `- name: X` followed by
#                              `valueFrom:` clears the pending match instead of
#                              reporting it.
#   *Ref / *Name keys          `secretName`, `secretKeyRef`, `tokenSecretRef`,
#                              `privateKeySecretRef`, `existingSecret` all hold
#                              the NAME of a Secret, never its contents.
#   *Secrets (plural) keys     `imagePullSecrets`, `secretResources`,
#                              `assertNoLeakedSecrets` are lists or flags.
#   *_FILE / *Path keys        point at a file, by definition not the value.
#   block scalars              `privateKey: |` -- the key material is on the
#                              following lines and check 2 (the PEM armour) is
#                              what catches it. Reporting the `|` would be noise.
#   templated values           `$__env{...}` (Grafana), `${...}`, `$(...)`,
#                              `{{ ... }}`, `<...>`.
#   booleans and numbers       `OIDC_AUTH_ENABLED: "true"`, `port: 443`.
#   placeholders               `PUT_THE_..._HERE`, `REPLACE-ME` and friends. Note
#                              scripts/placeholder-check.sh owns the question of
#                              whether a placeholder should still be there; this
#                              check only needs to know it is not a credential.
#
# WHAT IT CANNOT SEE, stated so nobody assumes otherwise: a credential under a key
# whose name does not suggest one (`foo: hunter2`), a credential inside a base64
# blob, and a credential inside a block scalar that is not PEM-armoured.
# ---------------------------------------------------------------------------
inline_scan() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

    # Strip one layer of matching quotes, so the value guards see the payload.
    function unquote(s) {
      if (s ~ /^".*"$/ || s ~ /^\x27.*\x27$/) { s = substr(s, 2, length(s) - 2) }
      return s
    }

    # Key names that name, locate or configure a secret rather than containing
    # one. Every arm here was added because a real construct in this repo or in a
    # vendored upstream bundle matched otherwise; the file and key are named.
    function key_is_reference(k) {
      # `secretKeyRef`, `tokenSecretRef`, `privateKeySecretRef`, `claimRef`.
      if (k ~ /(ref|refs)$/)                 { return 1 }
      # `secretName`, `existingSecretName`, `claimName`.
      if (k ~ /name$/)                       { return 1 }
      # `imagePullSecrets`, `secretResources` (KSOPS), `assertNoLeakedSecrets`.
      if (k ~ /secrets$/)                    { return 1 }
      # `*_FILE` and `privateKeyPath` point AT the value, and are the recommended
      # pattern rather than a leak.
      if (k ~ /(file|path|dir)$/)            { return 1 }
      # `existingSecret`, `existingConfigSecret` (infrastructure/democratic-csi/
      # values-iscsi.yaml), `existingClaim` (apps/immich/values.yaml).
      if (k ~ /^existing/)                   { return 1 }
      # `reclaimPolicy` / `persistentVolumeReclaimPolicy`
      # (infrastructure/nfs-storage/*.yaml, infrastructure/democratic-csi/
      # values-iscsi.yaml) -- these match on "claim", not on anything secret.
      if (k ~ /policy$/)                     { return 1 }
      # An endpoint is not a credential: `token_url`, `api_url`, `issuerUrl`,
      # `tokenEndpoint` (platform/kube-prometheus-stack/values.yaml,
      # apps/secrets/immich-config.sops.yaml.example).
      if (k ~ /(url|uri|endpoint|issuer)$/)  { return 1 }
      # `clientId`, `client_id`, `tokenTemplate`, `secretType`, `apiVersion`.
      if (k ~ /(id|template|templates|type|version|mode|class|scope|scopes)$/) { return 1 }
      if (k ~ /(enabled|_env)$/)             { return 1 }
      if (k == "secret")                     { return 0 }  # a bare `secret:` IS suspicious
      return 0
    }

    function value_is_harmless(v) {
      if (v == "")                                     { return 1 }
      if (v ~ /^[|>][-+]?$/)                           { return 1 }  # block scalar
      if (v ~ /^[&*]/)                                 { return 1 }  # yaml anchor/alias
      if (v ~ /^[[{]/)                                 { return 1 }  # inline seq/map
      if (v ~ /^[$%]/)                                 { return 1 }  # ${..} $(..) $__env{..}
      if (v ~ /^</)                                    { return 1 }  # <placeholder>
      # A YAML TAG NAMING AN INDIRECTION, as Recyclarr uses:
      #     api_key: !env_var SONARR_API_KEY
      # which reads the value from the environment at runtime. Same family as the
      # `${..}` and `*_FILE` cases above: the text in the file is a POINTER, and
      # excusing it is what keeps the check from arguing against the very
      # indirection it exists to demand.
      #
      # Deliberately narrow -- ONE tag, then ONE identifier-shaped token. So
      # `!env_var SONARR_API_KEY` and `!secret sonarr_key` pass, while `!!str
      # hunter2` (two bangs) and `!env_var some literal value` do not.
      if (v ~ /^![a-zA-Z_][a-zA-Z0-9_]*[ \t]+[a-zA-Z_][a-zA-Z0-9_]*$/) { return 1 }
      if (v ~ /[{][{]/)                                { return 1 }  # go/helm template
      u = tolower(unquote(v))
      if (u == "" || u == "null" || u == "~")          { return 1 }
      if (u ~ /^(true|false|yes|no|on|off)$/)          { return 1 }
      if (u ~ /^[0-9]+([.][0-9]+)*$/)                  { return 1 }
      if (length(u) < 4)                               { return 1 }
      # A bare URL is an endpoint. A URL with userinfo is a credential, so the
      # `://user:pass@host` form is deliberately NOT excused here.
      if (u ~ /^https?:\/\//  && u !~ /:\/\/[^\/@]+:[^\/@]+@/) { return 1 }
      # An absolute filesystem path. This is the value half of the `*_FILE`
      # convention -- `/etc/restic/password`, `/run/secrets/token` -- and is a
      # location, not a credential. Base64 payloads contain `/` but never lead
      # with one.
      if (u ~ /^\//)                                   { return 1 }
      # Placeholder shapes. Kept in step with scripts/placeholder-check.sh; that
      # script decides whether a placeholder is acceptable, this one only needs
      # to know it is not a live credential.
      if (u ~ /replace[-_]me|replace[-_]with|change[-_]?me|fill[-_]me[-_]in/) { return 1 }
      if (u ~ /put[-_](a|an|the|your)[-_]/)            { return 1 }
      if (u ~ /_here$|[-_]here$/)                      { return 1 }
      if (u ~ /^(todo|fixme|xxx+|example|dummy|redacted|placeholder|unset|none)$/) { return 1 }
      if (u ~ /todo|fixme|xxxx|redacted|placeholder/)  { return 1 }
      return 0
    }

    BEGIN {
      # High-signal key names. Anything outside this set is out of scope by
      # design: broadening it is how a leak check becomes a grep for "value".
      #
      # TWO regexes, and the difference is `claim`. As an ENVIRONMENT VARIABLE
      # name, `CLAIM` means PLEX_CLAIM -- one of the nine leaked credentials. As a
      # YAML MAPPING key in a Kubernetes manifest it means PersistentVolumeClaim
      # and never a credential: `claimName`, `claimRef`, `existingClaim`,
      # `volumeClaimTemplate`, `reclaimPolicy`,
      # `persistentVolumeReclaimPolicy`. Matching it in both places produced six
      # false positives in this repo and not one true one.
      KEYRE_MAP = "(password|passwd|secret|token|api[_-]?key|private[_-]?key)"
      KEYRE_ENV = "(password|passwd|secret|token|api[_-]?key|private[_-]?key|claim)"
      # The env var name seen on a `- name:` line, waiting for the `value:` or
      # `valueFrom:` that follows it. The line number reported is the one the
      # VALUE is on, because that is the line that has to change.
      #
      # NOTE: no apostrophes anywhere in this awk program. It is delimited by
      # single quotes in the surrounding shell function, so one apostrophe in a
      # comment ends the program and the script fails to parse.
      pending = ""
    }

    # Comment-only lines carry no value.
    /^[[:space:]]*#/ { next }

    {
      line = $0
      if (match(line, /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.\/-]+:([[:space:]]|$)/) == 0) {
        next
      }
      body = line
      sub(/^[[:space:]]*/, "", body)
      sub(/^-[[:space:]]+/, "", body)
      ci = index(body, ":")
      key = substr(body, 1, ci - 1)
      val = trim(substr(body, ci + 1))
      lk = tolower(key)

      # --- shape B, second half: `- name: <ENVVAR>` seen earlier ------------
      if (pending != "") {
        if (lk == "value") {
          if (!value_is_harmless(val)) {
            printf "%d:%s:%s\n", NR, pending, val
          }
          pending = ""
          next
        }
        # `valueFrom:` is the correct pattern, and any other key means the env
        # entry ended without a literal. Either way the pending match is void.
        pending = ""
      }

      # --- shape B, first half ----------------------------------------------
      #
      # key_is_reference() is applied to the ENV VAR NAME as well as to mapping
      # keys, because the same conventions apply there: `RESTIC_PASSWORD_FILE`
      # and `PAPERLESS_DBPASSWORD_FILE` name a path, `TOKEN_URL` names an
      # endpoint. Without this the `*_FILE` convention -- which is the
      # RECOMMENDED way to pass a credential -- reports as a leak, which would
      # push people away from it.
      if (lk == "name" && tolower(val) ~ KEYRE_ENV && !key_is_reference(tolower(unquote(val)))) {
        pending = unquote(val)
        next
      }

      # --- shape A: a mapping key that names a credential -------------------
      if (lk ~ KEYRE_MAP && !key_is_reference(lk)) {
        if (!value_is_harmless(val)) {
          printf "%d:%s:%s\n", NR, key, val
        }
      }
    }
  ' "$1" 2>/dev/null
}

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  is_argo_synced "$f" || continue
  case "$f" in
    *.yaml|*.yml|*.json|*.json5) ;;
    *) continue ;;
  esac
  # A sealed file's payload is ciphertext; there is nothing to read and the
  # ENC[...] values would fire on every key.
  if grep -q '^sops:' "$f" 2>/dev/null || grep -q 'ENC\[AES256_GCM' "$f" 2>/dev/null; then
    continue
  fi

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    lno=${hit%%:*}
    rest=${hit#*:}
    key=${rest%%:*}
    val=${rest#*:}
    if is_allowed_inline "$f:$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"; then
      continue
    fi
    bad "INLINE CREDENTIAL: $f:$lno  $key = $(printf '%s' "$val" | cut -c1-40)"
    bad "                   move it to a *.sops.yaml and reference it with"
    bad "                   valueFrom.secretKeyRef / envFrom.secretRef"
  done <<<"$(inline_scan "$f")"
done <<<"$files"

# 5. Filenames that should never be tracked at all, regardless of content.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.example) continue ;;
    *keys.txt|*age.key|*.agekey|*.pem|*.tfvars|*.tfstate|*.tfstate.*)
      bad "MUST NOT BE TRACKED: $f"
      ;;
    kubeconfig|kubeconfig-*|*.kubeconfig)
      bad "MUST NOT BE TRACKED: $f"
      ;;
  esac
done <<<"$files"

echo
if [[ $fail -eq 0 ]]; then
  good "leak-check passed"
else
  bad "leak-check FAILED -- fix the above before committing"
fi
exit $fail
