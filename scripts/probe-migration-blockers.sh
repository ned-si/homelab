#!/usr/bin/env bash
# Characterise the things that block applying this repo to the CURRENT cluster.
# Read-only.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
: "${KUBECONFIG:=$PWD/kubeconfig-homelab}"
export KUBECONFIG
s() { printf '\n########## %s ##########\n' "$*"; }

s "CNPG OPERATOR VERSION (does it support spec.plugins?)"
kubectl -n immich get deploy cnpg-cloudnative-pg \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>&1
echo "--- does the Cluster CRD declare spec.plugins? ---"
kubectl get crd clusters.postgresql.cnpg.io -o json 2>/dev/null \
  | grep -o '"plugins"' | head -1 || echo "  spec.plugins NOT in CRD schema"
echo "--- barmanObjectStore present in CRD (the in-tree path)? ---"
kubectl get crd clusters.postgresql.cnpg.io -o json 2>/dev/null \
  | grep -o '"barmanObjectStore"' | head -1 || echo "  barmanObjectStore NOT in schema"

s "EXISTING DEPLOYMENT STRATEGIES (why Recreate is rejected)"
for ns in seafile keycloak paperless mealie theater immich; do
  kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}  strategy={.spec.strategy.type}  rollingUpdate={.spec.strategy.rollingUpdate}{"\n"}{end}' 2>/dev/null
done

s "EXISTING SELECTORS (immutable - which of mine collide?)"
for ns in seafile keycloak paperless mealie theater syncthing; do
  kubectl -n "$ns" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name}  selector={.spec.selector.matchLabels}{"\n"}{end}' 2>/dev/null
done

s "SYNCTHING STATEFULSET - what exactly is immutable here?"
kubectl -n syncthing get statefulset syncthing \
  -o jsonpath='serviceName={.spec.serviceName}{"\n"}vct={.spec.volumeClaimTemplates}{"\n"}selector={.spec.selector.matchLabels}{"\n"}' 2>&1 | cut -c1-300

s "DOES rollingUpdate:null FIX THE STRATEGY PROBLEM? (isolated test on keycloak)"
kubectl -n keycloak get deploy keycloak -o json 2>/dev/null \
  | jq '{apiVersion,kind,metadata:{name:.metadata.name,namespace:.metadata.namespace},
         spec:{selector:.spec.selector,
               strategy:{type:"Recreate",rollingUpdate:null},
               template:.spec.template}}' \
  | kubectl apply --dry-run=server --server-side --force-conflicts \
      --field-manager=argocd-controller -f - 2>&1 | cut -c1-200 | head -4
