#!/usr/bin/env bash
# Validate every renderable kustomization against the LIVE API server.
#
# Uses --dry-run=server --server-side, which is what the Argo Applications
# actually do (syncOptions: ServerSideApply=true). This matters: CLIENT-side
# apply merges into the existing object and can invent invalid combinations --
# e.g. an env entry carrying both `value` and `valueFrom` -- that server-side
# apply does not produce. A client-side dry-run therefore reports failures that
# would never happen in practice.
#
# THE FIELD MANAGER MATTERS TOO. Server-side apply resolves ownership per field
# manager, so running as the default `kubectl` manager produces conflicts and
# bogus merges that Argo CD would never hit. Impersonating Argo's manager name
# is what makes this dry-run predictive rather than merely plausible. Without
# it you get a pile of
#
#   env[N].valueFrom: Invalid value: "": may not be specified when 'value' is
#   not empty
#
# which are artefacts of the wrong manager, not bugs in the manifests.
#
# Nothing here mutates the cluster: --dry-run=server validates through admission
# and merge logic, then discards.
#
# Usage:
#   KUBECONFIG=./kubeconfig-homelab ./scripts/dryrun-server.sh [dir ...]
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${KUBECONFIG:=$PWD/kubeconfig-homelab}"
export KUBECONFIG

# Must match what the Argo CD application controller uses, or the results do not
# predict what a real sync does. See the note above.
: "${FIELD_MANAGER:=argocd-controller}"

if [ "$#" -gt 0 ]; then
  DIRS="$*"
else
  DIRS=$(find clusters infrastructure platform apps -name kustomization.yaml \
           -exec dirname {} \; | sort)
fi

# ---------------------------------------------------------------------------
# EXPECTED failures. A dry-run against a cluster that has not been migrated yet
# cannot be clean, so "no output" is not a usable success signal. These are the
# failures that are understood, documented and accounted for in
# docs/migration-plan.md. Anything NOT on this list is a real problem.
#
# Keeping the list here rather than in a comment means the script can tell you
# whether the tree is in its expected state, which is the question you actually
# want answered.
# ---------------------------------------------------------------------------
expected_reason() {
  case "$1" in
    # Namespaces this change itself creates: `argocd` by OpenTofu in Phase 1,
    # the rest by infrastructure/namespaces in Phase 2.
    clusters/homelab/apps|clusters/homelab/bootstrap|\
clusters/homelab/infrastructure|clusters/homelab/platform)
      echo "namespace argocd not created until Phase 1" ;;
    infrastructure/gateway)
      echo "namespaces argocd + gateway not created until Phase 1/2" ;;
    platform/backup-verify)
      echo "namespace backup-verify not created until Phase 2" ;;
    platform/barman-cloud-plugin)
      echo "namespace cnpg-system not created until Phase 2; also not wired in yet" ;;

    # RollingUpdate -> Recreate. Fixed by scripts/normalize-deployment-strategy.sh
    # as a documented pre-cutover step.
    apps/paperless|apps/seafile|apps/theater|platform/keycloak)
      echo "needs scripts/normalize-deployment-strategy.sh (RollingUpdate -> Recreate)" ;;

    # The one genuinely irreversible change in the restructure.
    apps/immich/resources)
      echo "PG 16.5 -> 17 + pgvecto.rs -> VectorChord; needs docs/runbooks/immich-upgrade.md" ;;

    *) return 1 ;;
  esac
}

pass=0; fail=0; skip=0; xfail=0
for d in $DIRS; do
  case "$d" in
    */secrets) printf 'SKIP  %-44s (needs the age key)\n' "$d"; skip=$((skip+1)); continue ;;
  esac

  rendered=$(kubectl kustomize "$d" 2>&1)
  if [ -z "$rendered" ] || printf '%s' "$rendered" | head -1 | grep -qi error; then
    printf 'FAIL  %-44s (render)\n' "$d"
    printf '%s\n' "$rendered" | head -3 | sed 's/^/        /'
    fail=$((fail+1)); continue
  fi

  out=$(printf '%s' "$rendered" \
        | kubectl apply --dry-run=server --server-side --force-conflicts \
                        --field-manager="$FIELD_MANAGER" -f - 2>&1)
  if [ $? -eq 0 ]; then
    printf 'ok    %-44s (%s objects)\n' "$d" "$(printf '%s\n' "$out" | grep -c .)"
    pass=$((pass+1))
  else
    if reason=$(expected_reason "$d"); then
      printf 'xfail %-44s %s\n' "$d" "$reason"
      xfail=$((xfail+1))
    else
      printf 'FAIL  %s\n' "$d"
      fail=$((fail+1))
    fi
    printf '%s\n' "$out" \
      | grep -iE 'error|invalid|forbidden|immutable|unknown field|no matches|not found' \
      | cut -c1-200 | sort -u | sed 's/^/        /' | head -8
  fi
done

echo
echo "server-side dry-run:  ok=$pass  expected-fail=$xfail  UNEXPECTED-FAIL=$fail  skipped=$skip"
if [ "$fail" -eq 0 ]; then
  echo "no unexpected failures -- tree matches docs/migration-plan.md"
else
  echo "^^ $fail directory/ies failed for reasons that are NOT documented. Investigate."
fi
[ "$fail" -eq 0 ]
