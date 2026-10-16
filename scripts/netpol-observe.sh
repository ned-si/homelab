#!/usr/bin/env bash
# netpol-observe.sh -- what a namespace really does on the network, as input
# for its allow-list in infrastructure/network-policies/. Read-only.
#
#   scripts/netpol-observe.sh <namespace> [--since 1h] [--server localhost:4245]
#       Live: Hubble policy-verdict events of the namespace from the relay (one
#       event per new connection), grouped by direction, peer, port and
#       protocol, with the match type: `all` means no allow-list rule covers
#       the flow (a would-be drop once the namespace is default-deny).
#       The relay holds the last few thousand flows per node only; for longer
#       windows use --days.
#
#   scripts/netpol-observe.sh <namespace> --days 7 [--prom http://localhost:9090]
#       History: increase of hubble_policy_verdicts_total over N days, grouped
#       by direction, peer workload and match type (no ports: the metric has
#       none).
#
# Output: tab-separated, sorted by count, one row per (direction, peer, port,
# protocol, match): count first_seen last_seen (live), or count (history).
#
# Prerequisites:
#   kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
#   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
#
# Environment: HUBBLE (default `hubble`), CURL (default `curl`), for tests.
set -euo pipefail

usage() {
  echo "usage: $0 <namespace> [--since <dur>] [--server <host:port>] | [--days <n>] [--prom <url>]" >&2
  exit 64
}

ns=""; since="1h"; server="localhost:4245"; days=""; prom="http://localhost:9090"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) [ "$#" -ge 2 ] || usage; since=$2; shift ;;
    --server) [ "$#" -ge 2 ] || usage; server=$2; shift ;;
    --days) [ "$#" -ge 2 ] || usage; days=$2; shift ;;
    --prom) [ "$#" -ge 2 ] || usage; prom=$2; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$ns" ] || usage; ns=$1 ;;
  esac
  shift
done
[[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || usage
[ -z "$days" ] || [[ "$days" =~ ^[0-9]+$ ]] || usage

HUBBLE=${HUBBLE:-hubble}
CURL=${CURL:-curl}

if [ -n "$days" ]; then
  # Ingress verdicts are reported by the destination's agent, egress by the
  # source's: the policed namespace is the destination for ingress and the
  # source for egress.
  q="sum by (direction, match, source, source_namespace, destination, destination_namespace) (increase(hubble_policy_verdicts_total{direction=\"ingress\", destination_namespace=\"$ns\"}[${days}d]) or increase(hubble_policy_verdicts_total{direction=\"egress\", source_namespace=\"$ns\"}[${days}d]))"
  printf 'direction\tpeer\tmatch\tcount\n'
  "$CURL" -fsS -m 30 --get "$prom/api/v1/query" --data-urlencode "query=$q" |
    jq -r '
      .data.result[]
      | .metric as $m
      | (if $m.direction == "ingress"
           then (if ($m.source_namespace // "") != "" then $m.source_namespace + "/" + $m.source else $m.source end)
           else (if ($m.destination_namespace // "") != "" then $m.destination_namespace + "/" + $m.destination else $m.destination end)
         end) as $peer
      | [$m.direction, $peer, $m.match, ((.value[1] | tonumber | round) | tostring)]
      | @tsv' |
    sort -t "$(printf '\t')" -k4,4nr
  exit 0
fi

# Live. policy_match_type: monitor API PolicyMatchType.
printf 'direction\tpeer\tport\tprotocol\tmatch\tcount\tfirst_seen\tlast_seen\n'
"$HUBBLE" observe --server "$server" --namespace "$ns" --type policy-verdict \
  --since "$since" --all -o jsonpb |
  jq -r --arg ns "$ns" '
    def matchname:
      {"0": "none", "1": "l3-only", "2": "l3-l4", "3": "l4-only", "4": "all",
       "5": "l3-proto", "6": "proto-only"}[tostring] // tostring;
    def name(ep):
      (ep.workloads[0].name
       // ([ep.labels[]? | select(startswith("k8s:app.kubernetes.io/name=") or startswith("k8s:k8s-app=") or startswith("k8s:app="))][0] | if . then split("=")[1] else null end)
       // ep.pod_name // "");
    def peer(ep; ip):
      if (ep.namespace // "") != "" then ep.namespace + "/" + name(ep)
      else ([ep.labels[]? | select(startswith("reserved:"))][0] // "unknown" | sub("^reserved:"; ""))
           + (if (ep.labels // []) | index(["reserved:world"]) then ":" + ip else "" end)
      end;
    .flow
    | select(.traffic_direction == "INGRESS" or .traffic_direction == "EGRESS")
    | (.traffic_direction | ascii_downcase) as $dir
    # Only the verdicts of the policies of this namespace.
    | select(($dir == "ingress" and .destination.namespace == $ns) or ($dir == "egress" and .source.namespace == $ns))
    | (if $dir == "ingress" then peer(.source; .IP.source) else peer(.destination; .IP.destination) end) as $peer
    | (if .l4.TCP then ["TCP", .l4.TCP.destination_port]
       elif .l4.UDP then ["UDP", .l4.UDP.destination_port]
       elif .l4.ICMPv4 then ["ICMP", ""]
       else ["other", ""] end) as $l4
    | [$dir, $peer, ($l4[1] | tostring), $l4[0], (.policy_match_type // 0 | matchname), .time]
    | @tsv' |
  awk -F '\t' -v OFS='\t' '
    { k = $1 OFS $2 OFS $3 OFS $4 OFS $5
      n[k]++
      if (!(k in first) || $6 < first[k]) first[k] = $6
      if (!(k in last) || $6 > last[k]) last[k] = $6 }
    END { for (k in n) print k, n[k], first[k], last[k] }' |
  sort -t "$(printf '\t')" -k6,6nr -k1,1 -k2,2
