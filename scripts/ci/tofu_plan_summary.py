#!/usr/bin/env python3
"""Classify an OpenTofu plan from `tofu show -json`.

Usage: tofu_plan_summary.py <plan.json> <module>

Prints `status=<word>` on the first line, then a Markdown block (module,
counts, changed addresses). The status words:

  no-changes   nothing to do
  changes      only creates, in-place updates or reads
  destructive  at least one delete or replace (or forget): never applied by CI

Only resource addresses and action names are printed. The JSON holds attribute
values, sensitive ones included, so none of them is ever echoed.
"""

import json
import sys

# Actions that remove an object from AWS or from state.
DESTRUCTIVE = {"delete", "forget"}


def classify(plan):
    """Return (status, rows) where rows are (address, action label)."""
    rows = []
    destructive = False
    for rc in plan.get("resource_changes") or []:
        actions = rc.get("change", {}).get("actions") or []
        if actions in (["no-op"], ["read"]):
            continue
        if actions == ["delete", "create"] or actions == ["create", "delete"]:
            label = "replace"
        else:
            label = "+".join(actions)
        if DESTRUCTIVE.intersection(actions):
            destructive = True
        rows.append((rc.get("address", "?"), label))
    # Values changed outside OpenTofu that the configuration does not
    # correct (refresh-only drift) still count as drift worth reporting.
    drift = [
        (d.get("address", "?"), "drifted")
        for d in plan.get("resource_drift") or []
        if (d.get("change", {}).get("actions") or []) not in (["no-op"], ["read"])
    ]
    if destructive:
        status = "destructive"
    elif rows:
        status = "changes"
    else:
        status = "no-changes"
    return status, rows, drift


def render(module, status, rows, drift):
    counts = {}
    for _, label in rows:
        counts[label] = counts.get(label, 0) + 1
    out = [f"status={status}", f"**{module}**: {status}"]
    if counts:
        out.append(", ".join(f"{n} {k}" for k, n in sorted(counts.items())))
    for address, label in rows + drift:
        out.append(f"- `{address}`: {label}")
    return "\n".join(out)


def main(argv):
    if len(argv) != 3:
        print("usage: tofu_plan_summary.py <plan.json> <module>", file=sys.stderr)
        return 64
    with open(argv[1], encoding="utf-8") as f:
        plan = json.load(f)
    status, rows, drift = classify(plan)
    print(render(argv[2], status, rows, drift))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
