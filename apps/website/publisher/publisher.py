"""Nightly figures for the public dashboard at https://blog.nedsi.io/homelab/
(stdlib only).

Computes the previous day (Europe/Zurich) from Prometheus and the public
GitHub API, validates the document against schema.json and the shown apps of
config.json, then writes it as figures.json into the ConfigMap website-data,
which the site pod mounts read-only. Any failure exits 1 before the write, so
the ConfigMap keeps the last good figures. Only the apps of config.json are
ever queried. Design: .kiro/specs/public-website/design.md, "Public figures".
"""
from __future__ import annotations

import json
import math
import os
import re
import ssl
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

APP_DIR = os.environ.get("APP_DIR", os.path.dirname(os.path.abspath(__file__)))
PROM_URL = os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
GITHUB_API = os.environ.get("GITHUB_API", "https://api.github.com")
KUBE_API = os.environ.get("KUBE_API", "https://kubernetes.default.svc")
SA_DIR = os.environ.get("SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount")
NAMESPACE = os.environ.get("NAMESPACE", "website")
CONFIGMAP = os.environ.get("CONFIGMAP", "website-data")
KEY = "figures.json"
TZ = ZoneInfo("Europe/Zurich")
TIMEOUT = 10
DAYS = 30
# Download and indexer tooling: its uptime says when the downloads run.
HIDDEN = re.compile(r"sonarr|radarr|lidarr|readarr|prowlarr|bazarr|recyclarr|lazylibrarian|"
                    r"qbittorrent|torrent|jackett|flaresolverr|theater|arr$")
# CI runs read for the median: 3 pages of 100, newest first.
CI_PAGES = 3
VERSION = re.compile(r"v\d+\.\d+\.\d+")


class Fail(Exception):
    def __init__(self, figure: str, reason: str):
        super().__init__(f"{figure}: {reason}")
        self.figure = figure


def http_json(url: str, *, method: str = "GET", body: bytes | None = None,
              headers: dict | None = None, ctx: ssl.SSLContext | None = None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
        return json.loads(r.read().decode())


def load_config() -> dict:
    with open(os.path.join(APP_DIR, "config.json")) as f:
        cfg = json.load(f)
    for a in cfg["apps"]:
        if not re.fullmatch(r"[a-z][a-z0-9-]*", a["slo_app"]):
            raise Fail("config", f"slo_app {a['slo_app']!r} is not a plain label value")
        for field in ("id", "slo_app"):
            if HIDDEN.search(a[field]):
                raise Fail("config", f"{a[field]!r} is download or indexer tooling, never shown")
    return cfg


def window(now: datetime) -> tuple[str, datetime, datetime]:
    """`covers` (yesterday in Zurich) and the 30 days ending at its 24:00."""
    local = now.astimezone(TZ)
    end = datetime(local.year, local.month, local.day, tzinfo=TZ)
    covers = (end - timedelta(days=1)).date()
    start = datetime.combine(end.date() - timedelta(days=DAYS), datetime.min.time(), tzinfo=TZ)
    return covers.isoformat(), start, end


def prom(figure: str, query: str, at: datetime) -> list:
    qs = urllib.parse.urlencode({"query": query, "time": f"{at.timestamp():.0f}"})
    try:
        r = http_json(f"{PROM_URL}/api/v1/query?{qs}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Fail(figure, f"{type(e).__name__}: {e}") from e
    if r.get("status") != "success":
        raise Fail(figure, f"status {r.get('status')}: {r.get('error', '')}")
    return r["data"]["result"]


def by_app(result: list) -> dict[str, float]:
    return {s["metric"].get("app", ""): float(s["value"][1]) for s in result}


def pct_down(ratio: float) -> float:
    """Percent, one decimal, rounded down: an error never shows as 100.0."""
    return min(100.0, max(0.0, math.floor(ratio * 1000 + 1e-9) / 10))


def availability(cfg: dict, end: datetime) -> list[dict]:
    match = "|".join(a["slo_app"] for a in cfg["apps"])
    sel = f'{{app=~"{match}"}}'
    avail = by_app(prom("availability_30d", f"slo:availability:ratio_rate30d{sel}", end))
    budget = by_app(prom("error_budget_remaining_30d", f"slo:error_budget_remaining:ratio_rate30d{sel}", end))
    daily: list[dict[str, float]] = []
    for i in range(DAYS - 1, -1, -1):
        day_end = datetime.combine(end.date() - timedelta(days=i), datetime.min.time(), tzinfo=TZ)
        daily.append(by_app(prom("availability_daily", f"1 - slo:probe_error:ratio_rate1d{sel}", day_end)))
    out = []
    for a in cfg["apps"]:
        k = a["slo_app"]
        if k not in avail:
            raise Fail("availability_30d", f"no value for {a['id']}")
        if k not in budget:
            raise Fail("error_budget_remaining_30d", f"no value for {a['id']}")
        out.append({
            "id": a["id"],
            "name": a["name"],
            "availability_30d": pct_down(avail[k]),
            # -100 and below: the budget is exhausted (the page says so).
            "error_budget_remaining_30d": max(-100, min(100, round(budget[k] * 100))),
            # null: no probe that day (the app did not exist yet).
            "availability_daily": [pct_down(d[k]) if k in d else None for d in daily],
        })
    return out


def lowest_version(figure: str, result: list, label: str) -> str:
    found = []
    for s in result:
        m = VERSION.search(s["metric"].get(label, ""))
        if not m:
            raise Fail(figure, f"no version in {label} {s['metric'].get(label, '')!r}")
        found.append(m.group(0))
    if not found:
        raise Fail(figure, "empty result")
    # Mid-upgrade the nodes disagree: the lowest is what the whole cluster runs.
    return min(found, key=lambda v: tuple(int(x) for x in v[1:].split(".")))


def scalar(figure: str, query: str, at: datetime) -> int:
    r = prom(figure, query, at)
    if not r:
        raise Fail(figure, "empty result")
    return int(float(r[0]["value"][1]))


def cluster(end: datetime) -> dict:
    return {
        "nodes": scalar("nodes", "count(kube_node_info)", end),
        "apps": scalar("apps", "count(argocd_app_info)", end),
        "talos_version": lowest_version("talos_version", prom(
            "talos_version", "count by (os_image) (kube_node_info)", end), "os_image"),
        "kubernetes_version": lowest_version("kubernetes_version", prom(
            "kubernetes_version", "count by (kubelet_version) (kube_node_info)", end), "kubelet_version"),
    }


def github(figure: str, path: str) -> dict:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "homelab-website-publisher",
               "X-GitHub-Api-Version": "2022-11-28"}
    try:
        return http_json(f"{GITHUB_API}{path}", headers=headers)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Fail(figure, f"{type(e).__name__}: {e}") from e


def utc(t: datetime) -> str:
    return t.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")


def ts(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def merged_count(figure: str, repo: str, span: str, extra: str = "") -> int:
    q = f"repo:{repo} is:pr is:merged merged:{span}{extra}"
    r = github(figure, "/search/issues?" + urllib.parse.urlencode({"q": q, "per_page": 1}))
    if r.get("incomplete_results"):
        raise Fail(figure, "GitHub search returned incomplete results")
    return int(r["total_count"])


def project(cfg: dict, start: datetime, end: datetime) -> dict:
    repo = cfg["repo"]
    span = f"{utc(start)}..{utc(end - timedelta(seconds=1))}"
    merged = merged_count("prs_merged_30d", repo, span)
    renovate = merged_count("renovate_share_30d", repo, span, " author:app/renovate")
    walls = []
    for page in range(1, CI_PAGES + 1):
        qs = urllib.parse.urlencode({"status": "success", "created": span, "per_page": 100,
                                     "page": page, "exclude_pull_requests": "true"})
        runs = github("ci_median_seconds_30d",
                      f"/repos/{repo}/actions/workflows/{cfg['ci_workflow']}/runs?{qs}").get("workflow_runs", [])
        walls += [ts(r["updated_at"]) - ts(r["run_started_at"]) for r in runs if r.get("run_started_at")]
        if len(runs) < 100:
            break
    if not walls:
        raise Fail("ci_median_seconds_30d", "no successful run in the window")
    return {
        "prs_merged_30d": merged,
        "renovate_share_30d": round(100 * renovate / merged) if merged else 0,
        "ci_median_seconds_30d": max(1, round(statistics.median(walls))),
    }


def validate(value, schema: dict, path: str = "$") -> list[str]:
    """The JSON Schema keywords schema.json uses; tests keep the two in step."""
    errs: list[str] = []
    types = schema.get("type")
    if types is not None:
        types = types if isinstance(types, list) else [types]
        ok = {
            "object": isinstance(value, dict),
            "array": isinstance(value, list),
            "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool),
            "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "null": value is None,
        }
        if not any(ok[t] for t in types):
            return [f"{path}: not {'/'.join(types)}"]
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for k in schema.get("required", []):
            if k not in value:
                errs.append(f"{path}: missing key {k}")
        for k, v in value.items():
            if k in props:
                errs += validate(v, props[k], f"{path}.{k}")
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: extra key {k}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
            errs.append(f"{path}: {len(value)} items, want {schema.get('minItems')}-{schema.get('maxItems')}")
        for i, v in enumerate(value):
            errs += validate(v, schema.get("items", {}), f"{path}[{i}]")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{path}: {value} below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errs.append(f"{path}: {value} above {schema['maximum']}")
    if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
        errs.append(f"{path}: {value!r} does not match {schema['pattern']}")
    return errs


def check(doc: dict, cfg: dict) -> list[str]:
    with open(os.path.join(APP_DIR, "schema.json")) as f:
        errs = validate(doc, json.load(f))
    want = [(a["id"], a["name"]) for a in cfg["apps"]]
    got = [(a.get("id"), a.get("name")) for a in doc.get("apps", []) if isinstance(a, dict)]
    if got != want:
        errs.append(f"$.apps: {got} is not the shown apps of config.json")
    return errs


def build(now: datetime, cfg: dict) -> dict:
    covers, start, end = window(now)
    return {
        "covers": covers,
        "computed_at": now.astimezone(TZ).replace(second=0, microsecond=0).isoformat(),
        "apps": availability(cfg, end),
        "cluster": cluster(end),
        "project": project(cfg, start, end),
    }


def write(doc: dict) -> None:
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt")) if KUBE_API.startswith("https") else None
    # A merge patch of the one key: other keys of the ConfigMap stay.
    body = json.dumps({"data": {KEY: json.dumps(doc, separators=(",", ":"))}}).encode()
    try:
        http_json(f"{KUBE_API}/api/v1/namespaces/{NAMESPACE}/configmaps/{CONFIGMAP}", method="PATCH",
                  body=body, headers={"Authorization": f"Bearer {token}",
                                      "Content-Type": "application/merge-patch+json"}, ctx=ctx)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Fail("configmap", f"{type(e).__name__}: {e}") from e


def main(now: datetime | None = None) -> int:
    now = now or datetime.now(TZ)
    try:
        cfg = load_config()
        doc = build(now, cfg)
    except Fail as e:
        print(f"ERROR {e}", file=sys.stderr)
        return 1
    errs = check(doc, cfg)
    for e in errs:
        print(f"ERROR invalid: {e}", file=sys.stderr)
    if errs:
        return 1
    if os.environ.get("DRY_RUN"):
        print(json.dumps(doc, indent=2))
        return 0
    try:
        write(doc)
    except Fail as e:
        print(f"ERROR {e}", file=sys.stderr)
        return 1
    print(f"OK {CONFIGMAP}/{KEY} covers {doc['covers']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
