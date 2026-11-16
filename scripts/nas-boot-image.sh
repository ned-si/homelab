#!/bin/bash
# nas-boot-image.sh -- image, verify and restore the NAS's CORE boot SSD on the Mac.
#
#   sudo scripts/nas-boot-image.sh read    <diskN> <dir>
#   sudo scripts/nas-boot-image.sh verify  <diskN> <dir>
#   sudo scripts/nas-boot-image.sh restore <diskN> <dir>
#
# <diskN> as `diskutil list` shows it. Every command first refuses a disk that
# diskutil reports as internal, or whose size is not 100-130 GB (the 120 GB
# Kingston), then unmounts it. `read` writes core-boot.device.plist,
# core-boot.img.gz and core-boot.img.sha256 (SHA-256 of the raw device).
# `verify` reads the device again and compares. `restore` also refuses a disk
# whose size, media name (and serial, when recorded) differ from the plist,
# asks for the identifier again, writes the image and verifies it.
#
# Exit: 0 done, 1 hash mismatch or a failed read/write, 3 refused, 64 usage.
# Spec: .kiro/specs/nas-on-truenas-scale (design.md, "scripts/nas-boot-image.sh").
set -euo pipefail

MIN_BYTES=100000000000
MAX_BYTES=130000000000
PLIST=core-boot.device.plist
IMAGE=core-boot.img.gz
SUM=core-boot.img.sha256

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) nas-boot-image: $*" >&2; }
usage() {
  echo "usage: $0 read|verify|restore <diskN> <dir>" >&2
  exit 64
}
refuse() {
  log "refused: $*"
  exit 3
}

# plist_get <file> <key>: the value after <key>NAME</key> in a diskutil plist
# (true, false, an integer or a string); empty when the key is absent.
plist_get() {
  awk -v k="<key>$2</key>" '
    found { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
            if ($0 == "<true/>") print "true"; else if ($0 == "<false/>") print "false"
            else { gsub(/<\/?(integer|string)>/, ""); print }
            exit }
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line); if (line == k) found = 1 }
  ' "$1"
}

sha_of_device() {
  dd if="/dev/r$disk" bs=4m 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

[ "$#" -eq 3 ] || usage
cmd=$1 disk=$2 dir=$3
case "$cmd" in read | verify | restore) ;; *) usage ;; esac
case "$disk" in disk[0-9] | disk[0-9][0-9]) ;; *) usage ;; esac

info=$(mktemp)
trap 'rm -f "$info"' EXIT
diskutil info -plist "$disk" > "$info" 2>/dev/null || refuse "diskutil does not know $disk"
internal=$(plist_get "$info" Internal)
size=$(plist_get "$info" TotalSize)
media=$(plist_get "$info" MediaName)
[ "$internal" = false ] || refuse "$disk is not reported as external (Internal: ${internal:-absent})"
case "$size" in '' | *[!0-9]*) refuse "$disk has no TotalSize" ;; esac
if [ "$size" -lt "$MIN_BYTES" ] || [ "$size" -gt "$MAX_BYTES" ]; then
  refuse "$disk is $size bytes, not 100-130 GB"
fi
log "$disk: $media, $size bytes, external"

if [ "$cmd" = restore ]; then
  [ -f "$dir/$PLIST" ] && [ -f "$dir/$IMAGE" ] && [ -f "$dir/$SUM" ] || refuse "$dir lacks $PLIST, $IMAGE or $SUM"
  [ "$size" = "$(plist_get "$dir/$PLIST" TotalSize)" ] || refuse "$disk size differs from $PLIST"
  [ "$media" = "$(plist_get "$dir/$PLIST" MediaName)" ] || refuse "$disk media name differs from $PLIST"
  serial=$(plist_get "$dir/$PLIST" SerialNumber)
  if [ -n "$serial" ] && [ "$serial" != "$(plist_get "$info" SerialNumber)" ]; then
    refuse "$disk serial differs from $PLIST"
  fi
  echo "About to overwrite /dev/r$disk ($media, $size bytes) with $dir/$IMAGE." >&2
  printf 'Type the disk identifier again to continue: ' >&2
  answer=""
  read -r answer || true
  [ "$answer" = "$disk" ] || refuse "identifier not confirmed"
fi
if [ "$cmd" = verify ]; then
  [ -f "$dir/$SUM" ] || refuse "$dir has no $SUM"
fi
if [ "$cmd" = read ]; then
  mkdir -p "$dir"
  [ ! -e "$dir/$IMAGE" ] || refuse "$dir/$IMAGE exists; use another directory"
fi

diskutil unmountDisk "/dev/$disk" > /dev/null || { log "cannot unmount $disk"; exit 1; }

case "$cmd" in
  read)
    /bin/cp -f "$info" "$dir/$PLIST"
    fifo="$dir/.sha.fifo"
    rm -f "$fifo"
    mkfifo "$fifo"
    shasum -a 256 < "$fifo" | awk '{print $1}' > "$dir/$SUM.tmp" &
    sumpid=$!
    log "reading /dev/r$disk to $dir/$IMAGE"
    rc=0
    dd if="/dev/r$disk" bs=4m 2>/dev/null | tee "$fifo" | gzip -1 > "$dir/$IMAGE" || rc=$?
    wait "$sumpid" || rc=1
    rm -f "$fifo"
    if [ "$rc" -ne 0 ] || [ ! -s "$dir/$SUM.tmp" ]; then
      rm -f "$dir/$SUM.tmp" "$dir/$IMAGE"
      log "read failed"
      exit 1
    fi
    mv "$dir/$SUM.tmp" "$dir/$SUM"
    log "sha256 $(cat "$dir/$SUM")"
    ;;
  verify | restore)
    if [ "$cmd" = restore ]; then
      log "writing $dir/$IMAGE to /dev/r$disk"
      # Separate ibs/obs: dd joins the pipe's short reads into whole 4 MiB writes,
      # which a raw device needs (sector-aligned).
      gunzip -c "$dir/$IMAGE" | dd of="/dev/r$disk" ibs=1m obs=4m 2>/dev/null || { log "write failed"; exit 1; }
    fi
    want=$(cat "$dir/$SUM")
    got=$(sha_of_device) || { log "read failed"; exit 1; }
    if [ "$got" != "$want" ]; then
      log "MISMATCH: device $got, image $want"
      exit 1
    fi
    log "verified: sha256 $got"
    ;;
esac
