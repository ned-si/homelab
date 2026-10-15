#!/bin/bash
# tofu-run.sh plan|apply <module-dir> -- the steps of .github/workflows/tofu.yaml.
#
#   plan   tofu init, then tofu plan -lock=false (the plan role cannot write the
#          lock object). Writes the result to $TOFU_OUT/<name>.{status,md,txt}.
#   apply  tofu init, tofu plan with the lock, then tofu apply of that saved
#          plan only when it creates or updates; a plan that deletes, replaces
#          or forgets anything is refused (exit 3) and left for a hand apply
#          (scripts/tofu.sh).
#
# <name> is the module path with / replaced by -. Status words: no-changes,
# changes, destructive (scripts/ci/tofu_plan_summary.py).
#
# Environment:
#   TF_VAR_state_passphrase  the state passphrase (Actions secret)
#   AWS_*                    credentials from aws-actions/configure-aws-credentials
#   AWS_ACCOUNT_ID           replaced by <account> in every written file, which
#                            may end up in a public pull request comment
#   TOFU_OUT                 output directory (default $RUNNER_TEMP/tofu)
#
# Nothing from the plan is printed except the summary: `tofu show -json` holds
# sensitive values in clear, so it stays in a temp file that is deleted on exit.
# Exit: 0 done, 1 tofu error, 3 destructive plan refused, 64 usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode=${1:-}
module=${2:-}
case "$mode" in plan | apply) ;; *) echo "usage: tofu-run.sh plan|apply <module-dir>" >&2; exit 64 ;; esac
if [ -z "$module" ] || ! ls "$ROOT/$module"/*.tf > /dev/null 2>&1; then
  echo "tofu-run: not a module: $module" >&2
  exit 64
fi
: "${TF_VAR_state_passphrase:?TF_VAR_state_passphrase is not set}"

name=${module//\//-}
out=${TOFU_OUT:-${RUNNER_TEMP:?RUNNER_TEMP not set}/tofu}
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Variables without a default, per module. The names are public (backend
# blocks, docs); nothing secret is passed on the command line.
vars=()
case "$module" in
  bootstrap/aws-backup) vars+=(-var "bucket_name=ned-si-homelab-backups") ;;
esac

mask() { # file: drop the account ID
  if [ -n "${AWS_ACCOUNT_ID:-}" ]; then
    sed -i "s/${AWS_ACCOUNT_ID}/<account>/g" "$1"
  fi
}

cd "$ROOT/$module"
tofu init -input=false -no-color > "$work/init.log" 2>&1 || {
  mask "$work/init.log"; tail -n 20 "$work/init.log" >&2; exit 1
}

lock=true
[ "$mode" = plan ] && lock=false
rc=0
tofu plan -input=false -no-color -lock="$lock" -detailed-exitcode -out="$work/plan.bin" \
  ${vars[@]+"${vars[@]}"} > "$work/plan.log" 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  mask "$work/plan.log"
  tail -n 30 "$work/plan.log" >&2
  printf 'status=error\n**%s**: plan failed\n' "$module" > "$out/$name.md"
  echo error > "$out/$name.status"
  exit 1
fi

tofu show -json "$work/plan.bin" > "$work/plan.json"
tofu show -no-color "$work/plan.bin" > "$out/$name.txt"
mask "$out/$name.txt"
python3 "$ROOT/scripts/ci/tofu_plan_summary.py" "$work/plan.json" "$module" > "$work/summary"
mask "$work/summary"
status=$(sed -n '1s/^status=//p' "$work/summary")
sed '1d' "$work/summary" > "$out/$name.md"
echo "$status" > "$out/$name.status"
cat "$out/$name.md"

[ "$mode" = apply ] || exit 0
case "$status" in
  no-changes) exit 0 ;;
  destructive)
    echo "tofu-run: $module: the plan deletes, replaces or forgets a resource; apply it by hand" >&2
    exit 3 ;;
esac
rc=0
tofu apply -input=false -no-color "$work/plan.bin" > "$work/apply.log" 2>&1 || rc=$?
mask "$work/apply.log"
# The apply log repeats the plan, sensitive values masked by tofu.
tail -n 5 "$work/apply.log"
exit "$rc"
