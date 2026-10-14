#!/bin/bash
# kyverno.sh -- policy-as-code over deploy/ with the Kyverno CLI.
#
#   1. kyverno test policies/kyverno/tests    the policies' own unit tests
#   2. kyverno apply policies/kyverno/*.yaml  against every file in deploy/
#
# A policy with `validationActions: [Deny]` fails the check on any violation;
# an `[Audit]` policy only reports, with per-policy counts and the violating
# objects in the log and the step summary. These are the baseline for the
# in-cluster Kyverno gates: a policy moves from Audit to Deny once deploy/
# passes it.
#
# A run that checks zero resources fails: an empty deploy/ or a policy
# selector that matches nothing would otherwise pass silently.
#
# The decision is made here from the report, not from kyverno's exit code:
# for ValidatingPolicy, `kyverno apply` exits 1 on Audit findings even with
# --audit-warn.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
rc=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "== kyverno test policies/kyverno/tests"
kyverno test policies/kyverno/tests --remove-color || rc=1

policies=(policies/kyverno/*.yaml)
enforced=()
for p in "${policies[@]}"; do
  if [ "$(yq '.spec.validationActions // [] | contains(["Deny"])' "$p")" = "true" ]; then
    enforced+=("$(yq '.metadata.name' "$p")")
  fi
done
# `--resource <dir>` does not recurse: pass every file.
resources=()
while IFS= read -r f; do resources+=(--resource "$f"); done < <(find deploy -name '*.yaml' -type f | sort)
[ "${#resources[@]}" -gt 0 ] || { echo "kyverno: no files in deploy/; refusing to pass" >&2; exit 1; }
echo "== kyverno apply: ${#policies[@]} policies over $((${#resources[@]} / 2)) files in deploy/"
echo "enforced (Deny): ${enforced[*]:-none}"
kyverno apply "${policies[@]}" "${resources[@]}" --audit-warn --policy-report \
  --remove-color > "$out/report.yaml" 2> "$out/apply.err"
if [ "$(yq '.kind' "$out/report.yaml" 2>/dev/null)" != "ClusterReport" ]; then
  echo "kyverno apply produced no report:" >&2
  head -n 20 "$out/apply.err" "$out/report.yaml" >&2
  exit 1
fi

# A run that evaluated nothing (no files, or no policy matched any of them)
# must not pass: "skip" results do not count as checked.
checked=$(yq -N '[.results[] | select(.result != "skip")] | length' "$out/report.yaml")
if [ "${checked:-0}" -eq 0 ]; then
  echo "kyverno: 0 resources checked; refusing to pass" >&2
  exit 1
fi
echo "checked: $checked policy results"

table=$(yq -N '.results[] | .policy + " " + .result' "$out/report.yaml" | sort | uniq -c \
  | awk '{printf "| %s | %s | %s |\n", $2, $3, $1}')
printf '| policy | result | count |\n|---|---|---|\n%s\n' "$table"

findings=$(yq -N '.results[] | select(.result != "pass" and .result != "skip")
  | .policy + " " + .result + " " + (.resources[0].namespace // "-") + "/" + .resources[0].kind + "/" + .resources[0].name' \
  "$out/report.yaml" | sort -u)
blocking=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  pol=${line%% *}
  res=$(cut -d' ' -f2 <<<"$line")
  if [ "$res" = "error" ] || [[ " ${enforced[*]} " == *" $pol "* ]]; then
    blocking+="$line"$'\n'
  fi
done <<<"$findings"

if [ -n "$findings" ]; then
  echo "== findings (Audit policies report only)"
  echo "$findings"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### kyverno (deploy/)"
    printf '| policy | result | count |\n|---|---|---|\n%s\n' "$table"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "$blocking" ]; then
  echo "== BLOCKING: violations of enforced policies, or evaluation errors" >&2
  printf '%s' "$blocking" >&2
  rc=1
fi
exit "$rc"
