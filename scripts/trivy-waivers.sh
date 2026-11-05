#!/bin/bash
#
# Lint .trivyignore.yaml: every waiver has a `statement`, an `expired_at`
# within MAX_MONTHS, is not expired (a finding would reappear unexplained),
# and warns WARN_DAYS before expiry. Reads only the file. Whether a waiver
# still matches a finding is scripts/trivy-gate.sh's job.
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

  # yq to JSON, read by the standard library: no PyYAML on macOS's python,
  # and awk on nested YAML is a mistake.
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
