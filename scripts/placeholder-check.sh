#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Refuse to let a placeholder reach the cluster.
#
# THE PROBLEM THIS SOLVES
#
# `homelab-backups-REPLACE-ME` appears in six manifests and
# `REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` in .sops.yaml. Every check in this repo
# passes on all of it: it is well-formed YAML, it validates against the API
# schema, it renders deterministically, and it contains no secrets. The
# verification layer had nothing to say about the fact that the S3 destination is
# a string nobody has filled in, so the first real backup would have written to a
# bucket that does not exist -- or, worse, to one that someone else registered.
#
# A placeholder is not a syntax error. It needs its own check.
#
# TEMPLATE vs MANIFEST
#
# The distinction that makes this usable: a placeholder in a TEMPLATE is the
# template doing its job, and a placeholder in something that will be APPLIED is
# a bug. So `*.example` and friends are out of scope by construction (see
# is_template), and everything Argo syncs is in scope.
#
# THE ALLOWLIST
#
# scripts/placeholder-allowlist.tsv defers one specific placeholder, with a
# reason, without turning the check off. Every entry must name the command that
# removes it. An entry with no reason is rejected; an entry that matches nothing
# is reported as stale.
#
# Rejected alternative: making this a warning. A warning is what the repo already
# had -- the placeholders were visible in every render and nobody was told they
# mattered.
#
# USAGE
#   scripts/placeholder-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

ALLOWLIST=scripts/placeholder-allowlist.tsv

# Extended regex. Kept explicit rather than clever: a pattern like `<[A-Z_]+>`
# would sweep up legitimate angle-bracket text, and a check that cries wolf gets
# an --skip added to it within a week.
TOKENS_RE='REPLACE[-_]ME|REPLACE[-_]WITH|CHANGE[-_]?ME|TODO[-_]BEFORE[-_]DEPLOY|FIXME[-_]BEFORE[-_]DEPLOY|PUT[-_](A|AN|THE|YOUR)[-_]|YOUR[-_](VALUE|TOKEN|KEY|BUCKET|DOMAIN)[-_]HERE|FILL[-_]ME[-_]IN'

# Where a placeholder is a bug. deploy/ is what Argo applies; the source trees
# are where a human would fix it, and both are listed so the report names the
# file you actually edit. .sops.yaml is here because an unfilled age recipient
# means nothing in the repo can be encrypted at all.
SCOPE_PREFIXES='apps/ platform/ infrastructure/ clusters/ deploy/ bootstrap/ .sops.yaml'

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# A placeholder in one of these is the point of the file, not a defect.
is_template() {
  case "$1" in
    # MUST come before the *.sops.yaml arm. `.sops.yaml` is the SOPS config --
    # the recipient list -- and `case` lets `*` match the empty string, so the
    # encrypted-file pattern below swallows it. leak-check.sh carries the same
    # exclusion for the same reason. An unfilled recipient here is the highest
    # priority placeholder in the repo: nothing can be sealed until it is real.
    .sops.yaml) return 1 ;;
    *.example|*.example.*|*.tmpl|*.template|*.sample) return 0 ;;
    # Prose that discusses the placeholders, and the scripts that carry them as
    # literals (this one, age-key.sh, graceful-shutdown.sh, set-backup-target.sh).
    docs/*|*.md|scripts/*) return 0 ;;
    # An encrypted file cannot be inspected and must not be.
    *.sops.yaml|*.sops.yml|*.sops.env) return 0 ;;
    *) return 1 ;;
  esac
}

in_scope() {
  local f="$1" p
  for p in $SCOPE_PREFIXES; do
    case "$f" in "$p"*) return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Allowlist. TSV: <path glob>\t<token>\t<reason>
#
# The glob is a shell `case` pattern, so `*` spans directory separators --
# `apps/*` covers apps/immich/resources/database.yaml.
# ---------------------------------------------------------------------------
AL_GLOB=(); AL_TOKEN=(); AL_REASON=(); AL_HIT=()
allowlist_bad=0

if [ -f "$ALLOWLIST" ]; then
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    # Field COUNT first. `cut -f1` on a line with no tab returns the whole line,
    # and so do -f2 and -f3-, so a space-separated line would parse as three
    # identical non-empty columns and be accepted. An allowlist that silently
    # misreads its own format is worse than no allowlist.
    nf=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    glob=$(printf '%s' "$line" | cut -f1)
    token=$(printf '%s' "$line" | cut -f2)
    reason=$(printf '%s' "$line" | cut -f3-)
    if [ "$nf" -lt 3 ] || [ -z "$glob" ] || [ -z "$token" ] || [ -z "$reason" ]; then
      red "$ALLOWLIST:$lineno: needs three TAB-separated columns: <path glob> <token> <reason>"
      red "$ALLOWLIST:$lineno: got $nf column(s). Columns are TABS, not spaces."
      allowlist_bad=1
      continue
    fi
    AL_GLOB+=("$glob"); AL_TOKEN+=("$token"); AL_REASON+=("$reason"); AL_HIT+=(0)
  done <"$ALLOWLIST"
fi

# Return 0 if (file, token) is deferred, and put the reason in ALLOW_REASON.
#
# Deliberately NOT `reason=$(allowed ...)`: a command substitution runs the
# function in a subshell, so the AL_HIT bookkeeping would be discarded and every
# entry would be reported stale on every run.
ALLOW_REASON=""
allowed() {
  local f="$1" tok="$2" i
  ALLOW_REASON=""
  for i in "${!AL_GLOB[@]}"; do
    [ "${AL_TOKEN[$i]}" = "$tok" ] || continue
    # shellcheck disable=SC2254  # the glob is data on purpose
    case "$f" in
      ${AL_GLOB[$i]})
        AL_HIT[i]=1
        ALLOW_REASON="${AL_REASON[$i]}"
        return 0
        ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Scan. Tracked AND untracked-but-not-ignored, the same scope leak-check.sh uses:
# a placeholder in a brand-new file is exactly when you want to hear about it.
# ---------------------------------------------------------------------------
blocking=0
deferred=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  in_scope "$f" || continue
  is_template "$f" && continue

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lno=${hit%%:*}
    text=${hit#*:}
    tok=$(printf '%s' "$text" | grep -oE "$TOKENS_RE" | head -1)
    if allowed "$f" "$tok"; then
      yellow "  defer  $f:$lno  $tok  -- $ALLOW_REASON"
      deferred=$((deferred + 1))
    else
      red "  BLOCK  $f:$lno  $tok"
      red "         $(printf '%s' "$text" | cut -c1-140)"
      blocking=$((blocking + 1))
    fi
  done < <(grep -nE "$TOKENS_RE" "$f" 2>/dev/null)
done < <(git ls-files -co --exclude-standard)

# ---------------------------------------------------------------------------
echo
for i in "${!AL_GLOB[@]}"; do
  if [ "${AL_HIT[$i]}" -eq 0 ]; then
    yellow "stale allowlist entry (matched nothing): ${AL_GLOB[$i]}  ${AL_TOKEN[$i]}"
    yellow "  -> the placeholder is gone; delete the line from $ALLOWLIST"
  fi
done

if [ "$allowlist_bad" -ne 0 ]; then
  red "placeholder-check FAILED -- $ALLOWLIST is malformed"
  exit 1
fi

if [ "$blocking" -ne 0 ]; then
  echo >&2
  red "placeholder-check FAILED -- $blocking placeholder(s) would be applied to the cluster"
  red ""
  red "Fix the manifest, or -- if it genuinely has to wait -- add a line to"
  red "$ALLOWLIST naming the command that removes it."
  exit 1
fi

if [ "$deferred" -ne 0 ]; then
  green "placeholder-check passed ($deferred deferred by $ALLOWLIST)"
else
  green "placeholder-check passed"
fi
