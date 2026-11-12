#!/bin/bash
#
# Give every restic writer namespace its own S3 key and repository password
# (assessment P6, #1289). Run once by the operator, on the Mac:
#
#   aws login --profile homelab --region eu-central-1
#   scripts/restic-rekey.sh            # then review and commit the two files
#
# For each namespace of bootstrap/aws-backup `restic_writers`:
#   1. a new random password becomes an extra key (`restic key add`) on the
#      namespace's repositories, opened with the shared password. immich also
#      has the NAS copy, re-keyed by a one-off Pod in the cluster (the NFS
#      export only serves the nodes);
#   2. the new password and the namespace's own IAM key (tofu output
#      restic_access_keys) must open the repository: `restic cat config`;
#   3. the namespace's s3-backup Secret gets them (s3-backup.sops.yaml,
#      signoz-backup-s3.sops.yaml), re-sealed with sops.
# The shared password stays a key of every repository: backup-verify reads all
# of them with it, and keeps the shared Secret. The keycloak copy of s3-backup
# (read by nothing) is removed.
#
# Nothing secret is printed. Re-running skips a namespace whose Secret already
# holds its own IAM key. secrets.local.env keeps only the shared password, so
# `task secrets:seal:all --force` would undo this; seal these two files by hand.
set -euo pipefail
umask 077

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
export TOFU_SECRETS_FILE=${TOFU_SECRETS_FILE:-$MAIN/secrets.local.env}
S3=s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups
SHARED=platform/secrets/s3-backup.sops.yaml
SIGNOZ=platform/secrets/signoz-backup-s3.sops.yaml
IMAGE=restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510
repo_of() { # namespace -> repository path under the bucket (main.tf restic_writers)
  case $1 in
    books | home) echo "$1/configs" ;;
    immich) echo immich/library ;;
    mealie | syncthing) echo "$1/data" ;;
    monitoring) echo grafana/data ;;
    paperless) echo paperless/media ;;
    signoz) echo signoz/metadata ;;
    theater) echo theater/configs ;;
  esac
}

for t in restic sops yq jq openssl kubectl; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

TMP=$(mktemp -d)
trap '/bin/rm -rf "$TMP"' EXIT
. ./scripts/lib/sops-age.sh && sops_age_env

# A new worktree has no .terraform yet: init reads the backend, changes nothing.
scripts/tofu.sh bootstrap/aws-backup init -input=false >"$TMP/tofu.err" 2>&1 ||
  { sed -n '/Error/,$p' "$TMP/tofu.err" >&2; exit 1; }
scripts/tofu.sh bootstrap/aws-backup output -json restic_access_keys >"$TMP/keys.json" 2>"$TMP/tofu.err" ||
  { sed -n '/Error/,$p' "$TMP/tofu.err" >&2; exit 1; }
sops -d "$SHARED" >"$TMP/shared.yaml"
sops -d "$SIGNOZ" >"$TMP/signoz.yaml"

# The shared password, from the backup-verify copy (whose S3 key only reads:
# the key is added with the namespace's own, which can write its prefix).
field() { yq "select(.metadata.namespace == \"$2\") | .stringData.$3" "$1"; }
field "$TMP/shared.yaml" backup-verify RESTIC_PASSWORD | tr -d '\n' >"$TMP/old.pw"

rc=0
for ns in $(jq -r 'keys[]' "$TMP/keys.json"); do
  repo=$(repo_of "$ns")
  [ -n "$repo" ] || { echo "FAIL $ns: no repository known"; rc=1; continue; }
  file=$TMP/shared.yaml
  [ "$ns" = signoz ] && file=$TMP/signoz.yaml
  NEW_ID=$(jq -r --arg n "$ns" '.[$n].id' "$TMP/keys.json")
  if [ "$(field "$file" "$ns" AWS_ACCESS_KEY_ID)" = "$NEW_ID" ]; then
    echo "skip $ns: already has its own key"
    continue
  fi
  NEW_SECRET=$(jq -r --arg n "$ns" '.[$n].secret' "$TMP/keys.json")
  openssl rand -base64 32 | tr -d '\n' >"$TMP/$ns.pw"

  AWS_ACCESS_KEY_ID=$NEW_ID AWS_SECRET_ACCESS_KEY=$NEW_SECRET \
    restic -q -r "$S3/$repo" --password-file "$TMP/old.pw" key add \
    --new-password-file "$TMP/$ns.pw" --host "$ns" --user "$ns-writer"
  if ! AWS_ACCESS_KEY_ID=$NEW_ID AWS_SECRET_ACCESS_KEY=$NEW_SECRET \
    restic -q -r "$S3/$repo" --password-file "$TMP/$ns.pw" cat config >/dev/null; then
    echo "FAIL $ns: the new key and password do not open $repo"; rc=1; continue
  fi

  if [ "$ns" = immich ]; then
    kubectl -n immich create secret generic restic-rekey \
      --from-file=old="$TMP/old.pw" --from-file=new="$TMP/$ns.pw" >/dev/null
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: restic-rekey, namespace: immich}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: rekey
      image: $IMAGE
      args: [-q, -r, /backups/immich/library, --password-file, /pw/old, key, add,
             --new-password-file, /pw/new, --host, immich, --user, immich-writer]
      env: [{name: RESTIC_CACHE_DIR, value: /tmp}]
      resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: pw, mountPath: /pw, readOnly: true}, {name: backups, mountPath: /backups}, {name: tmp, mountPath: /tmp}]
  volumes:
    - {name: pw, secret: {secretName: restic-rekey}}
    - {name: backups, nfs: {server: 192.168.1.228, path: /mnt/homelab/k8s/backups}}
    - {name: tmp, emptyDir: {}}
EOF
    kubectl -n immich wait pod/restic-rekey --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m >/dev/null ||
      { echo "FAIL immich: NAS re-key Pod did not succeed"; kubectl -n immich logs restic-rekey | tail -5; rc=1; }
    kubectl -n immich delete pod/restic-rekey secret/restic-rekey >/dev/null
    [ "$rc" = 0 ] || continue
  fi

  NS=$ns NEW_ID=$NEW_ID NEW_SECRET=$NEW_SECRET PW=$(cat "$TMP/$ns.pw") yq -i '
    (select(.metadata.namespace == strenv(NS)) | .stringData) |= (
      .AWS_ACCESS_KEY_ID = strenv(NEW_ID) | .AWS_SECRET_ACCESS_KEY = strenv(NEW_SECRET) |
      .RESTIC_PASSWORD = strenv(PW) |
      with(select(has("ACCESS_KEY_ID")); .ACCESS_KEY_ID = strenv(NEW_ID) | .ACCESS_SECRET_KEY = strenv(NEW_SECRET)))' "$file"
  echo "ok   $ns: own key and password on $repo$([ "$ns" = immich ] && echo ' and the NAS copy')"
done

yq -i 'select(.metadata.namespace != "keycloak")' "$TMP/shared.yaml"
for pair in "shared.yaml:$SHARED" "signoz.yaml:$SIGNOZ"; do
  cp "$TMP/${pair%%:*}" "${pair#*:}"
  sops --encrypt --in-place "${pair#*:}"
  sops -d "${pair#*:}" >/dev/null
done
echo "sealed $SHARED $SIGNOZ"
exit "$rc"
