"""scripts/ci/chart_fetch.py: cache hits, verification on restore, retries."""
import subprocess
import sys

import pytest

import chart_fetch
from conftest import SCRIPTS

REPO_URL = "https://charts.example.org"


@pytest.fixture(autouse=True)
def no_wait(monkeypatch):
    monkeypatch.setenv("CHART_FETCH_DELAYS", "0,0,0")


def pulls(log):
    return [ln for ln in log.read_text().splitlines() if ln.startswith("pull ")]


def test_fetch_then_hit(tmp_path, fake_helm):
    cache = tmp_path / "c"
    a = chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache)
    assert a.name == "demo-1.2.3.tgz" and (a.parent / "sha256").is_file()
    assert chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache) == a
    assert len(pulls(fake_helm)) == 1


def test_oci_chart(tmp_path, fake_helm):
    chart_fetch.fetch("ghcr.io/example/charts", "demo", "0.1.0", tmp_path / "c")
    assert pulls(fake_helm)[0].startswith("pull oci://ghcr.io/example/charts/demo --version 0.1.0 ")


def test_version_bump_misses(tmp_path, fake_helm):
    cache = tmp_path / "c"
    chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache)
    b = chart_fetch.fetch(REPO_URL, "demo", "1.2.4", cache)
    assert b.name == "demo-1.2.4.tgz" and len(pulls(fake_helm)) == 2


def test_tampered_archive_is_fetched_again(tmp_path, fake_helm):
    cache = tmp_path / "c"
    a = chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache)
    a.write_bytes(a.read_bytes() + b"x")
    assert chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache).read_bytes() != a.read_bytes() + b"x"
    assert len(pulls(fake_helm)) == 2


def test_wrong_chart_in_entry_is_fetched_again(tmp_path, fake_helm):
    cache = tmp_path / "c"
    a = chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache)
    other = chart_fetch.fetch(REPO_URL, "other", "1.2.3", cache)
    a.unlink()
    target = a.parent / other.name
    target.write_bytes(other.read_bytes())
    (a.parent / "sha256").write_text(chart_fetch.sha256(target) + "\n")
    assert chart_fetch.fetch(REPO_URL, "demo", "1.2.3", cache).name == "demo-1.2.3.tgz"
    assert len(pulls(fake_helm)) == 3


def test_transient_error_is_retried(tmp_path, fake_helm, monkeypatch):
    monkeypatch.setenv("FAKE_HELM_TRANSIENT", "2")
    assert chart_fetch.fetch(REPO_URL, "demo", "1.2.3", tmp_path / "c").is_file()
    assert len(pulls(fake_helm)) == 3


def test_transient_error_gives_up(tmp_path, fake_helm, monkeypatch):
    monkeypatch.setenv("FAKE_HELM_TRANSIENT", "9")
    with pytest.raises(chart_fetch.FetchError, match="504 Gateway Timeout"):
        chart_fetch.fetch(REPO_URL, "demo", "1.2.3", tmp_path / "c")
    assert len(pulls(fake_helm)) == 4


def test_other_error_is_not_retried(tmp_path, fake_helm, monkeypatch):
    monkeypatch.setenv("FAKE_HELM_FAIL", "1")
    with pytest.raises(chart_fetch.FetchError, match="chart not found"):
        chart_fetch.fetch(REPO_URL, "demo", "1.2.3", tmp_path / "c")
    assert len(pulls(fake_helm)) == 1


def test_transient_pattern():
    assert chart_fetch.TRANSIENT.search("failed to fetch https://x/y.tgz : 504 Gateway Timeout")
    assert chart_fetch.TRANSIENT.search("read: connection reset by peer")
    assert not chart_fetch.TRANSIENT.search('chart "x" version "1.500.0" not found')
    assert not chart_fetch.TRANSIENT.search("failed to fetch https://x/y.tgz : 404 Not Found")


def test_range_is_never_cached(tmp_path, fake_helm):
    cache = tmp_path / "c"
    chart_fetch.fetch(REPO_URL, "demo", "1.2.*", cache)
    chart_fetch.fetch(REPO_URL, "demo", "1.2.*", cache)
    assert len(pulls(fake_helm)) == 2
    assert chart_fetch.prune(cache, set()) == 2 and list(cache.iterdir()) == []


def test_cli_prints_the_archive(tmp_path, fake_helm, monkeypatch):
    monkeypatch.setenv("CHART_CACHE", str(tmp_path / "c"))
    p = subprocess.run([sys.executable, str(SCRIPTS / "chart_fetch.py"), REPO_URL, "demo", "1.2.3"],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip().endswith("/demo-1.2.3.tgz")
