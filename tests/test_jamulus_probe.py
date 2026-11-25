"""platform/jamulus-probe/exporter.py: the protocol encoding, the parsing of
its inputs, and pings against in-process UDP servers."""
from __future__ import annotations

import importlib.util
import json
import socket
import struct
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "platform" / "jamulus-probe" / "exporter.py"
# design.md#jamulus-ping: CLM_PING_MS with timestamp 0.
PING_1001 = "0000e903000400000000006f60"
PING_1002 = "0000ea0300050000000000000714"


@pytest.fixture
def mod():
    spec = importlib.util.spec_from_file_location("jamulus_probe", SRC)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.TIMEOUT = 0.2
    return m


def udp_server(answer):
    """A UDP socket on 127.0.0.1 answering each datagram with answer(data), or nothing for None."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.1)
    stop = threading.Event()

    def run():
        while not stop.is_set():
            try:
                data, peer = sock.recvfrom(64)
            except socket.timeout:
                continue
            reply = answer(data)
            if reply is not None:
                sock.sendto(reply, peer)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return sock.getsockname()[1], lambda: (stop.set(), t.join(), sock.close())


@pytest.fixture
def servers(mod):
    def jamulus(data):
        # The server echoes the timestamp and reports 2 connected clients.
        assert struct.unpack_from("<H", data, 2)[0] == 1002
        return mod.frame(1002, data[7:11] + bytes([2]))

    started = {name: udp_server(fn) for name, fn in
               (("good", jamulus), ("silent", lambda d: None), ("garbage", lambda d: b"garbage"))}
    yield {name: port for name, (port, _) in started.items()}
    for _, close in started.values():
        close()


def test_crc_check_value(mod):
    assert mod.crc16(b"123456789") == 0xD64E


def test_encodings(mod):
    assert mod.frame(mod.PING_MS, struct.pack("<I", 0)).hex() == PING_1001
    assert mod.ping_request(0).hex() == PING_1002


def reply(mod, *, tag=0, msg_id=1002, length=5, clients=3, crc=None):
    head = struct.pack("<HHBH", tag, msg_id, 0, length) + struct.pack("<IB", 0, clients)
    return head + struct.pack("<H", mod.crc16(head) if crc is None else crc)


def test_valid_reply(mod):
    assert mod.parse_reply(reply(mod, clients=3)) == 3


@pytest.mark.parametrize("kw, defect", [
    ({"crc": 0}, "CRC"),
    ({"msg_id": 1001}, "message 1001"),
    ({"length": 4}, "length 4"),
    ({"tag": 1}, "tag 1"),
])
def test_invalid_reply(mod, kw, defect):
    with pytest.raises(ValueError, match=defect):
        mod.parse_reply(reply(mod, **kw))


def test_short_reply(mod):
    with pytest.raises(ValueError, match="13 bytes"):
        mod.parse_reply(bytes.fromhex(PING_1001))


def test_targets(mod):
    assert mod.parse_targets("192.168.1.202:41124") == [("192.168.1.202", 41124)]
    assert mod.parse_targets("a.example:1, b:65535") == [("a.example", 1), ("b", 65535)]


@pytest.mark.parametrize("value", [
    "", "host", "host:", "host:0", "host:65536", "host:x", "ho_st:1", "ho st:1",
    "a" * 254 + ":1", ",".join(["h:1"] * 9),
])
def test_bad_targets(mod, value):
    with pytest.raises(ValueError):
        mod.parse_targets(value)


def test_port(mod):
    assert mod.parse_port("9174") == 9174
    for bad in ("80", "65536", "x", ""):
        with pytest.raises(ValueError):
            mod.parse_port(bad)


def test_metrics_up_and_down(mod, monkeypatch):
    answers = {"up": (True, 0.002, 1, ""), "down": (False, 0.0, 0, "timeout")}
    monkeypatch.setattr(mod, "ping", lambda host, port: answers[host])
    text = mod.metrics([("up", 1), ("down", 2)])
    lines = [line for line in text.splitlines() if not line.startswith("#")]
    assert lines == [
        'jamulus_up{target="up:1"} 1',
        'jamulus_up{target="down:2"} 0',
        'jamulus_ping_seconds{target="up:1"} 0.002',
        'jamulus_clients{target="up:1"} 1',
    ]
    assert "# TYPE jamulus_clients gauge" in text


def test_transitions_log_once(mod, monkeypatch, capsys):
    state = {"ok": False}
    monkeypatch.setattr(mod, "ping", lambda h, p: (state["ok"], 0.001, 0, "timeout"))
    mod.metrics([("h", 1)])
    mod.metrics([("h", 1)])
    state["ok"] = True
    mod.metrics([("h", 1)])
    mod.metrics([("h", 1)])
    logs = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [(r["level"], r["msg"]) for r in logs] == [("warning", "target down"), ("info", "target up")]
    assert logs[0]["reason"] == "timeout"


def test_http_routing(mod, monkeypatch):
    monkeypatch.setattr(mod, "ping", lambda h, p: (True, 0.001, 0, ""))
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), mod.handler([("h", 1)]))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{httpd.server_address[1]}"
    try:
        with urllib.request.urlopen(f"{base}/metrics", timeout=5) as r:
            assert r.status == 200 and b'jamulus_up{target="h:1"} 1' in r.read()
        with urllib.request.urlopen(f"{base}/healthz", timeout=5) as r:
            assert r.status == 200
        for req, code in ((f"{base}/other", 404),
                          (urllib.request.Request(f"{base}/metrics", data=b"", method="POST"), 405)):
            with pytest.raises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(req, timeout=5)
            assert e.value.code == code
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_once(mod, servers, capsys):
    assert mod.once([f"127.0.0.1:{servers['good']}"]) == 0
    assert capsys.readouterr().out.startswith("up clients=2 rtt=")
    assert mod.once([f"127.0.0.1:{servers['silent']}"]) == 1
    assert capsys.readouterr().out == "down timeout\n"
    assert mod.once([f"127.0.0.1:{servers['garbage']}"]) == 1
    assert capsys.readouterr().out == "down reply of 7 bytes, want 14\n"
    assert mod.once(["nope"]) == 2


def test_scrape(mod, servers):
    targets = [("127.0.0.1", servers[name]) for name in ("good", "silent", "garbage")]
    values = {line.rsplit(" ", 1)[0]: line.rsplit(" ", 1)[1]
              for line in mod.metrics(targets).splitlines() if line.startswith("jamulus_up")}
    assert list(values.values()) == ["1", "0", "0"]


def test_bad_configuration_exits_1(mod, monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["exporter.py"])
    monkeypatch.setenv("TARGETS", "nope")
    assert mod.main() == 1
    assert json.loads(capsys.readouterr().out)["level"] == "error"
