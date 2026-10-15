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
