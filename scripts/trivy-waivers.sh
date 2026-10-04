#!/bin/bash
#
# Lint .trivyignore.yaml. Every waiver must justify and expire itself.
#
# Runs in pre-commit and CI. Needs no Trivy, no cluster and no network: it only
# reads the waiver file, so it is cheap enough to be unconditional.
#
# ---------------------------------------------------------------------------
# WHAT IT ENFORCES, AND WHY EACH RULE EXISTS
#
#   statement present     A waiver with no reason is indistinguishable from a
#                         waiver added to make a build green. Being unable to
#                         write the reason is the signal to fix the finding.
#
#   expired_at present    Without it a waiver is permanent, and permanent
#                         waivers accumulate silently. The old flat
#                         `.trivyignore` had five of them and one was actively
#                         hiding a real defect in our own manifests.
#
#   expiry bounded        A waiver expiring in 2040 is a permanent waiver with
#                         extra steps. MAX_MONTHS caps it.
#
#   not already expired   An expired waiver no longer suppresses anything, so
#                         Trivy has already started failing on it. Saying so
#                         here names the cause instead of leaving someone to
#                         work out why a finding reappeared.
#
#   warn near expiry      WARN_DAYS ahead, so renewal is a decision taken with
#                         time rather than under a red build.
#
# It deliberately does NOT check that a waiver still matches a real finding.
# That needs a full scan, so it lives in scripts/trivy-gate.sh which has one.
#
# USAGE
#   scripts/trivy-waivers.sh              lint, warn near expiry
#   TRIVY_WAIVERS_STRICT=1 ...            treat warnings as failures
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

readonly WAIVER_FILE=".trivyignore.yaml"

# NOT readonly: these are passed to python as command-prefix assignments below,
# and bash refuses `FOO=x cmd` when FOO is readonly -- with an error that names
# the assignment rather than the readonly, which is a confusing five minutes.
MAX_MONTHS=6
WARN_DAYS=30

: "${TRIVY_WAIVERS_STRICT:=0}"

# GitHub Actions renders these as annotations; locally they are bare prefixes.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  ANN_WARN='::warning::'
  ANN_ERR='::error::'
else
  ANN_WARN=''
  ANN_ERR=''
fi

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

main() {
  if [[ ! -f "${WAIVER_FILE}" ]]; then
    red "${ANN_ERR}${WAIVER_FILE} not found."
    red "Refusing to report success: a missing waiver file means every waiver"
    red "silently stopped applying and the SAST gate is about to fail instead."
    return 1
  fi

  # The flat file must not linger. Both would be loaded depending on which
  # --ignorefile a caller passes, and the two would drift.
  if [[ -f ".trivyignore" ]]; then
    red "${ANN_ERR}Both .trivyignore and ${WAIVER_FILE} exist."
    red "Trivy loads whichever --ignorefile names, so the two WILL drift and the"
    red "gate will depend on which caller ran. Delete .trivyignore."
    return 1
  fi

  # `yq` converts to JSON and python reads it with the standard library.
  #
  # Deliberately not PyYAML: it is not installed system-wide on macOS and
  # homebrew's python refuses `pip install` into it (externally-managed), so a
  # bare `bash scripts/trivy-waivers.sh` would fail on a developer machine while
  # passing in the pre-commit hook's own venv. Two behaviours for one script is
  # worse than one more binary.
  #
  # And deliberately not awk: this is nested YAML, and scripts/leak-check.sh is
  # the standing demonstration of what hand-rolling that costs.
  #
  # `yq` is already in `task tools` and `tools:check`.
  if ! command -v yq >/dev/null 2>&1; then
    red "${ANN_ERR}yq not found. Run 'task tools' (or: brew install yq)."
    return 1
  fi

  local json
  if ! json="$(yq -o=json '.' "${WAIVER_FILE}" 2>&1)"; then
    red "${ANN_ERR}${WAIVER_FILE} is not valid YAML:"
    printf '%s\n' "${json}" | sed 's/^/    /'
    red "Trivy would fail to parse it and apply NO waivers at all."
    return 1
  fi

  local rc
  printf '%s' "${json}" | MAX_MONTHS="${MAX_MONTHS}" WARN_DAYS="${WARN_DAYS}" \
    ANN_WARN="${ANN_WARN}" ANN_ERR="${ANN_ERR}" \
    STRICT="${TRIVY_WAIVERS_STRICT}" \
    python3 "${REPO_ROOT}/scripts/lib/trivy_waivers.py"
  rc=$?

  case "${rc}" in
    0) green "trivy-waivers passed" ;;
    2) yellow "trivy-waivers: warnings only (TRIVY_WAIVERS_STRICT=1 to fail)" ; rc=0 ;;
    *) red "trivy-waivers FAILED" ;;
  esac
  return "${rc}"
}

main "$@"
