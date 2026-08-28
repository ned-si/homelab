#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Assert that every file a KSOPS generator references exists and is encrypted.
#
# THE GAP THIS CLOSES
#
# The three KSOPS generators list nine `*.sops.yaml` files. None of them exist --
# only the `.example` templates do. Those three Applications sit at
# `sync-wave: -25`, the earliest wave in each layer, so on day one EVERY LAYER
# STALLS AT ITS FIRST WAVE and nothing downstream of them ever syncs.
#
# No existing check catches this, and none of them can:
#   - render-deploy.sh, render-check.sh and dryrun-server.sh all hard-skip
#     `*/secrets`, because rendering those directories means decrypting them.
#   - kubeconform validates deploy/, which by construction excludes them.
#   - leak-check.sh checks that files which EXIST are encrypted. A file that does
#     not exist cannot leak, so it passes.
#
# So the one property nobody was checking is the one that stops the cluster.
#
# NO KEY REQUIRED. This only looks at whether the path exists and whether the
# file carries a SOPS envelope (`sops:` block or `ENC[AES256_GCM`). It never
# decrypts, so it runs in CI, where the age key is absent and must stay absent.
#
# WARNING BY DEFAULT
#
# The owner has not created the secrets yet. Making this fatal today would block
# every commit on work that belongs to Phase 1, so:
#
#   SECRETS_CHECK_STRICT=0   (default) report, exit 0
#   SECRETS_CHECK_STRICT=1             report, exit 1
#
# Flip it in .github/workflows/ci.yaml when Phase 1 starts. docs/secrets.md
# already lists "Degraded on a secrets-* Application on first run" as expected;
# this script is what turns that from folklore into a check.
#
# USAGE
#   scripts/secrets-check.sh
#   SECRETS_CHECK_STRICT=1 scripts/secrets-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${SECRETS_CHECK_STRICT:=0}"
case "$SECRETS_CHECK_STRICT" in
  1|true|yes|on) STRICT=1 ;;
  *)             STRICT=0 ;;
esac

# GitHub Actions renders these as annotations; locally they are just prefixes.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  ANN_WARN='::warning::'
  ANN_ERR='::error::'
else
  ANN_WARN=''
  ANN_ERR=''
fi

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

problems=0
note() {
  if [ "$STRICT" -eq 1 ]; then
    red "${ANN_ERR}$*"
  else
    yellow "${ANN_WARN}$*"
  fi
  problems=$((problems + 1))
}

# No `2>/dev/null`: swallowing find's errors while piping into sort means the
# pipeline reports success on an empty result, which is the failure mode this
# whole script exists to prevent. The emptiness check below is the second half.
GENERATORS=$(find apps platform infrastructure clusters -name 'secret-generator.yaml' | sort)

if [ -z "$GENERATORS" ]; then
  red "no secret-generator.yaml found -- either the layout changed or this script"
  red "is looking in the wrong place. Refusing to report success."
  exit 1
fi

checked=0
for gen in $GENERATORS; do
  dir=$(dirname "$gen")
  printf '\n=== %s\n' "$gen"

  # A generator that the kustomization does not list is a no-op: kustomize never
  # runs it, the Secrets never appear, and the Application still reports Synced.
  kust="$dir/kustomization.yaml"
  if [ ! -f "$kust" ]; then
    note "$dir: no kustomization.yaml, so the generator is never invoked"
  elif ! grep -q "$(basename "$gen")" "$kust"; then
    note "$kust does not reference $(basename "$gen") -- the generator never runs"
  fi

  # `files:` is a flat list of relative paths. Parsed with awk rather than a YAML
  # library so this stays dependency-free; the shape is fixed by KSOPS.
  files=$(awk '
    /^files:[[:space:]]*$/            { inlist = 1; next }
    inlist && /^[[:space:]]*#/        { next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      sub(/^\.\//, "")
      sub(/[[:space:]]*(#.*)?$/, "")
      if (length($0)) print
      next
    }
    inlist && /^[^[:space:]]/         { inlist = 0 }
  ' "$gen")

  if [ -z "$files" ]; then
    note "$gen lists no files -- the generator produces nothing"
    continue
  fi

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$dir/$rel"
    checked=$((checked + 1))

    if [ ! -f "$f" ]; then
      if [ -f "$f.example" ]; then
        note "MISSING  $f"
        printf '           create it from %s, fill it in, then:\n' "$f.example"
        printf '             cp %s %s\n' "$f.example" "$f"
        printf '             (edit %s)\n' "$f"
        printf '             task secrets:seal -- %s\n' "$f"
      else
        note "MISSING  $f  (and there is no $f.example to copy)"
      fi
      continue
    fi

    if grep -q '^sops:' "$f" || grep -q 'ENC\[AES256_GCM' "$f"; then
      green "  sealed   $f"
    else
      # Distinct from missing, and more urgent: the file is in the tree in
      # plaintext. leak-check.sh also fails on this; both say so because this
      # script is the one that enumerates what SHOULD exist.
      note "PLAINTEXT $f  -- run: task secrets:seal -- $f"
    fi
  done <<<"$files"

  # A template with no entry in `files:` is a secret somebody meant to wire up.
  for ex in "$dir"/*.sops.yaml.example; do
    [ -e "$ex" ] || continue
    want=$(basename "$ex" .example)
    if ! printf '%s\n' "$files" | grep -qx "$want"; then
      note "$ex has no matching entry in $gen -- '$want' will never be generated"
    fi
  done
done

echo
if [ "$problems" -eq 0 ]; then
  green "secrets-check passed ($checked referenced files present and sealed)"
  exit 0
fi

if [ "$STRICT" -eq 1 ]; then
  red "secrets-check FAILED -- $problems problem(s)"
  red "Every layer's first sync wave (-25) depends on these."
  exit 1
fi

yellow "secrets-check: $problems problem(s), NOT fatal (SECRETS_CHECK_STRICT=0)."
yellow "Argo CD will stall at sync-wave -25 in every layer until these exist."
yellow "Nothing below that wave will ever sync -- not one Application."
yellow "Set SECRETS_CHECK_STRICT=1 to make this a hard gate."
exit 0
