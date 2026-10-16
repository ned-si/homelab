#!/bin/bash
# setup-python-deps.sh [requirements file] -- CI Python tools from
# ci/requirements-ci.txt (pytest, yamllint, pre-commit) or the file given
# (ci/requirements-fuzz.txt: Atheris).
#
# Every package, including transitive ones, is pinned by version and sha256;
# `--require-hashes` makes pip refuse anything else. Installs into a venv under
# $RUNNER_TEMP and puts its bin/ first on $GITHUB_PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
reqs="$ROOT/${1:-ci/requirements-ci.txt}"
venv="${RUNNER_TEMP:?RUNNER_TEMP not set}/venv"
python3 --version
python3 -m venv "$venv"
"$venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r "$reqs"
"$venv/bin/pip" freeze --all
if [ -n "${GITHUB_PATH:-}" ]; then echo "$venv/bin" >> "$GITHUB_PATH"; fi
