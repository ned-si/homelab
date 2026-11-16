"""scripts/nas-check.py against fake NAS APIs shaped like TrueNAS CORE 13.0,
SCALE 24.04 and Community Edition 25.10 (hand-written, no real values). No network."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("nas_check", ROOT / "scripts" / "nas-check.py")
nc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nc)

NODES = ["192.168.1.247", "192.168.1.238", "192.168.1.239", "192.168.1.240"]
NETS = [f"{n}/32" for n in NODES]
FINGERPRINT = "ab" * 32
FEATURES = ("feature@async_destroy\tenabled\nfeature@encryption\tactive\n"
            "feature@draid\tdisabled\nfeature@bookmark_v2\tenabled\nfreeing\t0\n")
ALL_CHECKS = ["version", "pools", "features", "services", "nfs", "smb", "iscsi", "tls", "ui"]


def services(**state):
    names = ("cifs", "nfs", "iscsitarget", "ssh", "rsync")
    return [{"service": n, "state": state.get(n, "STOPPED" if n == "rsync" else "RUNNING"),
             "enable": n != "rsync"} for n in names]


CORE = {
    "system/info": {"version": "TrueNAS-13.0-U6.7", "hostname": "nas.local"},
    "pool": [{"name": "homelab", "status": "ONLINE", "healthy": True}],
    "boot/get_state": {"name": "boot-pool", "status": "ONLINE", "healthy": True},
    "service": services(),
    "nfs": {"v4": True, "servers": 4},
    "sharing/nfs": [
        {"id": 1, "paths": ["/mnt/homelab/k8s/nfs"], "hosts": list(NODES), "networks": [],
         "maproot_user": "nobody", "maproot_group": "nogroup", "alldirs": True},
        {"id": 2, "paths": ["/mnt/homelab/k8s/backups"], "hosts": list(NODES), "networks": [],
         "maproot_user": "root", "maproot_group": "wheel", "alldirs": False},
    ],
    "sharing/smb": [{"id": 1, "name": "bits_and_pieces", "path": "/mnt/homelab/bits_and_pieces",
                     "purpose": "DEFAULT_SHARE", "hostsallow": ["192.168.1.0/24"], "guestok": True}],
    "iscsi/target": [{"id": 1, "name": "kube", "groups": [{"portal": 1, "initiator": 1}]},
                     {"id": 2, "name": "csi-pvc-1-cluster", "groups": [{"portal": 1, "initiator": 1}]}],
    "iscsi/initiator": [{"id": 1, "auth_network": list(NETS), "initiators": []}],
    "iscsi/portal": [{"id": 1, "listen": [{"ip": "0.0.0.0", "port": 3260}]}],
    "iscsi/global": {"basename": "iqn.2005-10.org.freenas.ctl"},
    "iscsi/global/sessions": [],
    "interface": [{"name": "igb0", "aliases": [{"address": "192.168.1.228", "netmask": 24}]}],
    "network/configuration": {"hostname": "nas", "ipv4gateway": "192.168.1.1"},
    "system/general": {"ui_httpsredirect": True, "ui_certificate": {"name": "nas", "privatekey": "PK"}},
    "certificate": [{"id": 1, "name": "nas", "certificate": "-----BEGIN CERTIFICATE-----x",
                     "privatekey": "pem-private-key-x"}],
    "user": [{"username": "root", "uid": 0, "unixhash": "$6$x", "smbhash": "*",
              "sshpubkey": "ssh-ed25519 AAAAexample", "password_disabled": False}],
    "tunable": [{"var": "hint.isp.0.role", "value": "2", "type": "LOADER"}],
    "pool/dataset": [{"name": "homelab", "children": [
        {"name": "homelab/k8s", "children": [{"name": "homelab/k8s/nfs", "children": []},
                                             {"name": "homelab/k8s/v/pvc-1", "children": []}]}]}],
    "cronjob": [],
    "initshutdownscript": [],
    "plugin": nc.ABSENT,
    "jail": [],
}


def scale_2404():
    d = copy.deepcopy(CORE)
    d["system/info"]["version"] = "TrueNAS-SCALE-24.04.2.5"
    d["nfs"] = {"protocols": ["NFSV3", "NFSV4"], "servers": 4}
    for s in d["sharing/nfs"]:
        s["path"] = s.pop("paths")[0]
        s.pop("alldirs")
    d["sharing/nfs"][1]["maproot_group"] = "root"
    for t in d["iscsi/target"]:
        t["auth_networks"] = list(NETS)
    d["iscsi/initiator"] = [{"id": 1, "initiators": [], "comment": ""}]
    d["iscsi/portal"] = [{"id": 1, "listen": [{"ip": "0.0.0.0"}]}]
    d["iscsi/global"]["listen_port"] = 3260
    d["features"] = FEATURES + "feature@raidz_expansion\tdisabled\n"
    return d


def scale_2510():
    d = scale_2404()
    d["system/info"]["version"] = "25.10.8"
    d["sharing/smb"] = [{"id": 1, "name": "bits_and_pieces", "path": "/mnt/homelab/bits_and_pieces",
                         "purpose": "LEGACY_SHARE",
                         "options": {"hostsallow": ["192.168.1.0/24"], "guestok": True, "recyclebin": False}}]
    return d


class FakeNas:
    def __init__(self, data, features=FEATURES, fingerprint=FINGERPRINT, http_root=(307, "https://192.168.1.228:443/"),
                 https_headers=None, snapshots=None, fail_on=None):
        self.data, self._features, self._fp = data, data.get("features", features), fingerprint
        self._http, self._headers = http_root, https_headers if https_headers is not None else {
            "strict-transport-security": "max-age=63072000"}
        self.snapshots, self.fail_on, self.calls = snapshots or [], fail_on, []

    def get(self, endpoint):
        self.calls.append(endpoint)
        if endpoint == self.fail_on:
            raise nc.Unreachable(f"{endpoint}: HTTP 401, api key rejected")
        if endpoint.startswith("zfs/snapshot?"):
            return self.snapshots
        value = self.data[endpoint]
        return value if value is nc.ABSENT else copy.deepcopy(value)

    def fingerprint(self):
        return self._fp

    def http_root(self):
        return self._http

    def https_headers(self):
        return self._headers

    def features(self, known_hosts, strict):
        if not strict:
            Path(known_hosts).write_text("192.168.1.228 ssh-ed25519 AAAAexample\n")
        return self._features


@pytest.fixture
def baseline(tmp_path):
    d = tmp_path / "pre"
    nc.record(FakeNas(CORE), d)
    return d


def run(capsys, nas, *argv):
    rc = nc.main(list(argv), nas_factory=lambda: nas)
    out = capsys.readouterr()
    return rc, out.out, out.err


def lines(out):
    return {ln.split()[1].rstrip(":"): ln for ln in out.splitlines()}


# ---- record --------------------------------------------------------------------

def test_record_writes_every_endpoint_redacted(baseline):
    meta = json.loads((baseline / "meta.json").read_text())
    assert meta["version"] == 1
    assert meta["system_version"] == "TrueNAS-13.0-U6.7"
    assert meta["endpoints"]["plugin"] == "absent" and meta["endpoints"]["jail"] == "ok"
    assert set(meta["endpoints"]) == set(nc.RECORD_ENDPOINTS)
    for ep in nc.RECORD_ENDPOINTS:
        assert (baseline / nc.fname(ep)).exists(), ep
    user = json.loads((baseline / "user.json").read_text())[0]
    assert user["unixhash"] == user["smbhash"] == "<redacted>"
    assert user["sshpubkey"] == "ssh-ed25519 AAAAexample"
    cert = json.loads((baseline / "certificate.json").read_text())[0]
    assert cert["privatekey"] == "<redacted>" and cert["certificate"].startswith("-----BEGIN CERTIFICATE")
    general = json.loads((baseline / "system_general.json").read_text())
    assert general["ui_certificate"]["privatekey"] == "<redacted>"
    text = "".join(p.read_text() for p in baseline.iterdir())
    assert "pem-private-key-x" not in text and "$6$" not in text
    assert (baseline / "features.txt").read_text() == FEATURES
    assert (baseline / "fingerprint.txt").read_text().strip() == FINGERPRINT
    assert (baseline / "known_hosts").exists()


@pytest.mark.parametrize("key", ["password", "bindpw_password", "secret", "Private_Key", "unixhash", "privatekey"])
def test_redact_key_suffixes(key):
    assert nc.redact({"a": [{key: "x"}]}) == {"a": [{key: "<redacted>"}]}


def test_record_refuses_to_overwrite(baseline, capsys):
    rc, _, err = run(capsys, FakeNas(CORE), "--record", str(baseline))
    assert rc == 64 and "already holds a record" in err


def test_record_with_features_file(tmp_path, capsys):
    f = tmp_path / "zpool.txt"
    f.write_text(FEATURES)
    rc, _, _ = run(capsys, FakeNas(CORE, features="unused"), "--record", str(tmp_path / "r"),
                   "--features-file", str(f))
    assert rc == 0
    assert json.loads((tmp_path / "r" / "meta.json").read_text())["features_from"] == "file"


# ---- expect: the three shapes --------------------------------------------------

def test_core_against_its_baseline_all_pass(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(CORE), "--expect", "core", "--baseline", str(baseline))
    assert rc == 0, out
    assert out.splitlines() == [f"PASS {c}" for c in ALL_CHECKS]


def test_2510_against_the_core_baseline_all_pass(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(scale_2510()), "--expect", "scale", "--baseline", str(baseline))
    assert rc == 0, out


def test_2404_fails_only_the_version(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(scale_2404()), "--expect", "scale", "--baseline", str(baseline))
    assert rc == 1
    got = lines(out)
    assert got["version"] == "FAIL version: TrueNAS-SCALE-24.04.2.5 is not 25.10.8"
    assert all(got[c].startswith("PASS") for c in ALL_CHECKS if c != "version")


def test_after_an_intermediate_update_only_pools_and_features(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(scale_2404()), "--expect", "scale", "--baseline", str(baseline),
                     "--only", "pools,features")
    assert rc == 0 and out.splitlines() == ["PASS pools", "PASS features"]


def test_core_expected_on_scale_fails_version_and_iscsi_field(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(scale_2510()), "--expect", "core", "--baseline", str(baseline))
    assert rc == 1
    got = lines(out)
    assert got["version"].startswith("FAIL")
    assert got["iscsi"] == "FAIL iscsi: field iscsi/initiator auth_network missing"


@pytest.mark.parametrize("version,ok", [("TrueNAS-13.0-U6.7", True), ("TrueNAS-13.0-U6.8", True),
                                        ("TrueNAS-13.0-U6.6", False), ("TrueNAS-13.3-U1.2", False)])
def test_core_versions(version, ok):
    assert (nc.c_version({"system/info": {"version": version}}, {}, "core") == []) is ok


@pytest.mark.parametrize("version,ok", [("25.10.8", True), ("TrueNAS-25.10.8", True), ("25.10.7", False),
                                        ("25.10.8.1", False), ("TrueNAS-SCALE-25.04.2.6", False)])
def test_scale_versions(version, ok):
    assert (nc.c_version({"system/info": {"version": version}}, {}, "scale") == []) is ok


# ---- SMB and NFS-service normalisation ---------------------------------------------

def test_smb_shapes_normalise_alike():
    want = {"path": "/mnt/homelab/bits_and_pieces", "hostsallow": ["192.168.1.0/24"], "guest": True}
    for shape in (CORE, scale_2404(), scale_2510()):
        assert nc.smb_norm(shape["sharing/smb"][0]) == want


def test_smb_default_share_on_2510_without_guestok_fails_naming_the_field(baseline, capsys):
    d = scale_2510()
    d["sharing/smb"][0].update(purpose="DEFAULT_SHARE", options={"hostsallow": ["192.168.1.0/24"]})
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "smb")
    assert rc == 1 and out.strip() == "FAIL smb: field sharing/smb guestok missing"


def test_smb_null_options_is_missing_not_false(baseline, capsys):
    d = scale_2510()
    d["sharing/smb"][0]["options"] = None
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "smb")
    assert rc == 1 and "field sharing/smb hostsallow missing" in out


@pytest.mark.parametrize("change,reason", [
    ({"guestok": False}, "guest access off"),
    ({"hostsallow": ["192.168.0.0/16"]}, "hostsallow"),
    ({"path": "/mnt/homelab/other"}, "path /mnt/homelab/bits_and_pieces != /mnt/homelab/other"),
])
def test_smb_differences(baseline, capsys, change, reason):
    d = copy.deepcopy(CORE)
    d["sharing/smb"][0].update(change)
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--only", "smb")
    assert rc == 1 and reason in out


def test_smb_share_gone(baseline, capsys):
    d = scale_2510()
    d["sharing/smb"] = []
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "smb")
    assert rc == 1 and "share bits_and_pieces missing" in out


@pytest.mark.parametrize("cfg,ok", [({"v4": True}, True), ({"v4": False}, False),
                                    ({"protocols": ["NFSV3", "NFSV4"]}, True), ({"protocols": ["NFSV3"]}, False)])
def test_nfs_service_shapes(cfg, ok):
    assert nc.nfsv4_on(cfg) is ok


def test_nfs_service_field_missing_fails_naming_it(baseline, capsys):
    d = scale_2510()
    d["nfs"] = {"servers": 4}
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "services")
    assert rc == 1 and out.strip() == "FAIL services: field nfs v4/protocols missing"


def test_service_stopped(baseline, capsys):
    d = copy.deepcopy(CORE)
    d["service"] = services(iscsitarget="STOPPED")
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--only", "services")
    assert rc == 1 and "iscsitarget STOPPED" in out


# ---- NFS exports ------------------------------------------------------------------

def test_nfs_wheel_and_root_are_the_same_group(baseline):
    base = {"sharing/nfs": json.loads((baseline / "sharing_nfs.json").read_text())}
    assert nc.c_nfs(scale_2510(), base, "scale") == []


@pytest.mark.parametrize("change,reason", [
    ({"maproot_user": "nobody"}, "maproot_user root != nobody"),
    ({"maproot_group": "nogroup"}, "maproot_group wheel != nogroup"),
    ({"hosts": NODES[:3]}, "hosts"),
    ({"networks": ["192.168.1.0/24"]}, "networks"),
    ({"path": "/mnt/homelab/k8s/backup"}, "paths differ: missing /mnt/homelab/k8s/backups extra /mnt/homelab/k8s/backup"),
])
def test_nfs_differences(baseline, capsys, change, reason):
    d = scale_2510()
    d["sharing/nfs"][1].update(change)
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "nfs")
    assert rc == 1 and reason in out, out


def test_nfs_without_path_fields(baseline, capsys):
    d = scale_2510()
    del d["sharing/nfs"][0]["path"]
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "nfs")
    assert rc == 1 and "field sharing/nfs paths/path missing" in out


# ---- iSCSI ------------------------------------------------------------------------

def test_iscsi_scale_target_open(baseline, capsys):
    d = scale_2510()
    d["iscsi/target"][1]["auth_networks"] = []
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "iscsi")
    assert rc == 1 and "1 targets not limited to the four nodes: csi-pvc-1-cluster" in out


def test_iscsi_scale_bare_addresses_count_as_32(baseline):
    d = scale_2510()
    for t in d["iscsi/target"]:
        t["auth_networks"] = list(NODES)
    base = {"iscsi/target": CORE["iscsi/target"]}
    assert nc.c_iscsi(d, base, "scale") == []


def test_iscsi_scale_field_missing(baseline, capsys):
    d = scale_2510()
    del d["iscsi/target"][0]["auth_networks"]
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "iscsi")
    assert rc == 1 and "field iscsi/target auth_networks missing" in out


@pytest.mark.parametrize("nets", [[], NETS[:3], NETS + ["192.168.1.50/32"], ["192.168.1.0/24"]])
def test_iscsi_core_group_not_the_four_nodes(baseline, capsys, nets):
    d = copy.deepcopy(CORE)
    d["iscsi/initiator"][0]["auth_network"] = nets
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--only", "iscsi")
    assert rc == 1 and "2 targets not limited" in out


def test_iscsi_core_target_without_group(baseline, capsys):
    d = copy.deepcopy(CORE)
    d["iscsi/target"][0]["groups"] = []
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--only", "iscsi")
    assert rc == 1 and "1 targets not limited to the four nodes: kube" in out


def test_iscsi_target_names(baseline, capsys):
    d = scale_2510()
    d["iscsi/target"][1]["name"] = "csi-pvc-2-cluster"
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "iscsi")
    assert rc == 1
    assert "1 targets missing: csi-pvc-1-cluster" in out and "1 targets not in the baseline: csi-pvc-2-cluster" in out


@pytest.mark.parametrize("portal,gport", [([{"ip": "0.0.0.0", "port": 3261}], None),
                                          ([{"ip": "192.168.1.228"}], 3260), ([], 3260)])
def test_iscsi_portal(baseline, portal, gport):
    d = scale_2510()
    d["iscsi/portal"] = [{"id": 1, "listen": portal}]
    d["iscsi/global"]["listen_port"] = gport
    base = {"iscsi/target": CORE["iscsi/target"]}
    assert nc.c_iscsi(d, base, "scale") == ["no portal on 0.0.0.0:3260"]


# ---- features, tls, ui, quiesced, snapshot -------------------------------------------

def test_features_new_enabled_feature_fails(baseline, capsys):
    d = scale_2510()
    d["features"] = FEATURES.replace("feature@draid\tdisabled", "feature@draid\tenabled")
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "scale", "--baseline", str(baseline), "--only", "features")
    assert rc == 1 and out.strip() == "FAIL features: enabled since the baseline: feature@draid"


def test_features_enabled_to_active_passes(baseline):
    now = {"features": FEATURES.replace("feature@bookmark_v2\tenabled", "feature@bookmark_v2\tactive")}
    assert nc.c_features(now, {"features": FEATURES}, "scale") == []


def test_features_empty_read_fails():
    assert nc.c_features({"features": ""}, {"features": FEATURES}, "scale") == ["no feature@ lines read"]


def test_features_file_instead_of_ssh(baseline, tmp_path, capsys):
    f = tmp_path / "pasted.txt"
    f.write_text("feature@async_destroy  enabled\nfeature@encryption  active\n")
    nas = FakeNas(scale_2510(), features="")
    nas._features = ""  # SSH broken: an SSH read would fail the check
    rc, out, _ = run(capsys, nas, "--expect", "scale", "--baseline", str(baseline),
                     "--features-file", str(f), "--only", "features")
    assert rc == 0 and out.strip() == "PASS features"


def test_features_need_known_hosts_without_a_file(baseline, capsys):
    (baseline / "known_hosts").unlink()
    rc, _, err = run(capsys, FakeNas(CORE), "--expect", "core", "--baseline", str(baseline), "--only", "features")
    assert rc == 64 and "use --features-file" in err


def test_tls_fingerprint_changed(baseline, capsys):
    rc, out, _ = run(capsys, FakeNas(scale_2510(), fingerprint="cd" * 32), "--expect", "scale",
                     "--baseline", str(baseline), "--only", "tls")
    assert rc == 1 and out.startswith("FAIL tls: fingerprint abababab")


@pytest.mark.parametrize("kwargs,reason", [
    ({"http_root": (200, "")}, "http:// answers 200"),
    ({"http_root": (302, "http://192.168.1.228/ui/")}, "http:// answers 302"),
    ({"https_headers": {"server": "nginx"}}, "no Strict-Transport-Security header"),
])
def test_ui_failures(baseline, capsys, kwargs, reason):
    rc, out, _ = run(capsys, FakeNas(CORE, **kwargs), "--expect", "core", "--baseline", str(baseline), "--only", "ui")
    assert rc == 1 and reason in out


@pytest.mark.parametrize("status", [301, 302, 307, 308])
def test_ui_redirect_codes(baseline, status):
    now = {"system/general": {"ui_httpsredirect": True}, "http_root": (status, "https://192.168.1.228/"),
           "https_headers": {"strict-transport-security": "max-age=1"}}
    assert nc.c_ui(now, {}, "core") == []


def test_ui_redirect_setting_off():
    now = {"system/general": {"ui_httpsredirect": False}, "http_root": (301, "https://x/"),
           "https_headers": {"strict-transport-security": "max-age=1"}}
    assert nc.c_ui(now, {}, "scale") == ["ui_httpsredirect off"]


def test_quiesced(baseline, capsys):
    d = copy.deepcopy(CORE)
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--quiesced")
    assert rc == 0 and out.splitlines()[-1] == "PASS quiesced"
    d["iscsi/global/sessions"] = [{"initiator_addr": "192.168.1.240", "target": "kube"}]
    rc, out, _ = run(capsys, FakeNas(d), "--expect", "core", "--baseline", str(baseline), "--quiesced",
                     "--only", "quiesced")
    assert rc == 1 and out.strip() == "FAIL quiesced: 1 iSCSI sessions open from 192.168.1.240"


def test_snapshot(baseline, capsys):
    names = ["homelab", "homelab/k8s", "homelab/k8s/nfs", "homelab/k8s/v/pvc-1"]
    snaps = [{"name": f"{n}@pre-scale-20261117"} for n in names]
    nas = FakeNas(CORE, snapshots=snaps)
    rc, out, _ = run(capsys, nas, "--expect", "core", "--baseline", str(baseline),
                     "--snapshot", "pre-scale-20261117", "--only", "snapshot")
    assert rc == 0 and out.strip() == "PASS snapshot"
    assert any(c.startswith("zfs/snapshot?snapshot_name=pre-scale-20261117") for c in nas.calls)
    nas = FakeNas(CORE, snapshots=snaps[:-1])
    rc, out, _ = run(capsys, nas, "--expect", "core", "--baseline", str(baseline),
                     "--snapshot", "pre-scale-20261117", "--only", "snapshot")
    assert rc == 1 and out.strip() == "FAIL snapshot: 1 of 4 without @pre-scale-20261117: homelab/k8s/v/pvc-1"


def test_only_fetches_what_the_checks_need(baseline, capsys):
    nas = FakeNas(scale_2404())
    run(capsys, nas, "--expect", "scale", "--baseline", str(baseline), "--only", "version,pools")
    assert nas.calls == ["system/info", "pool", "boot/get_state"]


# ---- usage and errors ---------------------------------------------------------------

@pytest.mark.parametrize("argv", [
    [], ["--expect", "core"], ["--expect", "bogus", "--baseline", "x"], ["--record", "x", "--only", "tls"],
    ["--record", "x", "--expect", "core"], ["--expect", "core", "--baseline", "B", "--only", "nope"],
    ["--expect", "core", "--baseline", "B", "--only", "snapshot"],
    ["--expect", "core", "--baseline", "B", "--only", "quiesced"],
    ["--expect", "core", "--baseline", "B", "--snapshot", "bad name;rm"],
])
def test_usage_exits_64(baseline, capsys, argv):
    argv = [str(baseline) if a == "B" else a for a in argv]
    nas = FakeNas(CORE)
    try:
        rc = nc.main(argv, nas_factory=lambda: nas)
    except SystemExit as e:  # argparse errors
        rc = e.code
    assert rc == 64
    assert nas.calls == []


def test_usage_returns_64_for_bad_only(baseline, capsys):
    rc, _, err = run(capsys, FakeNas(CORE), "--expect", "core", "--baseline", str(baseline), "--only", "nope")
    assert rc == 64 and "--only" in err


def test_baseline_version_must_be_1(baseline, capsys):
    (baseline / "meta.json").write_text(json.dumps({"version": 2}))
    nas = FakeNas(CORE)
    rc, _, err = run(capsys, nas, "--expect", "core", "--baseline", str(baseline))
    assert rc == 64 and "version 2 is not 1" in err and nas.calls == []


def test_unreachable_exits_2_with_endpoint_and_status(baseline, capsys):
    rc, out, err = run(capsys, FakeNas(CORE, fail_on="pool"), "--expect", "core", "--baseline", str(baseline))
    assert rc == 2 and out == "" and err.strip() == "nas-check: pool: HTTP 401, api key rejected"


# ---- inputs -----------------------------------------------------------------------

# Armour split so secret scanners do not flag the fixture.
BEGIN, END = "-----BEGIN OPENSSH " + "PRIVATE KEY-----", "-----END OPENSSH " + "PRIVATE KEY-----"
DRIVER_CONFIG = """\
driver: freenas-iscsi
httpConnection:
  protocol: https
  host: 192.168.1.228
  apiKey: 1-exampleapikey
  allowInsecure: false
sshConnection:
  host: 192.168.1.228
  # a comment with username: nobody
  username: kube
  privateKey: |
    BEGIN
    b3BlbnNzaC1rZXktdjEAAAAAexample

    AAAAexample
    END
zfs:
  datasetParentName: homelab/k8s/v
""".replace("BEGIN\n", BEGIN + "\n").replace("END\n", END + "\n")


def test_parse_driver_config():
    key, user, priv = nc.parse_driver_config(DRIVER_CONFIG)
    assert key == "1-exampleapikey" and user == "kube"
    assert priv.splitlines()[0] == BEGIN
    assert priv.splitlines()[-1] == END
    assert priv.endswith("-----\n") and "\n\n" in priv


def test_parse_driver_config_incomplete():
    with pytest.raises(ValueError):
        nc.parse_driver_config(DRIVER_CONFIG.replace("  apiKey: 1-exampleapikey\n", ""))


def test_parse_ca_from_values():
    ca = nc.parse_ca((ROOT / "infrastructure" / "democratic-csi" / "values-iscsi.yaml").read_text())
    assert ca.startswith("-----BEGIN CERTIFICATE-----\n") and ca.endswith("-----END CERTIFICATE-----\n")
