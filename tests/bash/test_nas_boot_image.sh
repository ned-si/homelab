#!/bin/bash
# test_nas_boot_image.sh -- scripts/nas-boot-image.sh against fake `diskutil`,
# `dd` and `shasum`. A device /dev/rdiskN is the file $FAKE/rdiskN.dev.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
SCRIPT="$REPO_ROOT/scripts/nas-boot-image.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FAKE="$tmp/fake"
mkdir -p "$tmp/bin" "$FAKE"

cat > "$tmp/bin/diskutil" <<'EOF'
#!/bin/bash
echo "diskutil $*" >> "$FAKE/calls.log"
case "$1" in
  info) [ -f "$FAKE/$3.plist" ] || exit 1; cat "$FAKE/$3.plist" ;;
  unmountDisk) echo "Unmount of all volumes on ${2#/dev/} was successful" ;;
  *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/dd" <<'EOF'
#!/bin/bash
echo "dd $*" >> "$FAKE/calls.log"
in="" out=""
for a in "$@"; do
  case "$a" in
    if=/dev/*) in="$FAKE/${a#if=/dev/}.dev" ;;
    of=/dev/*) out="$FAKE/${a#of=/dev/}.dev" ;;
  esac
done
if [ -n "$in" ]; then cat "$in"; else cat > "$out"; fi
EOF
cat > "$tmp/bin/shasum" <<'EOF'
#!/bin/bash
[ "$*" = "-a 256" ] || exit 2
set -- $(cksum)
echo "fake$1x$2  -"
EOF
chmod +x "$tmp/bin/diskutil" "$tmp/bin/dd" "$tmp/bin/shasum"

# plist <disk> <Internal: true|false|none> <TotalSize> <MediaName> [SerialNumber]
plist() {
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
    printf '\t<key>DeviceIdentifier</key>\n\t<string>%s</string>\n' "$1"
    [ "$2" = none ] || printf '\t<key>Internal</key>\n\t<%s/>\n' "$2"
    printf '\t<key>MediaName</key>\n\t<string>%s</string>\n' "$4"
    [ -z "${5:-}" ] || printf '\t<key>SerialNumber</key>\n\t<string>%s</string>\n' "$5"
    printf '\t<key>TotalSize</key>\n\t<integer>%s</integer>\n</dict>\n</plist>\n' "$3"
  } > "$FAKE/$1.plist"
}

KINGSTON="KINGSTON SA400S37120G"
SIZE=120034123776

# run <stdin> <args...>: "rc=<n>" and the output, stdout and stderr together.
run() {
  local input=$1 rc=0 out
  shift
  : > "$FAKE/calls.log"
  out=$(printf '%s\n' "$input" | PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>&1) || rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}
calls() { cat "$FAKE/calls.log"; }
# expect_same <name> <file> <file>
expect_same() {
  if cmp -s "$2" "$3"; then ok "$1"; else bad "$1"; fi
}

echo "nas-boot-image"

for args in "" "read" "read disk4" "copy disk4 $tmp/x" "read /dev/disk4 $tmp/x" "read disk4s1 $tmp/x" \
  "read disk $tmp/x" "read disk4 $tmp/x extra"; do
  # shellcheck disable=SC2086 # split into arguments on purpose
  out=$(run "" $args)
  expect_contains "usage: '$args'" "rc=64" "$out"
  expect_eq "usage: '$args': no diskutil call" "" "$(calls)"
done

out=$(run "" read disk9 "$tmp/img")
expect_contains "unknown disk: refused" "rc=3" "$out"

plist disk2 true "$SIZE" "APPLE SSD AP0512Z"
out=$(run "" read disk2 "$tmp/img")
expect_contains "internal disk: refused" "rc=3" "$out"
expect_contains "internal disk: says why" "not reported as external" "$out"
case "$(calls)" in *unmountDisk* | *dd*) bad "internal disk: no unmount, no dd" ;; *) ok "internal disk: no unmount, no dd" ;; esac

plist disk3 none "$SIZE" "$KINGSTON"
out=$(run "" read disk3 "$tmp/img")
expect_contains "no Internal key: refused" "rc=3" "$out"

plist disk5 false 7681501126656 "Micron_5210_MTFDDAK7T6QDE"
out=$(run "" read disk5 "$tmp/img")
expect_contains "7.68 TB pool disk: refused" "rc=3" "$out"
expect_contains "7.68 TB pool disk: says the size" "not 100-130 GB" "$out"
plist disk6 false 32017047552 "USB DISK"
out=$(run "" verify disk6 "$tmp/img")
expect_contains "32 GB stick: refused" "rc=3" "$out"
case "$(calls)" in *dd*) bad "size refusal: no dd" ;; *) ok "size refusal: no dd" ;; esac

# The boot SSD on the adapter.
plist disk4 false "$SIZE" "$KINGSTON"
head -c 65536 /dev/urandom > "$FAKE/rdisk4.dev"
/bin/cp -f "$FAKE/rdisk4.dev" "$tmp/original.dev"
want=$(PATH="$tmp/bin:$PATH" shasum -a 256 < "$FAKE/rdisk4.dev" | awk '{print $1}')

out=$(run "" read disk4 "$tmp/img")
expect_contains "read: ok" "rc=0" "$out"
expect_contains "read: unmounts first" "diskutil unmountDisk /dev/disk4" "$(calls)"
expect_contains "read: raw device, 4 MiB blocks" "dd if=/dev/rdisk4 bs=4m" "$(calls)"
expect_eq "read: sha256 of the raw device" "$want" "$(cat "$tmp/img/core-boot.img.sha256")"
gunzip -c "$tmp/img/core-boot.img.gz" > "$tmp/unpacked.dev"
expect_same "read: image is the device" "$tmp/unpacked.dev" "$FAKE/rdisk4.dev"
expect_contains "read: device plist saved" "$KINGSTON" "$(cat "$tmp/img/core-boot.device.plist")"
if [ -e "$tmp/img/.sha.fifo" ]; then bad "read: fifo removed"; else ok "read: fifo removed"; fi

out=$(run "" read disk4 "$tmp/img")
expect_contains "read again into the same dir: refused" "rc=3" "$out"

out=$(run "" verify disk4 "$tmp/img")
expect_contains "verify: same device" "rc=0" "$out"
printf 'x' >> "$FAKE/rdisk4.dev"
out=$(run "" verify disk4 "$tmp/img")
expect_contains "verify: changed device: rc=1" "rc=1" "$out"
expect_contains "verify: changed device: says so" "MISMATCH" "$out"
out=$(run "" verify disk4 "$tmp/empty")
expect_contains "verify: no recorded sha256: refused" "rc=3" "$out"

# Restore: the device was changed (the migration); the image puts CORE back.
head -c 4096 /dev/urandom > "$FAKE/rdisk4.dev"
plist disk7 false "$SIZE" "Samsung SSD 870"
head -c 4096 /dev/urandom > "$FAKE/rdisk7.dev"
/bin/cp -f "$FAKE/rdisk7.dev" "$tmp/disk7.before"
out=$(run disk7 restore disk7 "$tmp/img")
expect_contains "restore: other media name: refused" "rc=3" "$out"
expect_same "restore: other disk untouched" "$FAKE/rdisk7.dev" "$tmp/disk7.before"

plist disk8 false 120000000000 "$KINGSTON"
out=$(run disk8 restore disk8 "$tmp/img")
expect_contains "restore: other size: refused" "rc=3" "$out"

/bin/cp -f "$FAKE/rdisk4.dev" "$tmp/disk4.before"
out=$(run disk5 restore disk4 "$tmp/img")
expect_contains "restore: wrong identifier typed: refused" "rc=3" "$out"
expect_same "restore: unconfirmed disk untouched" "$FAKE/rdisk4.dev" "$tmp/disk4.before"
case "$(calls)" in *"dd of="*) bad "restore: no write before confirmation" ;; *) ok "restore: no write before confirmation" ;; esac

out=$(run disk4 restore disk4 "$tmp/img")
expect_contains "restore: ok" "rc=0" "$out"
expect_contains "restore: verified" "verified" "$out"
expect_same "restore: device is the image again" "$FAKE/rdisk4.dev" "$tmp/original.dev"
expect_contains "restore: unmounts first" "diskutil unmountDisk /dev/disk4" "$(calls)"

# A recorded serial must match too.
mkdir -p "$tmp/img2"
/bin/cp -f "$tmp/img/core-boot.img.gz" "$tmp/img/core-boot.img.sha256" "$tmp/img2/"
plist disk4 false "$SIZE" "$KINGSTON" "50026B7000000001"
/bin/cp -f "$FAKE/disk4.plist" "$tmp/img2/core-boot.device.plist"
plist disk4 false "$SIZE" "$KINGSTON" "50026B7000000002"
out=$(run disk4 restore disk4 "$tmp/img2")
expect_contains "restore: other serial: refused" "rc=3" "$out"

finish
