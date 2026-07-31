#!/usr/bin/env bash
# Render every kustomization and report pass/fail.
#
# Uses `kubectl kustomize` so it works without a standalone kustomize binary.
# NOTE: `kubectl kustomize` does NOT support --enable-alpha-plugins, so the
# SOPS-backed secret directories cannot be rendered this way; they are skipped
# and listed at the end. Use `task build` (real kustomize) to render those.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0; skipped=()

for d in $(find clusters infrastructure platform apps -name kustomization.yaml -exec dirname {} \; | sort); do
  case "$d" in
    */secrets)
      skipped+=("$d  (needs ksops + sealed *.sops.yaml)")
      continue
      ;;
    infrastructure/gateway-api)
      skipped+=("$d  (remote CRD URL, needs network)")
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
