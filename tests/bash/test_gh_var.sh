#!/bin/bash
# gh_var_state under `set -euo pipefail` against a fake gh that, like gh 2.102.0,
# prints the status line, headers and body and exits 1 on every non-2xx.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/lib/gh_var.sh
. "$REPO_ROOT/scripts/lib/gh_var.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install_fake_gh "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export GH_VAR_REPO=ned-si/homelab

CTRL='repos/ned-si/homelab/actions/variables?per_page=1'
NAME='repos/ned-si/homelab/actions/variables/MERGE_FREEZE'

case_() { # name control-status name-status expected
  export FAKE_GH_DIR="$tmp/$1"
  mkdir -p "$FAKE_GH_DIR"
  api_resp "$CTRL" "$2" '{"total_count":0,"variables":[]}'
  api_resp "$NAME" "$3" '{"name":"MERGE_FREEZE","value":"history rewrite"}'
  local got
  got=$(gh_var_state MERGE_FREEZE)
  expect_eq "$1" "$4" "$got"
}

case_ "control 200 + name 404 -> absent" 200 404 absent
case_ "control 200 + name 200 -> present" 200 200 present
case_ "control 404 (repo not visible) -> error" 404 404 error
case_ "control 500 -> error" 500 404 error
case_ "control 200 + name 403 -> error" 200 403 error
case_ "control 200 + name 500 -> error" 200 500 error
case_ "control network error -> error" neterr 404 error
case_ "name network error -> error" 200 neterr error
case_ "control exit 1 with no output -> error" empty 404 error
case_ "name exit 1 with no output -> error" 200 empty error
case_ "control output without a status line -> error" nostatus 404 error
case_ "name output without a status line -> error" 200 nostatus error

export FAKE_GH_DIR="$tmp/badname"; mkdir -p "$FAKE_GH_DIR"
expect_eq "invalid variable name -> error" error "$(gh_var_state 'X;rm')"
expect_eq "function returns 0 on error" 0 "$(gh_var_state '' >/dev/null; echo $?)"

finish
