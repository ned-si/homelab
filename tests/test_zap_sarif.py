"""scripts/zap_sarif.py: ZAP JSON -> SARIF, IGNORE rows dropped, counts only on stdout."""
import json
import subprocess
import sys

from conftest import REPO

CONVERT = str(REPO / "scripts" / "zap_sarif.py")

RULES = "# comment\n10105\tIGNORE\tbehind SSO\n10038\tWARN\tCSP missing\n"


def report(host, *alerts):
    return {"@programName": "ZAP", "@version": "2.17.0",
            "site": [{"@name": f"https://{host}", "@host": host, "alerts": list(alerts)}]}


def alert(plugin, risk, name="Some alert", ref=None, uri="https://example.test/secret-path"):
    return {"pluginid": plugin, "alertRef": ref or plugin, "alert": name, "riskcode": str(risk),
            "desc": "<p>Desc &amp; more</p>", "solution": "<p>Fix it</p>", "cweid": "693",
            "count": "2", "instances": [{"uri": uri, "method": "GET"}]}


def run(tmp_path, *reports, raw=None):
    rules = tmp_path / "rules.tsv"
    rules.write_text(RULES)
    rep = tmp_path / "reports"
    rep.mkdir()
    for i, r in enumerate(reports):
        (rep / f"h{i}.json").write_text(json.dumps(r))
    if raw is not None:
        (rep / "bad.json").write_text(raw)
    out = tmp_path / "out.sarif"
    ghout = tmp_path / "gh_output"
    ghout.write_text("")
    p = subprocess.run([sys.executable, CONVERT, "--rules", str(rules), "--out", str(out), str(rep)],
                       capture_output=True, text=True, env={"GITHUB_OUTPUT": str(ghout), "PATH": "/usr/bin:/bin"})
    outputs = dict(line.split("=", 1) for line in ghout.read_text().splitlines())
    return p, out, outputs


def test_converts_counts_and_drops_ignored(tmp_path):
    p, out, outputs = run(
        tmp_path,
        report("a.example.test", alert("10038", 2), alert("10105", 1), alert("40012", 3, ref="40012-1")),
        report("b.example.test", alert("10038", 2)),
    )
    assert p.returncode == 0, p.stderr
    assert outputs == {"written": "true", "high": "1"}
    sarif = json.loads(out.read_text())
    assert sarif["version"] == "2.1.0"
    run0 = sarif["runs"][0]
    assert run0["tool"]["driver"]["name"] == "ZAP"
    assert sorted(r["id"] for r in run0["tool"]["driver"]["rules"]) == ["10038", "40012-1"]
    results = run0["results"]
    assert len(results) == 3
    assert {r["ruleId"] for r in results} == {"10038", "40012-1"}
    fps = {r["partialFingerprints"]["zapAlert/v1"] for r in results}
    assert fps == {"a.example.test:10038", "b.example.test:10038", "a.example.test:40012-1"}
    high = [r for r in results if r["ruleId"] == "40012-1"][0]
    assert high["level"] == "error"
    loc = high["locations"][0]["physicalLocation"]
    assert loc["region"]["startLine"] == 1
    rule = [r for r in run0["tool"]["driver"]["rules"] if r["id"] == "40012-1"][0]
    assert rule["properties"]["security-severity"] == "7.5"
    assert "external/cwe/cwe-693" in rule["properties"]["tags"]
    assert rule["fullDescription"]["text"] == "Desc & more"


def test_stdout_has_counts_but_no_finding(tmp_path):
    p, _, _ = run(tmp_path, report("a.example.test", alert("40012", 3, name="Cross Site Scripting")))
    assert "1 high" in p.stdout
    assert "a.example.test" not in p.stdout + p.stderr
    assert "secret-path" not in p.stdout + p.stderr
    assert "Cross Site Scripting" not in p.stdout + p.stderr


def test_no_reports_is_an_error(tmp_path):
    p, out, outputs = run(tmp_path)
    assert p.returncode == 1
    assert not out.exists()
    assert outputs == {"written": "false", "high": "0"}


def test_invalid_report_is_an_error(tmp_path):
    p, out, outputs = run(tmp_path, raw="{not json")
    assert p.returncode == 1
    assert outputs["written"] == "false"
