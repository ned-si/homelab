"""Every script a workflow `run:` step calls directly exists and is executable."""
import os
import re

from conftest import REPO

WORKFLOWS = REPO / ".github" / "workflows"
CALL = re.compile(r"(?:^|[\s;&|(])((?:scripts|tests)/[A-Za-z0-9_./-]+\.(?:sh|py))")


def direct_calls():
    calls = set()
    for wf in sorted(WORKFLOWS.glob("*.y*ml")):
        for line in wf.read_text().splitlines():
            for m in CALL.finditer(line):
                before = line[: m.start(1)].rstrip()
                # `bash x.sh` / `python3 x.py` do not need the executable bit.
                if before.endswith(("bash", "python", "python3", "sh")):
                    continue
                calls.add(m.group(1))
    return sorted(calls)


def test_there_are_direct_calls():
    assert "scripts/ci/install-tool.sh" in direct_calls()


def test_direct_calls_are_executable():
    missing = [c for c in direct_calls() if not os.access(REPO / c, os.X_OK)]
    assert missing == []
