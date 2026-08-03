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
cd "$REPO_ROOT"

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
is_exempt() {
  case "$1" in
    *.example|.sops.yaml|docs/*|"$SELF") return 0 ;;
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

# 4. Filenames that should never be tracked at all, regardless of content.
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
