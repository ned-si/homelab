#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Print every hostname this cluster publishes over HTTPS, derived from the
# rendered manifests.
#
# WHY THIS EXISTS
#
# There used to be three hardcoded hostname lists -- scripts/tls-check.sh (15),
# .github/workflows/dast.yaml (7), and the manifests themselves -- and they
# already disagreed. A list that has to be edited by hand every time an app
# lands is a list that silently stops covering the newest thing, which is
# exactly the thing most likely to be misrouted.
#
# So: one derivation, from deploy/, which is what Argo actually applies.
#
# WHAT COUNTS AS PUBLISHED
#
#   yes  `spec.hostnames` of an HTTPRoute. That is the only thing the Gateway
#        terminates TLS for, so it is the only thing a TLS or header check can
#        meaningfully probe.
#
#   no   wildcards. `*.lilalala.com` appears twice: as the Gateway listener's
#        SNI and as the hostname of the `https-redirect` HTTPRoute on the :80
#        listener. Neither is a name you can connect to.
#
#   no   `homelab.lilalala.com`. Despite the shape, this is not a hostname: it
#        is the label-key domain prefix this repo uses for its own labels
#        (`homelab.lilalala.com/lb-pool`, `/managed-by`, `/share`,
#        `/ephemeral`). Nothing serves it. A naive grep for
#        `[a-z-]+\.lilalala\.com` picks it up and it is the reason the
#        "manifests declare 17 hostnames" count is wrong.
#
#   no   `sync.lilalala.com`. It is a real DNS record -- an external-dns
#        annotation on the `syncthing-sync` LoadBalancer Service -- but that
#        Service carries raw TCP/UDP 22000 and UDP 21027 for the Syncthing
#        block-exchange protocol. There is no TLS listener and no HTTP, so a
#        TLS/header probe against it fails for reasons that are not a defect.
#        The Syncthing WEB UI is published separately, as
#        `syncthing.lilalala.com`, and that one is an HTTPRoute.
#
# Parsing is done with awk against the RENDERED output rather than with a YAML
# library, so this stays dependency-free and runs on the self-hosted runner and
# on macOS. That is safe only because deploy/ is normalised kustomize output:
# `kind:` is always at column 0 and `spec.hostnames` always at exactly two
# spaces. It would not be safe against hand-written manifests, where the same
# key can appear at any indentation -- which is also why this reads deploy/ and
# not apps/.
#
# USAGE
#   scripts/published-hostnames.sh            one hostname per line, sorted
#   scripts/published-hostnames.sh --json     JSON array, for a workflow matrix
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# `-print0`/`-0` rather than a bare glob: deploy/ is nested three levels deep in
# places, and `find` is the same on macOS and Linux here.
hosts=$(find deploy -name 'manifests.yaml' -print0 \
        | xargs -0 awk '
    # Each file is a fresh multi-document stream.
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
  # would make tls-check.sh pass without probing anything, and collapse the DAST
  # matrix to nothing. Treat it as a bug in the extractor or in deploy/.
  echo "ERROR: no HTTPRoute hostnames found under deploy/." >&2
  echo "       Either deploy/ is empty (run 'task render') or the rendered" >&2
  echo "       layout changed and the awk program above needs updating." >&2
  exit 1
fi

if [ "$FORMAT" = json ]; then
  # Hand-rolled rather than jq: this runs on a self-hosted runner with nothing
  # installed, and DNS hostnames need no JSON escaping.
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
