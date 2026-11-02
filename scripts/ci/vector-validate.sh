#!/bin/bash
# vector-validate.sh [repo-root] -- compile the Vector agent config the way the
# DaemonSet loads it.
#
# The Vector chart is an upstream Helm chart (not rendered into deploy/) and
# passes customConfig through Helm `tpl`, so the config is checked here:
#   1. `helm template` the chart of clusters/homelab/platform/vector.yaml at
#      its targetRevision, with the Application's release name, namespace and
#      valueFiles;
#   2. take `vector.yaml` from the rendered ConfigMap;
#   3. `vector validate --no-environment` with the image the DaemonSet runs:
#      image.repository:image.tag@image.sha from the values, digest-pinned and
#      tracked by Renovate, so a chart or image bump is validated with its own
#      binary.
# Errors exit 1; warnings are printed only.
#
# VECTOR_BIN=<path> runs a local vector binary instead of the image (no Docker
# daemon); its version must equal the image tag's.
# Requires helm, yq v4, and docker unless VECTOR_BIN is set.
set -euo pipefail

root=${1:-.}
cd "$root"
app=clusters/homelab/platform/vector.yaml

die() { echo "vector-validate: $*" >&2; exit 1; }

[ -f "$app" ] || die "$app not found"
sel='.spec.sources[] | select(.chart == "vector")'
chart_repo=$(yq "$sel | .repoURL" "$app")
chart_version=$(yq "$sel | .targetRevision" "$app")
release=$(yq "$sel | .helm.releaseName // \"vector\"" "$app")
namespace=$(yq '.spec.destination.namespace' "$app")
value_files=$(yq "$sel | .helm.valueFiles[]" "$app")

[[ "$chart_repo" =~ ^https://[A-Za-z0-9./_-]+$ ]] || die "chart repoURL not understood: $chart_repo"
[[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "chart targetRevision not a version: $chart_version"
[[ "$release" =~ ^[a-z0-9-]+$ ]] || die "releaseName not understood: $release"
[[ "$namespace" =~ ^[a-z0-9-]+$ ]] || die "destination namespace not understood: $namespace"
[ -n "$value_files" ] || die "$app lists no valueFiles"

values_args=()
values=""
for vf in $value_files; do
  f=${vf#\$values/}
  [ -f "$f" ] || die "value file $vf not found"
  values_args+=(-f "$f")
  values=$f
done

# The image the chart deploys: the last value file that sets it.
image_repo="" image_tag="" image_sha=""
for vf in $value_files; do
  f=${vf#\$values/}
  r=$(yq '.image.repository // ""' "$f"); [ -z "$r" ] || image_repo=$r
  t=$(yq '.image.tag // ""' "$f"); [ -z "$t" ] || image_tag=$t
  s=$(yq '.image.sha // ""' "$f"); [ -z "$s" ] || image_sha=$s
done
[[ "$image_repo" =~ ^[a-z0-9./_-]+$ ]] || die "image.repository not set or not understood in $values"
[[ "$image_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]] || die "image.tag not a version in $values: $image_tag"
[[ "$image_sha" =~ ^sha256:[0-9a-f]{64}$ ]] || die "image.sha not a sha256 digest in $values"
version=${image_tag%%-*}

work=$(mktemp -d "${TMPDIR:-/tmp}/vector-validate.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod 0755 "$work"

echo "vector-validate: chart vector $chart_version, image $image_tag"
helm template "$release" vector --repo "$chart_repo" --version "$chart_version" \
  --namespace "$namespace" "${values_args[@]}" > "$work/render.yaml" \
  || die "helm template failed"

cm='[select(.kind == "ConfigMap" and .data["vector.yaml"] != null)]'
n=$(yq ea "$cm | length" "$work/render.yaml")
[ "$n" = 1 ] || die "expected one ConfigMap with data.vector.yaml in the render, found $n"
yq ea "$cm | .[0].data[\"vector.yaml\"]" "$work/render.yaml" > "$work/vector.yaml"
chmod 0644 "$work/vector.yaml"

if [ -n "${VECTOR_BIN:-}" ]; then
  got=$("$VECTOR_BIN" --version | awk '{print $2}')
  [ "$got" = "$version" ] || die "VECTOR_BIN is vector $got, the image is $version"
  VECTOR_SELF_NODE_NAME=ci "$VECTOR_BIN" validate --no-environment "$work/vector.yaml" \
    || die "vector $version rejects the config"
else
  ref="$image_repo:$image_tag@$image_sha"
  pulled=0
  for _ in 1 2 3; do
    if docker pull -q "$ref" > /dev/null; then pulled=1; break; fi
    sleep 5
  done
  [ "$pulled" = 1 ] || die "docker pull $ref failed"
  docker run --rm --network none -e VECTOR_SELF_NODE_NAME=ci -v "$work:/cfg:ro" \
    "$ref" validate --no-environment /cfg/vector.yaml \
    || die "vector $version rejects the config"
fi
echo "vector-validate: config valid for vector $version"
