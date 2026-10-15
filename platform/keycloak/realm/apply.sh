#!/bin/bash
# Apply sessions.conf, platform.conf and clients.conf to the `homelab` realm,
# then read the realm back and fail unless every managed value is the
# expected one. CHECK_ONLY=1 runs the static checks of the files and exits.
#
# Runs in the Keycloak image (kcadm.sh, bash, grep, sed; no awk, jq or curl).
# `kcadm.sh update -s` fetches an object, changes only the given fields and
# writes it back, so nothing outside the two files is touched.
set -euo pipefail
# Values such as a `*` redirect URI must never expand to file names.
set -f

KCADM=${KCADM:-/opt/keycloak/bin/kcadm.sh}
CFG=/tmp/kcadm.config
SERVER=${KEYCLOAK_URL:-http://keycloak.keycloak.svc.cluster.local:8080}
REALM=${REALM:-homelab}
CONF=${CONF:-/realm/sessions.conf}
PLATFORM_CONF=${PLATFORM_CONF:-/realm/platform.conf}
CLIENTS_CONF=${CLIENTS_CONF:-/realm/clients.conf}
FLOW=browser-loa
ACR=platform

kc() { "$KCADM" "$@" --config "$CFG"; }

rc=0
check() { # name want got
  if [ "$2" = "$3" ]; then
    echo "ok   $1=$3"
  else
    echo "FAIL $1: want $2, got ${3:-<missing>}" >&2
    rc=1
  fi
}

conf() { sed -n "s/^$1=//p" "$PLATFORM_CONF" | tail -n 1; }

# --- static checks, before any write -------------------------------------------
# clients.conf lines: <clientId>.<field>=<values>
client_lines() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$CLIENTS_CONF" | grep -v '^[[:space:]]*$' || true; }
managed_clients=$(client_lines | sed 's/\..*//' | sort -u)
bad=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! [[ "$line" =~ ^[A-Za-z0-9_-]+\.(redirectUris|webOrigins)=[^[:space:]] ]]; then
    echo "FAIL clients.conf: not <clientId>.<redirectUris|webOrigins>=<values>: $line" >&2
    bad=1
    continue
  fi
  field=${line#*.}
  field=${field%%=*}
  for v in ${line#*=}; do
    case "$field:$v" in
      *'*'* | *'+'* | *'"'* | *,*) ok=0 ;;
      redirectUris:https://?*/*) ok=1 ;;
      redirectUris:http:* | redirectUris:https:*) ok=0 ;;
      redirectUris:[a-z]*.[a-z]*:///*) ok=1 ;;
      webOrigins:https://*/*) ok=0 ;;
      webOrigins:https://?*) ok=1 ;;
      *) ok=0 ;;
    esac
    if [ "$ok" = 0 ]; then
      echo "FAIL clients.conf: $field value not allowed: $v" >&2
      bad=1
    fi
  done
done < <(client_lines)
for pc in $(conf proxy_clients); do
  if ! [[ "$pc" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
    echo "FAIL platform.conf: proxy_clients entry is not <clientId>:<group>: $pc" >&2
    bad=1
  fi
done
# A client that must not exist cannot also be configured.
for c in $(conf removed_clients); do
  for m in $(conf platform_clients) $managed_clients $(conf proxy_clients | tr ' ' '\n' | sed 's/:.*//'); do
    if [ "$c" = "$m" ]; then
      echo "FAIL client $c is in removed_clients and configured elsewhere" >&2
      bad=1
    fi
  done
done
[ "$bad" = 0 ] || exit 1
if [ -n "${CHECK_ONLY:-}" ]; then
  echo "ok   static checks"
  exit 0
fi

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

# --- sessions.conf: realm fields ---------------------------------------------
args=()
fields=()
while IFS= read -r line; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | tr -d '[:space:]')
  [ -z "$line" ] && continue
  args+=(-s "$line")
  fields+=("$line")
done < "$CONF"

if [ "${#fields[@]}" -gt 0 ]; then
  kc update "realms/$REALM" "${args[@]}"
  live=$(kc get "realms/$REALM")
  for f in "${fields[@]}"; do
    key=${f%%=*}
    got=$(printf '%s\n' "$live" | grep -E "^  \"$key\" : " | sed -E 's/^[^:]+: //; s/,$//; s/^"//; s/"$//' || true)
    check "$key" "${f#*=}" "$got"
  done
fi

# --- platform.conf: browser flow with a level-of-authentication max age --------
max_age=$(conf loa_max_age)
clients=$(conf platform_clients)
[[ "$max_age" =~ ^[0-9]+$ ]] || { echo "FAIL loa_max_age is not a number" >&2; exit 1; }

# requirement,displayName,level of every execution in the flow, in order.
execs() {
  kc get "authentication/flows/$FLOW/executions" -r "$REALM" --format csv --noquotes \
    --fields "${1:-requirement,displayName,level}"
}
exec_row() { # displayName fields -> the matching row; displayName is the 2nd field
  local row name
  while IFS= read -r row; do
    name=${row#*,}
    name=${name%%,*}
    if [ "$name" = "$1" ]; then
      printf '%s\n' "$row"
      return
    fi
  done < <(execs "$2")
}
exec_id() { exec_row "$1" id,displayName | cut -d, -f1; }
exec_cfg() { exec_row "$1" id,displayName,authenticationConfig | cut -d, -f3; }
set_req() { # displayName requirement
  # Send the execution's priority back unchanged: Keycloak 25+ applies the
  # priority of this request, and a missing one would reorder the flow.
  local row id prio
  row=$(exec_row "$1" id,displayName,priority)
  id=${row%%,*}
  prio=${row##*,}
  if [[ "$prio" =~ ^[0-9]+$ ]]; then
    kc update "authentication/flows/$FLOW/executions" -r "$REALM" \
      -b "{\"id\":\"$id\",\"requirement\":\"$2\",\"priority\":$prio}"
  else
    kc update "authentication/flows/$FLOW/executions" -r "$REALM" \
      -b "{\"id\":\"$id\",\"requirement\":\"$2\"}"
  fi
}

if ! kc get authentication/flows -r "$REALM" --format csv --noquotes --fields alias | grep -qx "$FLOW"; then
  echo "creating flow $FLOW"
  kc create authentication/flows -r "$REALM" -s alias="$FLOW" -s providerId=basic-flow \
    -s topLevel=true -s builtIn=false \
    -s 'description=Browser login; platform clients re-authenticate after platform.conf loa_max_age' >/dev/null 2>&1
  sub() { # parent alias
    kc create "authentication/flows/$1/executions/flow" -r "$REALM" -s alias="$2" \
      -s type=basic-flow -s provider=registration-page-form >/dev/null 2>&1
  }
  step() { # flow provider
    kc create "authentication/flows/$1/executions/execution" -r "$REALM" -s provider="$2" >/dev/null 2>&1
  }
  step "$FLOW" auth-cookie
  step "$FLOW" identity-provider-redirector
  sub "$FLOW" "$FLOW-forms"
  sub "$FLOW-forms" "$FLOW-level-1"
  step "$FLOW-level-1" conditional-level-of-authentication
  step "$FLOW-level-1" auth-username-password-form
  sub "$FLOW-level-1" "$FLOW-otp"
  step "$FLOW-otp" conditional-user-configured
  step "$FLOW-otp" auth-otp-form
  set_req "Cookie" ALTERNATIVE
  set_req "Identity Provider Redirector" ALTERNATIVE
  set_req "$FLOW-forms" ALTERNATIVE
  set_req "$FLOW-level-1" CONDITIONAL
  set_req "Condition - Level of Authentication" REQUIRED
  set_req "Username Password Form" REQUIRED
  set_req "$FLOW-otp" CONDITIONAL
  set_req "Condition - user configured" REQUIRED
  set_req "OTP Form" REQUIRED
fi

loa_cfg=$(exec_cfg "Condition - Level of Authentication")
if [ -z "$loa_cfg" ]; then
  kc create "authentication/executions/$(exec_id "Condition - Level of Authentication")/config" \
    -r "$REALM" -s alias="$FLOW-max-age" \
    -s 'config."loa-condition-level"=1' -s "config.\"loa-max-age\"=$max_age" >/dev/null 2>&1
  loa_cfg=$(exec_cfg "Condition - Level of Authentication")
else
  kc update "authentication/config/$loa_cfg" -r "$REALM" \
    -s 'config."loa-condition-level"=1' -s "config.\"loa-max-age\"=$max_age"
fi

kc update "realms/$REALM" -s browserFlow="$FLOW" -s "attributes.\"acr.loa.map\"=\"{\\\"$ACR\\\":1}\""

client_id() { # clientId -> internal id; empty when the client does not exist
  kc get clients -r "$REALM" -q clientId="$1" --format csv --noquotes --fields id,clientId |
    grep -E ",$1\$" | cut -d, -f1 || true
}

for c in $clients; do
  id=$(client_id "$c")
  if [ -z "$id" ]; then
    check "client $c" present ""
    continue
  fi
  kc update "clients/$id" -r "$REALM" -s "attributes.\"default.acr.values\"=$ACR"
  # `--fields attributes` returns an empty map: read the whole client.
  got=$(kc get "clients/$id" -r "$REALM" | sed -n 's/^ *"default\.acr\.values" : "\(.*\)",\{0,1\}$/\1/p')
  check "client $c default.acr.values" "$ACR" "$got"
done

# --- platform.conf: clients that must not exist --------------------------------
for c in $(conf removed_clients); do
  id=$(client_id "$c")
  if [ -n "$id" ]; then
    echo "deleting client $c"
    kc delete "clients/$id" -r "$REALM"
  fi
  if [ -z "$(client_id "$c")" ]; then got=absent; else got=present; fi
  check "client $c" absent "$got"
done

# --- platform.conf: confidential clients for oauth2-proxy ----------------------
name_id() { # resource name -> id of the entry with that name
  kc get "$1" -r "$REALM" --format csv --noquotes --fields id,name | grep -E ",$2\$" | cut -d, -f1 || true
}
for pc in $(conf proxy_clients); do
  c=${pc%%:*}
  g=${pc#*:}
  if [ -z "$(name_id groups "$g")" ]; then
    echo "creating group $g"
    kc create groups -r "$REALM" -s name="$g" >/dev/null
  fi
  if [ -n "$(name_id groups "$g")" ]; then got=present; else got=absent; fi
  check "group $g" present "$got"

  if [ -z "$(client_id "$c")" ]; then
    echo "creating client $c"
    kc create clients -r "$REALM" -s clientId="$c" -s protocol=openid-connect \
      -s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
      -s implicitFlowEnabled=false -s serviceAccountsEnabled=false \
      -s 'attributes."pkce.code.challenge.method"=S256' >/dev/null
  fi
  id=$(client_id "$c")
  if [ -z "$id" ]; then
    check "client $c" present ""
    continue
  fi

  # The secret is never printed: only whether the live one matches.
  var="$(printf '%s' "$c" | tr 'a-z-' 'A-Z_')_CLIENT_SECRET"
  secret=${!var:-}
  if [ -z "$secret" ] || [ "${secret#PENDING}" != "$secret" ]; then
    echo "WARN client $c: $var is unset or PENDING; secret left as is" >&2
  else
    kc update "clients/$id" -r "$REALM" -s "secret=$secret"
    live=$(kc get "clients/$id/client-secret" -r "$REALM" | sed -n 's/^ *"value" : "\(.*\)",\{0,1\}$/\1/p')
    if [ "$live" = "$secret" ]; then got=matches; else got=differs; fi
    check "client $c secret ($var)" matches "$got"
  fi
  unset secret live

  sid=$(name_id client-scopes groups)
  if ! kc get "clients/$id/default-client-scopes" -r "$REALM" --format csv --noquotes --fields name | grep -qx groups; then
    kc update "clients/$id/default-client-scopes/$sid" -r "$REALM"
  fi
  if kc get "clients/$id/default-client-scopes" -r "$REALM" --format csv --noquotes --fields name | grep -qx groups; then
    got=present
  else
    got=absent
  fi
  check "client $c default scope groups" present "$got"

  if ! kc get "clients/$id/protocol-mappers/models" -r "$REALM" --format csv --noquotes --fields name | grep -qx audience; then
    kc create "clients/$id/protocol-mappers/models" -r "$REALM" -s name=audience \
      -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=$c" -s 'config."access.token.claim"=true' \
      -s 'config."id.token.claim"=false' >/dev/null
  fi
  if kc get "clients/$id/protocol-mappers/models" -r "$REALM" --format csv --noquotes --fields name | grep -qx audience; then
    got=present
  else
    got=absent
  fi
  check "client $c audience mapper" present "$got"
done

# --- clients.conf: redirect URIs and web origins -------------------------------
json_list() { # space-separated values -> ["a","b"]
  local out="" v
  for v in $1; do out="$out${out:+,}\"$v\""; done
  printf '[%s]' "$out"
}
live_list() { # client JSON, field -> sorted, space-separated values
  printf '%s\n' "$1" | grep -E "^ *\"$2\" : \[" | head -n 1 |
    sed -E 's/^[^[]*\[//; s/\].*$//' | tr ',' '\n' | sed -E 's/^ *"//; s/" *$//' |
    grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//' || true
}
for c in $managed_clients; do
  id=$(client_id "$c")
  if [ -z "$id" ]; then
    check "client $c" present ""
    continue
  fi
  args=()
  fields=()
  while IFS= read -r line; do
    case "$line" in "$c".*) ;; *) continue ;; esac
    f=${line#*.}
    f=${f%%=*}
    args+=(-s "$f=$(json_list "${line#*=}")")
    fields+=("$f=${line#*=}")
  done < <(client_lines)
  kc update "clients/$id" -r "$REALM" "${args[@]}"
  live=$(kc get "clients/$id" -r "$REALM" --fields redirectUris,webOrigins)
  for f in "${fields[@]}"; do
    want=$(printf '%s\n' "${f#*=}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
    check "client $c ${f%%=*}" "$want" "$(live_list "$live" "${f%%=*}")"
  done
done

# Other clients: warn about absolute wildcard redirect URIs. Keycloak's own
# consoles use relative ones (/realms/<realm>/account/*), which stay.
current=""
while IFS= read -r line; do
  case "$line" in
    *'"clientId" : '*) current=$(printf '%s' "$line" | sed -E 's/^[^:]+: "//; s/",?$//') ;;
    *'"redirectUris" : '*)
      for v in $(printf '%s' "$line" | sed -E 's/^[^[]*\[//; s/\].*$//' | tr ',' ' ' | tr -d '"'); do
        case "$v" in
          /*) ;;
          *'*'*) echo "WARN client $current has a wildcard redirect URI: $v" >&2 ;;
        esac
      done
      ;;
  esac
done < <(kc get clients -r "$REALM" --fields clientId,redirectUris)

# Read back the flow, its condition and the realm binding.
want="ALTERNATIVE,Cookie,0
ALTERNATIVE,Identity Provider Redirector,0
ALTERNATIVE,$FLOW-forms,0
CONDITIONAL,$FLOW-level-1,1
REQUIRED,Condition - Level of Authentication,2
REQUIRED,Username Password Form,2
CONDITIONAL,$FLOW-otp,2
REQUIRED,Condition - user configured,3
REQUIRED,OTP Form,3"
got=$(execs)
if [ "$got" = "$want" ]; then
  echo "ok   flow $FLOW: $(printf '%s\n' "$got" | wc -l | tr -d ' ') executions"
else
  printf 'FAIL flow %s:\n%s\n' "$FLOW" "$got" >&2
  rc=1
fi
cfg=$(kc get "authentication/config/$loa_cfg" -r "$REALM")
check loa-condition-level 1 "$(printf '%s\n' "$cfg" | sed -n 's/^ *"loa-condition-level" : "\(.*\)",\{0,1\}$/\1/p')"
check loa-max-age "$max_age" "$(printf '%s\n' "$cfg" | sed -n 's/^ *"loa-max-age" : "\(.*\)",\{0,1\}$/\1/p')"
realm=$(kc get "realms/$REALM")
check browserFlow "$FLOW" "$(printf '%s\n' "$realm" | sed -n 's/^ *"browserFlow" : "\(.*\)",\{0,1\}$/\1/p')"
check acr.loa.map "{\\\"$ACR\\\":1}" "$(printf '%s\n' "$realm" | sed -n 's/^ *"acr\.loa\.map" : "\(.*\)",\{0,1\}$/\1/p')"
exit "$rc"
