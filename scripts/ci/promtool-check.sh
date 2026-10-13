#!/bin/bash
# promtool-check.sh -- validate every PrometheusRule in deploy/ and run the rule
# unit tests in tests/prometheus/.
#
#   1. `promtool check rules` on the `spec` of every rendered PrometheusRule:
#      syntax, PromQL parse, duplicate rules.
#   2. `promtool test rules` on tests/prometheus/*_test.yaml. A test names its
#      rule file as `<PrometheusRule name>.yaml`; this script writes those
#      files next to a copy of the tests.
#
# Requires promtool and yq v4. Exit 1 on any failure.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
command -v promtool >/dev/null 2>&1 || { echo "promtool-check: promtool not found" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "promtool-check: yq not found" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rc=0 n=0

while IFS= read -r f; do
  name=$(yq -r 'select(.kind == "PrometheusRule") | .metadata.name' "$f")
  [ -n "$name" ] || continue
  yq 'select(.kind == "PrometheusRule") | .spec' "$f" > "$work/$name.yaml"
  n=$((n + 1))
  if ! out=$(promtool check rules "$work/$name.yaml" 2>&1); then
    echo "FAIL  $f"; printf '%s\n' "$out" | sed 's/^/      /'; rc=1
  else
    echo "ok    $f"
  fi
done < <(grep -rl '^kind: PrometheusRule' deploy | sort)
[ "$n" -gt 0 ] || { echo "promtool-check: no PrometheusRule found under deploy/" >&2; exit 1; }

for t in tests/prometheus/*_test.yaml; do
  [ -f "$t" ] || continue
  cp "$t" "$work/"
  if ! promtool test rules "$work/$(basename "$t")"; then rc=1; fi
done
exit "$rc"
