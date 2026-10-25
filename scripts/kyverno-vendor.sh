#!/bin/bash
# kyverno-vendor.sh [--check] -- vendor the upstream kyverno/policies files
# listed in policies/kyverno/upstream/SOURCE, unchanged (scripts/vendor-upstream.sh).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/vendor-upstream.sh" policies/kyverno/upstream "$@"
