#!/bin/bash
# scripts/ci/tofu-run.sh apply against a fake `tofu`: a failed apply prints
# the whole `Error:` block, not only the last lines of the log.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/tofu" <<'FAKE'
#!/bin/bash
case "$1" in
  init) exit 0 ;;
  plan) for a in "$@"; do case "$a" in -out=*) : > "${a#-out=}" ;; esac; done; exit 2 ;;
  show)
    if [ "$2" = -json ]; then
      echo '{"resource_changes":[{"address":"aws_iam_user.u","change":{"actions":["update"]}}]}'
    else
      echo "  ~ aws_iam_user.u"
    fi ;;
  apply)
    echo "aws_iam_user.u: Modifying..."
    echo "Error: updating IAM User (u): InvalidParameter: tag value must match the allowed characters"
    echo ""
    for i in 1 2 3 4 5 6; do echo "  with aws_iam_user.u, line $i"; done
    exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/tofu"

set +e
o=$(cd "$REPO_ROOT" && PATH="$tmp/bin:$PATH" TF_VAR_state_passphrase=x TOFU_OUT="$tmp/out" \
  bash scripts/ci/tofu-run.sh apply bootstrap/aws-backup 2>&1)
rc=$?
set -e
expect_eq "a failed apply exits 1" 1 "$rc"
# #1362: tail -n 5 kept the source location and dropped the message.
expect_contains "the error message is shown" "InvalidParameter: tag value must match" "$o"
expect_contains "and its location" "with aws_iam_user.u, line 6" "$o"

finish
