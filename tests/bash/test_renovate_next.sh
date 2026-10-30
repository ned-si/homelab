#!/bin/bash
# test_renovate_next.sh -- scripts/ci/renovate-next.sh against a fake `gh`:
# the pull request list comes from $FAKE/prs.json, `behind_by` from
# $FAKE/behind/<sha>, and a PATCH writes its JSON input to $FAKE/patch-<n>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
NEXT="$REPO_ROOT/scripts/ci/renovate-next.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
FAKE="$tmp/fake"
mkdir -p "$FAKE/behind"
cat >"$tmp/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  "pr list") cat "$FAKE/prs.json" ;;
  "api repos/o/r/compare/"*) sha=${2##*...}; cat "$FAKE/behind/$sha" ;;
  "pr merge") echo "$*" >"$FAKE/merge-$3" ;;
  "pr comment") echo "$*" >"$FAKE/comment-$3" ;;
  "api -X")
    n=${4##*/}
    cat >"$FAKE/patch-$n"
    echo '{}'
    ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"
export FAKE

BOX='- [ ] <!-- rebase-check -->If you want to rebase/retry this PR, check this box'
TICKED='- [x] <!-- rebase-check -->If you want to rebase/retry this PR, check this box'

# pr <number> <created> <sha> <ci: SUCCESS|FAILURE|IN_PROGRESS|none> [ticked] [draft] [manual] [label]
pr() {
  local body draft=false am='{"enabledAt":"x"}' checks
  case "$4" in
    none) checks='[]' ;;
    SUCCESS | FAILURE) checks="[{\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"$4\"}]" ;;
    *) checks="[{\"name\":\"ci\",\"status\":\"$4\",\"conclusion\":\"\"}]" ;;
  esac
  body=$BOX
  [ "${5:-}" = ticked ] && body=$TICKED
  [ "${6:-}" = draft ] && draft=true
  [ "${7:-}" = manual ] && am=null
  local labels='[]'
  [ -n "${8:-}" ] && labels="[{\"name\":\"$8\"}]"
  jq -n --argjson n "$1" --arg c "$2" --arg s "$3" --arg b "intro
$body
outro" --argjson d "$draft" --argjson a "$am" --argjson k "$checks" --argjson l "$labels" \
    '{number: $n, createdAt: $c, headRefOid: $s, body: $b, isDraft: $d, autoMergeRequest: $a, statusCheckRollup: $k, labels: $l}'
}
setup() { # <pr json>...
  rm -f "$FAKE"/patch-* "$FAKE"/merge-* "$FAKE"/comment-*
  jq -s . <<<"$*" >"$FAKE/prs.json"
}
behind() { echo "$2" >"$FAKE/behind/$1"; }
run() { REPO=o/r GH="$tmp/gh" NOW="${NOW:-3 10}" "$NEXT" 2>&1; }

echo "renovate-next"

behind a1 3
behind b2 2
behind c3 0

setup "$(pr 12 2026-10-02 b2 SUCCESS)" "$(pr 11 2026-10-01 a1 SUCCESS)"
expect_eq "the oldest behind pull request gets the rebase" "#11: rebase requested" "$(run)"
expect_contains "its box is ticked" "$TICKED" "$(jq -r .body "$FAKE/patch-11")"
expect_eq "the rest of the body is kept" "intro" "$(jq -r '.body | split("\n")[0]' "$FAKE/patch-11")"
expect_eq "no other pull request is touched" "no" "$([ -e "$FAKE/patch-12" ] && echo yes || echo no)"

setup "$(pr 11 2026-10-01 a1 SUCCESS)" "$(pr 13 2026-10-03 c3 IN_PROGRESS)"
expect_eq "an up-to-date pull request with ci running holds the train" "#13: up to date, ci IN_PROGRESS; waiting" "$(run)"

setup "$(pr 11 2026-10-01 a1 SUCCESS)" "$(pr 13 2026-10-03 c3 none)"
expect_eq "an up-to-date pull request without ci yet holds the train" "#13: up to date, ci MISSING; waiting" "$(run)"

setup "$(pr 11 2026-10-01 a1 SUCCESS)" "$(pr 12 2026-10-02 b2 SUCCESS ticked)"
expect_eq "a requested rebase holds the train" "#12: rebase already requested; waiting" "$(run)"

setup "$(pr 11 2026-10-01 a1 FAILURE)" "$(pr 12 2026-10-02 b2 SUCCESS)"
expect_eq "a failed ci is skipped, the next one goes" "#12: rebase requested" "$(run)"

setup "$(pr 11 2026-10-01 a1 SUCCESS x draft)"
expect_eq "drafts are left alone" "no Renovate pull request to merge" "$(run)"

setup "$(pr 10 2026-09-30 a1 SUCCESS x x manual)"
expect_eq "auto-merge turned on, then rebased" "#10: auto-merge turned on
#10: rebase requested" "$(run)"
expect_eq "squash auto-merge" "pr merge 10 --repo o/r --auto --squash" "$(cat "$FAKE/merge-10")"

setup "$(pr 10 2026-09-30 a1 SUCCESS x x manual no-automerge)" "$(pr 12 2026-10-02 b2 SUCCESS)"
expect_eq "no-automerge is left alone" "#12: rebase requested" "$(run)"
expect_eq "no-automerge gets no auto-merge" "no" "$([ -e "$FAKE/merge-10" ] && echo yes || echo no)"

setup "$(pr 10 2026-09-30 a1 SUCCESS x x x automerge-weekdays)" "$(pr 12 2026-10-02 b2 SUCCESS)"
expect_eq "automerge-weekdays waits outside the window" "#12: rebase requested" "$(NOW='6 10' run)"
expect_eq "automerge-weekdays goes inside the window" "#10: rebase requested" "$(NOW='2 16' run)"
expect_eq "automerge-weekdays waits in the evening" "#12: rebase requested" "$(NOW='2 17' run)"

setup "$(pr 13 2026-10-03 c3 FAILURE)"
expect_eq "nothing behind and nothing running: nothing to do" \
  "nothing to rebase: every pull request is up to date or failed ci" "$(run)"

setup "$(pr 13 2026-10-03 c3 SUCCESS)" "$(pr 11 2026-10-01 a1 SUCCESS)"
expect_eq "an up-to-date green pull request does not block (auto-merge owns it)" "#11: rebase requested" "$(run)"

setup "$(pr 11 2026-10-01 a1 SUCCESS)"
expect_eq "dry run changes nothing" "#11: would request a rebase (dry run)" "$(DRY_RUN=1 run)"
expect_eq "dry run wrote no patch" "no" "$([ -e "$FAKE/patch-11" ] && echo yes || echo no)"

# Release age pending: commented once, no auto-merge, no rebase.
young() { # <pr json> <state> [commented]: add the stability status (and the comment)
  local c='[]'
  [ "${3:-}" = commented ] && c='[{"body":"x <!-- renovate-next:release-age -->"}]'
  jq --arg s "$2" --argjson c "$c" '.statusCheckRollup += [{"context":"renovate/stability-days","state":$s}] | .comments = $c' <<<"$1"
}
setup "$(young "$(pr 10 2026-09-30 a1 SUCCESS x x manual)" PENDING)" "$(pr 12 2026-10-02 b2 SUCCESS)"
expect_eq "release age pending: comment, then the next one" "#10: commented: waiting for its release age
#12: rebase requested" "$(run)"
expect_eq "release age pending: no auto-merge" "no" "$([ -e "$FAKE/merge-10" ] && echo yes || echo no)"
expect_contains "the comment says why" "minimumReleaseAge" "$(cat "$FAKE/comment-10")"
setup "$(young "$(pr 10 2026-09-30 a1 SUCCESS x x manual)" PENDING commented)"
expect_eq "commented once" "no Renovate pull request to merge" "$(run)"
setup "$(young "$(pr 10 2026-09-30 a1 SUCCESS x x manual)" SUCCESS commented)"
expect_eq "release age passed: it joins the train" "#10: auto-merge turned on
#10: rebase requested" "$(run)"

finish
