#!/bin/bash
# scripts/ci/vector-validate.sh with stubbed helm, docker and vector.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SHA=sha256:$(printf 'a%.0s' $(seq 1 64))
bin=$tmp/bin
mkdir -p "$bin"
export STUB_LOG=$tmp/calls.log

# helm: prints $STUB_RENDER. docker: `pull` ok; `run` copies the mounted
# config to $STUB_SEEN and fails when it contains BAD. vector: same, local.
cat > "$bin/helm" <<'EOF'
#!/bin/bash
echo "helm $*" >> "$STUB_LOG"
if [ "$1" = pull ]; then
  dest=${!#}
  src=$(mktemp -d)
  mkdir "$src/vector"
  printf 'name: vector\nversion: 0.61.0\n' > "$src/vector/Chart.yaml"
  tar -czf "$dest/vector-0.61.0.tgz" -C "$src" vector
  rm -rf "$src"
  exit 0
fi
cat "$STUB_RENDER"
EOF
cat > "$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
[ "$1" = run ] || exit 0
while [ "$#" -gt 0 ]; do
  if [ "$1" = -v ]; then src=${2%%:*}; fi
  shift
done
cp "$src/vector.yaml" "$STUB_SEEN"
! grep -q BAD "$STUB_SEEN"
EOF
cat > "$bin/vector" <<'EOF'
#!/bin/bash
echo "vector $* node=${VECTOR_SELF_NODE_NAME:-}" >> "$STUB_LOG"
if [ "$1" = --version ]; then echo "vector ${STUB_VERSION:-0.61.0} (x86_64-unknown-linux-gnu)"; exit 0; fi
cp "${!#}" "$STUB_SEEN"
! grep -q BAD "$STUB_SEEN"
EOF
chmod +x "$bin/helm" "$bin/docker" "$bin/vector"
export PATH="$bin:$PATH"

mkrepo() { # dir tag sha
  mkdir -p "$1/clusters/homelab/platform" "$1/platform/vector"
  cat > "$1/clusters/homelab/platform/vector.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vector
spec:
  sources:
    - repoURL: https://helm.vector.dev
      chart: vector
      targetRevision: 0.61.0
      helm:
        releaseName: vector
        valueFiles:
          - \$values/platform/vector/values.yaml
    - repoURL: https://github.com/ned-si/homelab.git
      targetRevision: main
      ref: values
  destination:
    namespace: logging
EOF
  cat > "$1/platform/vector/values.yaml" <<EOF
image:
  repository: docker.io/timberio/vector
  tag: $2
  sha: $3
EOF
}

render() { # config-line
  cat > "$tmp/render.yaml" <<EOF
---
# Source: vector/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vector
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector
data:
  vector.yaml: |
    sources:
      x: {type: internal_metrics}
    # $1
EOF
}

run_validate() { # repo -> "rc|output"
  local rc=0 out
  : > "$STUB_LOG"
  out=$(bash "$REPO_ROOT/scripts/ci/vector-validate.sh" "$1" 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

export STUB_RENDER=$tmp/render.yaml STUB_SEEN=$tmp/seen.yaml
repo=$tmp/repo
mkrepo "$repo" 0.61.0-distroless-libc "$SHA"

render ok
out=$(run_validate "$repo")
expect_eq "valid config passes" "0" "${out%%|*}"
expect_contains "helm pulls the Application's chart version" \
  "helm pull vector --repo https://helm.vector.dev --version 0.61.0 --destination " "$(cat "$STUB_LOG")"
expect_contains "helm renders the pulled chart with the values" \
  "/vector-0.61.0.tgz --namespace logging -f platform/vector/values.yaml" "$(cat "$STUB_LOG")"
expect_contains "docker runs the pinned image, offline" \
  "docker run --rm --network none -e VECTOR_SELF_NODE_NAME=ci -v " "$(cat "$STUB_LOG")"
expect_contains "docker validates the mounted config" \
  ":/cfg:ro docker.io/timberio/vector:0.61.0-distroless-libc@$SHA validate --no-environment /cfg/vector.yaml" "$(cat "$STUB_LOG")"
expect_contains "the ConfigMap's vector.yaml is validated" "type: internal_metrics" "$(cat "$STUB_SEEN")"

render BAD
out=$(run_validate "$repo")
expect_eq "invalid config fails" "1" "${out%%|*}"
expect_contains "failure names the version" "vector 0.61.0 rejects the config" "$out"

cat > "$tmp/render.yaml" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vector
EOF
out=$(run_validate "$repo")
expect_eq "render without the ConfigMap fails" "1" "${out%%|*}"
expect_contains "missing ConfigMap is reported" "found 0" "$out"

render ok
out=$(VECTOR_BIN=vector run_validate "$repo")
expect_eq "VECTOR_BIN of the image version passes" "0" "${out%%|*}"
expect_contains "VECTOR_BIN validates without environment checks" "validate --no-environment" "$(cat "$STUB_LOG")"
expect_contains "VECTOR_SELF_NODE_NAME is set" "node=ci" "$(cat "$STUB_LOG")"

out=$(STUB_VERSION=0.60.1 VECTOR_BIN=vector run_validate "$repo")
expect_eq "VECTOR_BIN of another version fails" "1" "${out%%|*}"
expect_contains "version mismatch is reported" "VECTOR_BIN is vector 0.60.1, the image is 0.61.0" "$out"

bad=$tmp/badsha
mkrepo "$bad" 0.61.0-distroless-libc latest
out=$(run_validate "$bad")
expect_eq "image without a digest fails" "1" "${out%%|*}"
expect_contains "missing digest is reported" "image.sha not a sha256 digest" "$out"

finish
