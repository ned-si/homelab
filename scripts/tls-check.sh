#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check TLS and security headers on every published hostname: the DAST gate.
# ZAP reports to code scanning and gates on HIGH alerts only; its header
# rules are WARN in .zap/rules.tsv.
#
# Hard failures: not reachable over HTTPS, plain HTTP serving content instead
# of redirecting (a route without `sectionName: https`), an unreadable
# certificate, or one closer to expiry than MIN_DAYS.
#
# The four security headers, on the page `/` lands on (docs/networking.md,
# Security headers), warn by default and fail with STRICT_HEADERS=1, which
# dast.yaml sets:
#
#         STRICT_HEADERS=1 ./scripts/tls-check.sh
#
# curl + openssl only. Hostnames come from scripts/published-hostnames.sh.
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
  # The page `/` lands on: up to 3 redirects, on the same host only (an app's
  # login redirect to Keycloak would otherwise check Keycloak's headers).
  url="https://$h/"
  for _ in 1 2 3; do
    raw=$(curl -sSI -m 15 "$url" 2>/dev/null | tr -d '\r')
    hdrs=$(printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]')
    loc=$(printf '%s\n' "$raw" | grep -i '^location:' | head -n 1 | sed 's/^[^:]*: *//')
    case "$loc" in
      "https://$h/"* | "https://$h:443/"*) url=$loc ;;
      /[!/]*) url="https://$h$loc" ;;
      *) break ;;
    esac
  done
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
  yellow "security headers are missing on at least one host: add them to the"
  yellow "route's ResponseHeaderModifier filter (docs/networking.md, Security headers)."
  echo
fi
if [ "$fail" -eq 0 ]; then
  green "tls-check passed"
else
  red "tls-check FAILED"
fi
exit "$fail"
