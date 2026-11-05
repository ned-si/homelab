# shellcheck shell=bash
#
# gh_var_state <NAME> -- does the GitHub Actions repository variable NAME exist?
#
# Prints exactly one word on stdout:
#   absent    the control call returned 200 AND the per-name call returned 404
#   present   the control call returned 200 AND the per-name call returned 200
#   error     anything else (a 404 on the name alone proves nothing: GitHub
#             also answers 404 for a repository the token cannot see)
#
# The only way the scripts read a variable's existence, so every caller fails
# closed the same way; never a (paginated) variables list. Only the HTTP
# status line is read, since gh exits 1 on any non-2xx. Always returns 0.
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
