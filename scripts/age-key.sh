#!/usr/bin/env bash
# Generate the cluster's age identity and wire its public key into .sops.yaml.
#
# Run this ONCE per cluster. The private key is the single thing that can
# decrypt every secret in this repository: if you lose it, every secret must be
# rotated from scratch; if it leaks, every secret is compromised.
#
# Usage: ./scripts/age-key.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="${SOPS_AGE_KEY_DIR:-$HOME/.config/sops/age}"
KEY_FILE="$KEY_DIR/keys.txt"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"

command -v age-keygen >/dev/null 2>&1 || {
  echo "age-keygen not found. Run 'task tools' (or: brew install age)." >&2
  exit 1
}

if [[ -f "$KEY_FILE" ]] && grep -q 'AGE-SECRET-KEY' "$KEY_FILE"; then
  echo "An age identity already exists at:"
  echo "    $KEY_FILE"
  echo
  echo "Public key(s) it contains:"
  age-keygen -y "$KEY_FILE" | sed 's/^/    /'
  echo
  echo "Refusing to overwrite. If you really want a NEW cluster key, move the"
  echo "existing file aside first and be aware that every already-encrypted"
  echo "*.sops.yaml in this repo will need to be re-encrypted:"
  echo "    sops updatekeys <file>"
  exit 1
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

umask 077
age-keygen -o "$KEY_FILE" 2>/dev/null
chmod 600 "$KEY_FILE"

PUBKEY="$(age-keygen -y "$KEY_FILE")"

echo "Generated a new age identity."
echo
echo "  private key : $KEY_FILE   (mode 600, never leaves this machine + your password manager)"
echo "  public key  : $PUBKEY"
echo

# Wire the public key into .sops.yaml so `sops -e` targets it automatically.
if grep -q 'REPLACE_WITH_YOUR_AGE_PUBLIC_KEY' "$SOPS_CONFIG"; then
  # BSD and GNU sed disagree about -i, so go through a temp file.
  tmp="$(mktemp)"
  sed "s|REPLACE_WITH_YOUR_AGE_PUBLIC_KEY|$PUBKEY|g" "$SOPS_CONFIG" >"$tmp"
  mv "$tmp" "$SOPS_CONFIG"
  echo "Wrote the public key into .sops.yaml."
else
  echo "NOTE: .sops.yaml already has a recipient configured. Add this public key"
  echo "      manually if you intend to encrypt to more than one identity."
fi

cat <<EOF

Next steps, in order:

  1. Back the PRIVATE key up to your password manager NOW. Copy the whole file:
         cat $KEY_FILE

  2. Seed it into the cluster so Argo CD can decrypt. The bootstrap OpenTofu
     reads it from an environment variable:
         export TF_VAR_sops_age_key="\$(cat $KEY_FILE)"
         task bootstrap:apply

  3. Create your secrets from the templates and seal them:
         cp secrets/cloudflare.sops.yaml.example secrets/cloudflare.sops.yaml
         \$EDITOR secrets/cloudflare.sops.yaml     # put the real value in
         task secrets:seal -- secrets/cloudflare.sops.yaml

  4. Verify nothing plaintext is about to be committed:
         task secrets:leak-check

See docs/secrets.md for the full workflow.
EOF
