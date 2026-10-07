#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create every *.sops.yaml from its *.example template and seal it, taking values
# from secrets.local.env.
#
# WHY A SCRIPT AND NOT TWELVE MANUAL EDITS
#
# There are twelve templates and about twenty-five values, several of which appear
# in more than one file (the Cloudflare token is used by cert-manager AND
# external-dns; RESTIC_PASSWORD protects both restic repositories). Doing that by
# hand means a typo in one place produces a runtime failure somewhere unrelated,
# weeks later.
#
# It also makes re-sealing cheap, which matters because two things force it:
# adding a second age recipient, and filling in the S3 credentials once
# bootstrap/aws-backup has been applied.
#
# THE PLACEHOLDER MAP IS PER-FILE, NOT GLOBAL.
# `PUT_A_FRESHLY_GENERATED_PASSWORD_HERE` appears in FOUR templates and means a
# different secret in each: the Paperless admin password, the Seafile admin
# password, the Seafile MariaDB root password and the Keycloak bootstrap admin
# password. A global search-and-replace would put the same value in all four.
#
# Idempotent: an already-sealed file is left alone unless --force is given.
#
# ---------------------------------------------------------------------------
# PENDING VALUES, AND WHY ONE FILE MUST SEAL WITHOUT ALL OF ITS SECRETS
#
# `platform/secrets/s3-backup.sops.yaml` holds two unrelated things: the AWS
# credentials (which do not exist until `bootstrap/aws-backup` has been applied)
# and RESTIC_PASSWORD (which is the encryption key for BOTH restic repositories,
# including the purely local one).
#
# `immich-library-backup-local` in apps/immich/resources/backup-files.yaml pulls
# only RESTIC_PASSWORD out of this Secret -- deliberately, so a LAN-only job never
# holds cloud credentials -- and writes to an NFS path. It needs no AWS anything.
# It is also the single most important job in the repository: it is the nightly
# second copy of the 317GB photo library.
#
# So refusing to seal this file until AWS exists would leave the most valuable
# backup unable to start, waiting on a credential it does not use.
#
# A variable whose value in secrets.local.env is exactly `__PENDING__` is
# therefore substituted with a visible sentinel (`PENDING-<VARNAME>`) instead of
# being treated as missing. This is only allowed for files listed in
# $PENDING_OK below, so it cannot quietly paper over a secret someone forgot.
#
# `__PENDING__:<text>` uses <text> as the sentinel instead. That exists because
# some consumers parse the value even when they never use it: Alertmanager's
# `url_file` must contain something that parses as a URL, and `PENDING-FOO`
# does not. A sentinel that breaks config loading takes the whole component down,
# which is the opposite of the point.
#
# What that buys, and what it costs:
#   - works  : every local/NFS backup, and every app that does not touch S3
#   - fails  : the S3 restic and barman jobs, loudly, with an auth error
#
# The second half is the honest outcome, not a regression -- every
# `destinationPath` in the tree still says `homelab-backups-REPLACE-ME`, so those
# jobs have no bucket to talk to either. `scripts/secrets-check.sh` reports the
# sentinel so it cannot be forgotten, and after `tofu apply` the fix is to put
# the real keys in secrets.local.env and re-run with --force.
# ---------------------------------------------------------------------------
#
# Usage:
#   scripts/seal-secrets-from-env.sh            seal anything not yet sealed
#   scripts/seal-secrets-from-env.sh --force    re-seal everything
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

ENV_FILE="secrets.local.env"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v sops >/dev/null 2>&1 || { echo "sops not found: brew install sops" >&2; exit 1; }

# Point sops at the age identity explicitly. Without this, sealing SUCCEEDS and
# nothing can be decrypted afterwards -- see scripts/lib/sops-age.sh.
# shellcheck source=scripts/lib/sops-age.sh
. "scripts/lib/sops-age.sh"
sops_age_env || exit 1

[ -f "$ENV_FILE" ]         || { echo "$ENV_FILE not found" >&2; exit 1; }
git check-ignore -q "$ENV_FILE" || {
  echo "REFUSING: $ENV_FILE is not git-ignored. It holds plaintext secrets." >&2
  exit 1
}
grep -q 'age1' .sops.yaml || {
  echo "REFUSING: .sops.yaml has no age recipient. Run scripts/age-key.sh first." >&2
  exit 1
}

# `set -a` so every assignment is exported and the python helpers below inherit
# them. Written on four lines rather than one: a `# shellcheck disable` directive
# attaches to the FIRST command of a `;`-separated list, so on
# `set -a; . "$f"; set +a` it lands on `set -a` and the source is still reported.
set -a
# SC1090: the path is a variable, and the file is git-ignored and machine-local
# by design, so there is nothing for shellcheck to follow.
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

# file|PLACEHOLDER=VARNAME,PLACEHOLDER=VARNAME...
# Multi-line values are handled automatically -- see subst() below.
MAP="
infrastructure/secrets/cloudflare-cert-manager|PUT_THE_CERT_MANAGER_CLOUDFLARE_TOKEN_HERE=CLOUDFLARE_API_TOKEN
infrastructure/secrets/cloudflare-external-dns|PUT_THE_EXTERNAL_DNS_CLOUDFLARE_TOKEN_HERE=CLOUDFLARE_API_TOKEN
infrastructure/secrets/democratic-csi-iscsi|PUT_A_NEW_TRUENAS_API_KEY_HERE=TRUENAS_API_KEY,PUT_A_NEWLY_GENERATED_PRIVATE_KEY_HERE=TRUENAS_SSH_PRIVATE_KEY,PUT_THE_TRUENAS_SSH_USERNAME_HERE=TRUENAS_SSH_USERNAME
platform/secrets/keycloak-admin|PUT_A_FRESHLY_GENERATED_PASSWORD_HERE=KEYCLOAK_ADMIN_PASSWORD
platform/secrets/grafana-oidc|PUT_THE_KEYCLOAK_GRAFANA_CLIENT_SECRET_HERE=GRAFANA_OIDC_CLIENT_SECRET
platform/secrets/s3-backup|PUT_A_GENERATED_RESTIC_REPOSITORY_PASSWORD_HERE=RESTIC_PASSWORD,PUT_THE_S3_ACCESS_KEY_HERE=S3_ACCESS_KEY_ID,PUT_THE_S3_SECRET_KEY_HERE=S3_SECRET_ACCESS_KEY,PUT_THE_S3_VERIFIER_ACCESS_KEY_HERE=S3_VERIFIER_ACCESS_KEY_ID,PUT_THE_S3_VERIFIER_SECRET_KEY_HERE=S3_VERIFIER_SECRET_ACCESS_KEY
apps/secrets/immich-config|PUT_THE_NEW_KEYCLOAK_IMMICH_CLIENT_SECRET_HERE=IMMICH_OIDC_CLIENT_SECRET
apps/secrets/mealie-oidc|PUT_THE_NEW_KEYCLOAK_MEALIE_CLIENT_SECRET_HERE=MEALIE_OIDC_CLIENT_SECRET
apps/secrets/paperless-secrets|PUT_A_FRESHLY_GENERATED_DJANGO_SECRET_KEY_HERE=PAPERLESS_SECRET_KEY,PUT_A_FRESHLY_GENERATED_PASSWORD_HERE=PAPERLESS_ADMIN_PASSWORD,PUT_THE_NEW_KEYCLOAK_PAPERLESS_CLIENT_SECRET_HERE=PAPERLESS_OIDC_CLIENT_SECRET
apps/secrets/seafile-admin|PUT_A_FRESHLY_GENERATED_PASSWORD_HERE=SEAFILE_ADMIN_PASSWORD
apps/secrets/seafile-db|PUT_A_FRESHLY_GENERATED_PASSWORD_HERE=SEAFILE_DB_ROOT_PASSWORD
apps/secrets/recyclarr-api-keys|PUT_THE_SONARR_API_KEY_HERE=RECYCLARR_SONARR_API_KEY,PUT_THE_RADARR_API_KEY_HERE=RECYCLARR_RADARR_API_KEY
apps/secrets/theater-sso|PUT_THE_KEYCLOAK_THEATER_SSO_CLIENT_SECRET_HERE=THEATER_SSO_CLIENT_SECRET,PUT_A_FRESHLY_GENERATED_COOKIE_SECRET_HERE=THEATER_SSO_COOKIE_SECRET
platform/secrets/alertmanager-notify|PUT_THE_PUSHOVER_APPLICATION_TOKEN_HERE=PUSHOVER_TOKEN,PUT_THE_PUSHOVER_USER_KEY_HERE=PUSHOVER_USER_KEY,PUT_THE_HEARTBEAT_PING_URL_HERE=HEARTBEAT_URL
platform/secrets/argocd-notifications|PUT_THE_AUTO_ROLLBACK_GITHUB_TOKEN_HERE=AUTO_ROLLBACK_GITHUB_TOKEN
"

# Files allowed to seal with `__PENDING__` values. See the block at the top.
# Keep this list as short as it can possibly be.
PENDING_OK="
platform/secrets/s3-backup
platform/secrets/alertmanager-notify
platform/secrets/argocd-notifications
apps/secrets/recyclarr-api-keys
apps/secrets/theater-sso
"

# Substitute one placeholder in a file, handling multi-line values.
#
# A single-line sed cannot insert a 38-line PEM: the newlines would terminate the
# replacement and produce invalid YAML. So a multi-line value is written with every
# line indented to match the placeholder's own indentation, which is what a YAML
# block scalar (`privateKey: |`) requires.
subst() {
  local file="$1" token="$2" value="$3"
  TOKEN="$token" VALUE="$value" python3 - "$file" <<'PY'
import os, re, sys
path  = sys.argv[1]
token = os.environ["TOKEN"]
value = os.environ["VALUE"]
text  = open(path).read()

if token not in text:
    sys.exit(0)

if "\n" not in value:
    open(path, "w").write(text.replace(token, value))
    sys.exit(0)

# Multi-line: re-indent every line after the first to the placeholder's column.
out = []
for line in text.split("\n"):
    if token in line:
        indent = re.match(r"[ \t]*", line).group(0)
        lines  = value.split("\n")
        out.append(line.replace(token, lines[0]))
        out.extend(indent + l for l in lines[1:])
    else:
        out.append(line)
open(path, "w").write("\n".join(out))
PY
}

sealed=0; skipped=0; incomplete=""; pending_report=""; bad_seal=0
while IFS='|' read -r base pairs; do
  [ -z "${base:-}" ] && continue
  tmpl="${base}.sops.yaml.example"
  out="${base}.sops.yaml"

  [ -f "$tmpl" ] || { echo "  MISSING TEMPLATE  $tmpl"; continue; }

  if [ -f "$out" ] && grep -q '^sops:' "$out" 2>/dev/null && [ "$FORCE" -eq 0 ]; then
    printf '  %-52s already sealed\n' "$out"
    skipped=$((skipped + 1)); continue
  fi

  # May this file seal with `__PENDING__` values?
  pending_allowed=0
  case "$PENDING_OK" in *"
$base
"*) pending_allowed=1 ;; esac

  # Are all this file's values present? A `__PENDING__` value is not missing --
  # it is a declared, tracked gap -- but only where that is allowed.
  missing=""; pending=""
  IFS=',' read -ra kvs <<<"$pairs"
  for kv in "${kvs[@]}"; do
    var="${kv#*=}"
    eval "val=\${$var:-}"
    case "$val" in
      __PENDING__|__PENDING__:*)
        if [ "$pending_allowed" -eq 1 ]; then
          pending="$pending $var"
        else
          missing="$missing $var"
        fi
        ;;
      "") missing="$missing $var" ;;
    esac
  done

  if [ -n "$missing" ]; then
    printf '  %-52s SKIPPED -- empty:%s\n' "$out" "$missing"
    incomplete="$incomplete\n  $out --$missing"
    continue
  fi

  cp "$tmpl" "$out"
  for kv in "${kvs[@]}"; do
    var="${kv#*=}"
    eval "val=\${$var}"
    case "$val" in
      __PENDING__)   val="PENDING-$var" ;;
      __PENDING__:*) val="${val#__PENDING__:}" ;;
    esac
    subst "$out" "${kv%%=*}" "$val"
  done

  [ -n "$pending" ] && pending_report="$pending_report\n  $out --$pending"

  # Nothing may remain unsubstituted.
  if grep -qE '(PUT_[A-Z0-9_]+|REPLACE_[A-Z0-9_]+)' "$out"; then
    printf '  %-52s FAILED -- placeholder left:\n' "$out"
    grep -oE '(PUT_[A-Z0-9_]+|REPLACE_[A-Z0-9_]+)' "$out" | sort -u | sed 's/^/      /'
    rm -f "$out"
    continue
  fi

  # ------------------------------------------------------------------------
  # Prove the value that lands in the Secret is the value from the env file.
  #
  # Text substitution puts a string into a YAML document, and YAML then gets an
  # opinion about it. Two ways that silently corrupted secrets here:
  #
  #   - an unquoted scalar containing ` #` -- everything from the hash on is a
  #     comment. `hunter2" #admin password` became `hunter2"`: a wrong password,
  #     with a stray quote, and valid YAML either way.
  #   - an unquoted scalar starting with `{` -- parsed as a flow mapping and
  #     re-serialised, which dropped the spaces after the colons in Paperless'
  #     JSON blob. Harmless there, but the same mechanism reorders keys and
  #     rewrites quoting in general.
  #
  # Neither shows up as an error at any point: the file encrypts, decrypts, and
  # renders. It fails at the application, as a bad password.
  #
  # So compare against the DECRYPTED file rather than the file we just wrote:
  # that puts the value through sops' own YAML parser, which is the one that
  # actually decides what Kubernetes receives.
  # ------------------------------------------------------------------------
  roundtrip_check() {
    local f="$1" vars="$2"
    VARS="$vars" python3 - "$f" <<'PY'
import os, re, subprocess, sys
path = sys.argv[1]
r = subprocess.run(["sops", "--decrypt", path], capture_output=True, text=True)
if r.returncode != 0:
    print("      decrypt failed: " + r.stderr.strip().split("\n")[0]); sys.exit(1)
text = r.stdout
bad = []
for var in os.environ["VARS"].split():
    val = os.environ.get(var, "")
    if not val:
        continue
    if val == "__PENDING__" or val.startswith("__PENDING__:"):
        continue
    lines = val.split("\n")
    if len(lines) == 1:
        if val not in text:
            bad.append(var)
    else:
        # A block scalar is re-indented, so compare line by line without indent.
        stripped = [l.strip() for l in text.split("\n")]
        if not all(l.strip() in stripped for l in lines if l.strip()):
            bad.append(var)
            continue
        # A PEM key must have EXACTLY as many armour lines in the file as the
        # value itself has -- one. More than that means the template supplied its
        # own BEGIN/END around the placeholder, which yields a key no SSH
        # implementation will parse while the YAML stays perfectly valid.
        #
        # Counted as whole LINES, not as substrings: these templates carry long
        # explanatory comments, and one of them quotes the armour in prose. A
        # substring count reports that comment as a duplicated key.
        def armour_lines(s):
            return [l.strip() for l in s.split("\n")
                    if re.fullmatch(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", l.strip())]
        want = armour_lines(val)
        if want:
            got = armour_lines(text)
            if len(got) != len(want):
                print(f"      {var}: file has {len(got)} PRIVATE KEY armour line(s),"
                      f" the value has {len(want)} -- the template probably wraps"
                      f" the placeholder in its own armour")
                bad.append(var)
for var in bad:
    print(f"      value of {var} did not survive the YAML round-trip")
sys.exit(1 if bad else 0)
PY
  }

  if sops --encrypt --in-place "$out" >/dev/null 2>&1; then
    vars=""
    for kv in "${kvs[@]}"; do vars="$vars ${kv#*=}"; done
    if ! roundtrip_check "$out" "$vars"; then
      printf '  %-52s CORRUPTED BY YAML -- quote the placeholder in %s\n' "$out" "$tmpl"
      rm -f "$out"
      bad_seal=1
      continue
    fi
    if [ -n "$pending" ]; then
      printf '  %-52s sealed, PENDING:%s\n' "$out" "$pending"
    else
      printf '  %-52s sealed\n' "$out"
    fi
    sealed=$((sealed + 1))
  else
    printf '  %-52s SOPS FAILED\n' "$out"
    sops --encrypt --in-place "$out" 2>&1 | head -4 | sed 's/^/      /'
    rm -f "$out"
  fi
done <<EOF
$MAP
EOF

echo
echo "sealed=$sealed  already-sealed=$skipped"

# Prove they decrypt, rather than trusting that encryption returned 0.
echo
echo "--- verifying every sealed file round-trips ---"
bad=$bad_seal
for f in $(git ls-files -co --exclude-standard '*.sops.yaml' 2>/dev/null); do
  case "$f" in .sops.yaml) continue ;; esac
  if sops --decrypt "$f" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$f"
  else
    printf '  FAIL  %s (cannot decrypt)\n' "$f"; bad=1
  fi
done

if [ -n "$pending_report" ]; then
  echo
  echo "SEALED WITH SENTINEL VALUES -- the file works, these keys do not:"
  printf '%b\n' "$pending_report"
  echo
  echo "  Fix after 'task bootstrap:aws-backup' (or whatever issues the credential):"
  echo "    1. put the real values in secrets.local.env"
  echo "    2. scripts/seal-secrets-from-env.sh --force"
fi

if [ -n "$incomplete" ]; then
  echo
  echo "STILL TO DO -- these have no value yet:"
  printf '%b\n' "$incomplete"
fi

exit $bad
