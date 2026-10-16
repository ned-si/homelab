#!/usr/bin/env python3
"""Rotation periods of the sealed secrets (docs/secrets.md, Rotation periods).

Usage: secret_rotation.py coverage|age [--repo-root .] [--today YYYY-MM-DD]

ci/secret-rotation.tsv has one row per sealed file: <file> <class> <date the
values were last set>. A row named actions-secret:<NAME> is a GitHub Actions
secret instead of a file.

  coverage  every tracked *.sops.yaml has exactly one row, every file row names
            a tracked one, every actions-secret row names a secret a tracked
            workflow reads, and every class and date is valid (repo-policy, CI)
  age       coverage, plus no row is older than its class period (the weekly
            `secret-age` workflow, which posts a failure to ntfy). Rows due
            within DUE_SOON days are listed without failing.

Only file names, classes and dates are printed, never a value.
Exit 0 = clean, 1 = findings.
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

TABLE = "ci/secret-rotation.tsv"
# Days a value may live. None: rotated on compromise or a change of owner only.
PERIODS = {"api-token": 180, "credential": 365, "static": None}
DUE_SOON = 30
# A row for an Actions secret instead of a sealed file: actions-secret:<NAME>.
ACTIONS_PREFIX = "actions-secret:"
SECRET_REF = re.compile(r"\bsecrets\.([A-Za-z_][A-Za-z0-9_]*)")


def sealed_files(root: Path) -> set[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                          "*.sops.yaml"], capture_output=True, check=True).stdout.decode()
    # .sops.yaml at the root is the SOPS configuration, not a sealed file.
    return {p for p in out.split("\0") if p and p != ".sops.yaml" and (root / p).is_file()}


def workflow_secrets(root: Path) -> set[str]:
    """Names of the Actions secrets the tracked workflows read (`secrets.<NAME>`)."""
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                          ".github/workflows/"], capture_output=True, check=True).stdout.decode()
    names: set[str] = set()
    for p in out.split("\0"):
        if p.endswith((".yaml", ".yml")) and (root / p).is_file():
            names |= set(SECRET_REF.findall((root / p).read_text()))
    return names


def read_table(root: Path, fails: list[str]) -> dict[str, tuple[str, dt.date]]:
    rows: dict[str, tuple[str, dt.date]] = {}
    path = root / TABLE
    if not path.is_file():
        fails.append(f"FAIL {TABLE}: missing")
        return rows
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3:
            fails.append(f"FAIL {TABLE}:{n}: expected <file> <class> <YYYY-MM-DD>")
            continue
        rel, cls, date = parts
        if cls not in PERIODS:
            fails.append(f"FAIL {TABLE}:{n}: {rel}: unknown class '{cls}' ({', '.join(PERIODS)})")
            continue
        try:
            day = dt.date.fromisoformat(date)
        except ValueError:
            fails.append(f"FAIL {TABLE}:{n}: {rel}: '{date}' is not a YYYY-MM-DD date")
            continue
        if rel in rows:
            fails.append(f"FAIL {TABLE}:{n}: {rel} is listed twice")
            continue
        rows[rel] = (cls, day)
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="sealed secret rotation periods")
    ap.add_argument("mode", choices=["coverage", "age"])
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--today", help="YYYY-MM-DD (default: today, UTC)")
    args = ap.parse_args(argv)
    root = Path(args.repo_root).resolve()
    today = dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()

    fails: list[str] = []
    rows = read_table(root, fails)
    files = sealed_files(root)
    file_rows = {r for r in rows if not r.startswith(ACTIONS_PREFIX)}
    used = workflow_secrets(root)
    for rel in sorted(files - file_rows):
        fails.append(f"FAIL {rel}: not in {TABLE}; add it with its class and today's date")
    for rel in sorted(file_rows - files):
        fails.append(f"FAIL {TABLE}: {rel} is not a tracked sealed file (stale row)")
    for rel in sorted(rows.keys() - file_rows):
        if rel[len(ACTIONS_PREFIX):] not in used:
            fails.append(f"FAIL {TABLE}: {rel}: no workflow reads secrets.{rel[len(ACTIONS_PREFIX):]} (stale row)")
    for rel, (_, day) in sorted(rows.items()):
        if day > today:
            fails.append(f"FAIL {TABLE}: {rel}: date {day} is in the future")

    soon: list[str] = []
    if args.mode == "age":
        for rel, (cls, day) in sorted(rows.items()):
            period = PERIODS[cls]
            if period is None:
                continue
            left = (day + dt.timedelta(days=period) - today).days
            if left < 0:
                fails.append(f"FAIL {rel}: {cls} last set {day}, {-left} day(s) past its {period}-day period")
            elif left <= DUE_SOON:
                soon.append(f"DUE  {rel}: {cls} last set {day}, due in {left} day(s)")

    for line in fails + soon:
        print(line)
    print(f"secret-rotation {args.mode}: {len(rows)} row(s), {len(fails)} failure(s), {len(soon)} due soon")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
