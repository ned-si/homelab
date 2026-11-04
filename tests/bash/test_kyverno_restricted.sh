#!/bin/bash
# Tests for the Pod Security rule of scripts/ci/kyverno.sh: the restricted
# set blocks in `enforce: restricted` namespaces, the renders of a
# webhook-excluded namespace are kept only when it enforces restricted.
# Needs the kyverno CLI and yq (the render job installs both).
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

if ! command -v kyverno > /dev/null 2>&1 || ! command -v yq > /dev/null 2>&1; then
  echo "  skip: kyverno or yq not installed"
  exit 0
fi

SCRIPT="$REPO_ROOT/scripts/ci/kyverno.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/namespaces.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: fixture-restricted
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: fixture-baseline
  labels:
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: argo
  labels:
    pod-security.kubernetes.io/enforce: restricted
EOF

# deployment <namespace>: passes baseline and the other blocking policies,
# fails the restricted set (no seccomp, no runAsNonRoot, capabilities kept,
# privilege escalation allowed).
deployment() {
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: $1
spec:
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: app
          image: registry.example/app:1.0
EOF
}

# run_case <deploy namespace> [<render namespace>]: kyverno.sh over a deploy/
# with one Deployment, plus a Helm render with one Deployment when given.
run_case() {
  rm -rf "$tmp/deploy" "$tmp/render"
  mkdir -p "$tmp/deploy/apps/app"
  deployment "$1" > "$tmp/deploy/apps/app/deployment-app.yaml"
  extra=()
  if [ -n "${2:-}" ]; then
    mkdir -p "$tmp/render/chart"
    deployment "$2" | sed '4s/name: app$/name: chart-app/' > "$tmp/render/chart/manifests.yaml"
    printf '[{"app": "chart", "namespace": "%s"}]\n' "$2" > "$tmp/render/index.json"
    extra=(KYVERNO_EXTRA="$tmp/render")
  fi
  out=$(env KYVERNO_APPLY_ONLY=1 KYVERNO_DEPLOY="$tmp/deploy" NAMESPACES_FILE="$tmp/namespaces.yaml" \
    ${extra[@]+"${extra[@]}"} bash "$SCRIPT" 2>&1)
  code=$?
}

echo "restricted set in an enforce: restricted namespace blocks"
run_case fixture-restricted
expect_eq "exit 1" 1 "$code"
expect_contains "names the namespaces read" "restricted namespaces ($tmp/namespaces.yaml): fixture-restricted argo" "$out"
expect_contains "blocking finding" "require-run-as-nonroot warn fixture-restricted/Deployment/app" "$out"

echo "the same Deployment in a warn-only namespace passes"
run_case fixture-baseline
expect_eq "exit 0" 0 "$code"
expect_contains "reported, not blocking" "require-run-as-nonroot warn fixture-baseline/Deployment/app" "$out"

echo "a render in a webhook-excluded namespace that enforces restricted is kept and blocks"
run_case fixture-baseline argo
expect_eq "exit 1" 1 "$code"
expect_contains "kept namespace logged" "renders kept: argo" "$out"
expect_contains "blocking finding" "require-run-as-nonroot warn argo/Deployment/chart-app" "$out"

echo "a render in a webhook-excluded namespace that does not enforce restricted is dropped"
run_case fixture-baseline kube-system
expect_eq "exit 0" 0 "$code"
case "$out" in
  *kube-system/Deployment/chart-app*) bad "kube-system render dropped" ;;
  *) ok "kube-system render dropped" ;;
esac

echo "no enforce: restricted namespace refuses to pass"
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: x\n' > "$tmp/empty.yaml"
out=$(env KYVERNO_APPLY_ONLY=1 KYVERNO_DEPLOY="$tmp/deploy" NAMESPACES_FILE="$tmp/empty.yaml" bash "$SCRIPT" 2>&1)
expect_eq "exit 1" 1 "$?"
expect_contains "says why" "no enforce: restricted namespace" "$out"

finish
