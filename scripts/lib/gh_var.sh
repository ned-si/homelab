#!/bin/bash
# shellcheck shell=bash
#
# gh_var_state <NAME> -- does the GitHub Actions repository variable NAME exist?
#
# Prints exactly one word on stdout:
#   absent    the control call returned 200 AND the per-name call returned 404
#   present   the control call returned 200 AND the per-name call returned 200
#   error     anything else: the control call was not 200 (GitHub also answers
#             404 for a private repository this token cannot see, so a 404 on
#             the name alone proves nothing), another status, a network error,
#             or no HTTP status line at all
#
# It is the only way the programme reads a variable's existence (pr-merge.sh's
# merge-freeze guard and the check before every `deployed` move), so both fail
# closed in the same way. A variables *list* is never used as the answer: it is
# paginated, and a failed call lists nothing, which would read as "absent".
#
# Only the HTTP status line is read, whatever gh's exit code: gh exits 1 on any
# non-2xx (including the 404 that means "absent"), so every call is captured as
# `out=$(gh api --include ... 2>&1) || true`. This keeps the function correct
# under `set -euo pipefail`. The function always returns 0; callers branch on
# the printed word.
#
# Repository: $GH_VAR_REPO, default ned-si/homelab.

_gh_var_status() { # <gh api output> -> 3-digit status or empty
  local first
  first=$(printf '%s\n' "$1" | head -n 1 | tr -d '\r')
  if [[ "$first" =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

gh_var_state() {
  local name=${1:-} repo=${GH_VAR_REPO:-ned-si/homelab} out status
  if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo error
    return 0
  fi

  # Positive control: this token can see the repository and read its variables.
  out=$(gh api --include "repos/${repo}/actions/variables?per_page=1" 2>&1) || true
  status=$(_gh_var_status "$out")
  if [ "$status" != "200" ]; then
    echo error
    return 0
  fi

  out=$(gh api --include "repos/${repo}/actions/variables/${name}" 2>&1) || true
  status=$(_gh_var_status "$out")
  case "$status" in
    404) echo absent ;;
    200) echo present ;;
    *) echo error ;;
  esac
  return 0
}
