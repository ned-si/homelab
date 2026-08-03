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
# WHAT IS NOT RENDERED HERE
#
#   */secrets   Rendering these means running KSOPS, which DECRYPTS them. The
#               output would be plaintext Secrets in git -- the exact thing this
#               repo exists to stop. Those three Applications keep pointing at
#               their source directory and keep using the plugin. The skip is
#               enforced below and is not a configuration option.
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
# embedded -- and records the embedded version below. CI installs exactly this
# kubectl. If your local kubectl differs you get a warning, because a formatting-
# only diff in deploy/ is almost always this and not your edit.
#
# Note this is unrelated to K8S_VERSION in ci.yaml. That one must track the
# cluster (1.31.2) because it validates against the API schema. This one is a
# local templating engine and never talks to the cluster.
#
# USAGE
#   scripts/render-deploy.sh            regenerate deploy/
#   scripts/render-deploy.sh --check    fail if deploy/ is not up to date (CI)
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The kustomize version embedded in the pinned kubectl. Keep in step with
# KUBECTL_VERSION in .github/workflows/ci.yaml.
EXPECT_KUSTOMIZE="v5.8.1"

actual_kustomize=$(kubectl version --client -o json 2>/dev/null \
                   | sed -n 's/.*"kustomizeVersion": *"\([^"]*\)".*/\1/p')
if [ -n "$actual_kustomize" ] && [ "$actual_kustomize" != "$EXPECT_KUSTOMIZE" ]; then
  echo "WARNING: kubectl embeds kustomize $actual_kustomize, expected $EXPECT_KUSTOMIZE." >&2
  echo "         Formatting-only differences in deploy/ are probably this." >&2
  echo "         CI pins KUBECTL_VERSION; match it or re-render there." >&2
  echo >&2
fi

MODE=render
[ "${1:-}" = "--check" ] && MODE=check

OUT=deploy
if [ "$MODE" = check ]; then
  OUT="$(mktemp -d)/deploy"
  trap 'rm -rf "$(dirname "$OUT")"' EXIT
fi

# Source directories, in a stable order. `deploy/` is excluded so a stale render
# can never feed itself.
DIRS=$(find clusters infrastructure platform apps -name kustomization.yaml \
         -not -path './deploy/*' -exec dirname {} \; | sort)

rendered=0; skipped=0; failed=0

rm -rf "$OUT"
mkdir -p "$OUT"

for d in $DIRS; do
  # HARD SKIP. See the note above -- rendering a secrets directory decrypts it.
  case "$d" in
    */secrets)
      printf 'skip   %-44s (encrypted; stays on KSOPS)\n' "$d"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  out="$OUT/$d/manifests.yaml"
  mkdir -p "$(dirname "$out")"

  body=$(kubectl kustomize "$d" 2>&1)
  if [ $? -ne 0 ] || [ -z "$body" ]; then
    printf 'FAIL   %s\n' "$d"
    printf '%s\n' "$body" | head -3 | sed 's/^/         /'
    failed=$((failed + 1))
    continue
  fi

  # Deliberately no timestamp, no tool version, no hostname: the output has to
  # be byte-identical for identical input or --check is useless.
  {
    echo "# ---------------------------------------------------------------------------"
    echo "# GENERATED FILE -- DO NOT EDIT."
    echo "#"
    echo "# Source:     $d"
    echo "# Regenerate: task render     (scripts/render-deploy.sh)"
    echo "#"
    echo "# Edit the kustomization in $d and re-render. Editing this file"
    echo "# directly will be reverted by the next render and rejected by CI."
    echo "# ---------------------------------------------------------------------------"
    printf '%s\n' "$body"
  } > "$out"

  objects=$(grep -c '^kind:' "$out")
  printf 'ok     %-44s %s objects\n' "$d" "$objects"
  rendered=$((rendered + 1))
done

echo
echo "rendered=$rendered  skipped=$skipped  failed=$failed"

if [ "$failed" -ne 0 ]; then
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
