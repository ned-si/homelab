#!/bin/bash
# drumcharts-data.sh <out dir> -- verify the pinned drum-charts data image and
# copy its /charts into <out dir> (.kiro/specs/drum-charts-site/design.md#the-pin).
#
# The pin in drumcharts/source.yaml must be ghcr.io/ned-si/drum-charts:main by
# digest; cosign must find a signature by DRUMCHARTS_IDENTITY (default: the
# drum-charts build workflow on main; set only by the negative test in
# drumcharts-check.sh) before anything is read. No container runs. Needs
# docker and cosign on PATH.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: drumcharts-data.sh <out dir>" >&2; exit 2; }
out=$1
root=$(git rev-parse --show-toplevel)
identity=${DRUMCHARTS_IDENTITY:-https://github.com/ned-si/drum-charts/.github/workflows/build.yaml@refs/heads/main}

ref=$(sed -n 's/^image: *//p' "$root/drumcharts/source.yaml")
pin='^ghcr\.io/ned-si/drum-charts:main@sha256:[0-9a-f]{64}$'
# One line only: a second image: line puts a newline in $ref.
if ! [[ $ref =~ $pin ]]; then
  echo "drumcharts/source.yaml: not a pinned drum-charts image" >&2
  exit 1
fi

cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "$identity" "$ref" >/dev/null

id=$(docker create --platform linux/amd64 "$ref" /none)
trap 'docker rm "$id" >/dev/null' EXIT
mkdir -p "$out"
if ! docker cp "$id:/charts/." "$out"; then
  echo "$ref: no /charts in the image" >&2
  exit 1
fi
echo "drumcharts-data: $ref verified, its /charts in $out"
