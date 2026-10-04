#!/bin/bash
# setup-python-deps.sh -- CI Python tools (pytest, yamllint) from ci/requirements-ci.txt.
#
# Every package, including transitive ones, is pinned by version and sha256;
# `--require-hashes` makes pip refuse anything else. Installs into a venv under
# $RUNNER_TEMP and puts its bin/ first on $GITHUB_PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
venv="${RUNNER_TEMP:?RUNNER_TEMP not set}/venv"
python3 -m venv "$venv"
"$venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r "$ROOT/ci/requirements-ci.txt"
"$venv/bin/pip" freeze --all
if [ -n "${GITHUB_PATH:-}" ]; then echo "$venv/bin" >> "$GITHUB_PATH"; fi
