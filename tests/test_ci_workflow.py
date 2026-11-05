"""The `ci` job aggregates every other job of ci.yaml.

`ci` is the only required check: a job missing from its `needs` or from its
result loop could fail without failing `ci`.
"""
from __future__ import annotations

import json
import re
import subprocess

from conftest import REPO

CI = REPO / ".github" / "workflows" / "ci.yaml"
# Jobs that may be skipped by their own `if:`; `ci` accepts them skipped only
# in the cases its loop names.
CONDITIONAL = {"pr-metadata", "talos-upgrade"}
SPLIT = ("render", "tests")
INSTALL = re.compile(r"scripts/ci/install-tool\.sh ([a-z -]+)")
VERSION_REF = re.compile(r"\$\{\{ env\.([A-Z_]+)_VERSION \}\}")


def yaml_json(path):
    out = subprocess.run(["yq", "-o=json", ".", str(path)], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def jobs():
    return yaml_json(CI)["jobs"]


def loop_jobs(js):
    run = "\n".join(s.get("run", "") for s in js["ci"]["steps"])
    m = re.search(r"for j in ([^;]+); do", run)
    assert m, "ci job has no `for j in ...; do` loop"
    return m.group(1).split()


def test_ci_needs_every_job():
    js = jobs()
    assert set(js["ci"]["needs"]) == set(js) - {"ci"}


def test_ci_loop_matches_needs():
    js = jobs()
    loop = loop_jobs(js)
    assert len(loop) == len(set(loop))
    assert set(loop) == set(js["ci"]["needs"])


def test_only_known_jobs_are_conditional():
    js = jobs()
    assert {name for name, job in js.items() if "if" in job} - {"ci"} == CONDITIONAL


def test_split_jobs_install_the_same_tools():
    js = jobs()

    def install(name):
        steps = [s for s in js[name]["steps"] if s.get("name") == "Install pinned tools"]
        assert len(steps) == 1, name
        return steps[0]["run"]

    assert {install(name) for name in SPLIT} == {install("render")}


def tool_cache(job):
    """(installed tools, restore key, saves) of a job that runs install-tool.sh."""
    steps = job.get("steps", [])
    installs = [m.group(1).split() for s in steps for m in [INSTALL.search(s.get("run", ""))] if m]
    keys = [s["with"]["key"] for s in steps if s.get("name") == "Restore tool archives"]
    saves = [s for s in steps if s.get("name") == "Save tool archives"]
    return installs, keys, saves


def test_tool_cache_key_names_every_installed_tool():
    checked = 0
    for name, job in jobs().items():
        installs, keys, _ = tool_cache(job)
        if not installs:
            continue
        assert len(installs) == 1 and len(keys) == 1, name
        assert "\\" not in keys[0] and "\n" not in keys[0] and "}} " not in keys[0] and "- " not in keys[0], name
        assert VERSION_REF.findall(keys[0]) == [t.upper().replace("-", "_") for t in installs[0]], name
        checked += 1
    assert checked == 9


def test_one_job_saves_each_tool_cache():
    savers = {}
    for name, job in jobs().items():
        installs, keys, saves = tool_cache(job)
        if not installs:
            continue
        prefix = keys[0].split("${{", 1)[0]
        if saves:
            assert prefix not in savers, f"{name} and {savers.get(prefix)} both save {prefix}"
            savers[prefix] = name
    assert savers["tools-render-"] == "render"
    assert len(savers) == 8
