"""The rendered Jamulus app keeps its invariants.

One UDP port in every place, the exact server arguments (no directory,
recording, JSON-RPC, status page or log file) and no node ports
(.kiro/specs/self-hosted-jamulus/design.md#invariants).
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEPLOY = REPO / "deploy" / "apps" / "jamulus"
POLICY = REPO / "deploy" / "infrastructure" / "network-policies" / "ciliumnetworkpolicy-jamulus.yaml"
PORT = 41124
ARGS = ["--server", "--nogui", "--port", str(PORT), "--numchannels", "8", "--fastupdate", "--discononquit"]
# Requirement 4.1: any of these would register the server with a directory.
DIRECTORY_OPTIONS = {"--directoryaddress", "-e", "--centralserver", "--directoryserver", "--directoryfile", "--serverinfo", "-o"}


def doc(path: Path) -> dict:
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def container() -> dict:
    (c,) = doc(DEPLOY / "deployment-jamulus.yaml")["spec"]["template"]["spec"]["containers"]
    return c


def test_server_arguments_are_exact():
    assert container()["args"] == ARGS


def test_no_directory_option():
    found = sorted(a.split("=", 1)[0] for a in container()["args"] if a.split("=", 1)[0] in DIRECTORY_OPTIONS)
    assert not found, f"the server would register with a directory: {found}"


def test_one_port_everywhere():
    ports = container()["ports"]
    assert ports == [{"name": "jamulus", "containerPort": PORT, "protocol": "UDP"}]
    svc = doc(DEPLOY / "service-jamulus.yaml")["spec"]
    assert svc["ports"] == [{"name": "jamulus", "protocol": "UDP", "port": PORT, "targetPort": "jamulus"}]
    rules = doc(POLICY)["spec"]["ingress"]
    assert rules and all(r["toPorts"] == [{"ports": [{"port": str(PORT), "protocol": "UDP"}]}] for r in rules)
    smoke = doc(DEPLOY / "job-jamulus-smoke.yaml")["spec"]["template"]["spec"]["containers"][0]["command"]
    assert f"jamulus-ping jamulus {PORT}" in smoke[-1]
    ping = (REPO / "jamulus" / "jamulus-ping").read_text()
    assert f"port=${{2:-{PORT}}}" in ping


def test_no_node_ports():
    svc = doc(DEPLOY / "service-jamulus.yaml")
    assert svc["metadata"]["annotations"]["lbipam.cilium.io/ips"] == "192.168.1.202"
    spec = svc["spec"]
    assert spec["type"] == "LoadBalancer"
    assert spec["allocateLoadBalancerNodePorts"] is False
    assert spec["externalTrafficPolicy"] == "Cluster"
    assert all("nodePort" not in p for p in spec["ports"])
