"""platform/github-exporter/exporter.py: collect() against canned API answers."""
from __future__ import annotations

import importlib.util
import re
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "platform" / "github-exporter" / "exporter.py"


def load():
    spec = importlib.util.spec_from_file_location("github_exporter", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def iso(offset: float) -> str:
    return datetime.fromtimestamp(time.time() - offset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(name, conclusion, branch, age, duration):
    return {"name": name, "status": "completed", "conclusion": conclusion, "head_branch": branch,
            "event": "push", "created_at": iso(age), "run_started_at": iso(age),
            "updated_at": iso(age - duration)}


def pr(number, login, created_age, closed_age=None, merged=False, labels=()):
    return {"number": number, "user": {"login": login}, "head": {"ref": f"b{number}"}, "draft": False,
            "created_at": iso(created_age), "closed_at": iso(closed_age) if closed_age is not None else None,
            "merged_at": iso(closed_age) if merged else None, "labels": [{"name": n} for n in labels]}


ANSWERS = {
    "/workflows?": {"workflows": [{"id": 1, "name": "ci", "state": "active", "path": ".github/workflows/ci.yaml"},
                                  {"id": 2, "name": "graph", "state": "active", "path": "dynamic/x"}]},
    "/workflows/1/runs": {"workflow_runs": [run("ci", "success", "main", 100, 60),
                                            run("ci", "failure", "feat", 50, 30),
                                            run("ci", "cancelled", "feat", 200, 5)]},
    "state=open": [pr(7, "renovate[bot]", 3600), pr(8, "someone", 60, labels=("auto-rollback",))],
    "state=closed": [pr(5, "renovate[bot]", 7200, 3600, merged=True),
                     pr(4, "renovate[bot]", 7200, 3600),
                     pr(3, "someone", 7200, 3600, merged=True, labels=("auto-rollback",)),
                     pr(2, "someone", 90 * 86400, 60 * 86400, merged=True)],
    "/issues": [{"title": "Dependency Dashboard",
                 "body": "## Open\n - [ ] <!-- rebase-branch=a -->a\n - [ ] <!-- rebase-branch=b -->b\n"
                         "## Rate-Limited\n - [ ] <!-- unlimit-branch=c -->c\n---\n - [ ] <!-- manual job -->Check"}],
}


def fake_get(path):
    for key in sorted(ANSWERS, key=lambda k: k != "/issues"):  # issues first: its query has state=open
        value = ANSWERS[key]
        if key in path:
            return value, {"X-RateLimit-Remaining": "42"}
    raise AssertionError(path)


def metrics(text: str) -> dict[str, float]:
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            name, value = line.rsplit(" ", 1)
            out[name] = float(value)
    return out


def test_collect():
    mod = load()
    mod.get = fake_get
    text = mod.collect()
    m = metrics(text)
    assert m['github_workflow_runs{conclusion="success",workflow="ci"}'] == 1
    assert m['github_workflow_runs{conclusion="failure",workflow="ci"}'] == 1
    assert m['github_workflow_last_success{conclusion="failure",event="push",scope="any",workflow="ci"}'] == 0
    assert m['github_workflow_last_success{conclusion="success",event="push",scope="main",workflow="ci"}'] == 1
    assert m['github_workflow_last_run_duration_seconds{scope="main",workflow="ci"}'] == 60
    assert not any("graph" in k for k in m)
    assert m['github_pull_requests_open{author="renovate"}'] == 1
    assert m['github_pull_requests_closed_30d{author="renovate",state="merged"}'] == 1
    assert m['github_pull_requests_closed_30d{author="renovate",state="closed"}'] == 1
    assert m['github_pull_requests_closed_30d{author="other",state="merged"}'] == 1
    assert m["github_auto_rollback_pull_requests_30d"] == 1
    assert m["github_auto_rollback_pull_requests_open"] == 1
    assert m['github_renovate_dashboard_entries{section="Open"}'] == 2
    assert m['github_renovate_dashboard_entries{section="Rate-Limited"}'] == 1
    assert m["github_ratelimit_remaining"] == 42


def wf_run(name, run_id, age, event, title, branch="main", conclusion="success"):
    return dict(run(name, conclusion, branch, age, 60), id=run_id, event=event, display_title=title,
                html_url=f"https://github.com/o/r/actions/runs/{run_id}")


EVENTS = {
    "/workflows?": {"workflows": [
        # Disabled for a planned window: its history still counts.
        {"id": 3, "name": "auto-rollback", "state": "disabled_manually", "path": ".github/workflows/auto-rollback.yaml"},
        {"id": 4, "name": "tofu", "state": "active", "path": ".github/workflows/tofu.yaml"}]},
    "/workflows/3/runs": {"workflow_runs": [
        wf_run("auto-rollback", 11, 600, "repository_dispatch", "auto-rollback home"),
        wf_run("auto-rollback", 12, 700, "repository_dispatch", "auto-rollback mealie"),
        wf_run("auto-rollback", 13, 10 * 86400, "repository_dispatch", "auto-rollback old")]},
    "/workflows/4/runs": {"workflow_runs": [
        wf_run("tofu", 21, 900, "schedule", "tofu"),
        wf_run("tofu", 22, 300, "pull_request", "tofu", branch="feat"),
        wf_run("tofu", 23, 1200, "push", "tofu", conclusion="failure")]},
    "/runs/11/jobs": {"jobs": [{"name": "decide", "conclusion": "success"}, {"name": "act", "conclusion": "success"}]},
    "/runs/12/jobs": {"jobs": [{"name": "decide", "conclusion": "success"}, {"name": "act", "conclusion": "skipped"}]},
    "/runs/21/jobs": {"jobs": [{"name": "plan", "conclusion": "success", "steps": []},
                               {"name": "apply", "conclusion": "success",
                                "steps": [{"name": "Drift corrected", "conclusion": "success"}]}]},
    "/runs/23/jobs": {"jobs": [{"name": "plan", "conclusion": "failure", "steps": []}]},
    "/issues": [],
    "state=open": [],
    "state=closed": [
        dict(pr(9, "renovate[bot]", 7200, 3600, merged=True), title="chore(deps): update x", html_url="https://github.com/o/r/pull/9"),
        dict(pr(10, "someone", 7200, 600, merged=True, labels=("auto-rollback",)),
             title="revert: feat(home): y (auto)", html_url="https://github.com/o/r/pull/10"),
        dict(pr(8, "someone", 30 * 86400, 20 * 86400, merged=True), title="feat(old): z", html_url="https://github.com/o/r/pull/8")],
}


def events_get(path):
    for key in sorted(EVENTS, key=lambda k: k != "/issues"):
        if key in path:
            return EVENTS[key], {"X-RateLimit-Remaining": "40"}
    raise AssertionError(path)


def event_labels(text: str) -> list[dict[str, str]]:
    out = []
    for line in text.splitlines():
        if line.startswith("automation_event_timestamp_seconds{"):
            out.append(dict(re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', line)))
    return out


def test_automation_events_from_github(tmp_path):
    mod = load()
    mod.get = events_get
    mod.SA_DIR = str(tmp_path / "none")
    ev = {(e["kind"], e["app"], e["result"]): e for e in event_labels(mod.collect())}
    assert ev[("renovate", "deps", "merged")]["what"] == "#9 chore(deps): update x"
    assert ev[("renovate", "deps", "merged")]["url"] == "https://github.com/o/r/pull/9"
    assert ("auto-rollback", "home", "merged") in ev
    assert ev[("auto-rollback", "home", "reverted")]["url"] == "https://github.com/o/r/actions/runs/11"
    assert ("auto-rollback", "mealie", "not reverted") in ev
    assert ("tofu-drift", "aws", "drift corrected") in ev
    assert ("tofu-apply", "aws", "failed") in ev
    # Older than the window, or a pull request's plan: not on the timeline.
    assert not any(e["app"] in ("old",) for e in ev.values())
    assert sum(1 for k in ev if k[0].startswith("tofu")) == 2


def test_jobs_reads_are_budgeted(tmp_path):
    mod = load()
    mod.get = events_get
    mod.SA_DIR = str(tmp_path / "none")
    mod.JOBS_PER_CYCLE = 1
    ev = {(e["kind"], e["app"], e["result"]) for e in event_labels(mod.collect())}
    # The newest run gets its jobs read; the next successful one says success
    # until a later collection, and a failed run is failed either way.
    assert ("auto-rollback", "home", "reverted") in ev
    assert ("auto-rollback", "mealie", "success") in ev
    assert ("tofu-drift", "aws", "success") in ev
    assert ("tofu-apply", "aws", "failed") in ev
    ev = {(e["kind"], e["app"], e["result"]) for e in event_labels(mod.collect())}
    assert ("auto-rollback", "mealie", "not reverted") in ev


def test_argocd_and_silence_events():
    mod = load()
    now = time.time()
    o = mod.Out()
    mod.argocd_events(o, {"items": [{"metadata": {"name": "mealie"}, "status": {
        "history": [{"deployedAt": iso(600), "revision": "a" * 40, "initiatedBy": {"automated": True}},
                    {"deployedAt": iso(400), "revisions": ["92.9.0", "c" * 40], "initiatedBy": {}},
                    # The same revision synced again: one series, not two.
                    {"deployedAt": iso(300), "revision": "a" * 40, "initiatedBy": {"automated": True}}],
        "operationState": {"phase": "Failed", "finishedAt": iso(60),
                           "syncResult": {"revisions": ["92.9.0", "b" * 40]}}}}]}, now)
    mod.silence_events(o, [{"startsAt": "2000-01-01T00:00:00.000Z", "endsAt": "2000-01-01T01:00:00.000Z",
                            "comment": "too old", "matchers": [], "status": {"state": "expired"}},
                           {"startsAt": iso(3600).replace("Z", ".276Z"), "endsAt": iso(0),
                            "comment": "maintenance: restart, PR #1",
                            "matchers": [{"name": "namespace", "value": "immich", "isEqual": True}],
                            "status": {"state": "expired"}}], now)
    ev = event_labels(o.text())
    assert {"source": "argocd", "kind": "sync", "app": "mealie", "what": "sync aaaaaaa", "result": "deployed",
            "url": "https://github.com/ned-si/homelab/commit/" + "a" * 40} in ev
    assert any(e["what"] == "sync ccccccc (manual)" for e in ev)
    assert {"source": "argocd", "kind": "sync", "app": "mealie", "what": "sync bbbbbbb", "result": "failed",
            "url": "https://argo.lilalala.com/applications/argo/mealie"} in ev
    assert {"source": "alertmanager", "kind": "silence", "app": "immich", "what": "maintenance: restart, PR #1 (1.0 h)",
            "result": "expired", "url": ""} in ev
    assert len(ev) == 4


def test_families_are_contiguous():
    mod = load()
    mod.get = fake_get
    seen, last = set(), None
    for line in mod.collect().splitlines():
        if line.startswith("#"):
            continue
        name = re.match(r"[a-z_0-9]+", line).group(0)
        if name != last:
            assert name not in seen, f"{name} split across the output"
            seen.add(name)
            last = name
