#!/bin/bash
# scripts/tofu.sh against a fake `aws` and a fake `tofu`: credentials and the
# passphrase reach tofu through the environment, tofu runs in the module
# directory with the given arguments, and neither secret is ever printed.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/mod"
touch "$tmp/mod/main.tf"

PASS='test-passphrase-0123456789abcdef+/='
SECRET='fake-secret-key-value'

# Fake aws: `configure export-credentials` prints env lines (plus one line
# that must not be exported), or fails when FAKE_AWS_FAIL is set.
cat > "$tmp/bin/aws" <<FAKE
#!/bin/bash
echo "\$*" >> "$tmp/aws.log"
[ -z "\${FAKE_AWS_FAIL:-}" ] || { echo "session expired" >&2; exit 255; }
echo "export AWS_ACCESS_KEY_ID=ASIAFAKE"
echo "export AWS_SECRET_ACCESS_KEY=$SECRET"
echo "export AWS_SESSION_TOKEN=fake-token"
echo "export AWS_CREDENTIAL_EXPIRATION=2099-01-01T00:00:00Z"
echo "export PATH=/injected"
FAKE

# Fake tofu: records where it ran, its arguments and the relevant environment.
cat > "$tmp/bin/tofu" <<FAKE
#!/bin/bash
{
  echo "pwd=\$(pwd)"
  echo "args=\$*"
  echo "pass=\${TF_VAR_state_passphrase:-}"
  echo "key=\${AWS_ACCESS_KEY_ID:-} secret=\${AWS_SECRET_ACCESS_KEY:-} token=\${AWS_SESSION_TOKEN:-}"
  echo "region=\${AWS_REGION:-} profile=\${AWS_PROFILE:-unset}"
} > "$tmp/tofu.log"
FAKE
chmod +x "$tmp/bin/aws" "$tmp/bin/tofu"
export PATH="$tmp/bin:$PATH"
export AWS_PROFILE=some-other-profile
export TOFU_SECRETS_FILE="$tmp/secrets.local.env"
printf "# comment\nOTHER='x'\nTOFU_STATE_PASSPHRASE='%s'\n" "$PASS" > "$TOFU_SECRETS_FILE"

out=$(bash "$REPO_ROOT/scripts/tofu.sh" "$tmp/mod" plan -lock-timeout=60s 2>&1)
log=$(cat "$tmp/tofu.log")
expect_contains "runs in the module dir" "pwd=$(cd "$tmp/mod" && pwd)" "$log"
expect_contains "passes the arguments" "args=plan -lock-timeout=60s" "$log"
expect_contains "passphrase unquoted into TF_VAR" "pass=$PASS" "$log"
expect_contains "session exported" "key=ASIAFAKE secret=$SECRET token=fake-token" "$log"
expect_contains "region set, AWS_PROFILE unset" "region=eu-central-1 profile=unset" "$log"
expect_contains "exports profile homelab" "configure export-credentials --profile homelab --format env" "$(cat "$tmp/aws.log")"
case "$out" in
  *"$PASS"* | *"$SECRET"*) bad "secrets not printed" ;;
  *) ok "secrets not printed" ;;
esac

# Module dir relative to the repository root.
rm -f "$tmp/tofu.log"
bash "$REPO_ROOT/scripts/tofu.sh" bootstrap/aws-backup version > /dev/null 2>&1
expect_contains "repo-relative module dir" "pwd=$REPO_ROOT/bootstrap/aws-backup" "$(cat "$tmp/tofu.log")"

# Double-quoted passphrase.
printf 'TOFU_STATE_PASSPHRASE="%s"\n' "$PASS" > "$TOFU_SECRETS_FILE"
bash "$REPO_ROOT/scripts/tofu.sh" "$tmp/mod" plan > /dev/null 2>&1
expect_contains "double-quoted passphrase" "pass=$PASS" "$(cat "$tmp/tofu.log")"

# Failures: tofu must not run.
rm -f "$tmp/tofu.log"
printf "OTHER='x'\n" > "$TOFU_SECRETS_FILE"
rc=0; out=$(bash "$REPO_ROOT/scripts/tofu.sh" "$tmp/mod" plan 2>&1) || rc=$?
expect_eq "missing passphrase -> exit 1" 1 "$rc"
expect_contains "missing passphrase message" "TOFU_STATE_PASSPHRASE missing" "$out"
expect_eq "missing passphrase -> tofu not run" no "$([ -f "$tmp/tofu.log" ] && echo yes || echo no)"

printf "TOFU_STATE_PASSPHRASE='%s'\n" "$PASS" > "$TOFU_SECRETS_FILE"
rc=0; out=$(FAKE_AWS_FAIL=1 bash "$REPO_ROOT/scripts/tofu.sh" "$tmp/mod" plan 2>&1) || rc=$?
expect_eq "expired session -> exit 1" 1 "$rc"
expect_contains "expired session names aws login" "aws login --profile homelab --region eu-central-1" "$out"
expect_eq "expired session -> tofu not run" no "$([ -f "$tmp/tofu.log" ] && echo yes || echo no)"

rc=0; bash "$REPO_ROOT/scripts/tofu.sh" "$tmp" plan > /dev/null 2>&1 || rc=$?
expect_eq "not a module -> exit 64" 64 "$rc"
rc=0; bash "$REPO_ROOT/scripts/tofu.sh" > /dev/null 2>&1 || rc=$?
expect_eq "no arguments -> exit 64" 64 "$rc"

finish
