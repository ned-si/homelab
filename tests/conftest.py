"""Shared helpers for the CI script tests (no network, no cluster)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts" / "ci"
FIXTURES = REPO / "tests" / "fixtures"
sys.path.insert(0, str(SCRIPTS))

FAKE_HELM = textwrap.dedent(
    """\
    #!/bin/bash
    # Fake helm: logs its argv (one call per line). `pull` writes a chart archive
    # (Chart.yaml only) to --destination; FAKE_HELM_TRANSIENT=n fails the first n
    # pulls with a 504. `template` renders one ConfigMap per call, named after the
    # release, carrying the concatenated -f value files.
    printf '%s\\n' "$*" >> "$FAKE_HELM_LOG"
    if [ -n "${FAKE_HELM_FAIL:-}" ]; then echo "Error: chart not found" >&2; exit 1; fi
    if [ "$1" = pull ]; then
      n=$(cat "$FAKE_HELM_LOG.n" 2>/dev/null || echo 0)
      if [ "$n" -lt "${FAKE_HELM_TRANSIENT:-0}" ]; then
        echo $((n + 1)) > "$FAKE_HELM_LOG.n"
        echo "Error: failed to fetch https://charts.example.org/x.tgz : 504 Gateway Timeout" >&2
        exit 1
      fi
      chart=${2##*/} version="" dest="" prev=""
      for a in "$@"; do
        case "$prev" in --version) version=$a ;; --destination) dest=$a ;; esac
        prev=$a
      done
      src=$(mktemp -d)
      mkdir "$src/$chart"
      printf 'apiVersion: v2\\nname: %s\\nversion: %s\\n' "$chart" "${version#v}" > "$src/$chart/Chart.yaml"
      tar -czf "$dest/$chart-${version#v}.tgz" -C "$src" "$chart"
      rm -rf "$src"
      exit 0
    fi
    release=$2
    vals=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-f" ]; then vals="$vals$(tr -d '\\n' < "$a" | tr '"' "'")|"; fi
      prev=$a
    done
    printf -- '---\\napiVersion: v1\\nkind: ConfigMap\\nmetadata:\\n  name: %s\\ndata:\\n  values: "%s"\\n' "$release" "$vals"
    """
)


def write(root: Path, rel: str, text: str) -> Path:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(textwrap.dedent(text))
    return p


@pytest.fixture
def fake_helm(tmp_path, monkeypatch):
    """A fake `helm` first on PATH; returns the path of its call log."""
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    helm = bindir / "helm"
    helm.write_text(FAKE_HELM)
    helm.chmod(0o755)
    log = tmp_path / "helm.log"
    log.write_text("")
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_HELM_LOG", str(log))
    monkeypatch.delenv("CHART_CACHE", raising=False)
    return log


def git_init(root: Path) -> None:
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)


def run_render(root: Path, out: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPTS / "render_apps.py"), "--repo-root", str(root),
                           "--out", str(out), *extra], capture_output=True, text=True)


def read_render(out: Path, app: str) -> list[dict]:
    docs = []
    for line in (out / app / "manifests.yaml").read_text().splitlines():
        if line and line != "---":
            docs.append(json.loads(line))
    return docs


def need_kubectl() -> None:
    if shutil.which("kubectl") is None:
        if os.environ.get("CI"):
            pytest.fail("kubectl is required in CI")
        pytest.skip("kubectl not installed")
