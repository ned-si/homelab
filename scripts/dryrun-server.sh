#!/usr/bin/env bash
# ---------------------------------------------------------------------------
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
# NO --force-conflicts. None of the Applications set `Force=true`
# (grep syncOptions in clusters/homelab/), and Argo's server-side apply does not
# force by default, so forcing here made the dry-run strictly MORE permissive
# than the sync it claims to predict: a field-ownership conflict that would stop
# a real sync was being resolved silently and reported ok. Conflicts are now
# reported as their own class -- see CONFLICT below.
#
# Nothing here mutates the cluster: --dry-run=server validates through admission
# and merge logic, then discards.
#
# ---------------------------------------------------------------------------
# EXPECTED FAILURES ARE KEYED ON THE FAILURE, NOT ON THE DIRECTORY
#
# A dry-run against a cluster that has not been migrated yet cannot be clean, so
# "no output" is not a usable success signal and some failures have to be
# tolerated. The question is which.
#
# Keying the tolerance on the DIRECTORY -- which is what this script used to do
# -- meant 12 of 20 directories were blanket-excused. Any new, real, undocumented
# breakage in 60% of the tree read as green, while README.md advertised that this
# script "can tell you whether anything is failing for an *undocumented* reason".
# It could not.
#
# So an expected failure is a (directory, regex-over-the-dry-run-output) pair. A
# failure in a listed directory whose message does NOT match the regex is an
# UNEXPECTED failure and is counted as such. Entries that never match during a
# run are reported as stale, so the table shrinks as the migration proceeds
# instead of quietly outliving it.
#
# Format:  <dir>::<extended regex over the kubectl output>::<why>
# ---------------------------------------------------------------------------
#
# Usage:
#   KUBECONFIG=./kubeconfig-homelab ./scripts/dryrun-server.sh [dir ...]
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
: "${KUBECONFIG:=$PWD/kubeconfig-homelab}"
export KUBECONFIG

# Must match what the Argo CD application controller uses, or the results do not
# predict what a real sync does. See the note above.
: "${FIELD_MANAGER:=argocd-controller}"

# These are the failures that are understood, documented and accounted for in
# docs/migration-plan.md.
XFAIL=(
  # Namespaces this change itself creates: `argocd` by OpenTofu in Phase 1, the
  # rest by infrastructure/namespaces in Phase 2.
  'clusters/homelab/apps::namespaces? "?argocd"? not found::namespace argocd not created until Phase 1'
  'clusters/homelab/bootstrap::namespaces? "?argocd"? not found::namespace argocd not created until Phase 1'
  'clusters/homelab/infrastructure::namespaces? "?argocd"? not found::namespace argocd not created until Phase 1'
  'clusters/homelab/platform::namespaces? "?argocd"? not found::namespace argocd not created until Phase 1'
  'infrastructure/gateway::namespaces? "?(argocd|gateway)"? not found::namespaces argocd + gateway not created until Phase 1/2'
  'platform/backup-verify::namespaces? "?backup-verify"? not found::namespace backup-verify not created until Phase 2'
  # nfs-storage declares the backup-local PVC in backup-verify as well as immich.
  'infrastructure/nfs-storage::namespaces? "?backup-verify"? not found::namespace backup-verify not created until Phase 2'
  'platform/barman-cloud-plugin::namespaces? "?cnpg-system"? not found::namespace cnpg-system not created until Phase 2; also not wired in yet'

  # RollingUpdate -> Recreate. Fixed by scripts/normalize-deployment-strategy.sh
  # as a documented pre-cutover step. The regex is the API server's own wording;
  # a Deployment in one of these directories failing for ANY other reason is a
  # real finding, which is the entire point of matching on the message.
  'apps/paperless::strategy\.rollingUpdate: Forbidden::needs scripts/normalize-deployment-strategy.sh (RollingUpdate -> Recreate)'
  'apps/seafile::strategy\.rollingUpdate: Forbidden::needs scripts/normalize-deployment-strategy.sh (RollingUpdate -> Recreate)'
  'apps/theater::strategy\.rollingUpdate: Forbidden::needs scripts/normalize-deployment-strategy.sh (RollingUpdate -> Recreate)'
  'platform/keycloak::strategy\.rollingUpdate: Forbidden::needs scripts/normalize-deployment-strategy.sh (RollingUpdate -> Recreate)'

  # The one genuinely irreversible change in the restructure.
  'apps/immich/resources::(imageName|major|shared_preload_libraries|VectorChord|vchord|pgvecto)::PG 16.5 -> 17 + pgvecto.rs -> VectorChord; needs docs/runbooks/immich-upgrade.md'
)

if [ "$#" -gt 0 ]; then
  DIRS="$*"
else
  DIRS=$(find clusters infrastructure platform apps -name kustomization.yaml \
           -exec dirname {} \; | sort)
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ERRF="$WORK/stderr"

# Parallel array of "matched at least once" flags, so stale entries can be
# reported. bash 3.2 (what macOS ships) has no associative arrays.
XHIT=()
for _ in "${XFAIL[@]}"; do XHIT+=(0); done

# Return 0 if $2 (the kubectl output) is an expected failure for directory $1,
# and put the reason in XFAIL_REASON.
#
# Deliberately NOT `reason=$(xfail_reason ...)`: a command substitution runs the
# function in a subshell, so the XHIT bookkeeping would be thrown away and the
# stale-entry report below would flag every entry on every run.
XFAIL_REASON=""
xfail_matches() {
  local dir="$1" out="$2"
  local i entry xdir rest xre
  XFAIL_REASON=""
  for i in "${!XFAIL[@]}"; do
    entry="${XFAIL[$i]}"
    xdir="${entry%%::*}"
    [ "$xdir" = "$dir" ] || continue
    rest="${entry#*::}"
    xre="${rest%%::*}"
    if printf '%s' "$out" | grep -qE "$xre"; then
      XHIT[i]=1
      XFAIL_REASON="${rest#*::}"
      return 0
    fi
  done
  return 1
}

pass=0; fail=0; skip=0; xfail=0; conflict=0
for d in $DIRS; do
  case "$d" in
    */secrets) printf 'SKIP  %-44s (needs the age key)\n' "$d"; skip=$((skip+1)); continue ;;
  esac

  # stdout and stderr kept apart, and the RENDER'S OWN EXIT STATUS is what
  # decides whether it worked.
  #
  # Do not substitute a heuristic on the text (`head -1 | grep -qi error`): it
  # misses any kustomize failure whose first line lacks the word "error", and it
  # misreads a first-line deprecation warning -- which kustomize writes on
  # SUCCESS -- as a failure. Same shape as render-deploy.sh, for the same reason.
  if ! rendered=$(kubectl kustomize "$d" 2>"$ERRF") || [ -z "$rendered" ]; then
    printf 'FAIL  %-44s (render)\n' "$d"
    sed 's/^/        /' <"$ERRF" | head -3
    fail=$((fail+1)); continue
  fi

  if out=$(printf '%s' "$rendered" \
           | kubectl apply --dry-run=server --server-side \
                           --field-manager="$FIELD_MANAGER" -f - 2>&1); then
    printf 'ok    %-44s (%s objects)\n' "$d" "$(printf '%s\n' "$out" | grep -c .)"
    pass=$((pass+1))
    continue
  fi

  # A field-ownership conflict is its own class. Argo does not force, so this is
  # a sync that would stop, not a manifest that is wrong -- usually the OLD Argo
  # CD still owning the object. Never expected-fail: it needs a decision.
  if printf '%s' "$out" | grep -qE 'conflict|Apply failed with [0-9]+ conflict'; then
    printf 'CONFLICT %-41s (another field manager owns these fields)\n' "$d"
    conflict=$((conflict+1))
    fail=$((fail+1))
  elif xfail_matches "$d" "$out"; then
    printf 'xfail %-44s %s\n' "$d" "$XFAIL_REASON"
    xfail=$((xfail+1))
  else
    printf 'FAIL  %s\n' "$d"
    fail=$((fail+1))
  fi
  printf '%s\n' "$out" \
    | grep -iE 'error|invalid|forbidden|immutable|unknown field|no matches|not found|conflict' \
    | cut -c1-200 | sort -u | sed 's/^/        /' | head -8
done

echo
echo "server-side dry-run:  ok=$pass  expected-fail=$xfail  UNEXPECTED-FAIL=$fail  conflicts=$conflict  skipped=$skip"

# Only meaningful over a full run: a subset invocation legitimately never
# reaches most entries.
if [ "$#" -eq 0 ]; then
  stale=0
  for i in "${!XFAIL[@]}"; do
    if [ "${XHIT[$i]}" -eq 0 ]; then
      if [ "$stale" -eq 0 ]; then
        echo
        echo "xfail entries that did not match anything this run:"
      fi
      entry="${XFAIL[$i]}"
      entry_rest="${entry#*::}"
      printf '  %s  --  %s\n' "${entry%%::*}" "${entry_rest#*::}"
      stale=$((stale+1))
    fi
  done
  if [ "$stale" -ne 0 ]; then
    echo "  ^^ either the migration step is done (delete the entry) or the failure"
    echo "     now has a different message (fix the regex). A stale entry is how"
    echo "     this table stops describing reality."
  fi
fi

if [ "$conflict" -ne 0 ]; then
  echo
  echo "$conflict directory/ies hit a field-ownership CONFLICT. Those are counted as"
  echo "unexpected on purpose: nothing in clusters/homelab/ sets Force=true, so Argo"
  echo "would stop on the same conflict. The usual cause is the old Argo CD still"
  echo "owning the object; resolve ownership, do not add --force-conflicts here."
fi

if [ "$fail" -eq 0 ]; then
  echo "no unexpected failures -- tree matches docs/migration-plan.md"
else
  echo "^^ $fail directory/ies failed for reasons that are NOT in the xfail table."
  echo "   An xfail entry matches on the failure MESSAGE, not the directory, so a"
  echo "   listed directory failing a NEW way still lands here. Investigate."
fi
[ "$fail" -eq 0 ]
