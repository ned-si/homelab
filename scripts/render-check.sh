#!/usr/bin/env bash
# Render every kustomization and report pass/fail. Writes nothing.
#
# NOT A PRE-COMMIT HOOK, AND NOT IN CI. `scripts/render-deploy.sh` renders the
# same tree, writes the result and diffs it, so it answers this question and one
# more. Running both meant rendering everything twice locally and a third time in
# CI, for one fact. This stays as a read-only diagnostic -- "which directory is
# broken", with no side effects on deploy/ -- and is referenced from README.md
# and docs/.
#
# Uses `kubectl kustomize` so it works without a standalone kustomize binary.
# NOTE: `kubectl kustomize` does NOT support --enable-alpha-plugins, so the
# SOPS-backed secret directories cannot be rendered this way; they are skipped
# and listed at the end. Use `task build` (real kustomize + ksops) for those, or
# `task lint:secrets` to check they are wired up at all.
#
# infrastructure/gateway-api is NOT skipped, despite fetching a remote CRD
# bundle. render-deploy.sh renders it on every run, so exempting it here only
# made the two scripts disagree about the same directory. If github.com is down
# it fails, and that is the truth about this tree.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0; skipped=()

for d in $(find clusters infrastructure platform apps -name kustomization.yaml -exec dirname {} \; | sort); do
  case "$d" in
    */secrets)
      skipped+=("$d  (needs ksops + sealed *.sops.yaml)")
      continue
      ;;
  esac

  if err=$(kubectl kustomize "$d" 2>&1 >/dev/null); then
    printf 'ok    %s\n' "$d"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$d"
    printf '%s\n' "$err" | sed 's/^/        /' | head -6
    fail=$((fail + 1))
  fi
done

echo
echo "passed: $pass   failed: $fail"
if [ ${#skipped[@]} -gt 0 ]; then
  echo "skipped:"
  printf '  %s\n' "${skipped[@]}"
fi

exit $(( fail > 0 ? 1 : 0 ))
