#!/usr/bin/env python3
"""Read-only checks of the NAS (TrueNAS CORE or SCALE) against a recorded baseline.

    scripts/nas-check.py --record <dir> [--features-file <file>]
    scripts/nas-check.py --expect core|scale --baseline <dir> [--quiesced]
        [--snapshot <name>] [--features-file <file>] [--only <check>,...]

`--record` writes one JSON file per REST v2.0 endpoint (secrets redacted),
`features.txt` (`zpool get all homelab` over SSH), `fingerprint.txt` (the TLS
certificate's SHA-256), `known_hosts` and `meta.json`. `--expect` prints one
`PASS <check>` or `FAIL <check>: <reason>` line per check, CORE and SCALE
field names normalised. `--features-file` reads the feature flags from a file
(`zpool get -H -o property,value all homelab`) instead of SSH.

The API key and the SSH user and key come from the democratic-csi driver
Secret (kubectl, operator kubeconfig), the CA from values-iscsi.yaml; they
stay in memory. TLS verifies the chain and the IP SAN against that CA.

Exit: 0 all PASS, 1 a FAIL, 2 NAS, API, TLS, SSH or Secret unreachable, 64 usage.
Standard library only. Spec: .kiro/specs/nas-on-truenas-scale (design.md).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import signal
import ssl
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VALUES = REPO / "infrastructure" / "democratic-csi" / "values-iscsi.yaml"
NAS = "192.168.1.228"
POOL = "homelab"
NODES = ("192.168.1.247", "192.168.1.238", "192.168.1.239", "192.168.1.240")
NODE_NETS = sorted(f"{n}/32" for n in NODES)
SERVICES = ("cifs", "nfs", "iscsitarget", "ssh")
SMB_SHARE = "bits_and_pieces"
SMB_HOSTS = ["192.168.1.0/24"]
TIMEOUT = 10
REDACT = ("privatekey", "private_key", "hash", "password", "secret")
# Names that resolve to the same id on FreeBSD and Linux (`wheel` is gid 0 on CORE only).
USER_IDS = {"root": 0}
GROUP_IDS = {"root": 0, "wheel": 0}

RECORD_ENDPOINTS = (
    "system/info", "pool", "boot/get_state", "service", "sharing/nfs", "sharing/smb",
    "iscsi/target", "iscsi/initiator", "iscsi/portal", "iscsi/global", "iscsi/global/sessions",
    "interface", "network/configuration", "system/general", "certificate", "user",
    "tunable", "pool/dataset", "nfs", "cronjob", "initshutdownscript", "plugin", "jail",
)
OPTIONAL = {"plugin", "jail"}  # CORE only; a 404 is recorded as absent
CHECKS = ("version", "pools", "features", "services", "nfs", "smb", "iscsi", "tls", "ui")
NEEDS = {
    "version": ("system/info",),
    "pools": ("pool", "boot/get_state"),
    "services": ("service", "nfs"),
    "nfs": ("sharing/nfs",),
    "smb": ("sharing/smb",),
    "iscsi": ("iscsi/target", "iscsi/initiator", "iscsi/portal", "iscsi/global"),
    "ui": ("system/general",),
    "quiesced": ("iscsi/global/sessions",),
    "snapshot": ("pool/dataset",),
}
BASELINE_FILES = {
    "features": ("features", "features.txt"),
    "nfs": ("sharing/nfs", "sharing_nfs.json"),
    "smb": ("sharing/smb", "sharing_smb.json"),
    "iscsi": ("iscsi/target", "iscsi_target.json"),
    "tls": ("fingerprint", "fingerprint.txt"),
}
ABSENT = {"absent": True}


class Usage(Exception):
    """Exit 64."""


class Unreachable(Exception):
    """Exit 2: the NAS, the API, TLS, SSH or the Secret failed."""


class Missing(Exception):
    """A field absent from both the CORE and the SCALE place: a FAIL naming it."""


def fname(endpoint: str) -> str:
    return endpoint.replace("/", "_") + ".json"


def redact(obj):
    if isinstance(obj, dict):
        return {k: "<redacted>" if k.lower().endswith(REDACT) else redact(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


def parse_driver_config(text: str) -> tuple[str, str, str]:
    """apiKey, sshConnection.username and the privateKey block, by line rules."""
    api_key = user = key = None
    section = None
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        top = re.match(r"^([A-Za-z_][^:\s]*):", line)
        if top:
            section = top.group(1)
        m = re.match(r"^\s+apiKey:\s*(\S+)\s*$", line)
        if m and section == "httpConnection":
            api_key = m.group(1).strip("'\"")
        m = re.match(r"^\s+username:\s*(\S+)\s*$", line)
        if m and section == "sshConnection":
            user = m.group(1).strip("'\"")
        m = re.match(r"^(\s+)privateKey:\s*\|[-+]?\s*$", line)
        if m and section == "sshConnection":
            indent, block = len(m.group(1)), []
            while i + 1 < len(lines) and (not lines[i + 1].strip()
                                          or len(lines[i + 1]) - len(lines[i + 1].lstrip()) > indent):
                i += 1
                block.append(lines[i])
            while block and not block[-1].strip():
                block.pop()
            pad = min(len(b) - len(b.lstrip()) for b in block if b.strip()) if block else 0
            key = "\n".join(b[pad:] for b in block) + "\n"
        i += 1
    if not (api_key and user and key and "PRIVATE KEY" in key):
        raise ValueError("incomplete driver config")
    return api_key, user, key


def parse_ca(text: str) -> str:
    """The extraCaCerts block of values-iscsi.yaml."""
    lines, out, inside = text.splitlines(), [], False
    for line in lines:
        if re.match(r"^extraCaCerts:\s*\|[-+]?\s*$", line):
            inside = True
            continue
        if inside:
            if line.strip() and not line.startswith(" "):
                break
            out.append(line.strip())
    ca = "\n".join(x for x in out if x) + "\n"
    if "BEGIN CERTIFICATE" not in ca:
        raise ValueError("no CA")
    return ca


def read_driver_config() -> str:
    cmd = ["kubectl", "--request-timeout=10s", "-n", "democratic-csi", "get", "secret",
           "iscsi-democratic-csi-driver-config", "-o", r"jsonpath={.data.driver-config-file\.yaml}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode or not r.stdout:
            raise ValueError
        return base64.b64decode(r.stdout).decode()
    except Exception:  # noqa: BLE001 -- one message, nothing else printed
        raise Unreachable("cannot read the driver config") from None


class Nas:
    """The live NAS: REST v2.0 over verified TLS, plain HTTP for the redirect, SSH for zpool."""

    def __init__(self, api_key: str, ca: str, ssh_user: str, ssh_key: str, host: str = NAS) -> None:
        self.host, self.api_key, self.ssh_user, self.ssh_key = host, api_key, ssh_user, ssh_key
        self.ctx = ssl.create_default_context(cadata=ca)
        self._fingerprint = None

    def _https(self):
        return http.client.HTTPSConnection(self.host, 443, timeout=TIMEOUT, context=self.ctx)

    def _request(self, conn, path: str, label: str, headers: dict):
        try:
            conn.request("GET", path, headers=headers)
            if self._fingerprint is None and getattr(conn, "sock", None) is not None \
                    and hasattr(conn.sock, "getpeercert"):
                self._fingerprint = hashlib.sha256(conn.sock.getpeercert(True)).hexdigest()
            resp = conn.getresponse()
            return resp, resp.read()
        except ssl.SSLCertVerificationError as e:
            raise Unreachable(f"{label}: TLS error ({e.verify_message})") from None
        except (OSError, http.client.HTTPException) as e:
            raise Unreachable(f"{label}: {type(e).__name__}") from None
        finally:
            conn.close()

    def get(self, endpoint: str):
        resp, body = self._request(self._https(), f"/api/v2.0/{endpoint}", endpoint,
                                   {"Authorization": f"Bearer {self.api_key}"})
        if resp.status == 404 and endpoint.split("?")[0] in OPTIONAL:
            return ABSENT
        if resp.status == 401:
            raise Unreachable(f"{endpoint}: HTTP 401, api key rejected")
        if resp.status != 200:
            raise Unreachable(f"{endpoint}: HTTP {resp.status}")
        try:
            return json.loads(body)
        except ValueError:
            raise Unreachable(f"{endpoint}: not JSON") from None

    def fingerprint(self) -> str:
        if self._fingerprint is None:
            self.get("system/info")
        return self._fingerprint

    def http_root(self) -> tuple[int, str]:
        resp, _ = self._request(http.client.HTTPConnection(self.host, 80, timeout=TIMEOUT),
                                "/", "http://", {})
        return resp.status, resp.getheader("Location") or ""

    def https_headers(self) -> dict:
        resp, _ = self._request(self._https(), "/", "https:// /", {})
        return {k.lower(): v for k, v in resp.getheaders()}

    def features(self, known_hosts: Path, strict: bool) -> str:
        """`zpool get` over SSH, the key in a throwaway ssh-agent killed on return."""
        try:
            out = subprocess.run(["ssh-agent", "-s"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            raise Unreachable("ssh: ssh-agent failed") from None
        sock = re.search(r"SSH_AUTH_SOCK=([^;]+);", out)
        pid = re.search(r"SSH_AGENT_PID=(\d+);", out)
        if not (sock and pid):
            raise Unreachable("ssh: ssh-agent failed")
        env = dict(os.environ, SSH_AUTH_SOCK=sock.group(1))
        env.pop("SSH_AGENT_PID", None)
        try:
            add = subprocess.run(["ssh-add", "-q", "-"], input=self.ssh_key, env=env,
                                 capture_output=True, text=True, timeout=10)
            if add.returncode:
                raise Unreachable("ssh: ssh-add rejected the key")
            cmd = f"zpool get -H -o property,value all {POOL}"
            if self.ssh_user != "root":
                cmd = "sudo -n " + cmd
            r = subprocess.run(
                ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                 "-o", f"UserKnownHostsFile={known_hosts}",
                 "-o", f"StrictHostKeyChecking={'yes' if strict else 'accept-new'}",
                 f"{self.ssh_user}@{self.host}", cmd],
                env=env, capture_output=True, text=True, timeout=30)
            if r.returncode:
                last = (r.stderr.strip().splitlines() or [""])[-1][:200]
                raise Unreachable(f"ssh: exit {r.returncode} {last}".rstrip())
            return r.stdout
        except subprocess.TimeoutExpired:
            raise Unreachable("ssh: timeout") from None
        finally:
            try:
                os.kill(int(pid.group(1)), signal.SIGTERM)
            except OSError:
                pass


# ---- normalisation -----------------------------------------------------------

def need(obj: dict, name: str, where: str):
    if not isinstance(obj, dict) or name not in obj:
        raise Missing(f"{where} {name}")
    return obj[name]


def nfs_paths(share: dict) -> list[str]:
    """CORE `paths`, SCALE `path`."""
    if "paths" in share:
        return list(share["paths"] or [])
    if "path" in share:
        return [share["path"]]
    raise Missing("sharing/nfs paths/path")


def smb_norm(share: dict) -> dict:
    """{path, hostsallow, guest}: top level on CORE to 25.04, under `options` on 25.10."""
    opts = share.get("options") or {}

    def pick(name):
        if name in share:
            return share[name]
        if name in opts:
            return opts[name]
        raise Missing(f"sharing/smb {name}")

    return {"path": need(share, "path", "sharing/smb"), "hostsallow": pick("hostsallow"),
            "guest": pick("guestok")}


def nfsv4_on(cfg: dict) -> bool:
    """CORE `v4`, SCALE `protocols` containing NFSV4."""
    if "protocols" in cfg:
        return "NFSV4" in (cfg["protocols"] or [])
    if "v4" in cfg:
        return bool(cfg["v4"])
    raise Missing("nfs v4/protocols")


def net(n: str) -> str:
    return n if "/" in n else f"{n}/32"


def target_nets(target: dict, initiators: dict, expect: str) -> list[str]:
    """Networks allowed on a target: SCALE its `auth_networks`, CORE its initiator groups'
    `auth_network`. `*` when a group allows any network."""
    if expect == "scale":
        return sorted(net(n) for n in need(target, "auth_networks", "iscsi/target") or ["*"])
    nets = set()
    for g in need(target, "groups", "iscsi/target") or [{}]:
        ini = initiators.get(g.get("initiator"))
        if ini is None:
            return ["*"]
        allowed = need(ini, "auth_network", "iscsi/initiator")
        if not allowed:
            return ["*"]
        nets.update(net(n) for n in allowed)
    return sorted(nets)


def parse_features(text: str) -> dict[str, str]:
    out = {}
    for line in text.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].startswith("feature@"):
            out[parts[0]] = parts[1].strip()
    return out


def few(items, n: int = 5) -> str:
    items = sorted(items)
    return ", ".join(items[:n]) + (f" (+{len(items) - n})" if len(items) > n else "")


def walk_datasets(entries) -> set[str]:
    names = set()
    for d in entries or []:
        names.add(d["name"])
        names |= walk_datasets(d.get("children"))
    return names


# ---- checks ------------------------------------------------------------------
# Each takes (now, base, expect) and returns the failure reasons; empty is PASS.

def c_version(now, base, expect):
    v = need(now["system/info"], "version", "system/info")
    if expect == "core":
        return [] if re.match(r"^TrueNAS-13\.0-U6\.[78]$", v) else [f"{v} is not 13.0-U6.7 or U6.8"]
    plain = re.sub(r"^TrueNAS-(SCALE-)?", "", v)
    return [] if plain == "25.10.8" else [f"{v} is not 25.10.8"]


def c_pools(now, base, expect):
    bad = []
    pools = {p["name"]: p for p in now["pool"]}
    boot = now["boot/get_state"]
    for name, p in ((POOL, pools.get(POOL)), (boot.get("name", "boot-pool"), boot)):
        if p is None:
            bad.append(f"pool {name} missing")
        elif need(p, "status", "pool") != "ONLINE" or not need(p, "healthy", "pool"):
            bad.append(f"pool {name} {p['status']}, healthy {p['healthy']}")
    return bad


def c_features(now, base, expect):
    cur, old = parse_features(now["features"]), parse_features(base["features"])
    if not cur:
        return ["no feature@ lines read"]
    if not old:
        return ["no feature@ lines in the baseline"]
    on = ("enabled", "active")
    new = [f for f, s in cur.items() if s in on and old.get(f) not in on]
    return [f"enabled since the baseline: {few(new)}"] if new else []


def c_services(now, base, expect):
    bad = []
    svc = {s["service"]: s for s in now["service"]}
    for name in SERVICES:
        s = svc.get(name)
        if s is None:
            bad.append(f"{name} missing")
        elif need(s, "state", "service") != "RUNNING" or not need(s, "enable", "service"):
            bad.append(f"{name} {s['state']}, enable {s['enable']}")
    if not nfsv4_on(now["nfs"]):
        bad.append("NFSv4 off")
    return bad


def same_id(a, b, ids) -> bool:
    return a == b or (a in ids and b in ids and ids[a] == ids[b])


def c_nfs(now, base, expect):
    bad = []
    old = {p: s for s in base["sharing/nfs"] for p in nfs_paths(s)}
    cur = {p: s for s in now["sharing/nfs"] for p in nfs_paths(s)}
    if set(cur) != set(old):
        missing, extra = set(old) - set(cur), set(cur) - set(old)
        bad.append("paths differ:" + (f" missing {few(missing)}" if missing else "")
                   + (f" extra {few(extra)}" if extra else ""))
    for path, s in sorted(cur.items()):
        hosts = sorted(need(s, "hosts", "sharing/nfs") or [])
        if hosts != sorted(NODES):
            bad.append(f"{path} hosts {hosts}")
        if need(s, "networks", "sharing/nfs"):
            bad.append(f"{path} networks {s['networks']}")
        b = old.get(path)
        if b is None:
            continue
        for key, ids in (("maproot_user", USER_IDS), ("maproot_group", GROUP_IDS)):
            if not same_id(need(s, key, "sharing/nfs"), need(b, key, "sharing/nfs"), ids):
                bad.append(f"{path} {key} {b[key]} != {s[key]}")
    return bad


def c_smb(now, base, expect):
    cur = next((s for s in now["sharing/smb"] if s.get("name") == SMB_SHARE), None)
    old = next((s for s in base["sharing/smb"] if s.get("name") == SMB_SHARE), None)
    if cur is None or old is None:
        return [f"share {SMB_SHARE} missing" + (" from the baseline" if cur else "")]
    c, o = smb_norm(cur), smb_norm(old)
    bad = []
    if c["path"] != o["path"]:
        bad.append(f"path {o['path']} != {c['path']}")
    if sorted(c["hostsallow"] or []) != SMB_HOSTS:
        bad.append(f"hostsallow {c['hostsallow']}")
    if c["guest"] is not True:
        bad.append("guest access off")
    return bad


def c_iscsi(now, base, expect):
    bad = []
    old = {t["name"] for t in base["iscsi/target"]}
    cur = {t["name"]: t for t in now["iscsi/target"]}
    missing, extra = old - set(cur), set(cur) - old
    if missing:
        bad.append(f"{len(missing)} targets missing: {few(missing)}")
    if extra:
        bad.append(f"{len(extra)} targets not in the baseline: {few(extra)}")
    initiators = {i["id"]: i for i in now["iscsi/initiator"]}
    open_ = [n for n, t in cur.items() if target_nets(t, initiators, expect) != NODE_NETS]
    if open_:
        bad.append(f"{len(open_)} targets not limited to the four nodes: {few(open_)}")
    gport = now["iscsi/global"].get("listen_port")
    ok = False
    for p in now["iscsi/portal"]:
        for li in need(p, "listen", "iscsi/portal") or []:
            port = li.get("port", gport)
            if port is None:
                raise Missing("iscsi/portal port/iscsi/global listen_port")
            ok = ok or (li.get("ip") == "0.0.0.0" and int(port) == 3260)
    if not ok:
        bad.append("no portal on 0.0.0.0:3260")
    return bad


def c_tls(now, base, expect):
    old = base["fingerprint"].strip()
    return [] if now["fingerprint"] == old else [f"fingerprint {old[:16]}… != {now['fingerprint'][:16]}…"]


def c_ui(now, base, expect):
    bad = []
    if need(now["system/general"], "ui_httpsredirect", "system/general") is not True:
        bad.append("ui_httpsredirect off")
    status, location = now["http_root"]
    if status not in (301, 302, 307, 308) or not location.startswith("https://"):
        bad.append(f"http:// answers {status} {location}".rstrip())
    if "strict-transport-security" not in now["https_headers"]:
        bad.append("no Strict-Transport-Security header")
    return bad


def c_quiesced(now, base, expect):
    sessions = now["iscsi/global/sessions"]
    if not sessions:
        return []
    addrs = {s.get("initiator_addr", "?") for s in sessions}
    return [f"{len(sessions)} iSCSI sessions open from {few(addrs)}"]


def c_snapshot(now, base, expect):
    name = now["snapshot_name"]
    datasets = {d for d in walk_datasets(now["pool/dataset"]) if d == POOL or d.startswith(POOL + "/")}
    have = {s["name"] for s in now["zfs/snapshot"]}
    missing = [d for d in datasets if f"{d}@{name}" not in have]
    if not datasets:
        return ["no dataset of the pool read"]
    return [f"{len(missing)} of {len(datasets)} without @{name}: {few(missing)}"] if missing else []


CHECK_FN = {"version": c_version, "pools": c_pools, "features": c_features, "services": c_services,
            "nfs": c_nfs, "smb": c_smb, "iscsi": c_iscsi, "tls": c_tls, "ui": c_ui,
            "quiesced": c_quiesced, "snapshot": c_snapshot}


def run_checks(checks, now, base, expect, out=None) -> int:
    out = out or sys.stdout
    rc = 0
    for name in checks:
        try:
            reasons = CHECK_FN[name](now, base, expect)
        except Missing as e:
            reasons = [f"field {e} missing"]
        except (KeyError, TypeError, AttributeError) as e:
            reasons = [f"unexpected shape ({type(e).__name__}: {e})"]
        if reasons:
            rc = 1
            print(f"FAIL {name}: {'; '.join(reasons)}", file=out)
        else:
            print(f"PASS {name}", file=out)
    return rc


# ---- record and expect ---------------------------------------------------------

def read_features_file(path: str) -> str:
    try:
        return Path(path).read_text()
    except OSError:
        raise Usage(f"cannot read {path}") from None


def record(nas, out: Path, features_text: str | None = None) -> None:
    if (out / "meta.json").exists():
        raise Usage(f"{out} already holds a record")
    data, endpoints = {}, {}
    for ep in RECORD_ENDPOINTS:
        data[ep] = nas.get(ep)
        endpoints[ep] = "absent" if data[ep] is ABSENT else "ok"
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    feats = features_text if features_text is not None else nas.features(out / "known_hosts", strict=False)
    fingerprint = nas.fingerprint()
    for ep, value in data.items():
        (out / fname(ep)).write_text(json.dumps(redact(value), indent=1, sort_keys=True) + "\n")
    (out / "features.txt").write_text(feats)
    (out / "fingerprint.txt").write_text(fingerprint + "\n")
    meta = {"version": 1, "host": NAS, "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "system_version": data["system/info"].get("version"), "endpoints": endpoints,
            "features_from": "file" if features_text is not None else "ssh"}
    (out / "meta.json").write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")


def load_baseline(d: Path, checks) -> dict:
    try:
        meta = json.loads((d / "meta.json").read_text())
    except (OSError, ValueError):
        raise Usage(f"{d}: no meta.json") from None
    if meta.get("version") != 1:
        raise Usage(f"{d}: meta.json version {meta.get('version')} is not 1")
    base = {}
    for check in checks:
        if check not in BASELINE_FILES:
            continue
        key, f = BASELINE_FILES[check]
        try:
            text = (d / f).read_text()
            base[key] = json.loads(text) if f.endswith(".json") else text
        except (OSError, ValueError):
            raise Usage(f"{d}: no readable {f}") from None
    return base


def gather(nas, checks, args, baseline: Path) -> dict:
    now = {}
    for check in checks:
        for ep in NEEDS.get(check, ()):
            if ep not in now:
                now[ep] = nas.get(ep)
    if "features" in checks:
        if args.features_file:
            now["features"] = read_features_file(args.features_file)
        else:
            kh = baseline / "known_hosts"
            if not kh.exists():
                raise Usage(f"{baseline}: no known_hosts; use --features-file")
            now["features"] = nas.features(kh, strict=True)
    if "tls" in checks:
        now["fingerprint"] = nas.fingerprint()
    if "ui" in checks:
        now["http_root"] = nas.http_root()
        now["https_headers"] = nas.https_headers()
    if "snapshot" in checks:
        now["snapshot_name"] = args.snapshot
        now["zfs/snapshot"] = nas.get("zfs/snapshot?" + urllib.parse.urlencode(
            {"snapshot_name": args.snapshot, "pool": POOL}))
    return now


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"nas-check: {message}", file=sys.stderr)
        sys.exit(64)


def parse_args(argv):
    p = Parser(description="Read-only checks of the NAS against a recorded baseline.")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--record", metavar="DIR")
    mode.add_argument("--expect", choices=("core", "scale"))
    p.add_argument("--baseline", metavar="DIR")
    p.add_argument("--quiesced", action="store_true")
    p.add_argument("--snapshot", metavar="NAME")
    p.add_argument("--features-file", metavar="FILE")
    p.add_argument("--only", metavar="CHECK,...")
    args = p.parse_args(argv)
    if args.record and (args.baseline or args.quiesced or args.snapshot or args.only):
        p.error("--record takes only --features-file")
    if args.expect and not args.baseline:
        p.error("--expect needs --baseline")
    if args.snapshot is not None and not re.match(r"^[A-Za-z0-9_.:-]+$", args.snapshot):
        p.error("--snapshot: letters, digits and _.:- only")
    return args


def select_checks(args) -> list[str]:
    available = list(CHECKS) + (["quiesced"] if args.quiesced else []) + (["snapshot"] if args.snapshot else [])
    if not args.only:
        return available
    only = [c.strip() for c in args.only.split(",") if c.strip()]
    unknown = [c for c in only if c not in available]
    if unknown or not only:
        raise Usage(f"--only: unknown or not enabled: {', '.join(unknown) or '(empty)'}")
    return [c for c in available if c in only]


def live_nas() -> Nas:
    try:
        api_key, user, key = parse_driver_config(read_driver_config())
    except ValueError:
        raise Unreachable("cannot read the driver config") from None
    try:
        ca = parse_ca(VALUES.read_text())
    except (OSError, ValueError):
        raise Unreachable(f"no CA in {VALUES.relative_to(REPO)}") from None
    return Nas(api_key, ca, user, key)


def main(argv=None, nas_factory=live_nas) -> int:
    try:
        args = parse_args(argv)
        if args.record:
            feats = read_features_file(args.features_file) if args.features_file else None
            out = Path(args.record).expanduser()
            record(nas_factory(), out, feats)
            print(f"recorded {len(RECORD_ENDPOINTS)} endpoints, features and fingerprint in {out}")
            return 0
        checks = select_checks(args)
        baseline = Path(args.baseline).expanduser()
        base = load_baseline(baseline, checks)
        if args.features_file:
            read_features_file(args.features_file)
        now = gather(nas_factory(), checks, args, baseline)
        return run_checks(checks, now, base, args.expect)
    except Usage as e:
        print(f"nas-check: {e}", file=sys.stderr)
        return 64
    except Unreachable as e:
        print(f"nas-check: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
