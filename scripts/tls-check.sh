#!/usr/bin/env bash
# Check TLS and security headers on every published hostname.
#
# Deliberately dependency-free (curl + openssl) so it runs on a self-hosted
# runner with nothing installed, and locally on macOS.
#
# Exit 1 if any hostname fails a hard check.
set -uo pipefail

HOSTS=(
  argo.lilalala.com
  auth.lilalala.com
  grafana.lilalala.com
  theater.lilalala.com
  cinema.lilalala.com
  media.lilalala.com
  archive.lilalala.com
  cook.lilalala.com
  drive.lilalala.com
  syncthing.lilalala.com
  sonarr.lilalala.com
  radarr.lilalala.com
  lidarr.lilalala.com
  prowlarr.lilalala.com
  qbittorrent.lilalala.com
)

# Warn when a certificate has fewer than this many days left. cert-manager
# renews at 30 days (renewBefore: 720h), so anything under 21 means renewal is
# failing and nobody noticed.
MIN_DAYS=21

fail=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

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
  # This is the check that catches an HTTPRoute accidentally attached to both
  # Gateway listeners (i.e. a missing `sectionName: https`).
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
    if exp=$(date -j -f '%b %e %T %Y %Z' "$notafter" +%s 2>/dev/null) \
       || exp=$(date -d "$notafter" +%s 2>/dev/null); then
      days=$(( (exp - $(date +%s)) / 86400 ))
      if [ "$days" -lt "$MIN_DAYS" ]; then
        red "  cert expires in ${days}d (< ${MIN_DAYS}d) - renewal is probably failing"
        fail=1
      else
        green "  cert valid for ${days}d"
      fi
    fi
  else
    red "  could not read certificate"
    fail=1
  fi

  # ---- headers ------------------------------------------------------------
  hdrs=$(curl -sSI -m 15 "https://$h/" 2>/dev/null | tr 'A-Z' 'a-z')
  for want in strict-transport-security x-content-type-options; do
    if echo "$hdrs" | grep -q "^${want}:"; then
      green "  $want present"
    else
      yellow "  $want MISSING"
    fi
  done
done

echo
if [ "$fail" -eq 0 ]; then
  green "tls-check passed"
else
  red "tls-check FAILED"
fi
exit "$fail"
