#!/usr/bin/env bash
# talos-genconfig.sh -- write the Talos machine configs (one per node, plus
# talosconfig) from talos/talconfig.yaml. Output is git-ignored.
#
#   1. talhelper genconfig --offline-mode. Reads talos/talconfig.yaml and the
#      cluster secrets (talos/talsecret.sops.yaml, decrypted by talhelper through
#      sops). --offline-mode computes the Image Factory schematic ID locally
#      instead of POSTing the schematic to factory.talos.dev.
#   2. talosctl machineconfig patch with every document in
#      talos/patches/talosctl/, plus talos/patches/talosctl/controlplane/ on the
#      control planes only. talhelper 3.1.17 vendors Talos machinery
#      1.14.0-alpha.2 and rejects documents added later (SecurityProfileConfig,
#      KubeTalosAPIAccessConfig).
#
# Environment:
#   WORKLOAD_ISOLATION  true|false, overrides SecurityProfileConfig
#                       workloadIsolation (default: the value in the patch file)
#   TALOS_SECRET_FILE   secrets file (default talos/talsecret.sops.yaml)
#   TALOS_OUT_DIR       output directory (default talos/clusterconfig)
#
# Needs talhelper and talosctl (the version of talosVersion in talconfig.yaml)
# on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALOS_DIR="$ROOT/talos"
secret="${TALOS_SECRET_FILE:-$TALOS_DIR/talsecret.sops.yaml}"
out="${TALOS_OUT_DIR:-$TALOS_DIR/clusterconfig}"

die() { echo "talos-genconfig: $*" >&2; exit 1; }

for t in talhelper talosctl; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH"
done
[ -f "$secret" ] || die "no secrets file $secret (create it once: see docs/talos.md)"

case "${WORKLOAD_ISOLATION:-}" in
  ""|true|false) ;;
  *) die "WORKLOAD_ISOLATION must be true or false, got '${WORKLOAD_ISOLATION}'" ;;
esac

# A sealed secrets file needs the age identity; a plaintext one (CI) does not.
if grep -q '^sops:' "$secret"; then
  # SC1091: pre-commit passes only the staged files, so the library may not be an input.
  # shellcheck source=scripts/lib/sops-age.sh disable=SC1091
  . "$ROOT/scripts/lib/sops-age.sh"
  sops_age_env
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# talhelper resolves `@./patches/...` relative to the working directory.
(cd "$TALOS_DIR" && talhelper genconfig --offline-mode -c talconfig.yaml -s "$secret" -o "$out")

patches=()
for p in "$TALOS_DIR"/patches/talosctl/*.yaml; do
  [ -f "$p" ] || continue
  if [ -n "${WORKLOAD_ISOLATION:-}" ] && grep -q '^kind: SecurityProfileConfig$' "$p"; then
    sed "s/^workloadIsolation: .*/workloadIsolation: ${WORKLOAD_ISOLATION}/" "$p" > "$work/$(basename "$p")"
    p="$work/$(basename "$p")"
  fi
  patches+=(--patch "@$p")
done

cp_patches=()
for p in "$TALOS_DIR"/patches/talosctl/controlplane/*.yaml; do
  [ -f "$p" ] && cp_patches+=(--patch "@$p")
done

n=0
for f in "$out"/*.yaml; do
  [ -f "$f" ] || continue
  these=(${patches[@]+"${patches[@]}"})
  if grep -qE '^ +type: controlplane$' "$f"; then
    these+=(${cp_patches[@]+"${cp_patches[@]}"})
  fi
  if [ "${#these[@]}" -gt 0 ]; then
    talosctl machineconfig patch "$f" "${these[@]}" -o "$work/patched.yaml"
    # Keep the 0600 mode talhelper gave the file: it holds the cluster secrets.
    cat "$work/patched.yaml" > "$f"
  fi
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "talhelper wrote no machine configs into $out"
echo "talos-genconfig: $n machine config(s) in $out"
