"""Pre-commit and CI run the same checks.

CI's `lint` job runs `pre-commit run --all-files` with a SKIP list. A skipped
hook is only allowed when ci.yaml runs the same check in a dedicated step; a
hook in another stage (commit-msg, pre-push) must map to a CI step too.
"""
from __future__ import annotations

import json
import re
import subprocess

from conftest import REPO

CI = REPO / ".github" / "workflows" / "ci.yaml"
PRECOMMIT = REPO / ".pre-commit-config.yaml"

# Hook id -> text that must appear in a `run:` of ci.yaml (or of the script it
# calls) for the hook to count as covered by a dedicated CI step.
DEDICATED = {
    "gitleaks": "gitleaks git",
    "yamllint": "yamllint -c .yamllint.yaml",
    "shellcheck": "scripts/ci/shellcheck-all.sh",
    "terraform_fmt": "tofu fmt -check",
    "actionlint": "actionlint -color",
    "kyverno": "scripts/ci/kyverno.sh",
    "leak-check": "scripts/ci/repo-policy.sh",
    "placeholder-check": "scripts/ci/repo-policy.sh",
    "secrets-check": "scripts/ci/repo-policy.sh",
    "render-deploy": "scripts/ci/repo-policy.sh",
    "trivy-waivers": "scripts/trivy-waivers.sh",
    # Not in the pre-commit stage, so never part of the CI pre-commit run.
    "conventional-pre-commit": "scripts/ci/check-commits.sh",
    "ci-render": "python3 scripts/ci/render_apps.py",
}
# What repo-policy.sh must call for the hooks mapped to it above.
REPO_POLICY_CALLS = {
    "leak-check": "scripts/leak-check.sh",
    "placeholder-check": "scripts/placeholder-check.sh",
    "secrets-check": "scripts/secrets-check.sh",
    "render-deploy": "scripts/render-deploy.sh --check",
}


def yaml_json(path):
    out = subprocess.run(["yq", "-o=json", ".", str(path)], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def hooks():
    cfg = yaml_json(PRECOMMIT)
    default = cfg.get("default_stages") or ["pre-commit"]
    for repo in cfg["repos"]:
        for h in repo["hooks"]:
            yield h["id"], h.get("stages", default), h


def ci_skip():
    wf = yaml_json(CI)
    for step in wf["jobs"]["lint"]["steps"]:
        if "pre-commit run" in step.get("run", ""):
            return set(step.get("env", {}).get("SKIP", "").split(",")) - {""}
    raise AssertionError("ci.yaml lint job has no `pre-commit run` step")


def ci_run_text():
    wf = yaml_json(CI)
    return "\n".join(s.get("run", "") for job in wf["jobs"].values() for s in job.get("steps", []))


def ci_commands():
    """Every command line of every `run:` in ci.yaml, stripped."""
    return [ln.strip() for ln in ci_run_text().splitlines() if ln.strip()]


def runs_command(needle, lines=None):
    # A command line that starts with the needle: a tool's name as an
    # argument (`install-tool.sh actionlint`) does not count as running it.
    lines = ci_commands() if lines is None else lines
    return any(ln == needle or ln.startswith(needle + " ") for ln in lines)


def test_ci_runs_precommit_with_all_files():
    wf = yaml_json(CI)
    runs = [s["run"] for s in wf["jobs"]["lint"]["steps"] if "pre-commit run" in s.get("run", "")]
    assert runs and "--all-files" in runs[0]


def test_every_skipped_hook_exists():
    ids = {i for i, _, _ in hooks()}
    assert ci_skip() - ids == set()


def test_skipped_or_other_stage_hooks_have_a_dedicated_ci_step():
    skip = ci_skip()
    uncovered = []
    for hid, stages, _ in hooks():
        if hid in skip or "pre-commit" not in stages:
            needle = DEDICATED.get(hid)
            if needle is None or not runs_command(needle):
                uncovered.append(hid)
    assert uncovered == []


def test_runs_command_ignores_a_tool_named_as_an_argument():
    install = ["scripts/ci/install-tool.sh actionlint shellcheck tofu", "# actionlint -color"]
    assert not runs_command("actionlint -color", install)
    assert runs_command("actionlint -color", install + ["actionlint -color"])
    assert not runs_command("actionlint -color", ["actionlint -colorful"])


def test_repo_policy_calls_the_hook_scripts():
    text = (REPO / "scripts" / "ci" / "repo-policy.sh").read_text()
    missing = [h for h, call in REPO_POLICY_CALLS.items() if call not in text]
    assert missing == []


def test_ci_render_hook_runs_the_render_job_scripts():
    text = (REPO / "scripts" / "ci" / "render-validate.sh").read_text()
    ci = ci_run_text()
    for script in ("scripts/ci/render_apps.py", "scripts/ci/kubeconform.sh", "scripts/ci/repo-policy.sh"):
        assert script in text and script in ci, script


def test_commit_types_match_check_title():
    types = next(h["args"] for i, _, h in hooks() if i == "conventional-pre-commit")
    rx = (REPO / "scripts" / "ci" / "check-title.sh").read_text()
    m = re.search(r"RX='\^\(([a-z|]+)\)", rx)
    assert m, "check-title.sh RX not found"
    assert sorted(types) == sorted(m.group(1).split("|"))
