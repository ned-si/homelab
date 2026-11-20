#!/bin/bash
# dashboard-compare.sh
#
# Compare the publisher's figures with the homelab-dashboard collector's for
# the same finished day, before the switch-over
# (.kiro/specs/homelab-dashboard/design.md#migration). Reads `covers` from
# the ConfigMap website/website-data, runs a dry run of the collector at the
# end of that day, and compares both documents as numbers, not as text
# (`100.0` and `100` are equal). Read-only: `kubectl get` and one `exec` of
# `collect --once --dry-run`, which pushes nothing.
#
# Environment: KUBECONFIG. Exit 0 equal, 1 different (the sorted diff on
# stdout), 2 kubectl or jq error.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

k() { kubectl --request-timeout=30s "$@"; }

if ! k -n website get configmap website-data -o 'jsonpath={.data.figures\.json}' > "$work/pub.json"; then
  echo "dashboard-compare: cannot read website/website-data" >&2
  exit 2
fi
covers=$(jq -er '.covers' "$work/pub.json") || { echo "dashboard-compare: no covers in figures.json" >&2; exit 2; }

if ! k -n homelab-dashboard exec deploy/homelab-dashboard-collector -- \
  /homelab-dashboard collect --once --dry-run --as-of "$covers" > "$work/app.json"; then
  echo "dashboard-compare: the collector's dry run failed" >&2
  exit 2
fi

equal=$(jq -n --slurpfile a "$work/pub.json" --slurpfile b "$work/app.json" \
  '($a[0] | del(.computed_at)) == ($b[0] | del(.computed_at))') || exit 2
if [ "$equal" = true ]; then
  echo "equal: covers $covers"
  exit 0
fi
echo "different: covers $covers"
jq -S 'del(.computed_at)' "$work/pub.json" > "$work/pub.sorted.json"
jq -S 'del(.computed_at)' "$work/app.json" > "$work/app.sorted.json"
diff -u -L publisher -L collector "$work/pub.sorted.json" "$work/app.sorted.json" || true
exit 1
