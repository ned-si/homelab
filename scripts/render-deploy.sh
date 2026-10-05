#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Render every kustomization into deploy/, the directory Argo CD actually syncs.
#
# WHY RENDERED MANIFESTS
#
# Without this, Argo CD runs kustomize itself at sync time. That has three
# consequences this repo would rather not live with:
#
#   1. What gets applied is not what is in the repo. `git show` tells you the
#      overlay changed; it does not tell you what the cluster will receive. A
#      one-line change to a `labels:` block can rewrite two hundred objects.
#
#   2. The repo-server needs the plugins. KSOPS is an *exec* plugin, so
#      enabling it means `--enable-alpha-plugins --enable-exec` globally on the
#      repo-server: any kustomization it builds may execute a binary. Rendering
#      ahead of time shrinks that blast radius to the three secret directories
#      that genuinely need it.
#
#   3. Renders happen N times, on a machine you are not watching, with network
#      access to fetch remote bases. Doing it once in CI makes it reproducible
#      and reviewable.
#
# So: source of truth stays the kustomizations. deploy/ is BUILD OUTPUT, checked
# in so Argo can read it, and verified in CI to be exactly what the sources
# produce. If deploy/ is ever edited by hand, CI fails.
#
# Layout: deploy/<source dir>/<kind>-<name>.yaml, one file per object (see
# split_objects below).
#
# WHAT IS NOT RENDERED HERE
#
#   */secrets   Rendering these means running KSOPS, which DECRYPTS them. The
#               output would be plaintext Secrets in git -- the exact thing this
#               repo exists to stop. Those three Applications keep pointing at
#               their source directory and keep using the plugin. The skip is
#               enforced below and is not a configuration option.
#
#               What DOES cover them: scripts/secrets-check.sh, which asserts
#               every file a KSOPS generator references exists and is encrypted,
#               without needing the age key.
#
#   Helm charts  Upstream charts stay as versioned `chart:` references. They are
#               not this repo's manifests; Renovate tracks their versions, and a
#               chart upgrade is reviewable as a version bump plus a values
#               diff. Rendering them would add ~50k lines of vendored YAML and
#               take Helm hook ordering away from Argo. See docs/architecture.md.
#
# THE RENDERER IS PINNED, AND IT HAS TO BE
#
# Checking generated output into git only works if the generator is
# deterministic. Two different kustomize versions can order or format the same
# input differently, which shows up as a `--check` failure that has nothing to do
# with anyone's change.
#
# So this uses `kubectl kustomize` -- one binary, already required, with kustomize
# embedded -- and records the embedded version below. EXPECT_KUSTOMIZE is the
# SINGLE SOURCE OF TRUTH for that number; ci.yaml deliberately does not restate
# it, and pins the kubectl release that carries it (KUBECTL_VERSION) instead.
#
# In --check mode a mismatch is FATAL, not a warning. A warning was worthless
# here: --check compares bytes, so the wrong renderer produces a diff that reads
# as "someone forgot to re-render" and sends you looking at the wrong thing.
# Bumping KUBECTL_VERSION therefore means updating EXPECT_KUSTOMIZE and
# re-rendering, in the same commit, and CI will say so.
#
# Note this is unrelated to K8S_VERSION in ci.yaml. That one must track the
# cluster (1.31.2) because it validates against the API schema. This one is a
# local templating engine and never talks to the cluster.
#
# RETRIES, AND WHY ONLY FOR SOME DIRECTORIES
#
# Three kustomizations resolve remote URLs at render time:
# infrastructure/gateway-api, infrastructure/snapshot-controller and
# platform/barman-cloud-plugin. A github.com blip therefore fails a CI job that
# has nothing to do with networking. Those directories -- and only those, keyed
# off an actual URL in the kustomization rather than off a name list or an
# error-message regex -- are retried with backoff, and a final failure is
# labelled NETWORK so it is distinguishable from a broken manifest at a glance.
#
# USAGE
#   scripts/render-deploy.sh            regenerate deploy/
#   scripts/render-deploy.sh --check    fail if deploy/ is not up to date (CI)
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# The kustomize version embedded in the pinned kubectl. The matching kubectl
# release is KUBECTL_VERSION in .github/workflows/ci.yaml.
EXPECT_KUSTOMIZE="v5.8.1"

MODE=render
[ "${1:-}" = "--check" ] && MODE=check

# ---------------------------------------------------------------------------
# Renderer identity. Fatal in check mode, advisory when regenerating (where a
# formatting-only difference is something you are about to see in the diff
# anyway).
# ---------------------------------------------------------------------------
renderer_problem=""
if ! command -v kubectl >/dev/null 2>&1; then
  renderer_problem="kubectl not found on PATH"
else
  actual_kustomize=$(kubectl version --client -o json 2>/dev/null \
                     | sed -n 's/.*"kustomizeVersion": *"\([^"]*\)".*/\1/p')
  if [ -z "$actual_kustomize" ]; then
    renderer_problem="could not read kustomizeVersion from 'kubectl version --client -o json'"
  elif [ "$actual_kustomize" != "$EXPECT_KUSTOMIZE" ]; then
    renderer_problem="kubectl embeds kustomize $actual_kustomize, expected $EXPECT_KUSTOMIZE"
  fi
fi

if [ -n "$renderer_problem" ]; then
  if [ "$MODE" = check ]; then
    echo "WRONG RENDERER: $renderer_problem" >&2
    echo >&2
    echo "deploy/ is byte-compared against a fresh render, so the renderer has to" >&2
    echo "be the pinned one or the comparison is meaningless." >&2
    echo "  - CI: KUBECTL_VERSION in .github/workflows/ci.yaml must carry kustomize" >&2
    echo "        $EXPECT_KUSTOMIZE. If it no longer does, update EXPECT_KUSTOMIZE in" >&2
    echo "        this script and re-render in the same commit." >&2
    echo "  - locally: match that kubectl, or just run 'task render' and let CI check." >&2
    exit 1
  fi
  echo "WARNING: $renderer_problem." >&2
  echo "         Formatting-only differences in deploy/ are probably this, and if" >&2
  echo "         you commit this render CI will report deploy/ as STALE -- it" >&2
  echo "         re-renders with the pinned kubectl and compares bytes." >&2
  echo "         Match KUBECTL_VERSION from ci.yaml, or re-render in CI." >&2
  echo >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT=deploy
[ "$MODE" = check ] && OUT="$WORK/deploy"

# Source directories, in a stable order.
#
# deploy/ is not among the search roots, so it cannot feed itself and needs no
# exclusion. (An earlier `-not -path './deploy/*'` here was dead twice over:
# deploy is not searched, and `find clusters ...` emits paths that do not start
# with `./` for the predicate to match.)
DIRS=$(find clusters infrastructure platform apps -name kustomization.yaml \
         -exec dirname {} \; | sort)

rendered=0; skipped=0; failed=0; netfailed=0

# Attempts for a kustomization that resolves remote URLs. One attempt for
# everything else: a local render that fails once fails every time, and retrying
# it only makes a real error take three times as long to report.
REMOTE_ATTEMPTS=3

rm -rf "$OUT"
mkdir -p "$OUT"

ERRF="$WORK/stderr"

# Render one directory. stdout of `kubectl kustomize` lands in $body; stderr
# lands in $ERRF and is NEVER merged into it.
#
# Do NOT merge them with `2>&1`. `kubectl kustomize` writes deprecation warnings
# to stderr ON SUCCESS, so a merged capture puts the warning text verbatim into
# deploy/ -- invalid YAML, in a file the exit status still calls ok. The
# tree happens to be warning-free today; that is a property of the current
# kustomize version, not of this script.
render_one() {
  : >"$ERRF"
  body=$(kubectl kustomize "$1" 2>"$ERRF")
}

# Only a kustomization that actually names a URL can fail for network reasons.
has_remote_resource() {
  grep -qE 'https?://' "$1/kustomization.yaml" 2>/dev/null
}

# split_objects <out-dir> <source-dir>
#
# Read one rendered kustomize stream on stdin and write ONE FILE PER OBJECT into
# <out-dir>, named `<kind>-<name>.yaml`, lowercase. Only when two objects in the
# same directory would get the same name (same kind and name, different
# namespaces) do both get `-<namespace>` appended. Characters outside
# [a-z0-9.-] become `_` (RBAC names may hold `:`). Every file carries the
# generated-file header, a `---`, then the object exactly as kustomize printed
# it, so `cat <dir>/*.yaml` is a valid multi-document stream again.
#
# Why one file per object: a single concatenated stream per directory is
# unreadable when the question is "what is running". Argo CD reads every
# *.yaml in a directory source, so the set of objects it applies is unchanged.
#
# Parsing is safe on kustomize output only, for the same reason
# published-hostnames.sh gives: documents are separated by `---` at column 0,
# `kind:` is at column 0, and `metadata.name` / `metadata.namespace` are at
# exactly two spaces under `metadata:`. A document without a kind or a name, or
# two objects that still map to one file name, is an error rather than a guess.
split_objects() {
  awk -v dir="$1" -v src="$2" '
    function unquote(s) {
      sub(/[[:space:]]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\x27.*\x27$/) { s = substr(s, 2, length(s) - 2) }
      return s
    }
    function clean(s) { s = tolower(s); gsub(/[^a-z0-9.-]/, "_", s); return s }
    function flush() {
      if (body != "") {
        if (kind == "" || name == "") {
          printf "split: %s: object %d has no kind or metadata.name\n", src, n + 1 > "/dev/stderr"
          bad = 1
        } else {
          n++; K[n] = kind; N[n] = name; NS[n] = ns; B[n] = body
          base = clean(kind) "-" clean(name); C[base]++
        }
      }
      body = ""; kind = ""; name = ""; ns = ""; inmeta = 0
    }
    /^---[[:space:]]*$/ { flush(); next }
    {
      body = body $0 "\n"
      if ($0 ~ /^kind:[[:space:]]/)       { v = $0; sub(/^kind:[[:space:]]*/, "", v); kind = unquote(v) }
      if ($0 ~ /^metadata:[[:space:]]*$/) { inmeta = 1; next }
      if ($0 ~ /^[^[:space:]#]/)          { inmeta = 0 }
      if (inmeta && $0 ~ /^  name:[[:space:]]/)      { v = $0; sub(/^  name:[[:space:]]*/, "", v); name = unquote(v) }
      if (inmeta && $0 ~ /^  namespace:[[:space:]]/) { v = $0; sub(/^  namespace:[[:space:]]*/, "", v); ns = unquote(v) }
    }
    END {
      flush()
      if (bad) { exit 1 }
      for (i = 1; i <= n; i++) {
        f = clean(K[i]) "-" clean(N[i])
        if (C[f] > 1 && NS[i] != "") { f = f "-" clean(NS[i]) }
        if (f in seen) {
          printf "split: %s: %s/%s and another object both map to %s.yaml\n", src, K[i], N[i], f > "/dev/stderr"
          exit 1
        }
        seen[f] = 1
        path = dir "/" f ".yaml"
        # Deliberately no timestamp, no tool version, no hostname: the output
        # has to be byte-identical for identical input or --check is useless.
        printf "# ---------------------------------------------------------------------------\n" > path
        printf "# GENERATED FILE -- DO NOT EDIT.\n#\n" > path
        printf "# Source:     %s\n", src > path
        printf "# Regenerate: task render     (scripts/render-deploy.sh)\n#\n" > path
        printf "# Edit the kustomization in %s and re-render. Editing this file\n", src > path
        printf "# directly will be reverted by the next render and rejected by CI.\n" > path
        printf "# ---------------------------------------------------------------------------\n" > path
        # Leading document marker: `cat <dir>/*.yaml` is then a valid stream.
        printf "%s", "---\n" B[i] > path
        close(path)
      }
      print n
    }
  '
}

for d in $DIRS; do
  # HARD SKIP. See the note above -- rendering a secrets directory decrypts it.
  case "$d" in
    */secrets)
      printf 'skip   %-44s (encrypted; stays on KSOPS)\n' "$d"
      skipped=$((skipped + 1))
      continue
      ;;
  esac
  # A kustomize Component is only meaningful inside the kustomization that
  # uses it; it has no standalone render.
  if grep -qE '^kind:[[:space:]]*Component[[:space:]]*$' "$d/kustomization.yaml"; then
    printf 'skip   %-44s (component; rendered by its users)\n' "$d"
    skipped=$((skipped + 1))
    continue
  fi

  out="$OUT/$d"

  attempts=1
  remote=no
  if has_remote_resource "$d"; then
    attempts=$REMOTE_ATTEMPTS
    remote=yes
  fi

  body=""
  rc=1
  try=1
  while [ "$try" -le "$attempts" ]; do
    if render_one "$d" && [ -n "$body" ]; then
      rc=0
      break
    fi
    rc=1
    if [ "$try" -lt "$attempts" ]; then
      backoff=$((try * 10))
      printf 'retry  %-44s (remote resources; attempt %d failed, sleeping %ds)\n' \
             "$d" "$try" "$backoff"
      sleep "$backoff"
    fi
    try=$((try + 1))
  done

  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    if [ "$remote" = yes ]; then
      printf 'FAIL   %-44s (NETWORK? this kustomization fetches remote URLs)\n' "$d"
      netfailed=$((netfailed + 1))
    else
      printf 'FAIL   %s\n' "$d"
    fi
    sed 's/^/         /' <"$ERRF" | head -5
    failed=$((failed + 1))
    continue
  fi

  # No per-directory cleanup needed: OUT was wiped before the loop, so a file
  # whose object left the source cannot survive as a stale leftover.
  mkdir -p "$out"
  if ! objects=$(printf '%s\n' "$body" | split_objects "$out" "$d"); then
    printf 'FAIL   %s (could not split the render into one file per object)\n' "$d"
    failed=$((failed + 1))
    continue
  fi
  printf 'ok     %-44s %s objects\n' "$d" "$objects"

  # A successful render that still said something. Surfaced here rather than
  # discarded, because a kustomize deprecation notice is the early warning for
  # the next renderer bump -- and it must not end up in the file.
  if [ -s "$ERRF" ]; then
    sed 's/^/       warn: /' <"$ERRF" | head -5 >&2
  fi

  rendered=$((rendered + 1))
done

echo
echo "rendered=$rendered  skipped=$skipped  failed=$failed"

if [ "$failed" -ne 0 ]; then
  if [ "$netfailed" -ne 0 ]; then
    echo >&2
    echo "$netfailed of those fetch remote URLs and were retried $REMOTE_ATTEMPTS times." >&2
    echo "If github.com or raw.githubusercontent.com is having a bad day, this is" >&2
    echo "that and not your change. Re-run the job." >&2
  fi
  echo "render failed -- deploy/ not updated" >&2
  exit 1
fi

if [ "$MODE" = check ]; then
  if diff -r -q deploy "$OUT" >/dev/null 2>&1; then
    echo "deploy/ is up to date"
    exit 0
  fi
  echo >&2
  echo "deploy/ IS STALE. Run 'task render' and commit the result." >&2
  echo >&2
  diff -r -u deploy "$OUT" 2>&1 | head -60 >&2
  exit 1
fi

echo "deploy/ regenerated"
