#!/bin/bash
# platform/talos-drift/check.sh against a fake wget (GitHub and the
# Pushgateway) and a fake talosctl whose `apply-config --dry-run` compares
# configs as Talos does: by content, not layout. Each case names the fix it
# guards.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$tmp/bin"

cat > "$tmp/bin/wget" <<'EOF'
#!/bin/bash
d=${FAKE_DIR:?}
url="" post=""
for a in "$@"; do
  case "$a" in --post-file=*) post=${a#--post-file=} ;; -*) ;; *) url=$a ;; esac
done
echo "wget $url" >> "$d/calls.log"
case "$url" in
  *api.github.com*) exit 1 ;;
  */info/refs?service=git-upload-pack) cat "$d/refs" ;;
  https://codeload.github.com/*/tar.gz/*) cat "$d/src.tar.gz" ;;
  */metrics/job/talos-drift) cp "$post" "$d/pushed.txt" ;;
  *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/talosctl" <<'EOF'
#!/bin/bash
d=${FAKE_DIR:?}
echo "talosctl $*" >> "$d/calls.log"
norm() { sed -E -e 's/(^| )#.*$//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }
ip="" file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) ip=$2; shift ;;
    -f) file=$2; shift ;;
    gen) cp "$4" "$d/secrets-from.yaml"; : > "$6"; exit 0 ;;
    get) cat "$d/live-$ip.yaml"; exit 0 ;;
  esac
  shift
done
if [ "$(norm "$file")" = "$(norm "$d/live-$ip.yaml")" ]; then echo "No changes."; else echo "Config diff:"; echo "- x"; echo "+ y"; fi
EOF
chmod +x "$tmp/bin/wget" "$tmp/bin/talosctl"

# The repository tarball: two nodes and a genconfig that renders
# render-<host>.yaml with the sealed Tailscale key as a placeholder.
src="$tmp/homelab-$SHA"
mkdir -p "$src/talos" "$src/scripts"
cat > "$src/talos/talconfig.yaml" <<'EOF'
nodes:
  - hostname: cp-1
    ipAddress: 192.0.2.247
  - hostname: w-1
    ipAddress: 192.0.2.240
EOF
cat > "$src/scripts/talos-genconfig.sh" <<'EOF'
#!/bin/bash
mkdir -p "$TALOS_OUT_DIR"
for h in cp-1 w-1; do cp "$FAKE_DIR/render-$h.yaml" "$TALOS_OUT_DIR/homelab-$h.yaml"; done
EOF
chmod +x "$src/scripts/talos-genconfig.sh"
tar -czf "$tmp/src.tar.gz" -C "$tmp" "homelab-$SHA"
# The ref list in git's pkt-line form: each line starts with its length.
printf '001e# service=git-upload-pack\n0000\n003f%s refs/heads/main\n0000\n' "$SHA" > "$tmp/refs"

cat > "$tmp/render-cp-1.yaml" <<'EOF'
version: v1alpha1
machine:
    type: controlplane
    env:
        TS_EXTRA: "TS_AUTHKEY=${TS_AUTHKEY}"
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
EOF
printf 'version: v1alpha1\nmachine:\n    type: worker\n' > "$tmp/render-w-1.yaml"
# What the nodes run: the same configs with Talos' documentation comments
# (since 2026-10-28), a blank line before the separator and the real key.
cat > "$tmp/live-192.0.2.247.yaml" <<'EOF'
version: v1alpha1 # Indicates the schema used to decode the contents.
machine:
    type: controlplane # Defines the role of the machine within the cluster.
    env:
        TS_EXTRA: "TS_AUTHKEY=tskey-auth-live"

---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
EOF
printf 'version: v1alpha1\nmachine:\n    # Defines the role.\n    type: worker\n' > "$tmp/live-192.0.2.240.yaml"

run() {
  local o r=0
  rm -rf "$tmp/work" && mkdir -p "$tmp/work"
  : > "$tmp/calls.log"
  rm -f "$tmp/pushed.txt"
  o=$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" PUSHGATEWAY=http://pushgateway:9091 TALOSCONFIG="$tmp/talosconfig" \
    WORK_DIR="$tmp/work" bash "$REPO_ROOT/platform/talos-drift/check.sh" 2>&1) || r=$?
  printf 'rc=%s\n%s' "$r" "$o"
}

o=$(run)
expect_contains "a cosmetic layout difference is no drift" "rc=0" "$o"
# #851: main's commit comes from the git ref list (pkt-line prefix stripped), not the REST API.
expect_contains "main's commit read from info/refs" "main at $SHA" "$o"
expect_eq "no REST API call" 0 "$(grep -c api.github.com "$tmp/calls.log" || true)"
# #854: the control plane is found though its type line carries a comment.
expect_eq "secrets rebuilt from the control plane" "$(cat "$tmp/live-192.0.2.247.yaml")" "$(cat "$tmp/secrets-from.yaml")"
# #856, #464, #858: comments and a blank line before `---` are no drift.
expect_contains "cp-1 matches" "cp-1 (192.0.2.247) matches main" "$o"
expect_contains "w-1 matches" "w-1 (192.0.2.240) matches main" "$o"
# #862: the sealed key is taken from the running node, and never logged.
expect_contains "pushed 0 for cp-1" 'talos_config_drift{node="cp-1"} 0' "$(cat "$tmp/pushed.txt")"
case "$o" in *tskey-auth-live*) bad "the Tailscale key is not logged" ;; *) ok "the Tailscale key is not logged" ;; esac

# A real difference still drifts.
printf 'version: v1alpha1\nmachine:\n    type: worker\n    install:\n        disk: /dev/sdb\n' > "$tmp/live-192.0.2.240.yaml"
o=$(run)
expect_contains "w-1 drifts" "w-1 (192.0.2.240) DRIFT" "$o"
expect_contains "pushed 1 for w-1" 'talos_config_drift{node="w-1"} 1' "$(cat "$tmp/pushed.txt")"
expect_contains "one node differs" "1 node(s) differ from main" "$o"

finish
