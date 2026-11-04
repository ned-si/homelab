#!/usr/bin/env bash
# Render every kustomization and report pass/fail. Writes nothing: a read-only
# "which directory is broken" next to render-deploy.sh. `kubectl kustomize`
# cannot run KSOPS, so the secrets directories are skipped and listed; use
# `task build` or `task lint:secrets` for those.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

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
