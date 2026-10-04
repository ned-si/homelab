"""Validate .trivyignore.yaml waiver hygiene.

NO SHEBANG, AND NOT EXECUTABLE, ON PURPOSE. This is invoked as
`python3 scripts/lib/trivy_waivers.py`, never as `./trivy_waivers.py`. The
`check-shebang-scripts-are-executable` pre-commit hook would demand mode 755 for a
`#!` line, and chmod +x on a file that is never run directly is a claim about how
it is used that is not true. Same reasoning as scripts/lib/sops-age.sh.

Called by scripts/trivy-waivers.sh, which owns the CLI contract and the colours.
Kept in Python because the input is nested YAML: leak-check.sh's hand-written awk
YAML parser is the standing argument against doing this in shell.

Exit codes, which the wrapper depends on:
    0  clean
    1  at least one hard failure
    2  warnings only (waivers approaching expiry)
"""

from __future__ import annotations

import datetime as _dt
import os
import sys

import json as _json

MAX_MONTHS = int(os.environ.get("MAX_MONTHS", "6"))
WARN_DAYS = int(os.environ.get("WARN_DAYS", "30"))
ANN_WARN = os.environ.get("ANN_WARN", "")
ANN_ERR = os.environ.get("ANN_ERR", "")
STRICT = os.environ.get("STRICT", "0") in {"1", "true", "yes", "on"}

# Trivy groups waivers by scanner. Only misconfigurations are used today; the
# others are accepted so that adding one later is not a silent no-op here.
SECTIONS = ("misconfigurations", "vulnerabilities", "secrets", "licenses")


def main() -> int:
    # JSON on stdin, produced by `yq -o=json` in the wrapper. See the comment
    # there for why this is not PyYAML.
    path = ".trivyignore.yaml"
    doc = _json.load(sys.stdin) or {}

    if not isinstance(doc, dict):
        print(f"{ANN_ERR}{path}: top level must be a mapping of scanner sections.")
        return 1

    unknown = sorted(set(doc) - set(SECTIONS))
    if unknown:
        print(
            f"{ANN_ERR}{path}: unknown section(s) {unknown}. "
            f"Trivy only reads {list(SECTIONS)}, so anything else is ignored "
            f"silently -- which for a waiver file means it does not apply."
        )
        return 1

    today = _dt.date.today()
    horizon = today + _dt.timedelta(days=MAX_MONTHS * 31)
    errors: list[str] = []
    warnings: list[str] = []
    total = 0
    unscoped: list[str] = []

    for section in SECTIONS:
        for index, entry in enumerate(doc.get(section) or []):
            total += 1
            where = f"{path}: {section}[{index}]"

            if not isinstance(entry, dict):
                errors.append(f"{where}: entry must be a mapping.")
                continue

            ident = entry.get("id")
            if not ident:
                errors.append(f"{where}: no `id`.")
                continue
            where = f"{path}: {ident}"

            statement = (entry.get("statement") or "").strip()
            if not statement:
                errors.append(
                    f"{where}: no `statement`. Every waiver must say why. If the "
                    f"reason cannot be written down, fix the finding instead."
                )
            elif len(statement) < 40:
                errors.append(
                    f"{where}: `statement` is {len(statement)} characters. That is "
                    f"a label, not a reason -- say what the control is and why it "
                    f"cannot be satisfied here."
                )

            expiry_raw = entry.get("expired_at")
            if not expiry_raw:
                errors.append(
                    f"{where}: no `expired_at`. A waiver without an expiry is "
                    f"permanent, and permanent waivers are how a real defect stays "
                    f"hidden -- see the header of {path}."
                )
            else:
                expiry = _coerce_date(expiry_raw)
                if expiry is None:
                    errors.append(
                        f"{where}: `expired_at` is {expiry_raw!r}, not a yyyy-mm-dd "
                        f"date. Trivy would fail to parse the file and apply NO "
                        f"waivers at all."
                    )
                elif expiry <= today:
                    errors.append(
                        f"{where}: expired on {expiry}. It no longer suppresses "
                        f"anything, so the finding has already come back. Re-assess "
                        f"and either fix it or renew with a fresh reason."
                    )
                elif expiry > horizon:
                    errors.append(
                        f"{where}: expires {expiry}, more than {MAX_MONTHS} months "
                        f"out. That is a permanent waiver with extra steps."
                    )
                elif (expiry - today).days <= WARN_DAYS:
                    warnings.append(
                        f"{where}: expires in {(expiry - today).days} day(s), on "
                        f"{expiry}. Renew or fix before it turns the build red."
                    )

            if not entry.get("paths"):
                unscoped.append(str(ident))

    for message in errors:
        print(f"{ANN_ERR}{message}")
    for message in warnings:
        print(f"{ANN_WARN}{message}")

    if unscoped:
        # Informational, never fatal. AVD-KSV-0014 is deliberately unscoped and
        # the file explains why, so failing on this would be wrong. Printing it
        # keeps the count visible so it cannot grow unnoticed.
        print(
            f"\nunscoped waivers (apply repo-wide): {', '.join(sorted(unscoped))}\n"
            f"  Each one is a claim that the finding is never worth fixing ANYWHERE.\n"
            f"  Prefer `paths`. A new workload that could satisfy the check is\n"
            f"  otherwise covered by accident."
        )

    print(f"\n{total} waiver(s) checked, {len(errors)} error(s), "
          f"{len(warnings)} warning(s)")

    if errors:
        return 1
    if warnings:
        return 1 if STRICT else 2
    return 0


def _coerce_date(value: object) -> _dt.date | None:
    """YAML parses an unquoted yyyy-mm-dd as a date already; accept both forms."""
    if isinstance(value, _dt.datetime):
        return value.date()
    if isinstance(value, _dt.date):
        return value
    if isinstance(value, str):
        try:
            return _dt.date.fromisoformat(value.strip())
        except ValueError:
            return None
    return None


if __name__ == "__main__":
    raise SystemExit(main())
