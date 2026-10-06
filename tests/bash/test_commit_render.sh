#!/bin/bash
# test_commit_render.sh -- scripts/ci/commit-render.sh against a stubbed `gh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../scripts/ci/commit-render.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Stub gh: log every call and its stdin, answer with fixed SHAs.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/bash
n=$(( $(ls "$GH_LOG" 2>/dev/null | wc -l) + 1 ))
printf '%s\n' "$*" > "$GH_LOG/$n.args"
case " $* " in *" --input - "*) cat > "$GH_LOG/$n.stdin" ;; esac
case "$*" in
  "api repos/o/r/git/blobs "*)      echo blob$n ;;
  "api repos/o/r/git/commits/"*)    echo basetree ;;
  "api repos/o/r/git/trees "*)      echo tree1 ;;
  "api repos/o/r/git/commits "*)    echo commit1 ;;
  "api -X PATCH repos/o/r/git/refs/heads/renovate/x "*) echo '{}' ;;
  "workflow run ci.yaml --repo o/r --ref renovate/x") ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/log" REPO=o/r BRANCH=renovate/x

repo="$tmp/repo"
mkdir -p "$repo/deploy" "$GH_LOG"
cd "$repo"
git init -q
git config user.email t@example.invalid
git config user.name t
git config commit.gpgsign false
echo a > deploy/a.yaml
echo b > deploy/b.yaml
git add -A
git commit -qm init
HEAD_SHA=$(git rev-parse HEAD)
export HEAD_SHA

# 1. Nothing changed: no API call.
out=$("$SCRIPT" 2>&1) || fail "up-to-date run exited non-zero: $out"
grep -q 'up to date' <<<"$out" || fail "up-to-date run did not say so: $out"
[ -z "$(ls "$GH_LOG")" ] || fail "up-to-date run called gh"

# 2. Wrong checkout is refused.
if HEAD_SHA=0000000000000000000000000000000000000000 "$SCRIPT" >/dev/null 2>&1; then
  fail "a checkout that is not HEAD_SHA was accepted"
fi

# 3. One modified, one deleted, one added file.
echo a2 > deploy/a.yaml
rm deploy/b.yaml
echo c > deploy/c.yaml
out=$("$SCRIPT" 2>&1) || fail "change run exited non-zero: $out"

blobs=$(grep -l '^api repos/o/r/git/blobs ' "$GH_LOG"/*.args | wc -l | tr -d ' ')
[ "$blobs" = 2 ] || fail "expected 2 blobs, got $blobs"
blob_in=$(cat "$(grep -l '^api repos/o/r/git/blobs ' "$GH_LOG"/*.args | head -n 1 | sed 's/args$/stdin/')")
[ "$(jq -r .encoding <<<"$blob_in")" = base64 ] || fail "blob is not base64: $blob_in"

tree_in=$(cat "$(grep -l '^api repos/o/r/git/trees ' "$GH_LOG"/*.args | sed 's/args$/stdin/')")
[ "$(jq -r .base_tree <<<"$tree_in")" = basetree ] || fail "tree has the wrong base: $tree_in"
[ "$(jq -r '.tree[] | select(.path == "deploy/b.yaml") | .sha' <<<"$tree_in")" = null ] \
  || fail "deleted file is not a null-sha entry: $tree_in"
[ "$(jq -r '[.tree[].path] | sort | join(",")' <<<"$tree_in")" = "deploy/a.yaml,deploy/b.yaml,deploy/c.yaml" ] \
  || fail "tree paths are wrong: $tree_in"

commit_in=$(cat "$(grep -lx 'api repos/o/r/git/commits --input - --jq .sha' "$GH_LOG"/*.args | sed 's/args$/stdin/')")
[ "$(jq -r '.parents | join(",")' <<<"$commit_in")" = "$HEAD_SHA" ] || fail "commit parent is not HEAD_SHA: $commit_in"
[ "$(jq -r 'has("author") or has("committer")' <<<"$commit_in")" = false ] \
  || fail "commit sets an author or committer, so GitHub would not sign it: $commit_in"
"$HERE/../../scripts/ci/check-title.sh" "$(jq -r .message <<<"$commit_in")" \
  || fail "commit subject fails check-title.sh"

ref_in=$(cat "$(grep -l '^api -X PATCH ' "$GH_LOG"/*.args | sed 's/args$/stdin/')")
[ "$(jq -c . <<<"$ref_in")" = '{"sha":"commit1","force":false}' ] || fail "ref update is wrong: $ref_in"

grep -qx 'workflow run ci.yaml --repo o/r --ref renovate/x' "$GH_LOG"/*.args || fail "ci.yaml was not dispatched"

if [ "$fails" -gt 0 ]; then
  echo "test_commit_render: $fails failure(s)"
  exit 1
fi
echo "test_commit_render: ok"
