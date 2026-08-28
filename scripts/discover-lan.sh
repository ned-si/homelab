#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Find what is on the LAN, identify it by behaviour, and say whether the cluster's
# static addresses are free.
#
# Built for the plug-one-thing-in-then-scan loop: power on one device, run this,
# confirm it landed where expected, move on.
#
# ---------------------------------------------------------------------------
# IT IDENTIFIES BY OPEN PORTS, NOT BY MAC VENDOR.
#
# Vendor lookup needs an OUI database and is wrong often enough to mislead: the
# device squatting on .247 at the new house has a MAC prefix that resolves to a
# network-equipment vendor, which would have read as "probably one of your nodes".
# It is not one -- it has no SSH and no kubelet. Ports settle it in one round trip:
#
#   6443 + 10250   Kubernetes control plane
#   10250 only     Kubernetes worker
#   3260 + 2049    TrueNAS (iSCSI + NFS)
#   22 only        some other Linux box
#
# ---------------------------------------------------------------------------
# WHY THIS DOES NOT SUGGEST NEW ADDRESSES
#
# The nodes' addresses are static in /etc/netplan/ ON THE NODES, and they are baked
# into kubelet --node-ip, kube-vip's static pods, the apiserver certificate SANs and
# etcd's peer URLs. The NAS address is baked into the iSCSI portal config and every
# NFS PersistentVolume. A device that comes back on a different address does not
# reconfigure itself; it breaks things that then need certificates re-issued.
#
# So the output is DHCP RESERVATIONS that pin each device to the address it already
# has, plus a conflict report. Reservations are belt-and-braces: the static config
# is what actually assigns the address, and the reservation stops the router handing
# it to something else.
#
# Usage:
#   scripts/discover-lan.sh              # scan the /24 the Mac is on
#   scripts/discover-lan.sh 192.168.1    # scan a specific /24
# ---------------------------------------------------------------------------
set -uo pipefail

PREFIX="${1:-}"
if [ -z "$PREFIX" ]; then
  IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  MYIP=$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null)
  [ -n "$MYIP" ] || { echo "cannot determine the local subnet -- pass one, e.g. $0 192.168.1" >&2; exit 1; }
  PREFIX="${MYIP%.*}"
fi

# The addresses the cluster needs. Anything here that is occupied by something
# other than its rightful owner is a blocker.
#   address  expected-owner  what-it-breaks-if-taken
EXPECTED="
228  truenas       iSCSI portal and every NFS PersistentVolume
238  homelab-cp-2  control plane, etcd member
239  homelab-cp-3  control plane, etcd member
240  homelab-w-1   worker
247  homelab-cp-1  control plane, etcd member, normally holds the API VIP
11   api-vip       the address kubectl and every in-cluster client uses
254  ingress-lb    the LoadBalancer the Gateway/ingress claims
"

echo "scanning ${PREFIX}.0/24 ..."
echo

# Populate the ARP cache. nmap is faster and also gives us ports in one pass, but
# a plain ping sweep works everywhere and needs no install.
if command -v nmap >/dev/null 2>&1; then
  nmap -sn -n --host-timeout 3s "${PREFIX}.0/24" >/dev/null 2>&1
else
  for i in $(seq 1 254); do (ping -c1 -W400 "${PREFIX}.$i" >/dev/null 2>&1 &); done
  sleep 5
fi

# --- what is alive --------------------------------------------------------
# Excludes .0 and .255: the network and broadcast addresses appear in the ARP cache
# as ff:ff:ff:ff:ff:ff and are not devices.
alive=$(arp -an 2>/dev/null \
  | awk -v p="$PREFIX" '$2 ~ "\\("p"\\." && $4 != "(incomplete)" {
      ip=$2; mac=$4; gsub(/[()]/,"",ip);
      n=ip; sub(/.*\./,"",n);
      if (n != 0 && n != 255 && mac != "ff:ff:ff:ff:ff:ff") print ip" "mac }' \
  | sort -t. -k4 -n)

if [ -z "$alive" ]; then
  echo "nothing responded. Are you on the right network?" >&2
  exit 1
fi

probe() {   # ip port -> 0 if open
  nc -z -G 2 -w 2 "$1" "$2" >/dev/null 2>&1
}

classify() {
  local ip="$1" k8s=0 kubelet=0 iscsi=0 nfs=0 ssh=0 https=0 out=""
  probe "$ip" 6443  && k8s=1
  probe "$ip" 10250 && kubelet=1
  probe "$ip" 3260  && iscsi=1
  probe "$ip" 2049  && nfs=1
  probe "$ip" 22    && ssh=1
  probe "$ip" 443   && https=1

  if [ $k8s -eq 1 ] && [ $kubelet -eq 1 ]; then out="k8s control plane"
  elif [ $k8s -eq 1 ];                    then out="k8s API endpoint (VIP?)"
  elif [ $kubelet -eq 1 ];                then out="k8s worker"
  elif [ $iscsi -eq 1 ] || [ $nfs -eq 1 ]; then out="storage (TrueNAS)"
  elif [ $ssh -eq 1 ];                     then out="linux host"
  elif [ $https -eq 1 ];                   then out="https device"
  else                                          out="-"
  fi

  local ports=""
  [ $ssh    -eq 1 ] && ports="$ports 22"
  [ $https  -eq 1 ] && ports="$ports 443"
  [ $nfs    -eq 1 ] && ports="$ports 2049"
  [ $iscsi  -eq 1 ] && ports="$ports 3260"
  [ $k8s    -eq 1 ] && ports="$ports 6443"
  [ $kubelet -eq 1 ] && ports="$ports 10250"
  printf '%s|%s' "$out" "${ports# }"
}

printf '%-16s %-19s %-22s %s\n' IP MAC LOOKS-LIKE OPEN-PORTS
printf '%-16s %-19s %-22s %s\n' ---------------- ------------------- ---------------------- ----------
while read -r ip mac; do
  [ -z "${ip:-}" ] && continue
  res=$(classify "$ip")
  printf '%-16s %-19s %-22s %s\n' "$ip" "$mac" "${res%%|*}" "${res#*|}"
done <<EOF
$alive
EOF

# --- the part that matters ------------------------------------------------
echo
echo "=== cluster addresses ==="
blockers=0
while read -r octet owner breaks; do
  [ -z "${octet:-}" ] && continue
  ip="${PREFIX}.${octet}"
  mac=$(arp -n "$ip" 2>/dev/null | grep -o '[0-9a-f:]\{11,17\}' | head -1)

  if [ -z "$mac" ]; then
    printf '  %-16s free            (%s)\n' "$ip" "$owner"
    continue
  fi

  # Occupied. Is it plausibly the right device?
  res=$(classify "$ip"); kind="${res%%|*}"
  case "$owner:$kind" in
    truenas:storage*|homelab-cp-*:"k8s control plane"|homelab-w-*:"k8s worker"|api-vip:*"API endpoint"*)
      printf '  %-16s OK              %s -- %s\n' "$ip" "$owner" "$kind" ;;
    ingress-lb:*)
      printf '  %-16s in use          %s -- %s (expected once the cluster is up)\n' "$ip" "$owner" "$kind" ;;
    *)
      printf '  %-16s CONFLICT        expected %s, found "%s" at %s\n' "$ip" "$owner" "$kind" "$mac"
      printf '  %-16s                 breaks: %s\n' "" "$breaks"
      blockers=$((blockers + 1)) ;;
  esac
done <<EOF
$EXPECTED
EOF

# --- reservations to enter in the router ----------------------------------
echo
echo "=== DHCP reservations to enter in the router ==="
echo "Pin each device to the address it ALREADY has. This does not change any"
echo "address -- it stops the router handing these out to anything else."
echo
printf '  %-16s %-19s %s\n' ADDRESS MAC HOSTNAME
while read -r octet owner _; do
  [ -z "${octet:-}" ] && continue
  case "$owner" in api-vip|ingress-lb) continue ;; esac   # not DHCP clients
  ip="${PREFIX}.${octet}"
  mac=$(arp -n "$ip" 2>/dev/null | grep -o '[0-9a-f:]\{11,17\}' | head -1)

  if [ -z "$mac" ]; then
    printf '  %-16s %-19s %s\n' "$ip" "<not powered on yet>" "$owner"
    continue
  fi

  # ONLY emit a MAC when the device answering is plausibly the right one.
  #
  # Without this check the table happily printed the squatter's MAC next to
  # `homelab-cp-1`, and following that output would have created a reservation
  # pinning a TV box to .247 PERMANENTLY -- turning a lease collision into a
  # configured one. A wrong reservation is worse than no reservation.
  res=$(classify "$ip"); kind="${res%%|*}"
  case "$owner:$kind" in
    truenas:storage*|homelab-cp-*:"k8s control plane"|homelab-w-*:"k8s worker")
      printf '  %-16s %-19s %s\n' "$ip" "$mac" "$owner" ;;
    *)
      printf '  %-16s %-19s %s\n' "$ip" "!! DO NOT RESERVE" \
        "$owner -- something else is here (\"$kind\", $mac). Move it first, then re-run."  ;;
  esac
done <<EOF
$EXPECTED
EOF

cat <<EOF

Also set the DHCP pool to ${PREFIX}.50 - ${PREFIX}.199 so it cannot reach any of
the addresses above, and add a static route for 192.168.2.0/24 via the LAN (the
Syncthing and qBittorrent LoadBalancers live there, announced by ARP from the
worker node).

EOF

if [ "$blockers" -gt 0 ]; then
  echo "$blockers CONFLICT(S). Free those addresses before powering on the affected device." >&2
  exit 1
fi
echo "no conflicts."
