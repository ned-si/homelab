"""The kube-state-metrics export of Kyverno's per-result PolicyReport series.

kube-state-metrics exports kyverno_policyreport_result_info for every
result of every policy (customResourceState cannot filter list elements);
the ServiceMonitor keeps only the verify-own-images results, which the
dashboard's SLSA tiles read (.kiro/specs/homelab-dashboard/design.md,
"Provenance (task 20)"). The relabelling is applied here as Prometheus
applies it: source labels joined by ";", the regex anchored at both ends.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VALUES = REPO / "platform" / "kube-prometheus-stack" / "values.yaml"


def ksm() -> dict:
    out = subprocess.run(["yq", "-o=json", ".kube-state-metrics", str(VALUES)], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def relabel(rules: list[dict], series: dict[str, str]) -> dict[str, str] | None:
    labels = dict(series)
    for r in rules:
        value = r.get("separator", ";").join(labels.get(n, "") for n in r["sourceLabels"])
        m = re.fullmatch(r.get("regex", "(.*)"), value)
        action = r.get("action", "replace")
        if action == "drop":
            if m:
                return None
        elif action == "replace":
            if m:
                labels[r["targetLabel"]] = m.expand(r.get("replacement", "$1").replace("$", "\\"))
        else:
            raise AssertionError(f"unhandled action {action}")
    return {k: v for k, v in labels.items() if not k.startswith("__tmp")}


def test_result_metric() -> None:
    resources = ksm()["customResourceState"]["config"]["spec"]["resources"]
    report = next(r for r in resources if r["groupVersionKind"]["kind"] == "PolicyReport")
    metric = next(m for m in report["metrics"] if m["name"] == "result_info")
    assert report["metricNamePrefix"] == "kyverno_policyreport"
    assert metric["labelsFromPath"] == {"resource": ["scope", "name"]}
    assert metric["each"]["type"] == "Info"
    assert metric["each"]["info"] == {
        "path": ["results"],
        "labelsFromPath": {"policy": ["policy"], "rule": ["rule"], "result": ["result"]},
    }


def test_only_verify_own_images_results_kept() -> None:
    rules = ksm()["prometheus"]["monitor"]["http"]["metricRelabelings"]
    result = {"__name__": "kyverno_policyreport_result_info", "namespace": "website", "resource": "website-1",
              "rule": "r", "result": "pass"}
    kept = relabel(rules, {**result, "policy": "verify-own-images"})
    assert kept == {**result, "policy": "verify-own-images"}
    for other in ("require-labels", "verify-own-images-2", "x-verify-own-images", ""):
        assert relabel(rules, {**result, "policy": other}) is None, other
    # Every other metric, with or without a policy label, is untouched.
    for series in ({"__name__": "kyverno_policyreport_summary", "result": "pass"},
                   {"__name__": "kube_pod_container_info", "pod": "p"},
                   {"__name__": "other_info", "policy": "require-labels"}):
        assert relabel(rules, series) == series
