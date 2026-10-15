"""TrueNAS CORE exporter: pools, disks, SMART self-tests, temperatures,
capacity and the NAS's own alerts, read from the REST API v2.0 as Prometheus
metrics.

Read-only: every call is a GET, except `disk/temperatures`, which is a query
the API only exposes as POST. Standard library only. Logs are JSON lines on
stdout.

Environment:
  TRUENAS_URL      base URL, e.g. https://192.168.1.228
  TRUENAS_CONFIG   democratic-csi driver config file; its httpConnection.apiKey
                   is the API key (the file is the Secret democratic-csi reads)
  LISTEN_PORT      default 9814
  CACHE_SECONDS    default 30; scrapes within this window reuse the last result
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TIMEOUT = 5  # per call; 9 calls stay under the 50 s scrape timeout
POOL_ROLES = ("data", "log", "cache", "spare", "special", "dedup")


def log(level: str, msg: str, **fields) -> None:
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": level, "msg": msg}
    rec.update(fields)
    print(json.dumps(rec, sort_keys=True), flush=True)


def read_api_key(path: str) -> str:
    """The apiKey value of the driver config, without a YAML parser."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\s*apiKey:\s*(\S+)\s*$", line)
            if m:
                return m.group(1).strip("'\"")
    raise ValueError(f"no apiKey in {path}")


def esc(value) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class Metrics:
    """Collects samples and renders the Prometheus text format."""

    def __init__(self) -> None:
        self.meta: dict[str, tuple[str, str]] = {}
        self.samples: dict[str, list[tuple[dict, float]]] = {}

    def add(self, name: str, kind: str, help_: str, value, **labels) -> None:
        if value is None:
            return
        self.meta.setdefault(name, (kind, help_))
        self.samples.setdefault(name, []).append((labels, float(value)))

    def render(self) -> str:
        out = []
        for name, (kind, help_) in self.meta.items():
            out.append(f"# HELP {name} {help_}")
            out.append(f"# TYPE {name} {kind}")
            for labels, value in self.samples[name]:
                lbl = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
                num = repr(value) if value != int(value) else str(int(value))
                out.append(f"{name}{{{lbl}}} {num}" if lbl else f"{name} {num}")
        return "\n".join(out) + "\n"


def leaves(vdev: dict):
    """Leaf devices of a vdev tree (a DISK is its own leaf)."""
    children = vdev.get("children") or []
    if not children:
        yield vdev
    for c in children:
        yield from leaves(c)


def parsed(prop) -> float | None:
    if isinstance(prop, dict):
        v = prop.get("parsed")
        return float(v) if isinstance(v, (int, float)) else None
    return None


def build(data: dict) -> Metrics:
    """Turn the API responses into metrics. `data` maps endpoint -> JSON."""
    m = Metrics()

    info = data.get("system/info")
    if info:
        m.add("truenas_info", "gauge", "TrueNAS version.", 1, version=info.get("version", ""))
        m.add("truenas_uptime_seconds", "gauge", "Seconds since boot.", info.get("uptime_seconds"))

    pools = list(data.get("pool") or [])
    boot = data.get("boot/get_state")
    for p in pools + ([boot] if boot else []):
        name = p["name"]
        m.add("truenas_pool_healthy", "gauge", "1 if ZFS reports the pool healthy.",
              1 if p.get("healthy") else 0, pool=name)
        m.add("truenas_pool_status", "gauge", "Pool status (ONLINE, DEGRADED, FAULTED, ...).",
              1, pool=name, status=p.get("status", ""))
        scan = p.get("scan") or {}
        if scan.get("function") == "SCRUB":
            end = (scan.get("end_time") or {}).get("$date")
            m.add("truenas_pool_scrub_end_timestamp_seconds", "gauge",
                  "End of the last finished scrub.", end / 1000 if end else None, pool=name)
            m.add("truenas_pool_scrub_errors", "gauge", "Errors found by the last scrub.",
                  scan.get("errors"), pool=name)
            m.add("truenas_pool_scrub_running", "gauge", "1 while a scrub runs.",
                  1 if scan.get("state") == "SCANNING" else 0, pool=name)

        # `groups` is the boot pool's name for the same tree.
        topology = p.get("topology") or p.get("groups") or {}
        for role in POOL_ROLES:
            for vdev in topology.get(role) or []:
                for leaf in leaves(vdev):
                    disk = leaf.get("disk") or leaf.get("name") or leaf.get("path") or ""
                    lbl = {"pool": name, "role": role, "disk": disk}
                    m.add("truenas_pool_device_online", "gauge",
                          "1 if the pool device is ONLINE.",
                          1 if leaf.get("status") == "ONLINE" else 0, **lbl)
                    stats = leaf.get("stats") or {}
                    for kind in ("read", "write", "checksum"):
                        m.add("truenas_pool_device_errors", "gauge",
                              "ZFS error count of the pool device since the last clear or import.",
                              stats.get(f"{kind}_errors"), type=kind, **lbl)

    used_help = "Bytes used by the dataset and its children."
    avail_help = "Bytes available to the dataset."
    for ds in data.get("datasets") or []:
        m.add("truenas_dataset_used_bytes", "gauge", used_help, parsed(ds.get("used")),
              dataset=ds["name"], pool=ds["pool"])
        m.add("truenas_dataset_available_bytes", "gauge", avail_help, parsed(ds.get("available")),
              dataset=ds["name"], pool=ds["pool"])
    if boot and boot.get("root_dataset"):
        props = boot["root_dataset"].get("properties") or {}
        m.add("truenas_dataset_used_bytes", "gauge", used_help, parsed(props.get("used")),
              dataset=boot["name"], pool=boot["name"])
        m.add("truenas_dataset_available_bytes", "gauge", avail_help, parsed(props.get("available")),
              dataset=boot["name"], pool=boot["name"])

    for d in data.get("disk") or []:
        name = d["name"]
        m.add("truenas_disk_info", "gauge", "Disk model and type.", 1, disk=name,
              model=d.get("model") or "", type=d.get("type") or "")
        m.add("truenas_disk_size_bytes", "gauge", "Disk size.", d.get("size"), disk=name)
        m.add("truenas_disk_smart_enabled", "gauge", "1 if SMART monitoring is on for the disk.",
              1 if d.get("togglesmart") else 0, disk=name)

    for name, temp in sorted((data.get("disk/temperatures") or {}).items()):
        m.add("truenas_disk_temperature_celsius", "gauge", "Disk temperature.", temp, disk=name)

    for r in data.get("smart/test/results") or []:
        name, tests = r["disk"], r.get("tests") or []
        m.add("truenas_disk_smart_tests", "gauge", "SMART self-tests in the disk's log.",
              len(tests), disk=name)
        if tests:
            last = tests[0]  # newest first
            m.add("truenas_disk_smart_last_test_success", "gauge",
                  "1 if the newest SMART self-test passed.",
                  1 if last.get("status") == "SUCCESS" else 0, disk=name,
                  test=last.get("description", ""))

    counts: dict[tuple[str, str], int] = {}
    for a in data.get("alert/list") or []:
        if a.get("dismissed"):
            continue
        key = (a.get("level", ""), a.get("klass", ""))
        counts[key] = counts.get(key, 0) + 1
    for (level, klass), n in sorted(counts.items()):
        m.add("truenas_alerts", "gauge", "Active (not dismissed) TrueNAS alerts.", n,
              level=level, klass=klass)
    return m


class Collector:
    GETS = ("system/info", "pool", "boot/get_state", "disk", "smart/test/results", "alert/list")

    def __init__(self, url: str, config: str, cache: float) -> None:
        self.url, self.config, self.cache = url.rstrip("/"), config, cache
        # The NAS serves its self-signed certificate (the same reason
        # democratic-csi runs with allowInsecure: true).
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE
        self.lock = threading.Lock()
        self.last, self.at, self.ok = "", 0.0, None

    def call(self, path: str, body=None):
        req = urllib.request.Request(
            f"{self.url}/api/v2.0/{path}",
            data=None if body is None else json.dumps(body).encode(),
            method="GET" if body is None else "POST",
            headers={"Authorization": f"Bearer {read_api_key(self.config)}",
                     "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=self.ctx) as r:
            return json.load(r)

    def collect(self) -> str:
        with self.lock:
            if time.time() - self.at < self.cache and self.last:
                return self.last
            start, data, failed = time.time(), {}, []
            for path in self.GETS:
                try:
                    data[path] = self.call(path)
                except Exception as e:  # noqa: BLE001 -- reported as a metric
                    failed.append(path)
                    log("error", "api call failed", path=path, error=type(e).__name__, detail=str(e)[:200])
            try:
                data["disk/temperatures"] = self.call("disk/temperatures", {"names": []})
            except Exception as e:  # noqa: BLE001
                failed.append("disk/temperatures")
                log("error", "api call failed", path="disk/temperatures", error=type(e).__name__)
            data["datasets"] = []
            for p in data.get("pool") or []:
                try:
                    root = self.call(f"pool/dataset/id/{p['name']}")
                    data["datasets"].append(root)
                    data["datasets"].extend(root.get("children") or [])
                except Exception as e:  # noqa: BLE001
                    failed.append("pool/dataset")
                    log("error", "api call failed", path="pool/dataset", error=type(e).__name__)
            m = build(data)
            ok = not failed
            m.add("truenas_up", "gauge", "1 if every API call of the last scrape succeeded.", 1 if ok else 0)
            m.add("truenas_scrape_duration_seconds", "gauge", "Time the API calls took.",
                  round(time.time() - start, 3))
            if ok != self.ok:
                log("info" if ok else "warning", "scrape state", ok=ok, failed=failed)
                self.ok = ok
            self.last, self.at = m.render(), time.time()
            return self.last


def main() -> None:
    collector = Collector(os.environ["TRUENAS_URL"], os.environ["TRUENAS_CONFIG"],
                          float(os.environ.get("CACHE_SECONDS", "30")))
    port = int(os.environ.get("LISTEN_PORT", "9814"))

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path == "/metrics":
                body, ctype = collector.collect().encode(), "text/plain; version=0.0.4"
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

    log("info", "listening", port=port, url=collector.url)
    ThreadingHTTPServer(("", port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
