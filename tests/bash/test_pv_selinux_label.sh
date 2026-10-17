#!/bin/bash
# test_pv_selinux_label.sh -- scripts/pv-selinux-label.sh against a stubbed
# `kubectl` that keeps one PV's mount options in a file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
SCRIPT="$REPO_ROOT/scripts/pv-selinux-label.sh"
LABEL="context=system_u:object_r:ephemeral_t:s0"
PV=pvc-2cf1f664-0f17-48c1-98e2-3283e74e50c9

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
case "$*" in
  *"patch pv"*)
    [ "${KUBECTL_FAIL_PATCH:-}" = 1 ] && exit 1
    p=${*##*-p }
    if [[ "$p" == *null* ]]; then : > "$STATE/opts"
    else echo "$p" | grep -o '"[^"]*"' | tr -d '"' | grep -v -E '^(spec|mountOptions)$' > "$STATE/opts"; fi ;;
  *"get pv"*"{.spec.csi.driver}"*) cat "$STATE/driver" ;;
  *"get pv"*"claimRef"*) echo "signoz/data-ch" ;;
  *"get pv"*"mountOptions[*]}{@}{\"\\n\"}"*) cat "$STATE/opts" ;;
  *"get pv"*"mountOptions[*]}{@}{\",\"}"*) tr '\n' ',' < "$STATE/opts" ;;
  *"get pods"*) printf 'chi-0 data-ch config\nother-0 x\n' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/kubectl"
export KUBECTL_LOG="$tmp/kubectl.log" STATE="$tmp"

# run <args...>: "rc=<n>" and the output, stdout and stderr together.
run() {
  : > "$KUBECTL_LOG"
  local rc=0 out
  out=$(PATH="$tmp/bin:$PATH" "$SCRIPT" "$@" 2>&1) || rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}
state() { echo org.democratic-csi.iscsi > "$tmp/driver"; printf '%s' "$1" > "$tmp/opts"; }

echo "pv-selinux-label"
state ""
out=$(run "$PV")
expect_contains "dry run: ok" "rc=0" "$out"
expect_contains "dry run: before" "before: []" "$out"
expect_contains "dry run: after" "after:  [$LABEL]" "$out"
expect_contains "dry run: says so" "dry run: kubectl patch pv $PV" "$out"
expect_eq "dry run: no patch" "" "$(grep 'patch' "$KUBECTL_LOG" || true)"

out=$(run "$PV" --apply)
expect_contains "apply: ok" "rc=0" "$out"
expect_contains "apply: patch" "patch pv $PV --type=merge -p {\"spec\":{\"mountOptions\":[\"$LABEL\"]}}" "$(cat "$KUBECTL_LOG")"
expect_contains "apply: prints the result" "now:    [$LABEL]" "$out"
expect_contains "apply: names the pod to restart" "restart: chi-0 (namespace signoz)" "$out"

out=$(run "$PV" --apply)
expect_contains "apply again: idempotent" "nothing to do" "$out"
expect_eq "apply again: no patch" "" "$(grep 'patch' "$KUBECTL_LOG" || true)"

state $'nouuid\ncontext=system_u:object_r:other_t:s0\n'
out=$(run "$PV" --apply)
expect_contains "other options kept, old context replaced" "after:  [nouuid,$LABEL]" "$out"

out=$(run "$PV" --revert)
expect_contains "revert: ok" "rc=0" "$out"
expect_contains "revert: label gone" "after:  [nouuid]" "$out"
state "$LABEL"
out=$(run "$PV" --revert)
expect_contains "revert to none: null patch" '{"spec":{"mountOptions":null}}' "$(cat "$KUBECTL_LOG")"

state ""
out=$(run pvc-b9d3e7d8-0d3e-43d4-b8d3-8f212ede0ea6 --apply)
expect_contains "immich-data: refused" "rc=2" "$out"
expect_contains "immich-data: says why" "stays unlabelled" "$out"
expect_eq "immich-data: no kubectl call" "" "$(cat "$KUBECTL_LOG")"

gitpv=$(grep -rhoE 'name: pvc-[0-9a-f-]{36}' "$REPO_ROOT/infrastructure/iscsi-volumes" | grep -v b9d3e7d8 | head -1)
gitpv=${gitpv#name: }
out=$(run "$gitpv" --apply)
expect_contains "git-managed: refused" "rc=2" "$out"
expect_eq "git-managed: no kubectl call" "" "$(cat "$KUBECTL_LOG")"

echo nfs.csi.k8s.io > "$tmp/driver"
out=$(run "$PV" --apply)
expect_contains "other driver: refused" "rc=2" "$out"

state ""
out=$(KUBECTL_FAIL_PATCH=1 run "$PV" --apply)
expect_contains "patch error: rc=1" "rc=1" "$out"

for bad in "" "nope" "$PV --force" "$PV --apply x"; do
  # shellcheck disable=SC2086 # split into arguments on purpose
  out=$(run $bad)
  expect_contains "usage: '$bad'" "rc=64" "$out"
done

finish
