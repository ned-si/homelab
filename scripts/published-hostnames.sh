#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Print every hostname this cluster publishes over HTTPS, from deploy/, so no
# hand-kept list falls behind.
#
# Published: `spec.hostnames` of an HTTPRoute, the only names the Gateway
# terminates TLS for. Not: wildcards, `homelab.lilalala.com` (a label-key
# prefix), `sync.lilalala.com` (raw TCP/UDP on a LoadBalancer).
#
# awk over deploy/, not a YAML library: kustomize output always has `kind:`
# at column 0 and `spec.hostnames` at two spaces. Not safe on hand-written
# manifests.
#
# USAGE
#   scripts/published-hostnames.sh            one hostname per line, sorted
#   scripts/published-hostnames.sh --json     JSON array, for a workflow matrix
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

FORMAT=lines
case "${1:-}" in
  "")       ;;
  --json)   FORMAT=json ;;
  *)        echo "usage: $0 [--json]" >&2; exit 2 ;;
esac

if [ ! -d deploy ]; then
  echo "ERROR: deploy/ not found. Run 'task render' first." >&2
  exit 1
fi

# SC2016: the single quotes delimit an awk program; `$2` and `$0` are awk
# fields.
# shellcheck disable=SC2016
hosts=$(find deploy -name '*.yaml' -print0 \
        | xargs -0 awk '
    # Each file is a fresh stream (one object per file since render-deploy.sh
    # splits them, but the program does not depend on that).
    FNR == 1                            { kind = ""; inhosts = 0 }
    /^---[[:space:]]*$/                 { kind = ""; inhosts = 0; next }
    /^kind:[[:space:]]/                 { kind = $2; inhosts = 0; next }
    kind == "HTTPRoute" && /^  hostnames:[[:space:]]*$/ { inhosts = 1; next }
    inhosts && /^  - / {
      h = $2
      gsub(/['"'"'"]/, "", h)           # rendered output may quote a wildcard
      if (h !~ /^\*/) print h
      next
    }
    inhosts                             { inhosts = 0 }
  ' | sort -u)

if [ -z "$hosts" ]; then
  # A silently empty list is the failure mode this script exists to prevent: it
  # would make tls-check.sh pass without probing anything, and leave DAST with
  # nothing to scan. Treat it as a bug in the extractor or in deploy/.
  echo "ERROR: no HTTPRoute hostnames found under deploy/." >&2
  echo "       Either deploy/ is empty (run 'task render') or the rendered" >&2
  echo "       layout changed and the awk program above needs updating." >&2
  exit 1
fi

if [ "$FORMAT" = json ]; then
  # Hand-rolled rather than jq, to stay dependency-free; DNS hostnames need no
  # JSON escaping.
  printf '['
  sep=''
  while IFS= read -r h; do
    printf '%s"%s"' "$sep" "$h"
    sep=','
  done <<<"$hosts"
  printf ']\n'
else
  printf '%s\n' "$hosts"
fi
