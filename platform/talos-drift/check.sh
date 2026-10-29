#!/usr/bin/env bash
# check.sh -- daily Talos machine config drift check (CronJob talos-drift).
#
#   1. Download main of the repository at one commit (public, no credentials).
#   2. Read every node's running machine config over the Talos API.
#   3. Rebuild the cluster secrets from a control plane's running config
#      (talosctl gen secrets --from-controlplane-config) and render the configs
#      from main with scripts/talos-genconfig.sh, as `task talos:genconfig`
#      does with talos/talsecret.sops.yaml. The age key never enters the
#      cluster; same secrets in, same bytes out.
#   4. Compare sha256 per node (see norm) and push talos_config_drift{node} (1 = differs
#      from main) and the run timestamp to the Pushgateway.
#
# Configs and secrets stay in a memory-backed emptyDir and are never printed;
# the log shows node names, match or drift, and hash prefixes.
set -euo pipefail

REPO=${REPO:-ned-si/homelab}
PUSHGATEWAY=${PUSHGATEWAY:?}
TALOSCONFIG=${TALOSCONFIG:?}
export TALOSCONFIG
work=${WORK_DIR:?}

# busybox wget (the image has no curl).
get() { wget -q -T 60 -O - "$@"; }

# The commit of main from the git smart-HTTP ref list, not the REST API: the
# API's unauthenticated quota (60/h per IP) is shared with github-exporter
# and ran out on 2026-10-29 (403), which failed the run.
sha=$(get "https://github.com/$REPO.git/info/refs?service=git-upload-pack" |
  awk '$2 == "refs/heads/main" { print substr($1, length($1) - 39) }')
case "$sha" in *[!0-9a-f]* | "") echo "talos-drift: bad commit id from GitHub" >&2; exit 1 ;; esac
mkdir -p "$work/src" "$work/live"
get "https://codeload.github.com/$REPO/tar.gz/$sha" | tar -xz -C "$work/src"
echo "talos-drift: main at $sha"

cd "$work/src"/*/
# hostname and IP of every node, from talconfig.yaml.
nodes=$(awk '/^ *- hostname:/ {h=$3} /^ *ipAddress:/ {print h, $2}' talos/talconfig.yaml)
[ -n "$nodes" ] || { echo "talos-drift: no nodes in talos/talconfig.yaml" >&2; exit 1; }

cp_live=""
while read -r host ip; do
  # $(...) drops every trailing newline; printf puts back the one the file has.
  spec=$(talosctl -n "$ip" get machineconfig v1alpha1 -o jsonpath='{.spec}')
  printf '%s\n' "$spec" > "$work/live/$host.yaml"
  unset spec
  if [ -z "$cp_live" ] && grep -qE '^ +type: controlplane$' "$work/live/$host.yaml"; then
    cp_live="$work/live/$host.yaml"
  fi
done <<< "$nodes"
[ -n "$cp_live" ] || { echo "talos-drift: no control plane config read" >&2; exit 1; }

talosctl gen secrets --from-controlplane-config "$cp_live" -o "$work/secrets.yaml" > /dev/null
TALOS_SECRET_FILE="$work/secrets.yaml" TALOS_OUT_DIR="$work/gen" \
  scripts/talos-genconfig.sh > /dev/null

# The running config has a blank line before the first `---` that the rendered
# one lacks; drop blank lines before a document separator on both sides. The
# Tailscale auth key is sealed in talos/talenv.sops.yaml and renders as a
# placeholder here: its value is masked on both sides.
norm() {
  sed 's/TS_AUTHKEY=.*/TS_AUTHKEY=-/' "$1" |
    awk '/^$/ { n++; next } { if ($0 != "---") for (; n > 0; n--) print ""; n = 0; print }
         END { for (; n > 0; n--) print "" }' | sha256sum | cut -c1-64
}

metrics="$work/metrics.txt"
{
  echo "# TYPE talos_config_drift gauge"
  echo "# HELP talos_config_drift 1 when the node's running machine config differs from the one rendered from main."
} > "$metrics"
drift=0
while read -r host ip; do
  want=$(norm "$work/gen/homelab-$host.yaml")
  have=$(norm "$work/live/$host.yaml")
  if [ "$want" = "$have" ]; then
    v=0; echo "talos-drift: $host ($ip) matches main (${have:0:12})"
  else
    v=1; drift=$((drift + 1))
    echo "talos-drift: $host ($ip) DRIFT: running ${have:0:12}, main renders ${want:0:12}"
  fi
  echo "talos_config_drift{node=\"$host\"} $v" >> "$metrics"
done <<< "$nodes"
{
  echo "# TYPE talos_config_drift_last_success_timestamp_seconds gauge"
  echo "talos_config_drift_last_success_timestamp_seconds $(date +%s)"
} >> "$metrics"

wget -q -T 30 -O /dev/null --post-file="$metrics" "$PUSHGATEWAY/metrics/job/talos-drift"
echo "talos-drift: $drift node(s) differ from main"
