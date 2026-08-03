#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time normalisation: switch existing Deployments to `strategy: Recreate`.
#
# WHY THIS SCRIPT EXISTS
#
# Several single-replica workloads sit on ReadWriteOnce iSCSI volumes. With the
# default RollingUpdate strategy Kubernetes tries to start the replacement pod
# *before* terminating the old one, the new pod can never attach the volume, and
# the rollout hangs until it times out. `Recreate` is the correct strategy and
# the repo declares it.
#
# But you cannot simply apply that over an existing Deployment:
#
#   spec.strategy.rollingUpdate: Forbidden: may not be specified when
#   strategy `type` is 'Recreate'
#
# The API server defaulted `spec.strategy.rollingUpdate` (maxSurge 25%,
# maxUnavailable 25%) when the Deployment was first created. A server-side apply
# only manages the fields it *sets*; it will not delete a field owned by another
# field manager. So the merged object ends up with both `type: Recreate` and a
# `rollingUpdate` block, which is invalid. `--force-conflicts` does not help,
# because there is no conflict -- nobody is claiming that field.
#
# A strategic-merge patch with an explicit null DOES remove it. That is all this
# script does.
#
# IS IT DISRUPTIVE? No. Verified against the live cluster: the pod template is
# untouched, so no new ReplicaSet is created and no pod restarts. Only
# `metadata.generation` moves. The change takes effect on the *next* rollout.
#
# Run this BEFORE the first Argo CD sync of the affected layers, or those syncs
# will fail. See docs/migration-plan.md.
#
# USAGE
#   scripts/normalize-deployment-strategy.sh            # report only (default)
#   scripts/normalize-deployment-strategy.sh --apply     # actually patch
# ---------------------------------------------------------------------------
set -uo pipefail

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

if [ -z "${KUBECONFIG:-}" ] && [ -f ./kubeconfig-homelab ]; then
  export KUBECONFIG=./kubeconfig-homelab
fi

# Deployments the repo declares as `strategy.type: Recreate`.
#
# Regenerate this list with:
#   grep -rln 'type: Recreate' --include='*.yaml' apps platform
# then read each file for its namespace and Deployment name. Kept as a literal
# table rather than parsed at runtime so that a YAML-parsing bug can never cause
# this script to patch something it should not.
#
# format: <namespace> <deployment>
DEPLOYMENTS="
keycloak  keycloak
mealie    mealie
paperless paperless
paperless valkey
seafile   seafile
seafile   mariadb
theater   jellyfin
theater   lidarr
theater   plex
theater   prowlarr
theater   qbittorrent
theater   radarr
theater   sonarr
"

missing=0
patched=0
already=0
failed=0

printf '%-12s %-14s %-16s %s\n' NAMESPACE DEPLOYMENT BEFORE ACTION
printf '%-12s %-14s %-16s %s\n' --------- ---------- ------ ------

while read -r ns name; do
  [ -z "${ns:-}" ] && continue

  current=$(kubectl -n "$ns" get deploy "$name" \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null)

  if [ -z "$current" ]; then
    printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "-" "NOT FOUND (skipped)"
    missing=$((missing + 1))
    continue
  fi

  if [ "$current" = "Recreate" ]; then
    printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "$current" "ok, nothing to do"
    already=$((already + 1))
    continue
  fi

  if [ "$APPLY" != true ]; then
    printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "$current" "WOULD PATCH"
    patched=$((patched + 1))
    continue
  fi

  if kubectl -n "$ns" patch deploy "$name" --type merge \
       -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' \
       >/dev/null 2>&1; then
    after=$(kubectl -n "$ns" get deploy "$name" \
      -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
    # Confirm the rollingUpdate block is really gone, not just that the patch
    # returned 0. This is the whole point of the exercise.
    leftover=$(kubectl -n "$ns" get deploy "$name" \
      -o jsonpath='{.spec.strategy.rollingUpdate}' 2>/dev/null)
    if [ "$after" = "Recreate" ] && [ -z "$leftover" ]; then
      printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "$current" "patched -> Recreate"
      patched=$((patched + 1))
    else
      printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "$current" \
        "FAILED (type=$after leftover=$leftover)"
      failed=$((failed + 1))
    fi
  else
    printf '%-12s %-14s %-16s %s\n' "$ns" "$name" "$current" "FAILED (patch rejected)"
    failed=$((failed + 1))
  fi
done <<EOF
$DEPLOYMENTS
EOF

echo
if [ "$APPLY" = true ]; then
  echo "patched=$patched  already-correct=$already  not-found=$missing  failed=$failed"
else
  echo "would-patch=$patched  already-correct=$already  not-found=$missing"
  echo
  echo "Nothing was changed. Re-run with --apply to patch."
fi

echo
echo "Reminder: no pods were restarted. Recreate takes effect on the next rollout."

[ "$failed" -eq 0 ]
