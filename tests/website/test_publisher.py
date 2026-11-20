"""apps/website/publisher/publisher.py against a fake Prometheus, GitHub and
Kubernetes API (stdlib http.server, no network)."""
from __future__ import annotations

import importlib.util
import json
import re
import shutil
import threading
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

SRC = Path(__file__).resolve().parents[2] / "apps" / "website" / "publisher"
TZ = ZoneInfo("Europe/Zurich")
NOW = datetime(2026, 11, 20, 3, 30, 12, tzinfo=TZ)
# The blog exists for the last 5 days only.
BLOG_SINCE = datetime(2026, 11, 15, tzinfo=TZ).timestamp()
SUPPORTED = {"$schema", "title", "type", "properties", "required", "additionalProperties",
             "items", "minItems", "maxItems", "minimum", "maximum", "pattern"}


class Fake:
    def __init__(self):
        self.queries: list[str] = []
        self.github: list[str] = []
        self.patches: list[dict] = []
        self.prom_status = 200
        self.patch_status = 200
        self.github_status = 200
        self.avail = {"media": 0.99956, "cook": 0.9991, "archive": 0.9918, "cinema": 1.0,
                      "syncthing": 0.996, "auth": 0.9954, "nedsi": 0.9844, "blog": 0.9995}
        self.budget = {k: 1 - (1 - v) / 0.005 for k, v in self.avail.items()}
        self.os_images = ["Talos (v1.14.6)"] * 4
        self.kubelets = ["v1.37.2"] * 4
        self.nodes = 4
        self.runs = [600, 700, 900]

    def prom(self, query: str, at: float) -> list:
        apps = re.search(r'app=~"([^"]+)"', query)
        apps = apps.group(1).split("|") if apps else []

        def series(values: dict) -> list:
            return [{"metric": {"app": a}, "value": [at, str(values[a])]} for a in apps if a in values]
        if query.startswith("slo:availability:ratio_rate30d"):
            return series(self.avail)
        if query.startswith("slo:error_budget_remaining:ratio_rate30d"):
            return series(self.budget)
        if query.startswith("1 - slo:probe_error:ratio_rate1d"):
            return series({a: v for a, v in self.avail.items() if a != "blog" or at > BLOG_SINCE})
        if query == "count(kube_node_info)":
            return [{"metric": {}, "value": [at, str(self.nodes)]}]
        if query == "count(argocd_app_info)":
            return [{"metric": {}, "value": [at, "55"]}]
        if query == "count by (os_image) (kube_node_info)":
            return [{"metric": {"os_image": v}, "value": [at, "1"]} for v in sorted(set(self.os_images))]
        if query == "count by (kubelet_version) (kube_node_info)":
            return [{"metric": {"kubelet_version": v}, "value": [at, "1"]} for v in sorted(set(self.kubelets))]
        raise AssertionError(f"unexpected query {query}")


@pytest.fixture
def fake():
    state = Fake()

    class Handler(BaseHTTPRequestHandler):
        def reply(self, code: int, body) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            u = urllib.parse.urlparse(self.path)
            qs = dict(urllib.parse.parse_qsl(u.query))
            if u.path == "/api/v1/query":
                state.queries.append(qs["query"])
                if state.prom_status != 200:
                    return self.reply(state.prom_status, {"status": "error", "error": "boom"})
                return self.reply(200, {"status": "success", "data": {
                    "resultType": "vector", "result": state.prom(qs["query"], float(qs["time"]))}})
            state.github.append(self.path)
            if state.github_status != 200:
                return self.reply(state.github_status, {"message": "rate limited"})
            if u.path == "/search/issues":
                n = 120 if "author:app/renovate" in qs["q"] else 300
                return self.reply(200, {"total_count": n, "incomplete_results": False, "items": []})
            if u.path.endswith("/actions/workflows/ci.yaml/runs"):
                runs = [{"run_started_at": "2026-11-10T10:00:00Z",
                         "updated_at": datetime.fromtimestamp(
                             datetime(2026, 11, 10, 10, tzinfo=ZoneInfo("UTC")).timestamp() + s,
                             ZoneInfo("UTC")).isoformat().replace("+00:00", "Z")}
                        for s in state.runs]
                return self.reply(200, {"total_count": len(runs), "workflow_runs": runs})
            return self.reply(404, {})

        def do_PATCH(self):  # noqa: N802
            assert self.headers["Content-Type"] == "application/merge-patch+json"
            assert self.headers["Authorization"] == "Bearer test-token"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state.patches.append({"path": self.path, "body": body})
            self.reply(state.patch_status, {})

        def log_message(self, fmt, *args):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    state.url = f"http://127.0.0.1:{srv.server_address[1]}"
    yield state
    srv.shutdown()
    srv.server_close()


def load(monkeypatch, tmp_path, fake, app_dir: Path = SRC):
    sa = tmp_path / "sa"
    sa.mkdir()
    (sa / "token").write_text("test-token\n")
    for k, v in {"APP_DIR": str(app_dir), "PROM_URL": fake.url, "GITHUB_API": fake.url,
                 "KUBE_API": fake.url, "SA_DIR": str(sa)}.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("DRY_RUN", raising=False)
    spec = importlib.util.spec_from_file_location("website_publisher", SRC / "publisher.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    return mod, mod.main(NOW)


def published(fake) -> dict:
    assert len(fake.patches) == 1
    p = fake.patches[0]
    assert p["path"] == "/api/v1/namespaces/website/configmaps/website-data"
    assert list(p["body"]["data"]) == ["figures.json", "figures.html"]
    return json.loads(p["body"]["data"]["figures.json"])


def test_valid_figures(monkeypatch, tmp_path, fake):
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    doc = published(fake)
    assert list(doc) == ["covers", "computed_at", "apps", "cluster", "project"]
    assert doc["covers"] == "2026-11-19"
    assert doc["computed_at"] == "2026-11-20T03:30:00+01:00"
    apps = {a["id"]: a for a in doc["apps"]}
    assert apps["immich"]["availability_30d"] == 99.9
    assert apps["jellyfin"]["availability_30d"] == 100.0
    assert apps["paperless"]["error_budget_remaining_30d"] == -64
    assert all(len(a["availability_daily"]) == 30 for a in doc["apps"])
    blog = apps["blog"]["availability_daily"]
    assert blog[:25] == [None] * 25 and None not in blog[25:]
    assert doc["cluster"] == {"nodes": 4, "apps": 55, "talos_version": "v1.14.6", "kubernetes_version": "v1.37.2"}
    assert doc["project"] == {"prs_merged_30d": 300, "renovate_share_30d": 40, "ci_median_seconds_30d": 700}


def test_only_shown_apps_are_queried(monkeypatch, tmp_path, fake):
    mod, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    cfg = json.loads((SRC / "config.json").read_text())
    shown = {a["slo_app"] for a in cfg["apps"]}
    for q in fake.queries:
        m = re.search(r'app=~"([^"]+)"', q)
        if m:
            assert set(m.group(1).split("|")) == shown
    assert not any(mod.HIDDEN.search(q) for q in fake.queries)


def test_github_window_is_the_30_days(monkeypatch, tmp_path, fake):
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    span = "2026-10-20T22:00:00Z..2026-11-19T22:59:59Z"
    searches = [urllib.parse.parse_qs(urllib.parse.urlparse(p).query)["q"][0]
                for p in fake.github if p.startswith("/search/")]
    assert searches == [f"repo:ned-si/homelab is:pr is:merged merged:{span}",
                        f"repo:ned-si/homelab is:pr is:merged merged:{span} author:app/renovate"]
    runs = [p for p in fake.github if "/actions/" in p]
    assert len(runs) == 1 and urllib.parse.quote(span, safe="") in runs[0]


def test_config_never_shows_download_tooling(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    cfg = json.loads((SRC / "config.json").read_text())
    for a in cfg["apps"]:
        assert not mod.HIDDEN.search(a["id"]) and not mod.HIDDEN.search(a["slo_app"]), a
    for name in ("sonarr", "radarr", "lidarr", "prowlarr", "bazarr", "recyclarr", "lazylibrarian",
                 "qbittorrent", "theater"):
        assert mod.HIDDEN.search(name), name


@pytest.mark.parametrize("app", [{"id": "sonarr", "name": "Sonarr", "slo_app": "sonarr"},
                                 {"id": "downloads", "name": "Downloads", "slo_app": "qbittorrent"},
                                 {"id": "media2", "name": "Media", "slo_app": 'media"} or vector(1'}])
def test_config_with_a_hidden_app_fails(monkeypatch, tmp_path, fake, app):
    d = tmp_path / "app"
    shutil.copytree(SRC, d)
    cfg = json.loads((d / "config.json").read_text())
    cfg["apps"].append(app)
    (d / "config.json").write_text(json.dumps(cfg))
    mod = load(monkeypatch, tmp_path, fake, app_dir=d)
    assert mod.main(NOW) == 1
    assert fake.queries == [] and fake.patches == []


def test_prometheus_unreachable(monkeypatch, tmp_path, fake, capsys):
    mod = load(monkeypatch, tmp_path, fake)
    mod.PROM_URL = "http://127.0.0.1:9"
    assert mod.main(NOW) == 1
    assert "ERROR availability_30d: " in capsys.readouterr().err
    assert fake.patches == []


def test_prometheus_error_status(monkeypatch, tmp_path, fake, capsys):
    fake.prom_status = 500
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR availability_30d: HTTPError" in capsys.readouterr().err


def test_missing_app_value(monkeypatch, tmp_path, fake, capsys):
    del fake.avail["cook"]
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR availability_30d: no value for mealie" in capsys.readouterr().err


def test_empty_cluster_figure(monkeypatch, tmp_path, fake, capsys):
    fake.os_images = []
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR talos_version: empty result" in capsys.readouterr().err


def test_github_failure(monkeypatch, tmp_path, fake, capsys):
    fake.github_status = 403
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR prs_merged_30d: HTTPError" in capsys.readouterr().err


def test_no_ci_runs(monkeypatch, tmp_path, fake, capsys):
    fake.runs = []
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR ci_median_seconds_30d: no successful run" in capsys.readouterr().err


def test_configmap_write_fails(monkeypatch, tmp_path, fake, capsys):
    fake.patch_status = 403
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1
    assert "ERROR configmap: HTTPError" in capsys.readouterr().err


def test_out_of_range_is_never_written(monkeypatch, tmp_path, fake, capsys):
    fake.nodes = 11
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR invalid: $.cluster.nodes: 11 above 10" in capsys.readouterr().err


def test_budget_below_minus_100_is_clamped(monkeypatch, tmp_path, fake):
    fake.avail["archive"] = 0.9
    fake.budget["archive"] = -19.0
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    apps = {a["id"]: a for a in published(fake)["apps"]}
    assert apps["paperless"]["error_budget_remaining_30d"] == -100


@pytest.mark.parametrize("images,want", [
    (["Talos (v1.14.5)", "Talos (v1.14.6)"], "v1.14.5"),
    (["Talos (v1.10.0)", "Talos (v1.9.3)"], "v1.9.3"),
])
def test_mid_upgrade_takes_the_lowest_version(monkeypatch, tmp_path, fake, images, want):
    fake.os_images = images
    fake.kubelets = ["v1.37.2", "v1.36.4"]
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    c = published(fake)["cluster"]
    assert c["talos_version"] == want and c["kubernetes_version"] == "v1.36.4"


def test_bad_version_string(monkeypatch, tmp_path, fake, capsys):
    fake.kubelets = ["1.37"]
    _, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 1 and fake.patches == []
    assert "ERROR kubernetes_version: no version" in capsys.readouterr().err


def test_check_rejects_extra_key_and_extra_app(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    cfg = mod.load_config()
    doc = mod.build(NOW, cfg)
    assert mod.check(doc, cfg) == []
    extra = dict(doc, solar_consumption_w=300)
    assert "$: extra key solar_consumption_w" in mod.check(extra, cfg)
    more = dict(doc, apps=doc["apps"] + [dict(doc["apps"][0], id="sonarr", name="Sonarr")])
    assert any("not the shown apps" in e for e in mod.check(more, cfg))
    inner = json.loads(json.dumps(doc))
    inner["cluster"]["node_ips"] = ["192.168.1.247"]
    assert "$.cluster: extra key node_ips" in mod.check(inner, cfg)
    missing = {k: v for k, v in doc.items() if k != "project"}
    assert "$: missing key project" in mod.check(missing, cfg)


def test_dry_run_writes_nothing(monkeypatch, tmp_path, fake, capsys):
    mod = load(monkeypatch, tmp_path, fake)
    monkeypatch.setenv("DRY_RUN", "1")
    assert mod.main(NOW) == 0
    assert fake.patches == []
    assert json.loads(capsys.readouterr().out)["covers"] == "2026-11-19"


def test_window_across_dst(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    covers, start, end = mod.window(datetime(2026, 3, 30, 3, 30, tzinfo=TZ))
    assert covers == "2026-03-29"
    assert (start.isoformat(), end.isoformat()) == ("2026-02-28T00:00:00+01:00", "2026-03-30T00:00:00+02:00")


FIXTURE = Path(__file__).with_name("figures.json")


def test_published_html_is_the_render_of_the_figures(monkeypatch, tmp_path, fake):
    mod, rc = run(monkeypatch, tmp_path, fake)
    assert rc == 0
    doc = published(fake)
    assert fake.patches[0]["body"]["data"]["figures.html"] == mod.render(doc)


def test_fixture_is_valid(monkeypatch, tmp_path, fake):
    """site-serve-check.sh renders this fixture into the page."""
    mod = load(monkeypatch, tmp_path, fake)
    assert mod.check(json.loads(FIXTURE.read_text()), mod.load_config()) == []


def test_render(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    out = mod.render(json.loads(FIXTURE.read_text()))
    assert '<time datetime="2026-11-19">19 November 2026</time>' in out
    assert '<time datetime="2026-11-20T03:30:00+01:00">20 November 2026, 03:30</time>' in out
    assert '<th scope="row">Paperless-ngx</th><td>99.1%</td><td>-62%</td>' in out
    assert '<th scope="row">Landing page</th><td>98.1%</td><td>exhausted</td>' in out
    assert "<dt>Talos</dt><dd>v1.14.6</dd>" in out and "<dt>Kubernetes</dt><dd>v1.37.2</dd>" in out
    assert "<dt>Pull requests merged</dt><dd>709</dd>" in out
    assert "<dt>Opened by Renovate</dt><dd>50%</dd>" in out
    assert "<dt>Median CI run</dt><dd>5 min 05 s</dd>" in out
    assert out.count('<svg class="spark"') == 8
    assert 'aria-label="Daily availability, lowest 83.9%"' in out


def test_render_is_safe_markup(monkeypatch, tmp_path, fake):
    """No script, style or event handler, nothing from another origin, no
    address, and no hidden app (the CSP and site_markup.py rules)."""
    mod = load(monkeypatch, tmp_path, fake)
    out = mod.render(json.loads(FIXTURE.read_text()))
    low = out.lower()
    for bad in ("<script", "style=", "<!--", "http:", "https:", "//"):
        assert bad not in low, bad
    assert not re.search(r"<[^>]*\son\w+=", low)
    assert not re.search(r"\d+\.\d+\.\d+\.\d+", out)
    assert not mod.HIDDEN.search(re.sub(r"<[^>]+>", " ", low))


def test_render_escapes_strings(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    doc = json.loads(FIXTURE.read_text())
    doc["apps"][0]["name"] = '<img src=x onerror="a">'
    out = mod.render(doc)
    assert "<img" not in out and "&lt;img src=x onerror=&quot;a&quot;&gt;" in out


def test_sparkline_gaps_and_floor(monkeypatch, tmp_path, fake):
    mod = load(monkeypatch, tmp_path, fake)
    # A null day splits the line; a lone day is a dot; 90 % and below sit on the bottom.
    svg = mod.sparkline([100.0, 50.0] + [None] * 26 + [95.0, None])
    assert svg.count("<polyline") == 1 and svg.count("<circle") == 1
    assert 'points="0.0,0.0 4.1,24.0"' in svg
    assert '<circle cx="115.9" cy="12.0" r="1.5"/>' in svg
    assert 'aria-label="Daily availability, lowest 50.0%"' in svg
    empty = mod.sparkline([None] * 30)
    assert "<polyline" not in empty and 'aria-label="No daily values yet"' in empty


def test_schema_uses_only_supported_keywords():
    def walk(s):
        assert set(s) <= SUPPORTED, set(s) - SUPPORTED
        for v in s.get("properties", {}).values():
            walk(v)
        if "items" in s:
            walk(s["items"])
    schema = json.loads((SRC / "schema.json").read_text())
    walk(schema)
    assert schema["additionalProperties"] is False
