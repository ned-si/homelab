#!/bin/bash
#
# The Trivy gate. Severity-tiered, and for HIGH it gates on the DELTA against a
# baseline rather than on the absolute count.
#
# ---------------------------------------------------------------------------
# THE PROBLEM THIS SOLVES
#
# An absolute-count gate has exactly two settings, and both are wrong:
#
#   fail on any finding    Inherited debt blocks every unrelated PR. Nobody can
#                          merge a typo fix until 39 pre-existing findings are
#                          resolved, so the gate gets waived wholesale and stops
#                          meaning anything.
#   waive by rule ID       What the old flat .trivyignore did. Bazarr added two
#                          findings of an already-waived class and CI could not
#                          say so, because the class was suppressed globally.
#
# Gating on the delta gives the property actually wanted: pre-existing findings
# are visible but non-blocking, and a change that ADDS one fails -- even when its
# rule is waived elsewhere in the tree.
#
# CRITICAL is not treated this way. It fails on presence, baseline or not.
# Inheriting a CRITICAL is not a reason to keep it.
#
# ---------------------------------------------------------------------------
# HOW THE BASELINE IS CHOSEN
#
# The merge-base with the target branch, NOT the target branch tip. Using the tip
# would attribute someone else's newly-merged finding to this PR, which is how a
# delta gate acquires a reputation for false positives and gets switched off.
#
# Findings are keyed on (id, target-file), deliberately NOT including the line
# number: adding a comment shifts every line below it and would otherwise present
# as a wholesale set of new findings.
#
# The consequence, stated because it is a real limitation: a SECOND occurrence of
# the same rule in the same file is not seen as new. Catching that needs a stable
# resource identity that Trivy's config output does not reliably provide. The
# count per key is compared too, which catches most of it.
#
# ---------------------------------------------------------------------------
# USAGE
#   scripts/trivy-gate.sh                     gate against merge-base with main
#   TRIVY_BASE_REF=origin/foo ...             gate against another branch
#   TRIVY_GATE_SUMMARY=/tmp/s.md ...          also write a markdown summary
#   TRIVY_GATE_BASELINE_SKIP=1 ...            no baseline; gate on presence only
#
# `--skip-check-update` is passed to Trivy on purpose. Without it Trivy tries to
# pull its checks bundle from a registry and, on a slow link, spends six minutes
# getting zero bytes and then dies rather than falling back to the embedded
# checks. That is why these findings went untriaged for so long. CI has a fast
# link and a cache, so it downloads; this flag makes a local run possible at all.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

readonly WAIVER_FILE=".trivyignore.yaml"
readonly SEVERITIES="HIGH,CRITICAL"

: "${TRIVY_BASE_REF:=}"
: "${TRIVY_GATE_SUMMARY:=}"
: "${TRIVY_GATE_BASELINE_SKIP:=0}"

# NOT readonly: passed to python as a command-prefix assignment below, and bash
# refuses `FOO=x cmd` when FOO is readonly.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  ANN_ERR='::error::'
else
  ANN_ERR=''
fi

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

require_tools() {
  local missing=0 tool
  for tool in trivy python3 git; do
    command -v "${tool}" >/dev/null 2>&1 || { red "missing: ${tool}"; missing=1; }
  done
  return "${missing}"
}

# Scan the working tree as it stands. Writes JSON to $1.
scan_to() {
  local out="$1"
  trivy config . \
    --severity "${SEVERITIES}" \
    --ignorefile "${WAIVER_FILE}" \
    --skip-check-update \
    --format json \
    --output "${out}" \
    --quiet
}

# Resolve the baseline commit, or print nothing if there is no usable one.
resolve_base() {
  local target="${TRIVY_BASE_REF}"

  if [[ -z "${target}" ]]; then
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
      # On a pull request GitHub names the target branch. This is the case that
      # matters and it is correct for stacked PRs too.
      target="origin/${GITHUB_BASE_REF}"
    else
      # Locally, prefer the branch this one tracks over a hardcoded main.
      #
      # This repository stacks branches heavily, and on a stacked branch main is
      # the WRONG baseline: it holds an entirely different layout, so the delta
      # comes out as "every finding under deploy/ is new, every finding under
      # kubernetes/ was fixed" -- 34 lines of noise that say nothing about the
      # change under review. Observed while building this script.
      target="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
      [[ -z "${target}" ]] && target="origin/main"
    fi
  fi

  git rev-parse --verify --quiet "${target}^{commit}" >/dev/null || return 1
  git merge-base HEAD "${target}" 2>/dev/null
}

main() {
  require_tools || return 1

  if [[ ! -f "${WAIVER_FILE}" ]]; then
    red "${ANN_ERR}${WAIVER_FILE} not found -- refusing to scan with no waivers,"
    red "which would report every deferred finding as if it were new."
    return 1
  fi

  local head_json="${TMPDIR:-/tmp}/trivy-head.$$.json"
  local base_json="${TMPDIR:-/tmp}/trivy-base.$$.json"
  # shellcheck disable=SC2064
  # Expand now: $$ must be this shell's pid, not the trap's.
  trap "rm -f '${head_json}' '${base_json}'" EXIT

  echo "=== scanning working tree ==="
  scan_to "${head_json}" || { red "trivy failed on the working tree"; return 1; }

  local base_sha=""
  if [[ "${TRIVY_GATE_BASELINE_SKIP}" != "1" ]]; then
    base_sha="$(resolve_base || true)"
  fi

  if [[ -z "${base_sha}" ]]; then
    yellow "no baseline available -- gating on presence, not delta."
    yellow "Every HIGH finding not covered by ${WAIVER_FILE} will fail."
    : > "${base_json}"
  else
    echo "=== baseline: ${base_sha} ($(git log -1 --format=%s "${base_sha}" | cut -c1-60)) ==="
    # A worktree, not `git stash` or a checkout: this must not touch the caller's
    # working tree. A gate that can leave a developer's checkout modified when it
    # is interrupted will not be trusted, and correctly so.
    local wt="${TMPDIR:-/tmp}/trivy-base-wt.$$"
    if git worktree add --detach --quiet "${wt}" "${base_sha}" 2>/dev/null; then
      # shellcheck disable=SC2064
      trap "rm -f '${head_json}' '${base_json}'; git -C '${REPO_ROOT}' worktree remove --force '${wt}' >/dev/null 2>&1" EXIT
      # Baseline is scanned with the CURRENT waiver file, not the baseline's.
      # Otherwise adding a waiver in this PR would remove findings from HEAD but
      # not from the baseline, and the delta would read as an improvement while
      # hiding whatever the waiver newly covers.
      cp "${WAIVER_FILE}" "${wt}/${WAIVER_FILE}" 2>/dev/null || true
      ( cd "${wt}" && trivy config . \
          --severity "${SEVERITIES}" \
          --ignorefile "${WAIVER_FILE}" \
          --skip-check-update \
          --format json --output "${base_json}" --quiet ) \
        || { yellow "baseline scan failed; gating on presence instead"; : > "${base_json}"; }
    else
      yellow "could not create a worktree for ${base_sha}; gating on presence"
      : > "${base_json}"
    fi
  fi

  echo
  SUMMARY_OUT="${TRIVY_GATE_SUMMARY}" ANN_ERR="${ANN_ERR}" \
    python3 "${REPO_ROOT}/scripts/lib/trivy_delta.py" "${head_json}" "${base_json}"
  local rc=$?

  echo
  case "${rc}" in
    0) green "trivy-gate passed" ;;
    *) red "trivy-gate FAILED"
       red "Fix the finding, or add a PATH-SCOPED waiver with a reason and an"
       red "expiry to ${WAIVER_FILE}. Reproduce locally with:"
       red "    scripts/trivy-gate.sh" ;;
  esac
  return "${rc}"
}

main "$@"
