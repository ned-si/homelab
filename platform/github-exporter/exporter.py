"""GitHub CI/CD and automation-history exporter for one repository (stdlib only).

Every INTERVAL seconds it reads, from the public GitHub REST API: the
workflows and the last 30 runs of each, open pull requests, the 100 most
recently updated closed pull requests, and Renovate's Dependency Dashboard
issue; then serves the derived gauges on :PORT/metrics. About 11 requests per
cycle; conditional requests (ETag, a 304 is free) keep that well inside the
unauthenticated quota of 60 requests/hour per IP. The repository is public,
so no credential is used. For auto-rollback (also while it is disabled) and
tofu it reads their last runs on main, and the jobs of each completed run
once.

For the Homelab / Automation dashboard it also writes one series per event of
the last EVENT_DAYS days, automation_event_timestamp_seconds{source, kind,
app, what, result, url} with the time of the event as the value: merged pull
requests, auto-rollback and tofu runs from GitHub; from inside the cluster,
the Argo CD syncs (Application status: history and the last operation, read
with the pod's ServiceAccount, list only) and the Alertmanager silences
(ALERTMANAGER_URL, no authentication). A source that fails is skipped and
reported in automation_source_up.

Logs are JSON lines on stdout.
"""
from __future__ import annotations

import json
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.environ.get("REPO", "ned-si/homelab")
INTERVAL = int(os.environ.get("INTERVAL", "900"))
PORT = int(os.environ.get("PORT", "9171"))
API = "https://api.github.com"
RENOVATE = "renovate[bot]"
WINDOW = 30 * 86400
EVENT_WINDOW = int(os.environ.get("EVENT_DAYS", "7")) * 86400
# Workflows whose runs are automation events, and how many runs of each.
TIMELINE_WORKFLOWS = ("auto-rollback", "tofu")
TIMELINE_RUNS = 15
ALERTMANAGER_URL = os.environ.get("ALERTMANAGER_URL", "")
ARGO_NAMESPACE = os.environ.get("ARGO_NAMESPACE", "argo")
ARGO_URL = os.environ.get("ARGO_URL", "https://argo.lilalala.com")
KUBE_API = os.environ.get("KUBE_API", "https://kubernetes.default.svc")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
# Syncs per Application on the timeline.
ARGO_HISTORY = 3

_etags: dict[str, tuple[str, object]] = {}
_jobs: dict[int, list] = {}
JOBS_PER_CYCLE = 5
_jobs_budget = JOBS_PER_CYCLE
_metrics = "# no data yet\n"
_lock = threading.Lock()


def log(level: str, msg: str, **kw) -> None:
    rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "level": level, "msg": msg}
    rec.update(kw)
    print(json.dumps(rec), flush=True)


def get(path: str):
    """GET with ETag caching; returns (json, rate-limit headers)."""
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "homelab-github-exporter",
    })
    cached = _etags.get(path)
    if cached:
        req.add_header("If-None-Match", cached[0])
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = json.load(r)
            if r.headers.get("ETag"):
                _etags[path] = (r.headers["ETag"], body)
            return body, r.headers
    except urllib.error.HTTPError as e:
        if e.code == 304 and cached:
            return cached[1], e.headers
        raise


def ts(s: str | None) -> float:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() if s else 0.0


def esc(v: str) -> str:
    return str(v).replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


class Out:
    """Gauges grouped per metric family, as the text format requires. A
    series written twice (two syncs of the same revision) keeps the larger
    value: a scrape must not repeat a series."""

    def __init__(self):
        self.families: dict[str, tuple[str, dict[str, float]]] = {}

    def g(self, name: str, help_: str, value: float, **labels) -> None:
        series = self.families.setdefault(name, (help_, {}))[1]
        lab = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
        key = f"{name}{{{lab}}}" if lab else name
        series[key] = max(value, series.get(key, value))

    def text(self) -> str:
        lines = []
        for name, (help_, series) in self.families.items():
            lines += [f"# HELP {name} {help_}", f"# TYPE {name} gauge"]
            lines += [f"{key} {value}" for key, value in series.items()]
        return "\n".join(lines) + "\n"


def started(r: dict) -> float:
    return ts(r.get("run_started_at") or r.get("created_at"))


def ts_any(s: str | None) -> float:
    """RFC 3339 with or without fractional seconds; 0 when missing."""
    if not s:
        return 0.0
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def event(o: Out, when: float, source: str, kind: str, app: str, what: str, result: str, url: str) -> None:
    o.g("automation_event_timestamp_seconds",
        "One automation event of the last days (Homelab / Automation dashboard); the value is when it happened.",
        when, source=source, kind=kind, app=app, what=what[:120], result=result, url=url)


def title_scope(title: str) -> str:
    """The Conventional Commits scope of a title: `feat(backups): x` -> backups."""
    m = re.match(r"^(?:revert: )?\w+\(([^)]+)\)!?:", title or "")
    return m.group(1) if m else ""


def run_jobs(run_id: int) -> list | None:
    """The jobs of a completed run; they never change, so each run is read
    once. At most JOBS_PER_CYCLE reads per collection, so that a restart (an
    empty cache) stays inside the unauthenticated quota; None until read."""
    global _jobs_budget
    if run_id not in _jobs:
        if _jobs_budget <= 0:
            return None
        _jobs_budget -= 1
        try:
            body, _ = get(f"/repos/{REPO}/actions/runs/{run_id}/jobs?per_page=20")
        except urllib.error.HTTPError as e:
            log("error", "jobs read failed", run=run_id, error=f"HTTP {e.code}")
            _jobs_budget = 0
            return None
        _jobs[run_id] = body.get("jobs", [])
    return _jobs[run_id]


def run_result(workflow: str, r: dict) -> tuple[str, str, str]:
    """(kind, app, result) of an auto-rollback or tofu run. Until its jobs are
    read, a successful run says `success`."""
    listed = run_jobs(r["id"])
    jobs = {j.get("name"): j for j in listed or []}
    concl = r.get("conclusion") or "unknown"
    if listed is None and concl == "success":
        if workflow == "auto-rollback":
            return "auto-rollback", (r.get("display_title") or "").removeprefix("auto-rollback ").strip(), "success"
        return {"schedule": "tofu-drift", "push": "tofu-apply"}.get(r.get("event", ""), "tofu-manual"), "aws", "success"
    if workflow == "auto-rollback":
        app = (r.get("display_title") or "").removeprefix("auto-rollback ").strip()
        act = (jobs.get("act") or {}).get("conclusion")
        if concl != "success":
            result = "failed"
        elif act == "success":
            result = "reverted"
        elif act == "failure":
            result = "revert failed"
        else:
            result = "not reverted"
        if r.get("event") == "workflow_dispatch":
            result = "manual: " + result
        return "auto-rollback", app, result
    kind = {"schedule": "tofu-drift", "push": "tofu-apply"}.get(r.get("event", ""), "tofu-manual")
    steps = {s.get("name"): s.get("conclusion") for j in jobs.values() for s in j.get("steps", [])}
    if concl != "success":
        result = "failed"
    elif steps.get("Drift corrected") == "success":
        result = "drift corrected"
    elif (jobs.get("apply") or {}).get("conclusion") == "success":
        result = "applied"
    else:
        result = "no changes"
    return kind, "aws", result


def kube_get(path: str):
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    req = urllib.request.Request(KUBE_API + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20, context=ctx) as r:
        return json.load(r)


def homelab_revision(revs: list) -> str:
    """The first full commit SHA among an Application's revisions (a chart version is not one)."""
    return next((r for r in revs if re.fullmatch(r"[0-9a-f]{40}", r or "")), "")


def argocd_events(o: Out, apps: dict, now: float) -> None:
    for a in apps.get("items", []):
        name = a["metadata"]["name"]
        status = a.get("status", {})
        app_url = f"{ARGO_URL}/applications/{ARGO_NAMESPACE}/{name}"
        for h in (status.get("history") or [])[-ARGO_HISTORY:]:
            when = ts_any(h.get("deployedAt"))
            if now - when > EVENT_WINDOW:
                continue
            rev = homelab_revision([h.get("revision", "")] + (h.get("revisions") or []))
            manual = not (h.get("initiatedBy") or {}).get("automated")
            event(o, when, "argocd", "sync", name, f"sync {rev[:7] or 'chart'}" + (" (manual)" if manual else ""),
                  "deployed", f"https://github.com/{REPO}/commit/{rev}" if rev else app_url)
        op = status.get("operationState") or {}
        when = ts_any(op.get("finishedAt"))
        if op.get("phase") in ("Failed", "Error") and now - when <= EVENT_WINDOW:
            res = op.get("syncResult") or {}
            rev = homelab_revision([res.get("revision", "")] + (res.get("revisions") or []))
            event(o, when, "argocd", "sync", name, f"sync {rev[:7] or 'chart'}", op["phase"].lower(), app_url)


def silence_events(o: Out, silences: list, now: float) -> None:
    for s in silences:
        when = ts_any(s.get("startsAt"))
        if now - when > EVENT_WINDOW:
            continue
        m = {x.get("name"): x.get("value") for x in s.get("matchers", []) if x.get("isEqual", True)}
        target = m.get("namespace") or (f"node/{m['node']}" if m.get("node") else "cluster")
        hours = max(0.0, ts_any(s.get("endsAt")) - when) / 3600
        event(o, when, "alertmanager", "silence", target, f"{s.get('comment', '')} ({hours:.1f} h)",
              (s.get("status") or {}).get("state", "unknown"), "")


def collect() -> str:
    global _jobs_budget
    _jobs_budget = JOBS_PER_CYCLE
    now = time.time()
    o = Out()
    workflows, hdr = get(f"/repos/{REPO}/actions/workflows?per_page=50")
    for w in workflows.get("workflows", []):
        if not w.get("path", "").startswith(".github/workflows/"):
            continue
        # A timeline workflow keeps its history while disabled (auto-rollback
        # is, during a planned window).
        if w.get("state") != "active" and w.get("name") not in TIMELINE_WORKFLOWS:
            continue
        runs, hdr = get(f"/repos/{REPO}/actions/workflows/{w['id']}/runs?per_page=30")
        done = [r for r in runs.get("workflow_runs", [])
                if r.get("status") == "completed" and now - started(r) <= WINDOW]
        if not done:
            continue
        wf = w["name"]
        counts: dict[str, int] = {}
        for r in done:
            c = r.get("conclusion") or "unknown"
            counts[c] = counts.get(c, 0) + 1
        for c, n in sorted(counts.items()):
            o.g("github_workflow_runs", "Completed runs among the last 30 (30 days), by conclusion.", n,
                workflow=wf, conclusion=c)
        ok = [ts(r["updated_at"]) - started(r) for r in done if r.get("conclusion") == "success"]
        if ok:
            o.g("github_workflow_success_duration_seconds_avg", "Mean duration of those runs that succeeded.",
                round(sum(ok) / len(ok), 1), workflow=wf)
        for scope, pool in (("any", done), ("main", [r for r in done if r.get("head_branch") == "main"])):
            if not pool:
                continue
            r = max(pool, key=started)
            concl = r.get("conclusion") or "unknown"
            o.g("github_workflow_last_success", "1 if the latest completed run succeeded (scope any or main).",
                1 if concl == "success" else 0, workflow=wf, scope=scope, conclusion=concl, event=r.get("event", ""))
            o.g("github_workflow_last_run_timestamp_seconds", "Start of the latest completed run.",
                started(r), workflow=wf, scope=scope)
            o.g("github_workflow_last_run_duration_seconds", "Duration of the latest completed run.",
                max(0.0, ts(r["updated_at"]) - started(r)), workflow=wf, scope=scope)
        if wf in TIMELINE_WORKFLOWS:
            # The runs on main only: pull request plans would crowd the
            # scheduled and merge runs out of the last 30.
            main_runs, _ = get(f"/repos/{REPO}/actions/workflows/{w['id']}/runs?per_page={TIMELINE_RUNS}&branch=main")
            recent = [r for r in sorted(main_runs.get("workflow_runs", []), key=started, reverse=True)
                      if r.get("status") == "completed" and now - started(r) <= EVENT_WINDOW
                      and r.get("event") != "pull_request"]
            for r in recent[:TIMELINE_RUNS]:
                kind, app, result = run_result(wf, r)
                event(o, ts(r["updated_at"]), "github", kind, app, r.get("display_title") or wf, result,
                      r.get("html_url", ""))

    open_prs, _ = get(f"/repos/{REPO}/pulls?state=open&per_page=100")
    by_author: dict[str, int] = {}
    for p in open_prs:
        author = "renovate" if p["user"]["login"] == RENOVATE else "other"
        by_author[author] = by_author.get(author, 0) + 1
        o.g("github_pull_request_open_age_seconds", "Age of each open pull request.",
            round(now - ts(p["created_at"])), number=str(p["number"]), branch=p["head"]["ref"], author=author,
            draft=str(bool(p.get("draft"))).lower())
    for author in ("renovate", "other"):
        o.g("github_pull_requests_open", "Open pull requests.", by_author.get(author, 0), author=author)

    closed, _ = get(f"/repos/{REPO}/pulls?state=closed&sort=updated&direction=desc&per_page=100")
    agg = {"merged": {}, "closed": {}}
    lead: list[float] = []
    rollbacks = 0
    for p in closed:
        if not p.get("closed_at") or now - ts(p["closed_at"]) > WINDOW:
            continue
        author = "renovate" if p["user"]["login"] == RENOVATE else "other"
        state = "merged" if p.get("merged_at") else "closed"
        agg[state][author] = agg[state].get(author, 0) + 1
        if state == "merged" and author == "renovate":
            lead.append(ts(p["merged_at"]) - ts(p["created_at"]))
        revert = any(lb["name"] == "auto-rollback" for lb in p.get("labels", []))
        if revert:
            rollbacks += 1
        if state == "merged" and now - ts(p["merged_at"]) <= EVENT_WINDOW:
            title = p.get("title") or f"#{p['number']}"
            event(o, ts(p["merged_at"]), "github",
                  "auto-rollback" if revert else ("renovate" if author == "renovate" else "pull-request"),
                  title_scope(title), f"#{p['number']} {title}", "merged", p.get("html_url", ""))
    for state in ("merged", "closed"):
        for author in ("renovate", "other"):
            o.g("github_pull_requests_closed_30d",
                "Pull requests closed in the last 30 days (of the 100 most recently updated), merged or not.",
                agg[state].get(author, 0), state=state, author=author)
    o.g("github_auto_rollback_pull_requests_30d", "Pull requests labelled auto-rollback closed in the last 30 days.",
        rollbacks)
    o.g("github_auto_rollback_pull_requests_open", "Open pull requests labelled auto-rollback.",
        sum(1 for p in open_prs if any(lb["name"] == "auto-rollback" for lb in p.get("labels", []))))
    if lead:
        o.g("github_renovate_merge_lead_time_seconds_avg_30d", "Mean time from opening to merge of Renovate PRs.",
            round(sum(lead) / len(lead)))

    issues, _ = get(f"/repos/{REPO}/issues?state=open&creator={urllib.request.quote(RENOVATE)}&per_page=20")
    dash = next((i for i in issues if i.get("title") == "Dependency Dashboard"), None)
    if dash:
        section = "none"
        sections: dict[str, int] = {}
        for line in (dash.get("body") or "").splitlines():
            m = re.match(r"^##\s+(.+?)\s*$", line)
            if m:
                section = m.group(1)
                continue
            if re.match(r"^\s*- \[[ x]\] ", line) and "manual job" not in line:
                sections[section] = sections.get(section, 0) + 1
        for name, n in sorted(sections.items()):
            o.g("github_renovate_dashboard_entries", "Entries per section of Renovate's Dependency Dashboard.",
                n, section=name)

    o.g("github_ratelimit_remaining", "GitHub API requests left in the current window.",
        float(hdr.get("X-RateLimit-Remaining", "-1")))

    # In-cluster sources: each optional, one failing does not hide the rest.
    sources = []
    if os.path.exists(f"{SA_DIR}/token"):
        sources.append(("argocd", lambda: argocd_events(
            o, kube_get(f"/apis/argoproj.io/v1alpha1/namespaces/{ARGO_NAMESPACE}/applications"), now)))
    if ALERTMANAGER_URL:
        sources.append(("alertmanager", lambda: silence_events(o, http_json(f"{ALERTMANAGER_URL}/api/v2/silences"), now)))
    for name, fn in sources:
        try:
            fn()
            up = 1
        except Exception as e:  # noqa: BLE001 -- reported, the rest still collects
            up = 0
            log("error", "source failed", source=name, error=f"{type(e).__name__}: {e}")
        o.g("automation_source_up", "1 if the in-cluster event source answered in the last collection.", up,
            source=name)
    return o.text()


def http_json(url: str):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json"}),
                                timeout=20) as r:
        return json.load(r)


def loop() -> None:
    global _metrics
    last_ok = 0.0
    while True:
        started = time.time()
        try:
            body = collect()
            last_ok = time.time()
            up = 1
            log("info", "collected", repo=REPO, seconds=round(last_ok - started, 2))
        except Exception as e:  # keep serving the previous data
            body = None
            up = 0
            log("error", "collect failed", repo=REPO, error=f"{type(e).__name__}: {e}")
        tail = (f"# TYPE github_exporter_up gauge\ngithub_exporter_up {up}\n"
                f"# TYPE github_exporter_last_success_timestamp_seconds gauge\n"
                f"github_exporter_last_success_timestamp_seconds {last_ok}\n")
        with _lock:
            if body is not None:
                _metrics = body
            _metrics = re.sub(r"(?s)# TYPE github_exporter_up.*\Z", "", _metrics) + tail
        time.sleep(max(60, INTERVAL - (time.time() - started)))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/metrics":
            with _lock:
                data = _metrics.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        elif self.path == "/healthz":
            data = b"ok\n"
            self.send_response(200)
        else:
            data = b"not found\n"
            self.send_response(404)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # scrapes are not logged
        pass


if __name__ == "__main__":
    log("info", "starting", repo=REPO, interval=INTERVAL, port=PORT)
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
