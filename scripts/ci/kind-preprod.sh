#!/bin/bash
# kind-preprod.sh <stage> -- pre-production checks on an ephemeral kind
# cluster: the `preprod` job of .github/workflows/ci.yaml.
#
#   node     pull $KIND_NODE_IMAGE (or load it from $CACHE_DIR/node.tar) and
#            tag it $KIND_NODE_LOCAL for `kind create cluster --image`
#   images   print the images the boot stage runs (cache key and pre-pull)
#   load     pull (or load from $CACHE_DIR) those images into the kind nodes
#   crds     install the CRDs: every pinned source in ci/schemas/SOURCES.txt
#            (sha256-checked, cached in $CACHE_DIR), then the CRDs vendored
#            in deploy/, which are what the cluster runs
#   dry-run  create every namespace deploy/ uses, then server-side apply
#            every file in deploy/ with --dry-run=server: the API server's
#            own validation (schemas, immutable fields, defaulting, built-in
#            admission) of exactly what Argo CD applies
#   boot     apply the stateless workloads in ci/kind-workloads.txt for real;
#            every Deployment must roll out, every Service must get a ready
#            endpoint, and every Valkey must answer PING through its Service
#   all      crds, dry-run, load, boot
#
# Expects the cluster in the current kubectl context (the workflow runs
# `kind create cluster`). Env: KIND_CLUSTER (default preprod), CACHE_DIR
# (default $RUNNER_TEMP/kind-cache), ROLLOUT_TIMEOUT (default 180s).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
KIND_CLUSTER=${KIND_CLUSTER:-preprod}
CACHE_DIR=${CACHE_DIR:-${RUNNER_TEMP:-/tmp}/kind-cache}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-180s}
KIND_NODE_LOCAL=${KIND_NODE_LOCAL:-kindest/node:preprod}
WORKLOADS=ci/kind-workloads.txt
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# Files (one per line) named by ci/kind-workloads.txt; a directory means
# every YAML file in it.
workload_files() {
  local p
  grep -vE '^[[:space:]]*(#|$)' "$WORKLOADS" | while IFS= read -r p; do
    if [ -d "$p" ]; then find "$p" -name '*.yaml' -type f | sort; else echo "$p"; fi
  done
}

# The tar holds the image under a local tag: `docker save` drops the repo
# digest, so a digest reference would not match after `docker load` and kind
# would pull again. The tar is only ever written from a pull of the pinned
# digest (the cache key is that reference).
node_image() {
  local tar="$CACHE_DIR/node.tar"
  : "${KIND_NODE_IMAGE:?KIND_NODE_IMAGE is not set}"
  mkdir -p "$CACHE_DIR"
  if [ -f "$tar" ]; then
    docker load -q -i "$tar"
    echo "node: $KIND_NODE_LOCAL from cache"
  else
    docker pull -q "$KIND_NODE_IMAGE"
    docker tag "$KIND_NODE_IMAGE" "$KIND_NODE_LOCAL"
    docker save -o "$tar" "$KIND_NODE_LOCAL"
    echo "node: $KIND_NODE_IMAGE pulled and saved"
  fi
}

images() {
  # shellcheck disable=SC2046
  yq ea -N 'select(.kind == "Deployment") | .spec.template.spec | (.initContainers // []) + .containers | .[].image' \
    $(workload_files) | sort -u
}

load() {
  local imgs=() i node arch tar="$CACHE_DIR/images.tar"
  while IFS= read -r i; do imgs+=("$i"); done < <(images)
  arch=$(docker version -f '{{.Server.Arch}}')
  mkdir -p "$CACHE_DIR"
  if [ -f "$tar" ]; then
    echo "images: from cache"
  else
    for i in "${imgs[@]}"; do docker pull -q --platform "linux/$arch" "$i"; done
    docker save -o "$tar" "${imgs[@]}"
  fi
  # Not `kind load docker-image`: it imports with --all-platforms, which fails
  # ("content digest ... not found") when Docker's containerd image store
  # holds only the runner's platform of a multi-arch image (kind#3795).
  for node in $(kind get nodes --name "$KIND_CLUSTER"); do
    docker exec -i "$node" ctr --namespace=k8s.io images import \
      --platform "linux/$arch" --digests --snapshotter=overlayfs - < "$tar"
  done
}

crds() {
  local sum url f n=0
  mkdir -p "$CACHE_DIR/crd-sources"
  : > "$work/crds.yaml"
  while read -r sum url; do
    case "$sum" in '#'* | '') continue ;; esac
    # The converter script and the Kubernetes OpenAPI document are not CRDs.
    case "$url" in *.py | *.json) continue ;; esac
    f="$CACHE_DIR/crd-sources/$sum"
    if [ ! -f "$f" ]; then
      curl -fsSL --retry 3 --retry-delay 5 -m 120 -o "$f.part" "$url"
      mv "$f.part" "$f"
    fi
    [ "$(sha256 "$f")" = "$sum" ] || { echo "kind-preprod: sha256 mismatch for $url" >&2; rm -f "$f"; exit 1; }
    yq 'select(.kind == "CustomResourceDefinition")' "$f" >> "$work/crds.yaml"
    echo "---" >> "$work/crds.yaml"
    n=$((n + 1))
  done < ci/schemas/SOURCES.txt
  # Later sources win (SOURCES.txt order): Cilium 1.17 after 1.16.
  kubectl apply --server-side --force-conflicts -f "$work/crds.yaml" > "$work/crds.log"
  find deploy -name 'customresourcedefinition-*.yaml' -type f | sort > "$work/vendored"
  while IFS= read -r f; do
    kubectl apply --server-side --force-conflicts -f "$f" >> "$work/crds.log"
  done < "$work/vendored"
  kubectl wait --for=condition=Established crd --all --timeout=120s > /dev/null
  echo "crds: $(kubectl get crd --no-headers | wc -l | tr -d ' ') established, from $n pinned sources and $(wc -l < "$work/vendored" | tr -d ' ') vendored files"
}

dry_run() {
  local ns files=() rc=0
  # A namespaced dry-run needs its namespace to exist.
  kubectl apply --server-side -f deploy/infrastructure/namespaces/ > /dev/null
  while IFS= read -r f; do files+=("$f"); done < <(find deploy -name '*.yaml' -type f | sort)
  for ns in $(yq ea -N '.metadata.namespace | select(. != null)' "${files[@]}" | sort -u); do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  done
  # Argo CD applies server-side (ServerSideApply=true) as argocd-controller.
  kubectl apply --server-side --force-conflicts --field-manager=argocd-controller \
    --dry-run=server -f deploy/ -R > "$work/dry-run.log" 2>&1 || rc=$?
  grep -v -E '(serverside-applied|configured|unchanged|created) \(server dry run\)$' "$work/dry-run.log" || true
  echo "dry-run: $(grep -c '(server dry run)$' "$work/dry-run.log" || true) objects accepted from ${#files[@]} files, rc=$rc"
  return "$rc"
}

boot() {
  local f ns name img rc=0 i ready
  workload_files > "$work/files"
  while IFS= read -r f; do kubectl apply --server-side -f "$f" > /dev/null; done < "$work/files"
  # One "<kind> <namespace> <name>" line per object (plain `yq`, not
  # `yq ea`: eval-all would join every document into one line).
  # shellcheck disable=SC2046
  yq -N '.kind + " " + (.metadata.namespace // "-") + " " + .metadata.name' $(cat "$work/files") > "$work/objects"
  grep '^Deployment ' "$work/objects" > "$work/deployments" || true
  grep '^Service ' "$work/objects" > "$work/services" || true
  # A boot that checks nothing must not pass.
  [ -s "$work/deployments" ] || { echo "FAIL  no Deployment in $WORKLOADS" >&2; return 1; }
  # Every kubectl in the loops reads /dev/null, not the list being read.
  while read -r _ ns name; do
    if kubectl -n "$ns" rollout status "deployment/$name" --timeout="$ROLLOUT_TIMEOUT" < /dev/null; then
      echo "ok    deployment $ns/$name"
    else
      echo "FAIL  deployment $ns/$name"
      kubectl -n "$ns" describe "deployment/$name" < /dev/null | tail -n 20 || true
      kubectl -n "$ns" get pods -o wide < /dev/null || true
      kubectl -n "$ns" logs "deployment/$name" --all-containers --tail=30 < /dev/null || true
      rc=1
    fi
  done < "$work/deployments"
  while read -r _ ns name; do
    ready=""
    for i in $(seq 1 30); do
      ready=$(kubectl -n "$ns" get endpointslices -l "kubernetes.io/service-name=$name" \
        -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' < /dev/null)
      [ -n "$ready" ] && break
      sleep 2
    done
    if [ -n "$ready" ]; then echo "ok    service $ns/$name -> $ready"; else echo "FAIL  service $ns/$name has no ready endpoint"; rc=1; fi
  done < "$work/services"
  # Valkey answers PING through its Service, from a pod in its namespace.
  # The Valkey Deployments have no readiness probe, so "rolled out" can come
  # before the server listens: up to 5 attempts, 3 s apart.
  while read -r _ ns name; do
    img=$(kubectl -n "$ns" get "deployment/$name" -o jsonpath='{.spec.template.spec.containers[0].image}' < /dev/null)
    case "$img" in */valkey:*) ;; *) continue ;; esac
    pong=0
    for try in 1 2 3 4 5; do
      if kubectl -n "$ns" run "ping-$name-$try" --image="$img" --restart=Never --rm -i --quiet \
        --command -- valkey-cli -h "$name" -p 6379 ping < /dev/null 2>/dev/null | grep -q PONG; then
        pong=1; break
      fi
      sleep 3
    done
    if [ "$pong" = 1 ]; then
      echo "ok    valkey $ns/$name answers PING"
    else
      echo "FAIL  valkey $ns/$name does not answer PING"
      rc=1
    fi
  done < "$work/deployments"
  echo "boot: $(wc -l < "$work/deployments" | tr -d ' ') Deployment(s), $(wc -l < "$work/services" | tr -d ' ') Service(s), rc=$rc"
  return "$rc"
}

stage=${1:-all}
case "$stage" in
  node) node_image ;;
  images) images ;;
  load) load ;;
  crds) crds ;;
  dry-run) dry_run ;;
  boot) boot ;;
  all) crds && dry_run && load && boot ;;
  *) echo "usage: $0 node|images|load|crds|dry-run|boot|all" >&2; exit 64 ;;
esac
