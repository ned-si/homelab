"""nas-iscsi-guard: keeps every iSCSI target on TrueNAS SCALE limited to the
four nodes. SCALE has no network limit on initiator groups and democratic-csi
never sets a target's `auth_networks`, so this sets it on every target whose
list differs. Design: .kiro/specs/nas-on-truenas-scale/design.md, "iSCSI
limited to the four nodes".

On CORE (`TrueNAS-13*`) initiator group 1 holds the limit: the guard logs
`core, nothing to do` and exits before it reads a target. A target without an
`auth_networks` field (a CORE-shaped answer) stops the run before any write.

Standard library only. JSON log lines on stdout, target names and networks
only.

Environment:
  TRUENAS_URL          base URL, e.g. https://192.168.1.228
  TRUENAS_CONFIG       democratic-csi driver config file; its
                       httpConnection.apiKey is the API key
  TRUENAS_CA           PEM file of the CA that signed the NAS certificate
  ISCSI_AUTH_NETWORKS  the four node addresses, `/32` each, space-separated

Exit: 0 done or nothing to do; 1 bad ISCSI_AUTH_NETWORKS (before any call),
an API error or an unexpected answer.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

TIMEOUT = 10
NODE_NET = ipaddress.ip_network("192.168.1.0/24")
NODES = 4


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


def parse_networks(value: str) -> list[str]:
    """ISCSI_AUTH_NETWORKS as a list: four distinct /32s in 192.168.1.0/24."""
    nets = []
    for item in (value or "").split():
        try:
            net = ipaddress.ip_network(item, strict=True)
        except ValueError as e:
            raise ValueError(f"not a network: {item}") from e
        if net.version != 4 or net.prefixlen != 32 or not net.subnet_of(NODE_NET):
            raise ValueError(f"not a /32 in {NODE_NET}: {item}")
        nets.append(str(net))
    if len(nets) != NODES or len(set(nets)) != NODES:
        raise ValueError(f"want {NODES} distinct addresses, got {len(nets)}")
    return nets


def normalise(nets) -> set[str]:
    """A target's networks as comparable strings; unparsable entries kept raw."""
    out = set()
    for n in nets or []:
        try:
            out.add(str(ipaddress.ip_network(str(n), strict=False)))
        except ValueError:
            out.add(str(n))
    return out


def is_core(info: dict) -> bool:
    return str(info.get("version", "")).startswith("TrueNAS-13")


def plan(targets: list, expected: list[str]) -> list[dict]:
    """Targets whose auth_networks differ from `expected`. Raises on a target
    without the field, so a CORE-shaped answer never leads to a write."""
    want = set(expected)
    changes = []
    for t in targets:
        if "auth_networks" not in t:
            raise ValueError(f"target {t.get('name')!r} has no auth_networks")
        if normalise(t["auth_networks"]) != want:
            changes.append(t)
    return changes


class Api:
    def __init__(self, url: str, config: str, cafile: str | None = None) -> None:
        self.url, self.config = url.rstrip("/"), config
        # Verified against the NAS's own CA (TRUENAS_CA), as in the exporter.
        self.ctx = ssl.create_default_context(cafile=cafile)

    def __call__(self, method: str, path: str, body=None):
        req = urllib.request.Request(
            f"{self.url}/api/v2.0/{path}",
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={"Authorization": f"Bearer {read_api_key(self.config)}",
                     "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=self.ctx) as r:
            return json.load(r)


def run(env: dict, api) -> int:
    try:
        expected = parse_networks(env.get("ISCSI_AUTH_NETWORKS", ""))
    except ValueError as e:
        log("error", "bad ISCSI_AUTH_NETWORKS", detail=str(e))
        return 1
    path = "system/info"
    try:
        info = api("GET", path)
        if is_core(info):
            log("info", "core, nothing to do", version=info.get("version", ""))
            return 0
        path = "iscsi/target"
        targets = api("GET", path)
        changes = plan(targets, expected)
        for t in changes:
            log("info", "limit target", target=t.get("name", ""), old=sorted(normalise(t["auth_networks"])),
                new=expected)
            path = f"iscsi/target/id/{t['id']}"
            api("PUT", path, {"auth_networks": expected})
        log("info", "done", version=info.get("version", ""), targets=len(targets), changed=len(changes))
        return 0
    except urllib.error.HTTPError as e:
        msg = "api key rejected" if e.code == 401 else "api call failed"
        log("error", msg, path=path, status=e.code)
        return 1
    except ValueError as e:
        log("error", "unexpected answer", path=path, detail=str(e)[:200])
        return 1
    except Exception as e:  # noqa: BLE001 -- the Job fails, KubeJobFailed shows it
        log("error", "api call failed", path=path, error=type(e).__name__, detail=str(e)[:200])
        return 1


def main() -> int:
    env = dict(os.environ)
    return run(env, Api(env.get("TRUENAS_URL", ""), env.get("TRUENAS_CONFIG", ""), env.get("TRUENAS_CA") or None))


if __name__ == "__main__":
    sys.exit(main())
