#!/bin/bash
# platform/keycloak/realm/apply.sh static checks (CHECK_ONLY=1): the repo's
# files pass, and wildcard or non-https redirect URIs, origins with a path,
# malformed access.conf lines, malformed OTP settings and clients both removed
# and configured fail before any kcadm call.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

REALM_DIR="$REPO_ROOT/platform/keycloak/realm"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\necho "$*" >> "%s/kcadm.log"\nexit 1\n' "$tmp" > "$tmp/kcadm"
chmod +x "$tmp/kcadm"
# A file named like a glob match must not hide a `*` value.
touch "$tmp/https:"

# run <platform.conf> <clients.conf> [access.conf] -> "rc=<n>" plus the output
run() {
  local o r=0
  o=$(cd "$tmp" && CHECK_ONLY=1 KCADM="$tmp/kcadm" PLATFORM_CONF="$1" CLIENTS_CONF="$2" \
    ACCESS_CONF="${3:-$REALM_DIR/access.conf}" bash "$REALM_DIR/apply.sh" 2>&1) || r=$?
  printf 'rc=%s %s' "$r" "$o"
}
clients() { printf '%s\n' "$@" > "$tmp/clients.conf"; echo "$tmp/clients.conf"; }

o=$(run "$REALM_DIR/platform.conf" "$REALM_DIR/clients.conf")
expect_contains "repo files pass" "rc=0 ok   static checks" "$o"
expect_eq "no kcadm call in CHECK_ONLY" "" "$(cat "$tmp/kcadm.log" 2>/dev/null || true)"
expect_contains "paperless has no wildcard" "paperless.redirectUris=https://archive.lilalala.com/accounts/oidc/keycloak/login/callback/" \
  "$(grep '^paperless.redirectUris=' "$REALM_DIR/clients.conf")"

good=https://app.example.org/cb
for v in '*' 'https://app.example.org/*' 'http://app.example.org/cb' 'https://app.example.org' '+'; do
  o=$(run "$REALM_DIR/platform.conf" "$(clients "app.redirectUris=$good $v")")
  expect_contains "redirect URI '$v' fails" "rc=1" "$o"
  expect_contains "redirect URI '$v' is named" "value not allowed: $v" "$o"
done
for v in 'https://app.example.org/' '*' '+' 'http://app.example.org'; do
  o=$(run "$REALM_DIR/platform.conf" "$(clients "app.webOrigins=$v")")
  expect_contains "web origin '$v' fails" "rc=1" "$o"
done
o=$(run "$REALM_DIR/platform.conf" "$(clients "app.redirectUris=$good app.example:///cb" "app.webOrigins=https://app.example.org")")
expect_contains "https callback, app scheme and bare origin pass" "rc=0" "$o"
o=$(run "$REALM_DIR/platform.conf" "$(clients "app.rootUrl=https://app.example.org")")
expect_contains "unmanaged field fails" "rc=1" "$o"

# Overlap: removed_clients against platform_clients and clients.conf.
sed 's/^removed_clients=.*/removed_clients=myclient argocd/' "$REALM_DIR/platform.conf" > "$tmp/p1.conf"
o=$(run "$tmp/p1.conf" "$(clients "x.webOrigins=https://x.example.org")")
expect_contains "removed platform client fails" "client argocd is in removed_clients" "$o"
sed 's/^removed_clients=.*/removed_clients=myclient app/' "$REALM_DIR/platform.conf" > "$tmp/p2.conf"
o=$(run "$tmp/p2.conf" "$(clients "app.redirectUris=$good")")
expect_contains "removed managed client fails" "client app is in removed_clients" "$o"

# proxy_clients: <clientId>:<group>, and not also removed.
sed 's/^proxy_clients=.*/proxy_clients=theater-sso/' "$REALM_DIR/platform.conf" > "$tmp/p3.conf"
o=$(run "$tmp/p3.conf" "$REALM_DIR/clients.conf")
expect_contains "proxy client without group fails" "proxy_clients entry is not <clientId>:<group>: theater-sso" "$o"
sed 's/^removed_clients=.*/removed_clients=myclient theater-sso/' "$REALM_DIR/platform.conf" > "$tmp/p4.conf"
o=$(run "$tmp/p4.conf" "$REALM_DIR/clients.conf")
expect_contains "removed proxy client fails" "client theater-sso is in removed_clients" "$o"

# OTP: mfa_role and automation_client one name each, mfa_groups not empty,
# otp_policy entries otpPolicy<Field>=<value>; the repo enforces OTP for admins.
expect_contains "mfa_groups has admins" "admins" "$(sed -n 's/^mfa_groups=//p' "$REALM_DIR/platform.conf")"
expect_contains "otp policy is TOTP, 6 digits, 30 s, SHA1" \
  "otpPolicyType=totp otpPolicyDigits=6 otpPolicyPeriod=30 otpPolicyAlgorithm=HmacSHA1" \
  "$(sed -n 's/^otp_policy=//p' "$REALM_DIR/platform.conf")"
for e in 's/^mfa_role=.*/mfa_role=mfa required/' 's/^automation_client=.*/automation_client=/' \
  's/^mfa_groups=.*/mfa_groups=/' 's/^mfa_groups=.*/mfa_groups=adm*ns/' \
  's/^otp_policy=.*/otp_policy=otpPolicyDigits=6 digits=8/'; do
  sed "$e" "$REALM_DIR/platform.conf" > "$tmp/p5.conf"
  o=$(run "$tmp/p5.conf" "$REALM_DIR/clients.conf")
  expect_contains "platform.conf '$e' fails" "rc=1 FAIL platform.conf" "$o"
done

# access.conf: <clientId>=<groups>, each client once, not also removed.
access() { printf '%s\n' "$@" > "$tmp/access.conf"; echo "$tmp/access.conf"; }
for l in 'immich=' 'immich' 'immich=family,media' 'imm ich=family' 'immich=fam*'; do
  o=$(run "$REALM_DIR/platform.conf" "$REALM_DIR/clients.conf" "$(access "$l")")
  expect_contains "access line '$l' fails" "not <clientId>=<groups>" "$o"
done
o=$(run "$REALM_DIR/platform.conf" "$REALM_DIR/clients.conf" "$(access 'immich=family' 'immich=media')")
expect_contains "client listed twice fails" "client listed twice: immich" "$o"
o=$(run "$REALM_DIR/platform.conf" "$REALM_DIR/clients.conf" "$(access 'myclient=admins')")
expect_contains "removed access client fails" "client myclient is in removed_clients" "$o"
o=$(run "$REALM_DIR/platform.conf" "$REALM_DIR/clients.conf" "$(access '# c' 'app=family  media' '' 'x=admins')")
expect_contains "comments, blanks and several groups pass" "rc=0" "$o"
# Every app client with a redirect URI is gated.
while IFS= read -r c; do
  expect_contains "client $c is in access.conf" "$c=" "$(grep "^$c=" "$REALM_DIR/access.conf" || true)"
done < <(sed -n 's/^\([A-Za-z0-9_-]*\)\.redirectUris=.*/\1/p' "$REALM_DIR/clients.conf")
expect_eq "still no kcadm call" "" "$(cat "$tmp/kcadm.log" 2>/dev/null || true)"

finish
