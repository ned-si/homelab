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

# Prefer the staged set; fall back to the whole tracked tree.
files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
scope="staged"
if [[ -z "$files" ]]; then
  files="$(git ls-files)"
  scope="tracked"
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
  if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; then
    bad "PRIVATE KEY: $f"
  fi
  if grep -q 'AGE-SECRET-KEY-1' "$f" 2>/dev/null; then
    bad "AGE SECRET KEY: $f"
  fi

  # 3. A plaintext Kubernetes Secret payload. Only meaningful in YAML that is
  #    not SOPS-encrypted (encrypted files were skipped above).
  case "$f" in
    *.yaml|*.yml)
      if grep -qE '^[[:space:]]*(stringData|data):[[:space:]]*$' "$f" 2>/dev/null \
         && grep -qE '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' "$f" 2>/dev/null; then
        bad "PLAINTEXT SECRET: $f  (should be a sealed *.sops.yaml)"
      fi
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
