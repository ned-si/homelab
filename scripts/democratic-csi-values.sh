#!/bin/bash
# democratic-csi-values.sh
#
# Print the `driver.config` Helm values overlay for the democratic-csi release
# `iscsi`, decrypted from infrastructure/democratic-csi/driver-config.sops.yaml.
# Use it only as a process substitution, so the plaintext never reaches disk:
#
#   helm upgrade iscsi democratic-csi --repo https://democratic-csi.github.io/charts/ \
#     --version 0.14.7 -n democratic-csi \
#     -f infrastructure/democratic-csi/values-iscsi.yaml -f <(scripts/democratic-csi-values.sh)
#
# The sealed file is the Secret the chart renders from `driver.config`
# (key driver-config-file.yaml); parsing it back gives the same values, so the
# rendered Secret and the pods' checksum/secret annotation stay unchanged.
# Requires: sops (with the age identity, see scripts/lib/sops-age.sh), yq v4.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/sops-age.sh
. "$ROOT/scripts/lib/sops-age.sh"

sops -d "$ROOT/infrastructure/democratic-csi/driver-config.sops.yaml" \
  | yq '{"driver": {"config": (.stringData["driver-config-file.yaml"] | from_yaml)}}'
