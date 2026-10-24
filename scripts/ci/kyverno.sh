#!/bin/bash
# kyverno.sh -- policy-as-code over deploy/ with the Kyverno CLI.
#
#   1. scripts/vendor-upstream.sh --check  the vendored Kyverno and Tetragon
#                                          files are unchanged
#   2. kyverno test policies/kyverno/tests the policies' own unit tests
#   3. kyverno apply                       policies/kyverno/*.yaml and the
#                                          vendored policies/kyverno/upstream
#                                          over every file in deploy/
#
# What blocks is decided here by policy name (BLOCKING), not by the files'
# validationActions: the vendored files stay as upstream wrote them, and the
# cluster runs every policy in Audit. A violation of a BLOCKING policy fails
# the check; every other finding is reported, with per-policy counts and the
# violating objects in the log and the step summary.
#
# An evaluation error fails the check, except the CLI gaps in CLI_GAPS: the
# CLI evaluates the manifests as written, without the API server's defaulting,
# so a policy that reads a defaulted field errors here and not in the cluster.
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

# The policies whose violations fail CI (Deny in CI before the upstream set
# replaced the homelab copies).
BLOCKING="disallow-latest-tag disallow-privileged-containers"
# One `policy|error message` per line: errors that come from the missing API
# defaulting (a Service without spec.type is a ClusterIP once stored).
CLI_GAPS="restrict-nodeport|error: no such key: type"

echo "== scripts/vendor-upstream.sh --check (Kyverno and Tetragon)"
scripts/vendor-upstream.sh policies/kyverno/upstream --check || rc=1
scripts/vendor-upstream.sh platform/tetragon/policies --check || rc=1

echo "== kyverno test policies/kyverno/tests"
kyverno test policies/kyverno/tests --remove-color || rc=1

# policies/kyverno/kustomization.yaml is how infrastructure/kyverno-policies
# syncs these files into the cluster; it is not a policy.
policies=()
for p in policies/kyverno/*.yaml; do
  [ "$(basename "$p")" = kustomization.yaml ] || policies+=("$p")
done
while IFS= read -r p; do policies+=("$p"); done \
  < <(find policies/kyverno/upstream -name '*.yaml' -type f ! -name controls.yaml | sort)
names=" $(for p in "${policies[@]}"; do yq '.metadata.name' "$p"; done | tr '\n' ' ') "
for b in $BLOCKING; do
  [[ "$names" == *" $b "* ]] || { echo "kyverno: BLOCKING policy $b is not in the policy set" >&2; exit 1; }
done
# Expected findings (policies/kyverno/exceptions), the same objects the
# cluster runs.
exceptions=()
for e in policies/kyverno/exceptions/*.yaml; do
  [ "$(basename "$e")" = kustomization.yaml ] || exceptions+=(--exception "$e")
done
# `--resource <dir>` does not recurse: pass every file.
resources=()
while IFS= read -r f; do resources+=(--resource "$f"); done < <(find deploy -name '*.yaml' -type f | sort)
[ "${#resources[@]}" -gt 0 ] || { echo "kyverno: no files in deploy/; refusing to pass" >&2; exit 1; }
# The CLI has no API server to look Namespaces up in: hand it every namespace
# deploy/ uses, so policies that read namespaceObject can evaluate.
{
  printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: Value\nmetadata:\n  name: values\nnamespaces:\n'
  { echo default; find deploy -name '*.yaml' -type f -exec yq -N '.metadata.namespace // ""' {} + ; } \
    | grep -v '^$' | sort -u | while IFS= read -r ns; do
      printf -- '- apiVersion: v1\n  kind: Namespace\n  metadata:\n    name: %s\n' "$ns"
    done
} > "$out/values.yaml"
echo "== kyverno apply: ${#policies[@]} policies over $((${#resources[@]} / 2)) files in deploy/"
echo "blocking: $BLOCKING"
kyverno apply "${policies[@]}" "${exceptions[@]}" "${resources[@]}" --values-file "$out/values.yaml" \
  --audit-warn --policy-report --remove-color > "$out/report.yaml" 2> "$out/apply.err"
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
  | .policy + " " + .result + " " + (.resources[0].namespace // "-") + "/" + .resources[0].kind + "/" + .resources[0].name
  + " " + ((.message // "") | split("\n") | .[0])' \
  "$out/report.yaml" | sort -u)
blocking=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  pol=$(cut -d' ' -f1 <<<"$line")
  res=$(cut -d' ' -f2 <<<"$line")
  msg=$(cut -d' ' -f4- <<<"$line")
  if [ "$res" = "error" ]; then
    grep -qxF "$pol|$msg" <<<"$CLI_GAPS" || blocking+="$line"$'\n'
  elif [[ " $BLOCKING " == *" $pol "* ]]; then
    blocking+="$line"$'\n'
  fi
done <<<"$findings"

if [ -n "$findings" ]; then
  echo "== findings (only BLOCKING policies and evaluation errors fail the check)"
  echo "$findings"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### kyverno (deploy/)"
    printf '| policy | result | count |\n|---|---|---|\n%s\n' "$table"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "$blocking" ]; then
  echo "== BLOCKING: violations of blocking policies, or evaluation errors" >&2
  printf '%s' "$blocking" >&2
  rc=1
fi
exit "$rc"
