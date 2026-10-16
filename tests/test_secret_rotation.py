"""scripts/ci/secret_rotation.py: coverage of the rotation table and the age check."""
import subprocess
import sys

import pytest

from conftest import REPO, SCRIPTS, git_init, write

TODAY = "2026-10-16"


def run(tmp_path, table, files=("apps/secrets/a.sops.yaml",), mode="age", today=TODAY):
    root = tmp_path / "repo"
    root.mkdir(parents=True, exist_ok=True)
    write(root, ".sops.yaml", "creation_rules: []\n")
    for rel in files:
        write(root, rel, "sops: {}\n")
    write(root, "ci/secret-rotation.tsv", "# header\n" + "".join("\t".join(r) + "\n" for r in table))
    git_init(root)
    return subprocess.run([sys.executable, str(SCRIPTS / "secret_rotation.py"), mode, "--repo-root", str(root),
                           "--today", today], capture_output=True, text=True)


def fails(r):
    return [ln for ln in r.stdout.splitlines() if ln.startswith("FAIL ")]


@pytest.mark.parametrize("cls,date,bad", [
    ("api-token", "2026-04-20", False),   # day 179
    ("api-token", "2026-04-18", True),    # day 181
    ("credential", "2025-10-17", False),
    ("credential", "2025-10-15", True),
    ("static", "2020-01-01", False),
])
def test_age(tmp_path, cls, date, bad):
    r = run(tmp_path, [("apps/secrets/a.sops.yaml", cls, date)])
    assert bool(fails(r)) == bad, r.stdout
    assert r.returncode == (1 if bad else 0)


def test_coverage_ignores_age(tmp_path):
    r = run(tmp_path, [("apps/secrets/a.sops.yaml", "api-token", "2020-01-01")], mode="coverage")
    assert r.returncode == 0, r.stdout


def test_due_soon_is_listed_not_failed(tmp_path):
    r = run(tmp_path, [("apps/secrets/a.sops.yaml", "api-token", "2026-05-01")])
    assert r.returncode == 0, r.stdout
    assert "DUE  apps/secrets/a.sops.yaml" in r.stdout


@pytest.mark.parametrize("table,needle", [
    ([], "apps/secrets/a.sops.yaml: not in ci/secret-rotation.tsv"),
    ([("apps/secrets/a.sops.yaml", "credential", "2026-10-01"), ("apps/secrets/gone.sops.yaml", "credential",
                                                                  "2026-10-01")], "gone.sops.yaml is not a tracked"),
    ([("apps/secrets/a.sops.yaml", "weekly", "2026-10-01")], "unknown class 'weekly'"),
    ([("apps/secrets/a.sops.yaml", "credential", "2026-13-01")], "is not a YYYY-MM-DD date"),
    ([("apps/secrets/a.sops.yaml", "credential", "2026-10-20")], "is in the future"),
    ([("apps/secrets/a.sops.yaml", "credential")], "expected <file> <class> <YYYY-MM-DD>"),
    ([("apps/secrets/a.sops.yaml", "credential", "2026-10-01")] * 2, "listed twice"),
])
def test_coverage_findings(tmp_path, table, needle):
    r = run(tmp_path, table, mode="coverage")
    assert r.returncode == 1
    assert any(needle in f for f in fails(r)), r.stdout


def test_this_repository_is_covered():
    r = subprocess.run([sys.executable, str(SCRIPTS / "secret_rotation.py"), "coverage", "--repo-root", str(REPO)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
