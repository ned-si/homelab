# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Resolve the local age identity and export SOPS_AGE_KEY_FILE.
#
# NO SHEBANG, AND NOT EXECUTABLE, ON PURPOSE. This file is sourced, never run.
# The `check-shebang-scripts-are-executable` pre-commit hook would demand mode
# 755 for a `#!` line, and a chmod +x on a library that does nothing when
# executed is a lie about how it is used. The `shell=bash` directive on the first
# line supplies the dialect that a shebang would otherwise have told shellcheck.
#
# (That directive must be the FIRST line. A line further down beginning with
# `# shellcheck` is parsed as a directive too, and a prose sentence there fails
# with SC1072/SC1073 -- which is how this paragraph got reworded.)
#
# Source this (do not execute it) from any script that runs `sops --decrypt`,
# `sops edit` or `kustomize build` over a KSOPS generator:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/sops-age.sh"
#     sops_age_env || exit 1
#
# WHY THIS EXISTS -- THE macOS DEFAULT PATH IS NOT ~/.config
#
# sops looks for an age identity in a fixed list of places and, when none of the
# environment variables are set, falls back to ONE directory that it derives from
# the platform. On Linux that is `$XDG_CONFIG_HOME/sops/age/keys.txt`, i.e.
# `~/.config/sops/age/keys.txt`. On macOS, Go's os.UserConfigDir() returns
# `~/Library/Application Support`, so sops 3.13 looks for
#
#     ~/Library/Application Support/sops/age/keys.txt
#
# Every piece of homelab/Kubernetes documentation in the wild -- including the
# KSOPS README and this repository's own docs/secrets.md -- says `~/.config`,
# because that is where it lives on the cluster side. So the natural thing to do
# on a Mac produces a key that sops cannot see.
#
# The failure mode is genuinely nasty because it is ASYMMETRIC:
#
#   - ENCRYPTION still works. `sops --encrypt` needs only the RECIPIENT, and that
#     comes from the `age:` field in .sops.yaml, not from the identity file. So
#     sealing twelve secrets appears to succeed completely.
#   - DECRYPTION fails, with "failed to load age identities" listing the paths it
#     tried -- which is only obvious once you read the list closely enough to
#     notice `Library/Application Support` where you expected `.config`.
#
# That is exactly how this repository's first sealing run went: ten files sealed,
# ten files unreadable, and no error until the verification pass. Hence the rule
# that the seal script proves a round-trip instead of trusting exit code 0.
#
# WHAT THIS DOES
#
# Finds the identity in whichever of the two locations actually has it, exports
# SOPS_AGE_KEY_FILE explicitly so behaviour no longer depends on the platform
# default, and (best effort) symlinks the platform default at the real file so
# that bare interactive `sops -d some.sops.yaml` also works without the export.
#
# An already-set SOPS_AGE_KEY_FILE or SOPS_AGE_KEY always wins -- CI passes the
# key through the environment and must not be overridden.
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
