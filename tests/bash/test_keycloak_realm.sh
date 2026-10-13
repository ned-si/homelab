#!/bin/bash
# platform/keycloak/realm/apply.sh static checks (CHECK_ONLY=1): the repo's
# files pass, and wildcard or non-https redirect URIs, origins with a path and
# clients both removed and configured fail before any kcadm call.
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

# run <platform.conf> <clients.conf> -> "rc=<n>" plus the output
run() {
  local o r=0
  o=$(cd "$tmp" && CHECK_ONLY=1 KCADM="$tmp/kcadm" PLATFORM_CONF="$1" CLIENTS_CONF="$2" \
    bash "$REALM_DIR/apply.sh" 2>&1) || r=$?
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
expect_eq "still no kcadm call" "" "$(cat "$tmp/kcadm.log" 2>/dev/null || true)"

finish
