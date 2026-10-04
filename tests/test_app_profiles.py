"""scripts/ci/app_profiles.py: root and legacy-root, one passing and one failing fixture per assertion."""
import subprocess
import sys

import pytest

import app_profiles
from conftest import FIXTURES, SCRIPTS

APPS = FIXTURES / "apps"


def load(name):
    return app_profiles.load_one(str(APPS / name))


def test_root_passes():
    assert app_profiles.check_root(load("root.yaml")) == []


def test_legacy_root_passes():
    assert app_profiles.check_legacy_root(load("legacy-root.yaml")) == []


def test_legacy_root_no_automated():
    doc = load("legacy-root-no-automated.yaml")
    assert app_profiles.check_legacy_root(doc, no_automated=True) == []
    assert app_profiles.check_legacy_root(doc) != []
    assert app_profiles.check_legacy_root(load("legacy-root.yaml"), no_automated=True) != []


@pytest.mark.parametrize("name,needle", [
    ("root-ns-argocd.yaml", "metadata.namespace"),
    ("root-finalizer.yaml", "finalizers"),
    ("root-prune-true.yaml", "automated"),
    ("root-target-main.yaml", "targetRevision"),
])
def test_root_failures(name, needle):
    fails = app_profiles.check_root(load(name))
    assert len(fails) == 1 and needle in fails[0], fails


@pytest.mark.parametrize("name,needle", [
    ("legacy-root-ns-argocd.yaml", "metadata.namespace"),
    ("legacy-root-finalizer.yaml", "finalizers"),
    ("legacy-root-prune-true.yaml", "automated"),
    ("legacy-root-target-main.yaml", "targetRevision"),
])
def test_legacy_root_failures(name, needle):
    fails = app_profiles.check_legacy_root(load(name))
    assert len(fails) == 1 and needle in fails[0], fails


def test_root_repo_url_and_ssa():
    doc = load("root.yaml")
    doc["spec"]["source"]["repoURL"] = "https://github.com/someone-else/homelab"
    doc["spec"]["syncPolicy"]["syncOptions"] = ["CreateNamespace=false"]
    fails = app_profiles.check_root(doc)
    assert any("repoURL" in f for f in fails) and any("ServerSideApply" in f for f in fails)


def test_cli_exit_codes():
    cli = [sys.executable, str(SCRIPTS / "app_profiles.py")]
    assert subprocess.run(cli + ["root", str(APPS / "root.yaml")], capture_output=True).returncode == 0
    r = subprocess.run(cli + ["root", str(APPS / "root-ns-argocd.yaml")], capture_output=True, text=True)
    assert r.returncode == 1 and "namespace" in r.stderr
    assert subprocess.run(cli + ["legacy-root", "--no-automated", str(APPS / "legacy-root-no-automated.yaml")],
                          capture_output=True).returncode == 0
    assert subprocess.run(cli + ["nope", "x"], capture_output=True).returncode == 64
