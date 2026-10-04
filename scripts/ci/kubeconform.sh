#!/bin/bash
# kubeconform.sh <render-dir>
#
# The `kubeconform` CI check over every render_apps.py output file:
#   -strict -summary -kubernetes-version $K8S_VERSION (default 1.32.13)
#   core schemas: one pinned commit of yannh/kubernetes-json-schema (never the
#                 default branch); CRD schemas: the vendored ci/schemas/
#   no -ignore-missing-schemas: a kind without a schema fails.
# Prints per-file results only for failures (kubeconform names the file, kind
# and object, never values) and the summary line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
render=${1:?usage: kubeconform.sh <render-dir>}
K8S_VERSION=${K8S_VERSION:-1.32.13}
# yannh/kubernetes-json-schema @ 2026-09-29; contains v1.31.2..v1.33.x directories (v1.32.13 included).
SCHEMA_SHA=${KUBE_SCHEMA_SHA:-8df8a883b68a24a104b4a9e43c1288090ae60b3b}

core="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${SCHEMA_SHA}/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
crds="$ROOT/ci/schemas/{{.Group}}_{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$render" -name manifests.yaml -type f | sort)
[ "${#files[@]}" -gt 0 ] || { echo "kubeconform.sh: no manifests under $render" >&2; exit 1; }

set +e
out=$(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
  -schema-location "$core" -schema-location "$crds" "${files[@]}" 2>&1)
rc=$?
set -e
# Paths relative to the render dir keep the output short.
printf '%s\n' "$out" | sed "s|$render/||g"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### kubeconform (k8s $K8S_VERSION, ${#files[@]} files)"; printf '%s\n' "$out" | grep '^Summary' || true; } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$rc"
