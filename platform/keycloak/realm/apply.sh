#!/bin/bash
# Write the fields of sessions.conf to the `homelab` realm, then read the realm
# back and fail unless every field holds the expected value.
#
# Runs in the Keycloak image (kcadm.sh, bash, grep, sed; no jq or curl).
# `kcadm.sh update -s` fetches the realm, changes only the given fields and
# writes it back, so nothing outside sessions.conf is touched.
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm.config
SERVER=${KEYCLOAK_URL:-http://keycloak.keycloak.svc.cluster.local:8080}
REALM=${REALM:-homelab}
CONF=${CONF:-/realm/sessions.conf}

# Keycloak may still be starting after a sync: retry the login for 5 minutes.
for i in $(seq 1 30); do
  if "$KCADM" config credentials --config "$CFG" --server "$SERVER" \
    --realm master --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" = 30 ]; then
    echo "admin login to $SERVER failed" >&2
    exit 1
  fi
  sleep 10
done

args=()
fields=()
while IFS= read -r line; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | tr -d '[:space:]')
  [ -z "$line" ] && continue
  args+=(-s "$line")
  fields+=("$line")
done < "$CONF"

"$KCADM" update "realms/$REALM" --config "$CFG" "${args[@]}"

live=$("$KCADM" get "realms/$REALM" --config "$CFG")
rc=0
for f in "${fields[@]}"; do
  key=${f%%=*}
  want=${f#*=}
  got=$(printf '%s\n' "$live" | grep -E "^  \"$key\" : " | sed -E 's/^[^:]+: //; s/,$//; s/^"//; s/"$//' || true)
  if [ "$got" = "$want" ]; then
    echo "ok   $key=$got"
  else
    echo "FAIL $key: want $want, got ${got:-<missing>}" >&2
    rc=1
  fi
done
exit "$rc"
