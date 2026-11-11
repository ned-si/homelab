#!/usr/bin/env bash
# agent-kubeconfig.sh <readonly|pentest-setup> [duration]
#
# Mint a short-lived ServiceAccount token (kubectl create token, default 12h)
# and write it as a kubeconfig under ~/homelab-backups/agent/ (mode 600):
#   readonly       kube-system/agent-readonly  -> kubeconfig-readonly
#   pentest-setup  pentest/pentest-setup       -> kubeconfig-pentest-setup
# Run with the operator's kubeconfig (it needs serviceaccounts/token). The
# token expires on its own; no Secret holds a long-lived one (finding P8).
# Prints the file and its expiry, never the token.
set -euo pipefail

case "${1:-}" in
  readonly) ns=kube-system sa=agent-readonly file=kubeconfig-readonly ctx_ns=default ;;
  pentest-setup) ns=pentest sa=pentest-setup file=kubeconfig-pentest-setup ctx_ns=pentest ;;
  *)
    echo "usage: $0 <readonly|pentest-setup> [duration, default 12h]" >&2
    exit 64
    ;;
esac
duration=${2:-12h}
dir=${AGENT_DIR:-$HOME/homelab-backups/agent}
out=$dir/$file

umask 077
mkdir -p "$dir"
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$tmp/ca.crt"
token=$(kubectl -n "$ns" create token "$sa" --duration "$duration")

export KUBECONFIG=$tmp/kubeconfig
kubectl config set-cluster homelab --server="$server" \
  --certificate-authority="$tmp/ca.crt" --embed-certs=true >/dev/null
kubectl config set-credentials "$sa" --token="$token" >/dev/null
kubectl config set-context agent --cluster=homelab --user="$sa" --namespace="$ctx_ns" >/dev/null
kubectl config use-context agent >/dev/null
unset token
mv "$tmp/kubeconfig" "$out"
chmod 600 "$out"
echo "wrote $out, valid for $duration"
