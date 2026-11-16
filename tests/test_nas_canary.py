"""The canary objects of scripts/nas-maintenance.sh against the backup-verify namespace's policies.

Kyverno runs over scripts/nas-canary/ in scripts/ci/kyverno.sh. Here: the label and namespace the script
selects by, the namespace's Pod Security level, and that the pods need no pod network, so the namespace's
enforced default deny (infrastructure/network-policies/90-enforcement.yaml) admits them as they are.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CANARY = ROOT / "scripts" / "nas-canary"
SCRIPT = ROOT / "scripts" / "nas-maintenance.sh"
# Volume kinds the kubelet mounts on the node: pod network policy never sees their traffic.
NODE_MOUNTED = {"persistentVolumeClaim", "nfs", "emptyDir"}


def docs(path: Path) -> list[dict]:
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], check=True, capture_output=True, text=True)
    return [d for d in (json.loads(line) for line in out.stdout.splitlines() if line.strip()) if isinstance(d, dict)]


def canary_objects() -> list[dict]:
    objs = [d for f in sorted(CANARY.glob("*.yaml")) for d in docs(f)]
    assert objs, "no objects under scripts/nas-canary/"
    return objs


def script_value(name: str) -> str:
    m = re.search(rf"^{name}=(\S+)$", SCRIPT.read_text(), re.M)
    assert m, f"{name} not set in {SCRIPT.name}"
    return m.group(1)


def test_labels_and_namespace_match_the_script():
    ns = script_value("CANARY_NS")
    key, _, value = script_value("CANARY_LABEL").partition("=")
    for o in canary_objects():
        md = o["metadata"]
        assert md.get("namespace") == ns, md["name"]
        assert (md.get("labels") or {}).get(key) == value, md["name"]
    names = {(o["kind"], o["metadata"]["name"]) for o in canary_objects()}
    assert names == {("PersistentVolumeClaim", "nas-canary"), ("Pod", "nas-canary-iscsi"), ("Pod", "nas-canary-nfs")}
    text = SCRIPT.read_text()
    for _, name in names:
        assert name in text, f"{name} is not used by the script"


def test_namespace_is_baseline_with_egress_denied():
    ns = script_value("CANARY_NS")
    nss = [d for d in docs(ROOT / "infrastructure/namespaces/namespaces.yaml")
           if d.get("kind") == "Namespace" and d["metadata"]["name"] == ns]
    assert len(nss) == 1
    assert nss[0]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "baseline"
    switch = [d for d in docs(ROOT / "infrastructure/network-policies/90-enforcement.yaml")
              if d["metadata"].get("namespace") == ns and d["metadata"]["name"] == "enforce-default-deny"]
    assert len(switch) == 1 and switch[0]["spec"]["endpointSelector"] == {}


def test_pods_need_no_pod_network():
    for o in canary_objects():
        if o["kind"] != "Pod":
            continue
        spec = o["spec"]
        assert spec.get("automountServiceAccountToken") is False, o["metadata"]["name"]
        assert spec.get("restartPolicy") == "Never"
        for c in spec["containers"]:
            assert not c.get("ports"), c["name"]
            sc = c["securityContext"]
            assert sc["allowPrivilegeEscalation"] is False and sc["capabilities"]["drop"] == ["ALL"]
        assert spec["securityContext"]["runAsNonRoot"] is True
        for v in spec["volumes"]:
            kinds = set(v) - {"name"}
            assert kinds <= NODE_MOUNTED, (o["metadata"]["name"], v["name"], kinds)
