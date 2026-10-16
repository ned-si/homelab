#!/usr/bin/env python3
"""Run one fuzz target from tests/fuzz/targets.py under Atheris (libFuzzer).

Usage: tests/fuzz/fuzz.py <target> [libFuzzer flags] [corpus dir ...]
       tests/fuzz/fuzz.py --list

Targets and their properties: tests/fuzz/targets.py. CI: .github/workflows/fuzz.yaml.
"""
import sys

import atheris

with atheris.instrument_imports():
    import targets


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in targets.TARGETS and sys.argv[1] != "--list":
        print(f"usage: {sys.argv[0]} <{'|'.join(targets.TARGETS)}> [libFuzzer flags] | --list", file=sys.stderr)
        sys.exit(64)
    if sys.argv[1] == "--list":
        print("\n".join(targets.TARGETS))
        return
    target = targets.TARGETS[sys.argv[1]]
    atheris.Setup([sys.argv[0], *sys.argv[2:]], target)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
