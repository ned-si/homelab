#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time normalisation: switch existing Deployments to `strategy: Recreate`
# (single replicas on ReadWriteOnce volumes cannot roll).
#
# Applying `Recreate` over an existing Deployment fails: the API server
# defaulted `rollingUpdate`, and server-side apply never removes a field it
# does not own. A strategic-merge patch with an explicit null does. The pod
# template is untouched, so nothing restarts. Run it before the first sync of
# the affected layers.
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

# Deployments the repo declares as `strategy.type: Recreate`, a literal table
# so a parsing bug cannot patch the wrong thing. Regenerate with
#   grep -rln 'type: Recreate' --include='*.yaml' apps platform
# format: <namespace> <deployment>
DEPLOYMENTS="
keycloak  keycloak
mealie    mealie
paperless paperless
paperless valkey
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
