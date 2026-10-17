#!/bin/bash
# pv-selinux-label.sh <pv> [--apply | --revert]
#
# Give one existing iSCSI PersistentVolume the SELinux mount option of the
# StorageClasses (context=system_u:object_r:ephemeral_t:s0), or take it away.
# Dry run by default: prints the options before and after and the patch it
# would send. `--apply` sends it, `--revert` removes the option. Idempotent: a
# volume that already has the wanted options is left alone.
#
# The option takes effect at the volume's next mount, so the pod that uses it
# must be restarted afterwards (the script prints it; it never restarts
# anything). Runbook: docs/runbooks/pv-selinux-label.md. Why:
# docs/decisions.md, SELinux labels on CSI volumes.
#
# Refuses (exit 2):
#   - the volume of immich/immich-data, which stays unlabelled by decision;
#   - a volume whose manifest is in infrastructure/iscsi-volumes/: change it
#     in git instead, or Argo CD would own a different value;
#   - a volume of another driver.
#
# Environment: KUBECONFIG. Exit 0 done or nothing to do, 1 kubectl error,
# 2 refused, 64 usage.
set -euo pipefail

LABEL="context=system_u:object_r:ephemeral_t:s0"
DRIVER="org.democratic-csi.iscsi"
# immich/immich-data: never labelled, patched or restarted for this.
EXCLUDED_PV="pvc-b9d3e7d8-0d3e-43d4-b8d3-8f212ede0ea6"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_PV_DIR="$REPO_ROOT/infrastructure/iscsi-volumes"

usage() {
  sed -n '2p' "$0" | sed 's/^# //' >&2
  exit 64
}

k() { kubectl --request-timeout=60s "$@"; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
pv=$1 mode=${2:-dry-run}
[[ "$pv" =~ ^pvc-[0-9a-f-]{36}$ ]] || usage
case "$mode" in dry-run|--apply|--revert) ;; *) usage ;; esac

if [ "$pv" = "$EXCLUDED_PV" ]; then
  echo "pv-selinux-label: refused: $pv is immich/immich-data, which stays unlabelled" >&2
  exit 2
fi
if [ -d "$GIT_PV_DIR" ] && grep -rqF -- "name: $pv" "$GIT_PV_DIR"; then
  echo "pv-selinux-label: refused: $pv is defined in infrastructure/iscsi-volumes/; add the mount option there" >&2
  exit 2
fi

driver=$(k get pv "$pv" -o jsonpath='{.spec.csi.driver}') || { echo "pv-selinux-label: cannot read $pv" >&2; exit 1; }
if [ "$driver" != "$DRIVER" ]; then
  echo "pv-selinux-label: refused: $pv uses driver '${driver:-none}', not $DRIVER" >&2
  exit 2
fi
claim=$(k get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}') || exit 1

before=()
while IFS= read -r o || [ -n "$o" ]; do [ -n "$o" ] && before+=("$o"); done \
  < <(k get pv "$pv" -o jsonpath='{range .spec.mountOptions[*]}{@}{"\n"}{end}')

# The wanted options: every other option kept in order; the label added once
# (apply) or dropped (revert). Any other context= value is replaced.
after=()
for o in ${before[@]+"${before[@]}"}; do
  case "$o" in context=*) ;; *) after+=("$o") ;; esac
done
[ "$mode" = "--revert" ] || after+=("$LABEL")

join() { local IFS=,; echo "$*"; }
echo "pv:     $pv ($claim)"
echo "before: [$(join ${before[@]+"${before[@]}"})]"
echo "after:  [$(join ${after[@]+"${after[@]}"})]"

if [ "$(join ${before[@]+"${before[@]}"})" = "$(join ${after[@]+"${after[@]}"})" ]; then
  echo "nothing to do"
  exit 0
fi

if [ "${#after[@]}" -eq 0 ]; then
  patch='{"spec":{"mountOptions":null}}'
else
  items=""
  for o in "${after[@]}"; do items="$items${items:+,}\"${o//\"/\\\"}\""; done
  patch="{\"spec\":{\"mountOptions\":[$items]}}"
fi

if [ "$mode" = "dry-run" ]; then
  echo "dry run: kubectl patch pv $pv --type=merge -p '$patch'"
  echo "run again with --apply (or --revert) to send it"
  exit 0
fi

k patch pv "$pv" --type=merge -p "$patch" >/dev/null || { echo "pv-selinux-label: patch failed" >&2; exit 1; }
now=$(k get pv "$pv" -o jsonpath='{range .spec.mountOptions[*]}{@}{","}{end}') || exit 1
echo "now:    [${now%,}]"
ns=${claim%%/*} pvc=${claim#*/}
pods=$(k -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}' \
  | awk -v c="$pvc" '{for (i = 2; i <= NF; i++) if ($i == c) { printf "%s ", $1; break }}') || pods=""
pods=${pods% }
echo "takes effect at the next mount; restart: ${pods:-no pod uses $claim now} (namespace $ns)"
