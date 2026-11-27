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
    "alert/list": [
        {"level": "CRITICAL", "klass": "SMART", "dismissed": False},
        {"level": "CRITICAL", "klass": "SMART", "dismissed": False},
        {"level": "WARNING", "klass": "UnscheduledReboot", "dismissed": True},
    ],
    "iscsi/target": [],
    "iscsi/initiator": [],
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


def test_disks_and_alerts():
    out = lines()
    assert 'truenas_disk_info{disk="ada0",model="Model \\"X\\"",type="SSD"} 1' in out
    assert 'truenas_disk_temperature_celsius{disk="ada0"} 37' in out
    assert not any(l.startswith('truenas_disk_temperature_celsius{disk="nvd0"') for l in out)
    assert not any(l.startswith("truenas_disk_smart") for l in out)
    assert 'truenas_alerts{klass="SMART",level="CRITICAL"} 2' in out
    assert not any("UnscheduledReboot" in l for l in out)


# Recorded from SCALE 25.10.8, trimmed: `system/info` and `reporting/get_data`
# for the `cpu` and `memory` graphs (per-second rows, `cpu` in percent).
SCALE = {
    **DATA,
    "system/info": {"version": "25.10.8", "uptime_seconds": 360337.6, "cores": 12, "physical_cores": 6,
                    "physmem": 33580396544, "loadavg": [0.025390625, 0.564453125, 0.7578125]},
    "reporting/get_data": [
        {"name": "cpu", "identifier": "cpu", "legend": ["time", "cpu", "cpu0", "cpu1"],
         "data": [[1795503462, 0, 0, 0], [1795503463, 25, 1, 0], [1795503464, None, None, None]]},
        {"name": "memory", "identifier": "memory", "legend": ["time", "available"],
         "data": [[1795503463, 4099068000], [1795503464, 4105572000]]},
        {"name": "arcsize", "identifier": "arcsize", "legend": ["time", "size"],
         "data": [[1795503463, 20000000000], [1795503464, 20000000000]]},
    ],
}


def test_cpu_memory_load():
    out = exporter.build(SCALE).render().splitlines()
    assert "truenas_cpu_cores 12" in out
    assert "truenas_load1 0.025390625" in out
    assert "truenas_memory_total_bytes 33580396544" in out
    assert "truenas_cpu_utilisation_ratio 0.25" in out
    assert "truenas_memory_arc_bytes 20000000000" in out
    assert "truenas_memory_used_bytes 9474824544" in out


def test_memory_used_absent_without_arc():
    graphs = [g for g in SCALE["reporting/get_data"] if g["name"] != "arcsize"]
    out = exporter.build({**SCALE, "reporting/get_data": graphs}).render().splitlines()
    assert not any(l.startswith(("truenas_memory_used", "truenas_memory_arc")) for l in out)


def test_cpu_memory_absent_without_answers():
    out = lines()
    for name in ("truenas_cpu_cores", "truenas_load1", "truenas_memory_total_bytes",
                 "truenas_cpu_utilisation_ratio", "truenas_memory_used_bytes"):
        assert not any(l.startswith(name) for l in out)
    graphs = [{"name": "cpu", "legend": ["time", "user"], "data": [[1, 5]]},
              {"name": "memory", "legend": ["time", "available"], "data": [[1, None]]}]
    out = exporter.build({**SCALE, "reporting/get_data": graphs}).render().splitlines()
    assert not any(l.startswith(("truenas_cpu_utilisation", "truenas_memory_used")) for l in out)
    assert "truenas_memory_total_bytes 33580396544" in out


def test_every_metric_has_help_and_type():
    for data in (DATA, SCALE):
        out = exporter.build(data).render().splitlines()
        names = {l.split("{")[0].split(" ")[0] for l in out if not l.startswith("#")}
        for n in names:
            assert f"# TYPE {n} gauge" in out
            assert any(l.startswith(f"# HELP {n} ") for l in out)


def collector(fail):
    """A Collector whose API answers from DATA and raises for paths in `fail`."""
    c = exporter.Collector("https://nas", "/nonexistent", cache=0)
    def call(path, body=None):
        if path in fail:
            raise OSError("HTTP Error 404: Not Found")
        if path.startswith("pool/dataset/id/"):
            name = path.rsplit("/", 1)[1]
            return {"name": name, "pool": name, "used": {"parsed": 1}, "available": {"parsed": 1}}
        return DATA[path]

    c.call = call
    return c


def test_required_endpoint_failure():
    out = collector({"alert/list"}).collect().splitlines()
    assert "truenas_up 0" in out


def test_reporting_optional():
    out = collector({"reporting/get_data"}).collect().splitlines()
    assert "truenas_up 1" in out
    assert not any(l.startswith("truenas_cpu_utilisation_ratio") for l in out)


def test_reporting_query():
    c = collector(set())
    plain, bodies = c.call, []
    def call(path, body=None):
        if path == "reporting/get_data":
            bodies.append(body)
            return SCALE[path]
        return plain(path, body)
    c.call = call
    out = c.collect().splitlines()
    assert [g["name"] for g in bodies[0]["graphs"]] == ["cpu", "memory", "arcsize"]
    assert bodies[0]["query"]["end"] - bodies[0]["query"]["start"] == exporter.REPORT_WINDOW
    assert "truenas_cpu_utilisation_ratio 0.25" in out


def test_temperatures_body_scale_and_core():
    import urllib.error
    for accepts in ({}, {"names": []}):
        c = collector(set())
        plain = c.call
        def call(path, body=None, accepts=accepts, plain=plain):
            if path == "disk/temperatures" and body != accepts:
                raise urllib.error.HTTPError(path, 400, "Bad Request", {}, None)
            return plain(path, body)
        c.call = call
        out = c.collect().splitlines()
        assert "truenas_up 1" in out
        assert 'truenas_disk_temperature_celsius{disk="ada0"} 37' in out


def test_read_api_key(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("driver: freenas-iscsi\nhttpConnection:\n  host: nas\n  apiKey: \"1-abc\"\n")
    assert exporter.read_api_key(str(cfg)) == "1-abc"


NODES = exporter.networks("192.168.1.247/32 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32".split())


def iscsi_gauge(targets, initiators=None, nets=NODES):
    data = {"iscsi/target": targets, "iscsi/initiator": initiators or []}
    return [l for l in exporter.build(data, nets).render().splitlines()
            if l.startswith("truenas_iscsi_targets_unrestricted")]


def test_iscsi_unrestricted_core():
    initiators = [
        {"id": 1, "initiators": [], "auth_network": ["192.168.1.247", "192.168.1.238/32",
                                                     "192.168.1.239/32", "192.168.1.240/32"]},
        {"id": 2, "initiators": [], "auth_network": []},
    ]
    targets = [
        {"id": 1, "name": "a", "groups": [{"portal": 1, "initiator": 1}]},
        {"id": 2, "name": "b", "groups": [{"portal": 1, "initiator": 2}]},
        {"id": 3, "name": "c", "groups": [{"portal": 1, "initiator": None}]},
        {"id": 4, "name": "d", "groups": []},
        {"id": 5, "name": "e", "groups": [{"portal": 1, "initiator": 1}, {"portal": 1, "initiator": 2}]},
    ]
    assert iscsi_gauge(targets, initiators) == ["truenas_iscsi_targets_unrestricted 4"]
    assert iscsi_gauge(targets[:1], initiators) == ["truenas_iscsi_targets_unrestricted 0"]


def test_iscsi_unrestricted_scale():
    targets = [
        {"id": 1, "name": "a", "groups": [{"initiator": None}], "auth_networks": sorted(NODES)},
        {"id": 2, "name": "b", "groups": [{"initiator": 1}], "auth_networks": []},
        {"id": 3, "name": "c", "groups": [], "auth_networks": sorted(NODES)[:3]},
    ]
    assert iscsi_gauge(targets) == ["truenas_iscsi_targets_unrestricted 2"]


def test_iscsi_gauge_absent_without_networks_or_targets():
    assert iscsi_gauge([], nets=frozenset()) == []
    assert not any(l.startswith("truenas_iscsi") for l in lines())


NAS_CA = REPO / "platform" / "truenas-exporter" / "nas-ca.crt"


def test_tls_verifies_against_the_nas_ca():
    import ssl
    ctx = exporter.Collector("https://nas", "/nonexistent", cache=0, cafile=str(NAS_CA)).ctx
    assert ctx.verify_mode == ssl.CERT_REQUIRED and ctx.check_hostname
    subjects = [dict(x[0] for x in c["subject"]) for c in ctx.get_ca_certs()]
    assert {"commonName": "homelab-nas-ca"}.items() <= subjects[0].items()


def test_nas_ca_matches_democratic_csi():
    import yaml
    values = yaml.safe_load((REPO / "infrastructure" / "democratic-csi" / "values-iscsi.yaml").read_text())
    assert NAS_CA.read_text().strip() == values["extraCaCerts"].strip()
