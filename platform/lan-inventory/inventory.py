"""LAN inventory: an ARP scan of the node's /24 every SCAN_INTERVAL seconds,
served as Prometheus metrics.

Each scan sends one ARP request per address, twice, and records every reply
to this host: an IP and the MAC that answered. Needs host networking and
CAP_NET_RAW (an AF_PACKET socket). Standard library only; logs are JSON lines
on stdout.

Environment:
  INTERFACE       default: the interface of the IPv4 default route
  SCAN_INTERVAL   seconds between scans, default 300
  LISTEN_PORT     default 9815
"""
from __future__ import annotations

import ipaddress
import json
import os
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ETH_P_ARP = 0x0806
BROADCAST = b"\xff" * 6
LISTEN_SECONDS = 3.0


def log(level: str, msg: str, **fields) -> None:
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": level, "msg": msg}
    rec.update(fields)
    print(json.dumps(rec, sort_keys=True), flush=True)


def default_interface(route_file: str = "/proc/net/route") -> str:
    with open(route_file, encoding="ascii") as f:
        for line in f.readlines()[1:]:
            fields = line.split()
            if len(fields) > 2 and fields[1] == "00000000":
                return fields[0]
    raise RuntimeError("no IPv4 default route")


def local_ip_and_net(iface: str) -> tuple[str, ipaddress.IPv4Network]:
    """The primary IPv4 address of iface and its /24 (the LAN is one /24)."""
    import fcntl  # Linux only

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        req = struct.pack("256s", iface.encode()[:15])
        addr = socket.inet_ntoa(fcntl.ioctl(s.fileno(), 0x8915, req)[20:24])  # SIOCGIFADDR
    finally:
        s.close()
    return addr, ipaddress.ip_network(f"{addr}/24", strict=False)


def mac_str(b: bytes) -> str:
    return ":".join(f"{x:02x}" for x in b)


def arp_request(src_mac: bytes, src_ip: str, dst_ip: str) -> bytes:
    eth = BROADCAST + src_mac + struct.pack("!H", ETH_P_ARP)
    arp = struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 1, src_mac,
                      socket.inet_aton(src_ip), b"\x00" * 6, socket.inet_aton(dst_ip))
    return eth + arp


def parse_reply(frame: bytes, my_ip: str) -> tuple[str, str] | None:
    """(ip, mac) of an ARP reply addressed to my_ip, else None."""
    if len(frame) < 42 or struct.unpack("!H", frame[12:14])[0] != ETH_P_ARP:
        return None
    htype, ptype, hlen, plen, op, sha, spa, _tha, tpa = struct.unpack("!HHBBH6s4s6s4s", frame[14:42])
    if (htype, ptype, hlen, plen, op) != (1, 0x0800, 6, 4, 2):
        return None
    if socket.inet_ntoa(tpa) != my_ip:
        return None
    return socket.inet_ntoa(spa), mac_str(sha)


def locally_administered(mac: str) -> bool:
    """Randomised (private) MACs, as phones use, set bit 1 of the first octet."""
    return bool(int(mac[:2], 16) & 0x02)


def scan(iface: str) -> dict[str, set[str]]:
    """MAC -> set of IPs that answered."""
    my_ip, net = local_ip_and_net(iface)
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ARP))
    try:
        s.bind((iface, ETH_P_ARP))
        my_mac = s.getsockname()[4]
        found: dict[str, set[str]] = {mac_str(my_mac): {my_ip}}
        targets = [str(h) for h in net.hosts() if str(h) != my_ip]
        for _ in range(2):
            for ip in targets:
                s.send(arp_request(my_mac, my_ip, ip))
                time.sleep(0.002)
        deadline = time.time() + LISTEN_SECONDS
        s.settimeout(0.2)
        while time.time() < deadline:
            try:
                frame = s.recv(65535)
            except socket.timeout:
                continue
            hit = parse_reply(frame, my_ip)
            if hit and ipaddress.ip_address(hit[0]) in net:
                found.setdefault(hit[1], set()).add(hit[0])
        return found
    finally:
        s.close()


def render(found: dict[str, set[str]], ok: bool, at: float, duration: float) -> str:
    out = [
        "# HELP lan_device_present 1 for each MAC and IP that answered the last ARP scan.",
        "# TYPE lan_device_present gauge",
    ]
    for mac in sorted(found):
        la = "true" if locally_administered(mac) else "false"
        for ip in sorted(found[mac], key=ipaddress.ip_address):
            out.append(f'lan_device_present{{ip="{ip}",mac="{mac}",random_mac="{la}"}} 1')
    out += [
        "# HELP lan_inventory_devices MACs that answered the last ARP scan.",
        "# TYPE lan_inventory_devices gauge",
        f"lan_inventory_devices {len(found)}",
        "# HELP lan_inventory_scan_success 1 if the last scan completed.",
        "# TYPE lan_inventory_scan_success gauge",
        f"lan_inventory_scan_success {1 if ok else 0}",
        "# HELP lan_inventory_scan_timestamp_seconds When the last scan finished.",
        "# TYPE lan_inventory_scan_timestamp_seconds gauge",
        f"lan_inventory_scan_timestamp_seconds {int(at)}",
        "# HELP lan_inventory_scan_duration_seconds How long the last scan took.",
        "# TYPE lan_inventory_scan_duration_seconds gauge",
        f"lan_inventory_scan_duration_seconds {duration:.3f}",
    ]
    return "\n".join(out) + "\n"


class Inventory:
    def __init__(self, iface: str, interval: float) -> None:
        self.iface, self.interval = iface, interval
        self.lock = threading.Lock()
        self.page = ""
        self.known: set[str] = set()

    def run_once(self) -> None:
        start = time.time()
        try:
            found, ok = scan(self.iface), True
        except OSError as e:
            found, ok = {}, False
            log("error", "scan failed", error=type(e).__name__, detail=str(e)[:200])
        page = render(found, ok, time.time(), time.time() - start)
        new = sorted(set(found) - self.known) if self.known else []
        for mac in new:
            log("info", "mac first seen since start", mac=mac, ips=sorted(found[mac]))
        self.known |= set(found)
        log("info", "scan", ok=ok, devices=len(found), seconds=round(time.time() - start, 2))
        with self.lock:
            self.page = page

    def loop(self) -> None:
        while True:
            time.sleep(self.interval)
            self.run_once()


def main() -> None:
    iface = os.environ.get("INTERFACE") or default_interface()
    inv = Inventory(iface, float(os.environ.get("SCAN_INTERVAL", "300")))
    port = int(os.environ.get("LISTEN_PORT", "9815"))
    inv.run_once()
    threading.Thread(target=inv.loop, daemon=True).start()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path == "/metrics":
                with inv.lock:
                    body = inv.page.encode()
                ctype = "text/plain; version=0.0.4"
            elif self.path == "/healthz":
                body, ctype = b"ok\n", "text/plain"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    log("info", "listening", port=port, interface=iface)
    ThreadingHTTPServer(("", port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
