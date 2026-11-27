# shellcheck shell=bash
# Shared helpers for the bash tests. Bash 3.2 compatible.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "  ok   $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL $1"; }

# expect_eq <name> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# expect_contains <name> <needle> <haystack>
expect_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (missing '$2' in: $3)" ;;
  esac
}

finish() {
  echo "  $passed passed, $failed failed"
  [ "$failed" -eq 0 ]
}

# install_fake_gh <dir>: a fake `gh` that behaves like gh 2.102.0 for the calls
# the scripts make. Responses come from $FAKE_GH_DIR:
#   api/<path with / ? = & replaced by _>.status   HTTP status, or one of:
#       neterr (stderr only, exit 1), empty (no output, exit 1),
#       nostatus (body without a status line, exit 0),
#       stderr (the body on stderr, exit 1)
#   api/<...>.body                                  JSON body
#   api/<...>.seq/                                  successive answers (api_seq)
#   pr-view.json, pr-checks.json                    for `gh pr view|checks`
#   stderr-hint                                     printed on stderr first
# Non-2xx responses print the status line, headers and body on stdout, an
# error on stderr, and exit 1, as gh does. Every call is logged to calls.log.
# `pr merge` prints `merged`; with --auto it exits $FAKE_MERGE_RC (default 0).
install_fake_gh() {
  local bindir=$1
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'FAKE'
#!/bin/bash
d=${FAKE_GH_DIR:?}
echo "$*" >> "$d/calls.log"
# gh 2.105 prints agent hints on stderr before the output.
if [ -f "$d/stderr-hint" ]; then cat "$d/stderr-hint" >&2; fi
case "$1 $2" in
  "pr view") cat "$d/pr-view.json"; exit 0 ;;
  "pr checks") cat "$d/pr-checks.json"; exit "$(cat "$d/pr-checks.exit" 2>/dev/null || echo 0)" ;;
  "pr merge")
    echo "merged"
    case " $* " in *" --auto "*) exit "${FAKE_MERGE_RC:-0}" ;; esac
    exit 0 ;;
esac
[ "$1" = "api" ] || { echo "fake gh: unsupported: $*" >&2; exit 2; }
shift
include=0; jqexpr=""; path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --include|-i) include=1 ;;
    --paginate) ;;
    --jq|-q) shift; jqexpr=$1 ;;
    -*) ;;
    *) path=$1 ;;
  esac
  shift
done
key=$(printf '%s' "$path" | tr '/?=&' '____')
src="$d/api/$key"
if [ -d "$d/api/$key.seq" ]; then
  # The next answer of the sequence; the last one repeats.
  i=$(( $(cat "$d/api/$key.seq/n" 2>/dev/null || echo 0) + 1 ))
  [ -f "$d/api/$key.seq/$i.status" ] || i=$((i - 1))
  echo "$i" > "$d/api/$key.seq/n"
  src="$d/api/$key.seq/$i"
fi
status=$(cat "$src.status" 2>/dev/null || echo 404)
body=$(cat "$src.body" 2>/dev/null || echo '{"message":"Not Found","status":"404"}')
case "$status" in
  neterr) echo "error connecting to api.github.com" >&2; exit 1 ;;
  stderr) printf '%s\n' "$body" >&2; exit 1 ;;
  empty) exit 1 ;;
  nostatus) echo "$body"; exit 0 ;;
esac
if [ "$include" = 1 ]; then
  printf 'HTTP/2.0 %s Fake\r\nContent-Type: application/json; charset=utf-8\r\nX-Github-Request-Id: FAKE\r\n\r\n' "$status"
fi
if [ -n "$jqexpr" ] && [ "${status:0:1}" = 2 ]; then
  printf '%s\n' "$body" | jq -r "$jqexpr"
else
  printf '%s\n' "$body"
fi
if [ "${status:0:1}" != 2 ]; then
  echo "gh: Fake error (HTTP $status)" >&2
  exit 1
fi
exit 0
FAKE
  chmod +x "$bindir/gh"
}

# api_resp <path> <status> [body]
api_resp() {
  local key
  key=$(printf '%s' "$1" | tr '/?=&' '____')
  mkdir -p "$FAKE_GH_DIR/api"
  printf '%s\n' "$2" > "$FAKE_GH_DIR/api/$key.status"
  if [ "$#" -ge 3 ]; then printf '%s\n' "$3" > "$FAKE_GH_DIR/api/$key.body"; fi
}

# api_seq <path> <status> <body> [<status> <body>]...: successive answers,
# the last one repeats.
api_seq() {
  local key dir i=0
  key=$(printf '%s' "$1" | tr '/?=&' '____')
  dir="$FAKE_GH_DIR/api/$key.seq"
  rm -rf "$dir"
  mkdir -p "$dir"
  shift
  while [ "$#" -ge 2 ]; do
    i=$((i + 1))
    printf '%s\n' "$1" > "$dir/$i.status"
    printf '%s\n' "$2" > "$dir/$i.body"
    shift 2
  done
}
