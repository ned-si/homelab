"""Unit tests for platform/truenas-exporter/iscsi_guard.py: the env check, the
CORE no-op and which targets get a PUT, against a fake API. No network."""
from __future__ import annotations

import importlib.util
import io
import json
import urllib.error
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("iscsi_guard", REPO / "platform" / "truenas-exporter" / "iscsi_guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

NODES = "192.168.1.247/32 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32"
EXPECTED = NODES.split()


class FakeApi:
    def __init__(self, version, targets=None, fail=None):
        self.version, self.targets, self.fail = version, targets or [], fail
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if self.fail and path.startswith(self.fail[0]):
            raise self.fail[1]
        if path == "system/info":
            return {"version": self.version}
        if path == "iscsi/target":
            return self.targets
        if method == "PUT":
            return {}
        raise AssertionError(f"unexpected call {method} {path}")

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]


def logs(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def http_error(code):
    return urllib.error.HTTPError("https://nas/api", code, "x", {}, io.BytesIO(b""))


@pytest.mark.parametrize("value", [
    "",
    "192.168.1.247/32 192.168.1.238/32 192.168.1.239/32",
    NODES + " 192.168.1.241/32",
    "192.168.1.247/32 192.168.1.247/32 192.168.1.239/32 192.168.1.240/32",
    "192.168.1.0/24 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32",
    "10.0.0.1/32 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32",
    "192.168.1.247 192.168.1.238/32 192.168.1.239/32 192.168.1.240/31",
    "0.0.0.0/0 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32",
    "nas 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32",
])
def test_bad_env_exits_before_any_call(value, capsys):
    api = FakeApi("25.10.1")
    assert guard.run({"ISCSI_AUTH_NETWORKS": value}, api) == 1
    assert api.calls == []
    assert logs(capsys)[-1]["level"] == "error"


def test_core_is_a_noop(capsys):
    targets = [{"id": 1, "name": "pvc-a", "groups": [{"initiator": 1}]}]
    api = FakeApi("TrueNAS-13.0-U6.7", targets)
    assert guard.run({"ISCSI_AUTH_NETWORKS": NODES}, api) == 0
    assert api.calls == [("GET", "system/info", None)]
    assert logs(capsys)[-1]["msg"] == "core, nothing to do"


def test_scale_puts_only_differing_targets(capsys):
    targets = [
        {"id": 1, "name": "ok", "auth_networks": list(reversed(EXPECTED))},
        {"id": 2, "name": "open", "auth_networks": []},
        {"id": 3, "name": "wrong", "auth_networks": ["192.168.1.0/24"]},
        {"id": 4, "name": "bare", "auth_networks": ["192.168.1.247", "192.168.1.238",
                                                    "192.168.1.239", "192.168.1.240"]},
        {"id": 5, "name": "extra", "auth_networks": EXPECTED + ["192.168.1.50/32"]},
    ]
    api = FakeApi("25.10.1", targets)
    assert guard.run({"ISCSI_AUTH_NETWORKS": NODES}, api) == 0
    assert api.writes() == [
        ("PUT", "iscsi/target/id/2", {"auth_networks": EXPECTED}),
        ("PUT", "iscsi/target/id/3", {"auth_networks": EXPECTED}),
        ("PUT", "iscsi/target/id/5", {"auth_networks": EXPECTED}),
    ]
    out = logs(capsys)
    limited = [r for r in out if r["msg"] == "limit target"]
    assert [r["target"] for r in limited] == ["open", "wrong", "extra"]
    assert limited[1]["old"] == ["192.168.1.0/24"]
    assert out[-1]["msg"] == "done" and out[-1]["changed"] == 3


def test_core_shaped_target_on_other_version_writes_nothing(capsys):
    targets = [{"id": 1, "name": "ok", "auth_networks": []}, {"id": 2, "name": "core", "groups": []}]
    api = FakeApi("25.10.1", targets)
    assert guard.run({"ISCSI_AUTH_NETWORKS": NODES}, api) == 1
    assert api.writes() == []
    assert logs(capsys)[-1]["msg"] == "unexpected answer"


@pytest.mark.parametrize("fail, msg", [
    (("system/info", http_error(401)), "api key rejected"),
    (("iscsi/target/id", http_error(500)), "api call failed"),
    (("iscsi/target", TimeoutError("timed out")), "api call failed"),
])
def test_api_errors_exit_1(fail, msg, capsys):
    api = FakeApi("25.10.1", [{"id": 2, "name": "open", "auth_networks": []}], fail=fail)
    assert guard.run({"ISCSI_AUTH_NETWORKS": NODES}, api) == 1
    rec = logs(capsys)[-1]
    assert rec["level"] == "error" and rec["msg"] == msg


def test_read_api_key(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("driver: freenas-iscsi\nhttpConnection:\n  apiKey: \"1-abc\"\n")
    assert guard.read_api_key(str(cfg)) == "1-abc"
