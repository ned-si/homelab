# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Resolve the local age identity and export SOPS_AGE_KEY_FILE.
#
# Sourced, never run: no shebang and not executable; the `shell=bash`
# directive must stay the first line.
#
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/sops-age.sh"
#     sops_age_env || exit 1
#
# On macOS sops looks in ~/Library/Application Support/sops/age/keys.txt, not
# ~/.config/sops/age/keys.txt. Encryption still works there (it needs only
# the recipient), so only decryption fails. This finds the identity in either
# place, exports SOPS_AGE_KEY_FILE and symlinks the platform default to it. An
# already-set SOPS_AGE_KEY_FILE or SOPS_AGE_KEY wins (CI).
# ---------------------------------------------------------------------------

# Print the resolved key file path, or nothing.
sops_age_key_file() {
  local candidates=(
    "${SOPS_AGE_KEY_FILE:-}"
    "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
    "$HOME/Library/Application Support/sops/age/keys.txt"
  )
  local f
  for f in "${candidates[@]}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    grep -q 'AGE-SECRET-KEY' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

# Export SOPS_AGE_KEY_FILE. Returns non-zero (with an actionable message) when no
# identity exists anywhere, which is a different problem from "wrong path".
sops_age_env() {
  # The key passed inline through the environment needs no file at all.
  if [ -n "${SOPS_AGE_KEY:-}" ]; then
    return 0
  fi

  local key
  if ! key="$(sops_age_key_file)"; then
    cat >&2 <<'EOF'
No age identity found. Looked in:
    $SOPS_AGE_KEY_FILE
    ~/.config/sops/age/keys.txt
    ~/Library/Application Support/sops/age/keys.txt   (the sops default on macOS)

Create one with:
    ./scripts/age-key.sh

If you already have the key in your password manager, restore it instead --
generating a new one does NOT let you read anything already sealed:
    mkdir -p ~/.config/sops/age && umask 077
    pbpaste > ~/.config/sops/age/keys.txt
EOF
    return 1
  fi

  export SOPS_AGE_KEY_FILE="$key"
  sops_age_link_default "$key"
  return 0
}

# Make the platform default resolve to the real key, so that a bare `sops -d`
# typed by hand behaves the same as a `sops -d` run from these scripts.
#
# Best effort by design: it is a convenience, and a read-only $HOME or an
# existing regular file there must not fail the caller. A regular file is never
# replaced -- if someone deliberately keeps a second identity there, silently
# clobbering it would destroy the only copy.
sops_age_link_default() {
  local key="$1"
  local default_dir default_file
  case "$(uname -s)" in
    Darwin) default_dir="$HOME/Library/Application Support/sops/age" ;;
    *)      default_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age" ;;
  esac
  default_file="$default_dir/keys.txt"

  [ "$default_file" = "$key" ] && return 0
  [ -e "$default_file" ] && [ ! -L "$default_file" ] && return 0
  if [ -L "$default_file" ] && [ "$(readlink "$default_file")" = "$key" ]; then
    return 0
  fi

  mkdir -p "$default_dir" 2>/dev/null || return 0
  ln -sfn "$key" "$default_file" 2>/dev/null || return 0
}
