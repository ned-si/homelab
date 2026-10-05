#!/bin/bash
#
# Run OpenTofu in one of the root modules under bootstrap/, with the two things
# every one of them needs and that must never be in git or on the command line:
#
#   - AWS credentials for the S3 state backend (and the AWS provider). They come
#     from the `aws login` session of profile `homelab`, exported as environment
#     variables, because neither the backend nor the provider can read a login
#     session themselves.
#   - the state encryption passphrase, read from TOFU_STATE_PASSPHRASE in
#     secrets.local.env and passed as TF_VAR_state_passphrase.
#
# Neither value is printed.
#
# Usage:
#   aws login --profile homelab --region eu-central-1   # once per session
#   scripts/tofu.sh <module-dir> <tofu args...>
#
# Examples:
#   scripts/tofu.sh bootstrap/aws-backup init
#   scripts/tofu.sh bootstrap/aws-backup plan
#
# Environment (all optional):
#   TOFU_SECRETS_FILE  passphrase file (default: <repo>/secrets.local.env)
#   TOFU_AWS_PROFILE   profile to export (default: homelab)
#   TOFU_AWS_REGION    region (default: eu-central-1)
#
# Exit codes: tofu's own, or 64 usage, 1 missing passphrase or AWS session.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SECRETS_FILE="${TOFU_SECRETS_FILE:-${ROOT}/secrets.local.env}"
readonly AWS_LOGIN_PROFILE="${TOFU_AWS_PROFILE:-homelab}"
readonly REGION="${TOFU_AWS_REGION:-eu-central-1}"

err() {
  echo "tofu.sh: $*" >&2
}

usage() {
  echo "usage: scripts/tofu.sh <module-dir> <tofu args...>" >&2
  exit 64
}

# Resolves the module directory: as given, or relative to the repository root.
module_dir() {
  local dir=$1
  if [[ ! -d "${dir}" ]]; then
    dir="${ROOT}/${dir}"
  fi
  if ! ls "${dir}"/*.tf > /dev/null 2>&1; then
    err "not an OpenTofu module (no *.tf): $1"
    exit 64
  fi
  (cd "${dir}" && pwd)
}

# Exports TF_VAR_state_passphrase from TOFU_STATE_PASSPHRASE in SECRETS_FILE.
# The value may be bare, 'single-' or "double-quoted".
load_passphrase() {
  local line value
  if [[ ! -r "${SECRETS_FILE}" ]]; then
    err "cannot read ${SECRETS_FILE} (TOFU_STATE_PASSPHRASE lives there)"
    exit 1
  fi
  line="$(grep -E '^TOFU_STATE_PASSPHRASE=' "${SECRETS_FILE}" | tail -n 1 || true)"
  value="${line#TOFU_STATE_PASSPHRASE=}"
  case "${value}" in
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
  esac
  if [[ ${#value} -lt 16 ]]; then
    err "TOFU_STATE_PASSPHRASE missing or shorter than 16 characters in ${SECRETS_FILE}"
    exit 1
  fi
  export TF_VAR_state_passphrase="${value}"
}

# Exports the profile's session as AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_SESSION_TOKEN (and AWS_CREDENTIAL_EXPIRATION). Only those four names are
# accepted from the output, so nothing else can be injected into the
# environment.
export_aws_session() {
  local out line name value
  if ! out="$(AWS_REGION="${REGION}" aws configure export-credentials \
    --profile "${AWS_LOGIN_PROFILE}" --format env)"; then
    err "no valid AWS session for profile ${AWS_LOGIN_PROFILE}; run:"
    err "  aws login --profile ${AWS_LOGIN_PROFILE} --region ${REGION}"
    exit 1
  fi
  while IFS= read -r line; do
    line="${line#export }"
    name="${line%%=*}"
    value="${line#*=}"
    case "${name}" in
      AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY | AWS_SESSION_TOKEN | AWS_CREDENTIAL_EXPIRATION)
        export "${name}=${value}"
        ;;
    esac
  done <<< "${out}"
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    err "aws configure export-credentials returned no credentials for ${AWS_LOGIN_PROFILE}"
    exit 1
  fi
  # The exported variables are the only credential source from here on.
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  export AWS_REGION="${REGION}"
}

main() {
  local dir
  [[ $# -ge 1 ]] || usage
  dir="$(module_dir "$1")"
  shift
  load_passphrase
  export_aws_session
  cd "${dir}"
  exec tofu "$@"
}

main "$@"
