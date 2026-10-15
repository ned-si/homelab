"""platform/vuln-enrich/enrich.py: feed parsing, exposure and the pushed metrics."""
from __future__ import annotations

import gzip
import importlib.util
import json
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "platform" / "vuln-enrich" / "enrich.py"
spec = importlib.util.spec_from_file_location("enrich", SRC)
enrich = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enrich)


def epss_gz(rows: list[str], pad: int = 1000) -> bytes:
    body = "#model_version:v2025.03.14,score_date:2026-10-15T00:00:00+0000\ncve,epss,percentile\n"
    body += "".join(r + "\n" for r in rows)
    body += "".join(f"CVE-1999-{i:05d},0.0001,0.01\n" for i in range(pad))
    return gzip.compress(body.encode())


def test_our_cves():
    res = {"status": "success", "data": {"result": [
        {"metric": {"vuln_id": "CVE-2026-0001"}, "value": [0, "3"]},
        {"metric": {"vuln_id": "GHSA-xxxx"}, "value": [0, "1"]},
        {"metric": {}, "value": [0, "1"]}]}}
    assert enrich.our_cves(res) == {"CVE-2026-0001", "GHSA-xxxx"}
    with pytest.raises(ValueError):
        enrich.our_cves({"status": "error"})


def test_parse_kev():
    raw = json.dumps({"vulnerabilities": [{"cveID": "CVE-2026-0001"}, {"cveID": "CVE-2021-44228"}]}).encode()
    assert enrich.parse_kev(raw) == {"CVE-2026-0001", "CVE-2021-44228"}
    with pytest.raises(ValueError):
        enrich.parse_kev(b'{"vulnerabilities": []}')


def test_parse_epss_keeps_only_wanted():
    raw = epss_gz(["CVE-2026-0001,0.42,0.97", "CVE-2026-0002,0.001,0.2"])
    assert enrich.parse_epss(raw, {"CVE-2026-0001", "CVE-2026-0404"}) == {"CVE-2026-0001": (0.42, 0.97)}


def test_parse_epss_rejects_a_truncated_or_changed_file():
    with pytest.raises(ValueError):
        enrich.parse_epss(epss_gz([], pad=10), set())
    bad = gzip.compress(b"cve,score\nCVE-1,0.1\n")
    with pytest.raises(ValueError):
        enrich.parse_epss(bad, set())


def test_exposed_namespaces():
    routes = {"items": [
        {"metadata": {"namespace": "immich"}, "spec": {"rules": [{"backendRefs": [{"name": "immich-server"}]}]}},
        {"metadata": {"namespace": "gateway"}, "spec": {"rules": [{"backendRefs": [{"name": "argocd-server", "namespace": "argo"}]}]}},
        # A redirect-only route has no backend.
        {"metadata": {"namespace": "gateway"}, "spec": {"rules": [{"filters": [{"type": "RequestRedirect"}]}]}},
    ]}
    assert enrich.exposed_namespaces(routes) == {"immich", "argo"}


def test_render():
    text = enrich.render({"CVE-2026-0001", "CVE-2026-0002"}, {"CVE-2026-0001", "CVE-2021-44228"},
                         {"CVE-2026-0002": (0.4, 0.99)}, {"immich"}, 1700000000.5)
    lines = [line for line in text.splitlines() if not line.startswith("#")]
    assert lines == [
        'vuln_kev{vuln_id="CVE-2026-0001"} 1',
        'vuln_epss_score{vuln_id="CVE-2026-0002"} 0.4',
        'vuln_epss_percentile{vuln_id="CVE-2026-0002"} 0.99',
        'vuln_namespace_exposed{namespace="immich"} 1',
        "vuln_enrich_cves 2",
        "vuln_enrich_last_success_timestamp_seconds 1700000000",
    ]
