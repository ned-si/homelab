"""Every security policy maps to published framework controls.

policies/kyverno/upstream/controls.yaml maps each Kyverno policy (the vendored
set and the homelab ones in policies/kyverno/) to CIS Kubernetes Benchmark
section 5, NIST SP 800-190 section 4, the NSA/CISA Kubernetes Hardening Guide
and NIST CSF 2.0. platform/tetragon/policies/controls.yaml, once it exists,
maps each TracingPolicy to one MITRE ATT&CK technique and to DE.CM-09; no
TracingPolicy may carry an enforcement action (observe only).
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
KYVERNO = REPO / "policies" / "kyverno"
UPSTREAM = KYVERNO / "upstream"
TETRAGON = REPO / "platform" / "tetragon" / "policies"

CIS = re.compile(r"^5\.[1-7](\.\d{1,2})?$")
NIST_800_190 = re.compile(r"^4\.[1-5]\.[1-5]$")
CSF = re.compile(r"^(GV|ID|PR|DE|RS|RC)\.[A-Z]{2}-\d{2}$")
MITRE = re.compile(r"^T\d{4}(\.\d{3})?$")
NSA_CISA = {
    "Kubernetes Pod security: Non-root containers and rootless container engines",
    "Kubernetes Pod security: Immutable container file systems",
    "Kubernetes Pod security: Building secure container images",
    "Kubernetes Pod security: Pod security enforcement",
    "Kubernetes Pod security: Protecting Pod service account tokens",
    "Kubernetes Pod security: Hardening container environments",
    "Network separation and hardening: Namespaces",
    "Network separation and hardening: Network policies",
    "Network separation and hardening: Resource policies",
    "Network separation and hardening: Control plane hardening",
    "Authentication and authorization",
    "Audit logging and threat detection",
    "Upgrading and application security practices",
}
ENFORCEMENT = {"Sigkill", "Override", "Signal", "NotifyEnforcer"}


def docs(path: Path) -> list[dict]:
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], check=True, capture_output=True, text=True)
    return [d for d in (json.loads(line) for line in out.stdout.splitlines() if line.strip()) if isinstance(d, dict)]


def kyverno_policies() -> dict[str, Path]:
    files = sorted(KYVERNO.glob("*.yaml")) + sorted(p for p in UPSTREAM.rglob("*.yaml") if p.name != "controls.yaml")
    out = {}
    for f in files:
        for d in docs(f):
            if d.get("kind") == "ValidatingPolicy":
                out[d["metadata"]["name"]] = f
    return out


def kyverno_controls() -> dict:
    return docs(UPSTREAM / "controls.yaml")[0]["policies"]


def test_every_kyverno_policy_has_an_entry():
    missing = sorted(set(kyverno_policies()) - set(kyverno_controls()))
    assert not missing, f"no entry in policies/kyverno/upstream/controls.yaml: {missing}"


def test_every_kyverno_entry_names_a_policy():
    policies = kyverno_policies()
    for name, entry in kyverno_controls().items():
        assert name in policies, f"controls.yaml: {name} is not a policy"
        assert (UPSTREAM / entry["file"]).resolve() == policies[name].resolve(), f"{name}: file is {policies[name]}"


@pytest.mark.parametrize("name", sorted(kyverno_controls()))
def test_kyverno_ids(name):
    entry = kyverno_controls()[name]
    for cis in entry["cis"]:
        assert CIS.match(cis), f"{name}: CIS {cis}"
    for nist in entry["nist_800_190"]:
        assert NIST_800_190.match(nist), f"{name}: NIST SP 800-190 {nist}"
    for nsa in entry["nsa_cisa"]:
        assert nsa in NSA_CISA, f"{name}: NSA/CISA section {nsa!r}"
    assert entry["csf"], f"{name}: no CSF 2.0 subcategory"
    for csf in entry["csf"]:
        assert CSF.match(csf), f"{name}: CSF {csf}"
    if not (entry["cis"] or entry["nist_800_190"] or entry["nsa_cisa"]):
        assert entry.get("reliability_only"), f"{name}: needs a CIS, NIST SP 800-190 or NSA/CISA control"


def tracing_policies() -> dict[str, dict]:
    out = {}
    for f in sorted(TETRAGON.rglob("*.yaml")) if TETRAGON.is_dir() else []:
        if f.name == "controls.yaml":
            continue
        for d in docs(f):
            if d.get("kind") in ("TracingPolicy", "TracingPolicyNamespaced"):
                out[d["metadata"]["name"]] = d
    return out


def actions(node) -> set[str]:
    found = set()
    if isinstance(node, dict):
        if isinstance(node.get("action"), str):
            found.add(node["action"])
        for v in node.values():
            found |= actions(v)
    elif isinstance(node, list):
        for v in node:
            found |= actions(v)
    return found


def test_actions_finds_nested_enforcement():
    policy = {"spec": {"kprobes": [{"selectors": [{"matchActions": [{"action": "Post"}, {"action": "Sigkill"}]}]}]}}
    assert actions(policy) & ENFORCEMENT == {"Sigkill"}


def test_tracing_policies_observe_only():
    for name, policy in tracing_policies().items():
        bad = actions(policy) & ENFORCEMENT
        assert not bad, f"TracingPolicy {name} has enforcement actions {sorted(bad)}"


def test_tracing_policies_mapped():
    policies = tracing_policies()
    if not policies:
        pytest.skip("no TracingPolicy yet")
    controls = docs(TETRAGON / "controls.yaml")[0]["policies"]
    assert set(policies) == set(controls), f"controls.yaml vs TracingPolicies: {sorted(set(policies) ^ set(controls))}"
    for name, entry in controls.items():
        assert MITRE.match(entry["mitre"]), f"{name}: MITRE {entry['mitre']}"
        assert "DE.CM-09" in entry["csf"], f"{name}: CSF must include DE.CM-09"
