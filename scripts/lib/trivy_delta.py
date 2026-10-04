"""Compare two Trivy config-scan reports and decide whether to fail.

No shebang and not executable: invoked as `python3 scripts/lib/trivy_delta.py`.
See the note in trivy_waivers.py.

Called by scripts/trivy-gate.sh, which owns the CLI contract, the baseline
checkout and the colours.

Policy:
    CRITICAL   fails on presence. Inheriting one is not a reason to keep it.
    HIGH       fails only when NEW relative to the baseline.
    inherited  reported, not blocking.

Findings are keyed on (id, target). See the header of trivy-gate.sh for why the
line number is excluded and what that costs.

Exit codes:
    0  nothing new, no CRITICAL
    1  a CRITICAL is present, or a HIGH is new
"""

from __future__ import annotations

import collections
import json
import os
import sys

ANN_ERR = os.environ.get("ANN_ERR", "")
SUMMARY_OUT = os.environ.get("SUMMARY_OUT", "")

Key = tuple[str, str]


def load(path: str) -> collections.Counter[tuple[str, str, str]]:
    """Return a Counter of (severity, id, target). Missing/empty file -> empty."""
    counts: collections.Counter[tuple[str, str, str]] = collections.Counter()
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read().strip()
    except FileNotFoundError:
        return counts
    if not text:
        return counts
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        return counts
    for result in doc.get("Results") or []:
        target = result.get("Target") or "?"
        for finding in result.get("Misconfigurations") or []:
            counts[(finding.get("Severity") or "?",
                    finding.get("ID") or "?",
                    target)] += 1
    return counts


def main(head_path: str, base_path: str) -> int:
    head = load(head_path)
    base = load(base_path)

    criticals = {k: n for k, n in head.items() if k[0] == "CRITICAL"}

    # New = present in head with a higher count than in the baseline. Comparing
    # counts rather than mere presence catches a second occurrence of a rule that
    # already fired once in the same file.
    new = {k: n - base.get(k, 0) for k, n in head.items() if n > base.get(k, 0)}
    new_high = {k: d for k, d in new.items() if k[0] != "CRITICAL"}

    fixed = {k: base[k] - head.get(k, 0)
             for k in base if base[k] > head.get(k, 0)}

    inherited = sum(n for k, n in head.items() if k not in new)

    lines: list[str] = []
    say = lines.append

    say(f"findings: {sum(head.values())} total "
        f"({sum(1 for k in head if k[0] == 'CRITICAL')} critical keys), "
        f"baseline {sum(base.values())}")
    say(f"  new       : {sum(new.values())}")
    say(f"  inherited : {inherited}")
    say(f"  fixed     : {sum(fixed.values())}")

    if criticals:
        say("")
        say("CRITICAL -- these fail regardless of the baseline:")
        for (sev, rid, target), n in sorted(criticals.items()):
            say(f"  {rid}  x{n}  {target}")

    if new_high:
        say("")
        say("NEW since the baseline -- introduced by this change:")
        for (sev, rid, target), delta in sorted(new_high.items()):
            say(f"  [{sev}] {rid}  +{delta}  {target}")

    if fixed:
        say("")
        say("FIXED since the baseline:")
        for (sev, rid, target), delta in sorted(fixed.items()):
            say(f"  [{sev}] {rid}  -{delta}  {target}")

    report = "\n".join(lines)
    print(report)

    # GitHub annotations, one per blocking finding, so they attach to the file.
    for (sev, rid, target), n in sorted(criticals.items()):
        print(f"{ANN_ERR}file={target}::{rid} ({sev}) x{n} -- CRITICAL findings "
              f"are not waivable by inheritance. Fix it, or add a path-scoped "
              f"waiver with a short expiry to .trivyignore.yaml.")
    for (sev, rid, target), delta in sorted(new_high.items()):
        print(f"{ANN_ERR}file={target}::{rid} ({sev}) +{delta} -- NEW relative to "
              f"the baseline. Pre-existing findings of this rule elsewhere do not "
              f"excuse a new one here.")

    if SUMMARY_OUT:
        _write_summary(SUMMARY_OUT, head, base, criticals, new_high, fixed,
                       inherited)

    return 1 if (criticals or new_high) else 0


def _write_summary(path, head, base, criticals, new_high, fixed, inherited):
    """Markdown for the sticky PR comment. Informational; never the gate."""
    verdict = "**FAIL**" if (criticals or new_high) else "**PASS**"
    out = [
        "## Trivy config scan",
        "",
        f"{verdict} &nbsp; "
        f"{sum(head.values())} finding(s) &nbsp;|&nbsp; "
        f"{sum(new_high.values()) + sum(criticals.values())} blocking &nbsp;|&nbsp; "
        f"{inherited} inherited &nbsp;|&nbsp; "
        f"{sum(fixed.values())} fixed",
        "",
    ]

    if criticals:
        out += ["### CRITICAL — blocking regardless of baseline", "",
                "| rule | count | file |", "|---|---|---|"]
        out += [f"| `{r}` | {n} | `{t}` |"
                for (s, r, t), n in sorted(criticals.items())]
        out += [""]

    if new_high:
        out += ["### New since the baseline — blocking", "",
                "| severity | rule | added | file |", "|---|---|---|---|"]
        out += [f"| {s} | `{r}` | +{d} | `{t}` |"
                for (s, r, t), d in sorted(new_high.items())]
        out += [""]

    if fixed:
        out += ["### Fixed", "",
                "| severity | rule | removed | file |", "|---|---|---|---|"]
        out += [f"| {s} | `{r}` | -{d} | `{t}` |"
                for (s, r, t), d in sorted(fixed.items())]
        out += [""]

    if not criticals and not new_high:
        out += [
            f"No new findings. {inherited} inherited finding(s) remain, deferred "
            f"in `.trivyignore.yaml` with a reason and an expiry.",
            "",
        ]

    out += [
        "<details><summary>How this gate works</summary>",
        "",
        "- **CRITICAL** fails on presence — inheriting one is not a reason to keep it.",
        "- **HIGH** fails only when *new* relative to the merge-base, so inherited "
        "debt is visible without blocking unrelated changes.",
        "- Waivers live in `.trivyignore.yaml` and must carry a `statement` and an "
        "`expired_at`; `scripts/trivy-waivers.sh` enforces that and warns 30 days "
        "before expiry.",
        "- Reproduce locally: `scripts/trivy-gate.sh`",
        "",
        "</details>",
    ]

    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: trivy_delta.py <head.json> <base.json>", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
