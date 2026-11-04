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
SPLIT = ("render", "tests", "promtool", "alertmanager")


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
