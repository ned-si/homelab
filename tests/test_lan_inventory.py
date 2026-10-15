"""Unit tests for platform/lan-inventory/inventory.py: ARP frames and metrics.
No network, no raw socket."""
from __future__ import annotations

import importlib.util
import socket
import struct
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("inventory", REPO / "platform" / "lan-inventory" / "inventory.py")
inv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inv)

MY_MAC = bytes.fromhex("020000000001")
PEER_MAC = bytes.fromhex("a8bbccddeeff")


def reply(op=2, tpa="192.168.1.240", spa="192.168.1.1", ethertype=0x0806):
    eth = MY_MAC + PEER_MAC + struct.pack("!H", ethertype)
    arp = struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, op, PEER_MAC,
                      socket.inet_aton(spa), MY_MAC, socket.inet_aton(tpa))
    return eth + arp


def test_request_frame():
    f = inv.arp_request(MY_MAC, "192.168.1.240", "192.168.1.1")
    assert len(f) == 42
    assert f[:6] == b"\xff" * 6 and f[6:12] == MY_MAC
    assert struct.unpack("!H", f[12:14])[0] == 0x0806
    assert struct.unpack("!H", f[20:22])[0] == 1  # who-has
    assert socket.inet_ntoa(f[38:42]) == "192.168.1.1"


def test_parse_reply():
    assert inv.parse_reply(reply(), "192.168.1.240") == ("192.168.1.1", "a8:bb:cc:dd:ee:ff")
    assert inv.parse_reply(reply(op=1), "192.168.1.240") is None
    assert inv.parse_reply(reply(tpa="192.168.1.239"), "192.168.1.240") is None
    assert inv.parse_reply(reply(ethertype=0x0800), "192.168.1.240") is None
    assert inv.parse_reply(b"short", "192.168.1.240") is None


def test_random_mac():
    assert inv.locally_administered("02:00:00:00:00:01")
    assert inv.locally_administered("da:a1:19:00:00:01")
    assert not inv.locally_administered("a8:bb:cc:dd:ee:ff")
    assert not inv.locally_administered("00:11:22:33:44:55")


def test_render():
    page = inv.render({"a8:bb:cc:dd:ee:ff": {"192.168.1.1"},
                       "02:00:00:00:00:01": {"192.168.1.240", "192.168.1.11"}}, True, 100.0, 3.5)
    lines = page.splitlines()
    assert 'lan_device_present{ip="192.168.1.1",mac="a8:bb:cc:dd:ee:ff",random_mac="false"} 1' in lines
    assert 'lan_device_present{ip="192.168.1.11",mac="02:00:00:00:00:01",random_mac="true"} 1' in lines
    assert lines.index('lan_device_present{ip="192.168.1.11",mac="02:00:00:00:00:01",random_mac="true"} 1') < \
        lines.index('lan_device_present{ip="192.168.1.240",mac="02:00:00:00:00:01",random_mac="true"} 1')
    assert "lan_inventory_devices 2" in lines
    assert "lan_inventory_scan_success 1" in lines
    assert "lan_inventory_scan_timestamp_seconds 100" in lines


def test_default_interface(tmp_path):
    route = tmp_path / "route"
    route.write_text(
        "Iface\tDestination\tGateway\tFlags\n"
        "cilium_host\t0001A8C0\t00000000\t0001\n"
        "end0\t00000000\t0101A8C0\t0003\n"
    )
    assert inv.default_interface(str(route)) == "end0"
