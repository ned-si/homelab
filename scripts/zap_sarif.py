#!/usr/bin/env python3
"""Convert ZAP JSON reports into one SARIF file for code scanning.

usage: zap_sarif.py --rules .zap/rules.tsv --out zap.sarif <report-dir | report.json>...

Reads every `*.json` ZAP report (scripts/dast-zap.sh writes one per host),
drops alerts whose rule ID is IGNORE in the rules file, and writes a single
SARIF 2.1.0 run. The output on stdout is counts only, never a finding: the
logs of a public repository's workflows are public, code scanning alerts are
not.

Under GitHub Actions it also writes `written=true|false` and `high=<n>` to
$GITHUB_OUTPUT for the upload and gate steps of dast.yaml.

SARIF needs a file location for every result, and a DAST finding has none in
the repository. Every result points at line 1 of the rules file, which is where
an alert is tuned; the affected URL is in the message. partialFingerprints
(host + ZAP alert reference) keep one alert per host and rule across runs.

Exit 0 when the SARIF was written, 1 when there was nothing to read or a report
was not valid JSON, 64 on usage errors.
"""
import argparse
import html
import json
import os
import re
import sys
from pathlib import Path

# ZAP riskcode -> (SARIF level, GitHub security-severity, label)
RISK = {
    3: ("error", "7.5", "high"),
    2: ("warning", "5.0", "medium"),
    1: ("note", "2.0", "low"),
    0: ("note", None, "info"),
}
TAG = re.compile(r"<[^>]+>")


def text(value):
    """ZAP descriptions are HTML fragments; SARIF wants plain text."""
    return " ".join(html.unescape(TAG.sub(" ", value or "")).split())


def ignored_rules(rules_file):
    ignored = set()
    for line in Path(rules_file).read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 2 and fields[1].strip() == "IGNORE":
            ignored.add(fields[0].strip())
    return ignored


def report_files(paths):
    files = []
    for p in map(Path, paths):
        if p.is_dir():
            files.extend(sorted(p.glob("*.json")))
        elif p.is_file():
            files.append(p)
    return files


def convert(reports, ignored, rules_uri):
    rules = {}
    results = []
    version = None
    for report in reports:
        version = version or report.get("@version")
        for site in report.get("site", []):
            host = site.get("@host") or site.get("@name", "")
            for alert in site.get("alerts", []):
                plugin = str(alert.get("pluginid", ""))
                if not plugin or plugin in ignored:
                    continue
                ref = str(alert.get("alertRef") or plugin)
                risk = int(alert.get("riskcode", 0))
                level, severity, _ = RISK.get(risk, RISK[0])
                if ref not in rules:
                    rule = {
                        "id": ref,
                        "name": text(alert.get("alert") or alert.get("name")) or ref,
                        "shortDescription": {"text": text(alert.get("alert") or alert.get("name")) or ref},
                        "fullDescription": {"text": text(alert.get("desc")) or ref},
                        "help": {"text": text(alert.get("solution")) or "See the ZAP alert documentation."},
                        "helpUri": f"https://www.zaproxy.org/docs/alerts/{plugin}/",
                        "defaultConfiguration": {"level": level},
                        "properties": {"tags": ["security", "dast"]},
                    }
                    if severity:
                        rule["properties"]["security-severity"] = severity
                    cwe = str(alert.get("cweid", ""))
                    if cwe.isdigit() and cwe != "0":
                        rule["properties"]["tags"].append(f"external/cwe/cwe-{cwe}")
                    rules[ref] = rule
                instances = alert.get("instances") or []
                uri = instances[0].get("uri", "") if instances else ""
                count = alert.get("count") or len(instances)
                results.append({
                    "ruleId": ref,
                    "level": level,
                    "message": {"text": f"{rules[ref]['name']} on {host}: {count} instance(s), first at {uri or 'n/a'}"},
                    "locations": [{
                        "physicalLocation": {
                            "artifactLocation": {"uri": rules_uri},
                            "region": {"startLine": 1},
                        },
                    }],
                    "partialFingerprints": {"zapAlert/v1": f"{host}:{ref}"},
                    "properties": {"risk": risk},
                })
    sarif = {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "ZAP",
                "version": version or "unknown",
                "informationUri": "https://www.zaproxy.org/",
                "rules": [rules[k] for k in sorted(rules)],
            }},
            "results": results,
        }],
    }
    return sarif, results


def github_output(**values):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as fh:
            for k, v in values.items():
                fh.write(f"{k}={v}\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rules", required=True, help="ZAP rules file (.zap/rules.tsv)")
    ap.add_argument("--out", required=True, help="SARIF file to write")
    ap.add_argument("reports", nargs="+", help="ZAP JSON reports or directories of them")
    args = ap.parse_args(argv)

    files = report_files(args.reports)
    if not files:
        print("zap_sarif: no ZAP reports found", file=sys.stderr)
        github_output(written="false", high="0")
        return 1
    reports = []
    for f in files:
        try:
            reports.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            print(f"zap_sarif: {f.name} is not a valid ZAP JSON report", file=sys.stderr)
            github_output(written="false", high="0")
            return 1

    sarif, results = convert(reports, ignored_rules(args.rules), args.rules)
    Path(args.out).write_text(json.dumps(sarif, indent=1) + "\n")

    counts = {label: 0 for _, _, label in RISK.values()}
    for r in results:
        counts[RISK.get(r["properties"]["risk"], RISK[0])[2]] += 1
    print(f"zap: {len(files)} report(s), {len(results)} alert(s): "
          + ", ".join(f"{counts[k]} {k}" for k in ("high", "medium", "low", "info")))
    github_output(written="true", high=str(counts["high"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
