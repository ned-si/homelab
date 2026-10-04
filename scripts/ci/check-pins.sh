#!/bin/bash
# check-pins.sh [repo-root]
#
# Every `uses:` in .github/workflows/*.y*ml and in every action.y*ml must be one of:
#   owner/repo[/path]@<40-hex commit sha> # v<version>   remote action, SHA-pinned
#   ./.github/actions/<name>                             local action; its own
#                                                        action.y*ml is checked too
#   docker://<image>@sha256:<64 hex>                     container, digest-pinned
# Anything else (a tag, a branch, docker:// without a digest, a missing local
# action) fails with file, line and reason. Exit 0 = all pinned, 1 = violations.
#
# Bash 3.2 compatible (runs on macOS as well as on the runner).
set -euo pipefail

root=${1:-.}
cd "$root"

RX_USES='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(.*)$'
RX_REMOTE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}$'
RX_LOCAL='^\./\.github/actions/[A-Za-z0-9_.-]+$'
RX_DOCKER='^docker://[^@[:space:]]+@sha256:[0-9a-f]{64}$'
RX_VERSION_COMMENT='^#[[:space:]]*v[0-9]'

fail=0
checked=0

report() { # file line reason
  echo "$1:$2: $3" >&2
  fail=1
}

# SC2094: report() only prints the file name; nothing writes to the file being read.
# shellcheck disable=SC2094
check_file() {
  local file=$1 n=0 line rest ref comment
  while IFS= read -r -u 3 line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ $RX_USES ]] || continue
    rest=${BASH_REMATCH[2]}
    comment=""
    # Split "ref  # comment" (a '#' inside the ref is not valid in any allowed form).
    if [[ "$rest" == *"#"* ]]; then
      comment="#${rest#*#}"
      rest=${rest%%#*}
    fi
    # Trim whitespace and optional quotes.
    rest=$(printf '%s' "$rest" | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")
    comment=$(printf '%s' "$comment" | sed -e 's/[[:space:]]*$//')
    ref=$rest
    checked=$((checked + 1))
    if [[ "$ref" =~ $RX_LOCAL ]]; then
      if [ ! -f "${ref#./}/action.yml" ] && [ ! -f "${ref#./}/action.yaml" ]; then
        report "$file" "$n" "local action $ref has no action.yml/action.yaml"
      fi
    elif [[ "$ref" == docker://* ]]; then
      [[ "$ref" =~ $RX_DOCKER ]] || report "$file" "$n" "docker reference without a sha256 digest: $ref"
    elif [[ "$ref" =~ $RX_REMOTE ]]; then
      [[ "$comment" =~ $RX_VERSION_COMMENT ]] || report "$file" "$n" "SHA-pinned action without a '# vX.Y.Z' comment: $ref"
    else
      report "$file" "$n" "not pinned to a 40-hex commit SHA: $ref"
    fi
  done 3< "$file"
}

files=$(
  {
    if [ -d .github/workflows ]; then
      find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \)
    fi
    find . -path ./.git -prune -o -type f \( -name action.yml -o -name action.yaml \) -print
  } | sed 's|^\./||' | sort -u
)

for f in $files; do
  check_file "$f"
done

if [ "$fail" -ne 0 ]; then
  echo "check-pins: FAILED" >&2
  exit 1
fi
echo "check-pins: ${checked} uses: reference(s) pinned"
