"""Unit tests for platform/truenas-exporter/exporter.py: API responses in,
Prometheus text out. No network."""
from __future__ import annotations

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("exporter", REPO / "platform" / "truenas-exporter" / "exporter.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def disk(name, status="ONLINE", read=0, write=0, cksum=0):
    return {"type": "DISK", "disk": name, "status": status, "children": [],
            "stats": {"read_errors": read, "write_errors": write, "checksum_errors": cksum}}


DATA = {
    "system/info": {"version": "TrueNAS-13.0-U6.7", "uptime_seconds": 100.5},
    "pool": [{
        "name": "tank", "status": "DEGRADED", "healthy": False,
        "scan": {"function": "SCRUB", "state": "FINISHED", "end_time": {"$date": 1700000000000}, "errors": 0},
        "topology": {
            "data": [{"type": "RAIDZ1", "status": "DEGRADED", "stats": {},
                      "children": [disk("ada0"), disk("ada1", status="FAULTED", cksum=3)]}],
            "cache": [disk("nvd0")], "log": [], "spare": [], "special": [], "dedup": [],
        },
    }],
    "boot/get_state": {
        "name": "boot-pool", "status": "ONLINE", "healthy": True, "scan": {},
        "groups": {"data": [disk("ada9")]},
        "root_dataset": {"properties": {"used": {"parsed": 10}, "available": {"parsed": 90}}},
    },
    "datasets": [
        {"name": "tank", "pool": "tank", "used": {"parsed": 600}, "available": {"parsed": 400}},
        {"name": "tank/k8s", "pool": "tank", "used": {"parsed": 500}, "available": {"parsed": 400}},
    ],
    "disk": [{"name": "ada0", "model": "Model \"X\"", "type": "SSD", "size": 1000, "togglesmart": True}],
    "disk/temperatures": {"ada0": 37, "nvd0": None},
    "smart/test/results": [
        {"disk": "ada0", "tests": [{"description": "Short offline", "status": "FAILED"},
                                   {"description": "Short offline", "status": "SUCCESS"}]},
        {"disk": "ada1", "tests": []},
    ],
    "alert/list": [
        {"level": "CRITICAL", "klass": "SMART", "dismissed": False},
        {"level": "CRITICAL", "klass": "SMART", "dismissed": False},
        {"level": "WARNING", "klass": "UnscheduledReboot", "dismissed": True},
    ],
}


def lines():
    return exporter.build(DATA).render().splitlines()


def test_pool_health_and_devices():
    out = lines()
    assert 'truenas_pool_healthy{pool="tank"} 0' in out
    assert 'truenas_pool_healthy{pool="boot-pool"} 1' in out
    assert 'truenas_pool_status{pool="tank",status="DEGRADED"} 1' in out
    assert 'truenas_pool_device_online{disk="ada1",pool="tank",role="data"} 0' in out
    assert 'truenas_pool_device_online{disk="nvd0",pool="tank",role="cache"} 1' in out
    assert 'truenas_pool_device_online{disk="ada9",pool="boot-pool",role="data"} 1' in out
    assert 'truenas_pool_device_errors{disk="ada1",pool="tank",role="data",type="checksum"} 3' in out
    assert 'truenas_pool_scrub_end_timestamp_seconds{pool="tank"} 1700000000' in out


def test_capacity():
    out = lines()
    assert 'truenas_dataset_used_bytes{dataset="tank",pool="tank"} 600' in out
    assert 'truenas_dataset_available_bytes{dataset="tank/k8s",pool="tank"} 400' in out
    assert 'truenas_dataset_available_bytes{dataset="boot-pool",pool="boot-pool"} 90' in out


def test_disks_smart_and_alerts():
    out = lines()
    assert 'truenas_disk_info{disk="ada0",model="Model \\"X\\"",type="SSD"} 1' in out
    assert 'truenas_disk_temperature_celsius{disk="ada0"} 37' in out
    assert not any(l.startswith('truenas_disk_temperature_celsius{disk="nvd0"') for l in out)
    assert 'truenas_disk_smart_last_test_success{disk="ada0",test="Short offline"} 0' in out
    assert 'truenas_disk_smart_tests{disk="ada1"} 0' in out
    assert not any(l.startswith('truenas_disk_smart_last_test_success{disk="ada1"') for l in out)
    assert 'truenas_alerts{klass="SMART",level="CRITICAL"} 2' in out
    assert not any("UnscheduledReboot" in l for l in out)


def test_every_metric_has_help_and_type():
    out = lines()
    names = {l.split("{")[0].split(" ")[0] for l in out if not l.startswith("#")}
    for n in names:
        assert f"# TYPE {n} gauge" in out
        assert any(l.startswith(f"# HELP {n} ") for l in out)


def test_read_api_key(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("driver: freenas-iscsi\nhttpConnection:\n  host: nas\n  apiKey: \"1-abc\"\n")
    assert exporter.read_api_key(str(cfg)) == "1-abc"
