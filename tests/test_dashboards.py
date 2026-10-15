"""Checks for the Grafana dashboards in platform/kube-prometheus-stack/dashboards.

Structure only: every file is valid JSON, uids are unique and stable, every
panel and target uses the `${datasource}` variable, panel ids are unique and
panels do not overlap. When promtool is on PATH (CI), every PromQL expression
is also parsed by `promtool check rules`.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
DASH_DIR = REPO / "platform" / "kube-prometheus-stack" / "dashboards"
DASHBOARDS = sorted(DASH_DIR.glob("*.json"))
EXPECTED_UIDS = {"homelab-overview", "homelab-security", "homelab-nodes"}


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def all_panels(board: dict) -> list[dict]:
    out = []
    for p in board.get("panels", []):
        out.append(p)
        out.extend(p.get("panels", []))
    return out


def annotations(board: dict) -> list[dict]:
    return board.get("annotations", {}).get("list", [])


def exprs(board: dict) -> list[str]:
    panel = [t["expr"] for p in all_panels(board) for t in p.get("targets", []) if "expr" in t]
    return panel + [a["expr"] for a in annotations(board) if "expr" in a]


@pytest.mark.parametrize("path", DASHBOARDS, ids=lambda p: p.name)
def test_annotations_use_the_variable(path):
    for a in annotations(load(path)):
        assert a.get("datasource", {}).get("uid") == "${datasource}", a["name"]
        assert a.get("expr", "").strip(), a["name"]


def test_expected_dashboards_present():
    assert {load(p)["uid"] for p in DASHBOARDS} == EXPECTED_UIDS


def test_kustomization_lists_every_file():
    kust = (DASH_DIR / "kustomization.yaml").read_text()
    for p in DASHBOARDS:
        assert f"- {p.name}" in kust, f"{p.name} is not in the configMapGenerator"


@pytest.mark.parametrize("path", DASHBOARDS, ids=lambda p: p.name)
def test_datasource_is_the_variable(path):
    board = load(path)
    names = [v["name"] for v in board["templating"]["list"] if v.get("type") == "datasource"]
    assert names == ["datasource"]
    for p in all_panels(board):
        if p["type"] in ("row", "text"):
            continue
        assert p.get("datasource", {}).get("uid") == "${datasource}", p["title"]
        for t in p["targets"]:
            assert t.get("datasource", {}).get("uid") == "${datasource}", p["title"]


@pytest.mark.parametrize("path", DASHBOARDS, ids=lambda p: p.name)
def test_panel_ids_unique_and_no_overlap(path):
    panels = all_panels(load(path))
    ids = [p["id"] for p in panels]
    assert len(ids) == len(set(ids))
    cells = {}
    for p in panels:
        g = p["gridPos"]
        assert 0 <= g["x"] and g["x"] + g["w"] <= 24, p["title"]
        for x in range(g["x"], g["x"] + g["w"]):
            for y in range(g["y"], g["y"] + g["h"]):
                assert (x, y) not in cells, f"{p['title']} overlaps {cells[(x, y)]}"
                cells[(x, y)] = p["title"]


@pytest.mark.parametrize("path", DASHBOARDS, ids=lambda p: p.name)
def test_every_query_panel_has_an_expression(path):
    for p in all_panels(load(path)):
        if p["type"] in ("row", "text"):
            continue
        assert p["targets"], p["title"]
        assert all(t.get("expr", "").strip() for t in p["targets"]), p["title"]


def test_promql_parses(tmp_path):
    if shutil.which("promtool") is None:
        pytest.skip("promtool not installed (CI installs it in the render job)")
    rules = []
    for path in DASHBOARDS:
        for i, e in enumerate(exprs(load(path))):
            # Dashboard variables are not PromQL; none are used in queries today.
            assert "$" not in e, f"{path.name}: template variable in query: {e}"
            rules.append({"record": f"dashboard:check:{path.stem.replace('-', '_')}_{i}", "expr": e})
    f = tmp_path / "dashboards.rules.json"
    f.write_text(json.dumps({"groups": [{"name": "dashboards", "rules": rules}]}))
    r = subprocess.run(["promtool", "check", "rules", str(f)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
