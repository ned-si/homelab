#!/bin/bash
# check-indexers.sh: fail if any private or semi-private Prowlarr indexer can
# be used automatically (RSS or automatic search). Policy: docs/theater.md,
# "Indexers". Read-only; reads the API key inside the Prowlarr pod, never prints
# it.
#
# Usage: scripts/check-indexers.sh
# Exit:  0 policy holds, 1 violation, 2 cannot read Prowlarr.
set -euo pipefail

NS=${NS:-theater}
api() { # path -> JSON on stdout
  kubectl --request-timeout=30s -n "$NS" exec deploy/prowlarr -- sh -c \
    "k=\$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml); curl -fsS -m 20 -H \"X-Api-Key: \$k\" http://localhost:9696/arr/prowlarr/api/v1/$1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
api indexer >"$tmp/indexer.json" || { echo "cannot read Prowlarr indexers" >&2; exit 2; }
api appprofile >"$tmp/appprofile.json" || { echo "cannot read Prowlarr app profiles" >&2; exit 2; }

python3 - "$tmp" <<'EOF'
import json, re, sys
d = sys.argv[1]
indexers = json.load(open(f"{d}/indexer.json"))
profiles = {p["id"]: p for p in json.load(open(f"{d}/appprofile.json"))}
bad = 0
for i in sorted(indexers, key=lambda x: x["name"].lower()):
    p = profiles.get(i["appProfileId"], {})
    auto = p.get("enableRss", True) or p.get("enableAutomaticSearch", True)
    restricted = i.get("privacy") != "public" or re.search("ygg", i["name"], re.I)
    state = "auto" if auto else "manual"
    verdict = "ok"
    # A disabled indexer is not used at all, whatever its profile.
    if restricted and auto and i.get("enable"):
        verdict = "FAIL"
        bad = 1
    print(f"{verdict:4} {i['name']:<22} {i.get('privacy'):<12} "
          f"enabled={str(i.get('enable')).lower():<5} profile={p.get('name', '?')} ({state})")
sys.exit(bad)
EOF
