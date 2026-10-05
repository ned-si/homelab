#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check TLS and security headers on every published hostname.
#
# THIS IS THE DAST GATE. ZAP is not.
#
# There are three artefacts that have an opinion about the same handful of
# response headers: this script, .zap/rules.tsv, and .github/workflows/dast.yaml.
# They used to hold three different positions on one control -- rules.tsv marked
# a missing HSTS header FAIL, this script warned about it, and the workflow set
# `fail_action: false` and discarded ZAP's exit code entirely.
#
# Resolved as follows, and all three files say the same thing:
#
#   * ZAP REPORTS to code scanning (SARIF) and gates only on HIGH alerts. The
#     four header rules are WARN in rules.tsv.
#   * This script is the GATE, because it is cheap, deterministic, and its hard
#     checks are things that are true today and would be regressions if they
#     stopped being true.
#
# HARD FAILURES (a real regression, and green today)
#   - hostname not reachable over HTTPS
#   - plain HTTP serves content instead of redirecting -- catches an HTTPRoute
#     attached to both Gateway listeners, i.e. a missing `sectionName: https`
#   - certificate unreadable
#   - certificate closer to expiry than MIN_DAYS
#
# WARNINGS (real gaps, not regressions)
#   - the four security headers below. The shared Gateway sets NO response
#     headers at all right now: there is no ResponseHeaderModifier filter
#     anywhere in the repo. Making these hard failures today would mean a job
#     that is red on arrival, which is how a gate gets ignored.
#
#     When the Gateway grows the header filter, the promotion is one variable:
#
#         STRICT_HEADERS=1 ./scripts/tls-check.sh
#
#     and then the same flag goes in dast.yaml, in the same commit.
#
# Deliberately dependency-free (curl + openssl) so it runs on a stock CI
# runner and locally on macOS. dast.yaml keeps its output off the public log.
#
# Hostnames are DERIVED from deploy/ by scripts/published-hostnames.sh -- see
# that script for why the list is 15 names and not the 17 a naive grep finds.
#
# Exit 1 if any hostname fails a hard check.
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# Promote the header warnings to hard failures. Off by default; see above.
: "${STRICT_HEADERS:=0}"

# Warn when a certificate has fewer than this many days left. cert-manager
# renews at 30 days (renewBefore: 720h), so anything under 21 means renewal is
# failing and nobody noticed.
MIN_DAYS=21

# The same four controls .zap/rules.tsv lists, in the same order, so the two
# files can be read side by side:
#   strict-transport-security  ZAP 10035
#   content-security-policy    ZAP 10038
#   x-frame-options            ZAP 10020
#   x-content-type-options     ZAP 10021
WANT_HEADERS=(
  strict-transport-security
  content-security-policy
  x-frame-options
  x-content-type-options
)

if ! HOSTS_RAW=$(./scripts/published-hostnames.sh); then
  echo "could not derive the hostname list -- see the error above" >&2
  exit 1
fi

HOSTS=()
while IFS= read -r h; do
  [ -n "$h" ] && HOSTS+=("$h")
done <<<"$HOSTS_RAW"

fail=0
warned=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

printf 'checking %d hostnames derived from deploy/\n' "${#HOSTS[@]}"

for h in "${HOSTS[@]}"; do
  printf '\n=== %s ===\n' "$h"

  # ---- reachability + HTTPS ------------------------------------------------
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 "https://$h/" 2>/dev/null || echo 000)
  if [ "$code" = "000" ]; then
    red "  UNREACHABLE over https"
    fail=1
    continue
  fi
  green "  https reachable (HTTP $code)"

  # ---- plain HTTP must redirect, not serve ---------------------------------
  hcode=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 "http://$h/" 2>/dev/null || echo 000)
  case "$hcode" in
    301|302|307|308) green "  http -> https redirect ($hcode)" ;;
    000)             yellow "  http not reachable (fine if 80 is not forwarded)" ;;
    *)               red "  http served content directly ($hcode) - redirect missing"; fail=1 ;;
  esac

  # ---- certificate expiry --------------------------------------------------
  notafter=$(echo | openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null \
             | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$notafter" ]; then
    # BSD `date -j -f` first, GNU `date -d` second: this runs on both macOS and
    # the Linux runner.
    if exp=$(date -j -f '%b %e %T %Y %Z' "$notafter" +%s 2>/dev/null) \
       || exp=$(date -d "$notafter" +%s 2>/dev/null); then
      days=$(( (exp - $(date +%s)) / 86400 ))
      if [ "$days" -lt "$MIN_DAYS" ]; then
        red "  cert expires in ${days}d (< ${MIN_DAYS}d) - renewal is probably failing"
        fail=1
      else
        green "  cert valid for ${days}d"
      fi
    else
      # Neither date dialect parsed it. Silently skipping was hiding the one
      # thing this check exists for.
      red "  could not parse cert expiry '$notafter'"
      fail=1
    fi
  else
    red "  could not read certificate"
    fail=1
  fi

  # ---- headers ------------------------------------------------------------
  # Character classes rather than 'A-Z' 'a-z': a range depends on the collation
  # order of the ambient locale, and header names are matched case-insensitively
  # below, so a locale where the range does not cover plain ASCII would silently
  # stop finding Strict-Transport-Security.
  hdrs=$(curl -sSI -m 15 "https://$h/" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  for want in "${WANT_HEADERS[@]}"; do
    if printf '%s' "$hdrs" | grep -q "^${want}:"; then
      green "  $want present"
    elif [ "$STRICT_HEADERS" = "1" ]; then
      red "  $want MISSING"
      fail=1
    else
      yellow "  $want MISSING (warning; set STRICT_HEADERS=1 to gate on this)"
      warned=1
    fi
  done
done

echo
if [ "$warned" -eq 1 ] && [ "$STRICT_HEADERS" != "1" ]; then
  yellow "security headers are missing on at least one host. The Gateway sets no"
  yellow "response headers yet -- add a ResponseHeaderModifier filter in"
  yellow "infrastructure/gateway, then flip STRICT_HEADERS=1 here and in dast.yaml."
  echo
fi
if [ "$fail" -eq 0 ]; then
  green "tls-check passed"
else
  red "tls-check FAILED"
fi
exit "$fail"
