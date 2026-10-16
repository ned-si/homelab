#!/bin/bash
# check-indexers.sh: assert the Prowlarr policy for enabled private and
# semi-private indexers (docs/theater.md, "Indexers"):
#   1. on an automatic profile (RSS or automatic search) only with the
#      definition's freeleech-only option on;
#   2. without that option, on a manual profile;
#   and never with the `books` tag that syncs them to LazyLibrarian;
#   3. the indexers in MUST_BE_DISABLED are disabled;
#   4. the set of indexers is EXPECTED, no more, no less.
# Read-only; reads the API key inside the Prowlarr pod, never prints it.
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
api tag >"$tmp/tag.json" || { echo "cannot read Prowlarr tags" >&2; exit 2; }

python3 - "$tmp" <<'EOF'
import json, sys
d = sys.argv[1]
indexers = json.load(open(f"{d}/indexer.json"))
profiles = {p["id"]: p for p in json.load(open(f"{d}/appprofile.json"))}
books = {t["id"] for t in json.load(open(f"{d}/tag.json")) if t["label"] == "books"}
# The definition's "freeleech only" switch; its name varies per definition.
FREELEECH = {"freeleechonly", "freeleech"}
# Off whatever their settings (docs/theater.md): IPTorrents has locked the
# account; no use, freeleech included, until it restores access.
MUST_BE_DISABLED = {"iptorrents"}
# The indexers Prowlarr should have (docs/theater.md, "Indexers"). Add one here
# when you add it in Prowlarr; remove one whose definition Prowlarr no longer
# ships (Prowlarr -> System -> Status, "Indexers have no definition").
EXPECTED = {"bt.etree", "c411", "ebookbay", "iptorrents", "limetorrents",
            "the pirate bay", "torrent9"}
bad = 0
names = {i["name"].lower() for i in indexers}
for n in sorted(EXPECTED - names):
    print(f"FAIL {n:<22} missing: expected in Prowlarr")
    bad = 1
for i in sorted(indexers, key=lambda x: x["name"].lower()):
    p = profiles.get(i["appProfileId"], {})
    auto = p.get("enableRss", True) or p.get("enableAutomaticSearch", True)
    tagged = bool(books & set(i.get("tags", [])))
    restricted = i.get("privacy") != "public"
    fl = next((f.get("value") for f in i.get("fields", []) if f["name"].lower() in FREELEECH), None)
    state = "auto" if auto else "manual"
    verdict = "ok"
    reason = ""
    if restricted:
        if tagged:
            verdict, reason = "FAIL", "books tag on a non-public indexer"
        elif auto and fl is None:
            # Rule 2: no freeleech-only option, so manual only.
            verdict, reason = "FAIL", "automatic without a freeleech-only option"
        elif auto and fl is not True:
            # Rule 1: automatic only with freeleech-only on.
            verdict, reason = "FAIL", "automatic with freeleech-only off"
        elif fl is True and not auto:
            verdict, reason = "WARN", "freeleech-only on but manual"
        # A disabled indexer is not used at all, whatever its settings.
        if verdict == "FAIL" and not i.get("enable"):
            verdict, reason = "ok", reason + " (ignored: disabled)"
    if i["name"].lower() in MUST_BE_DISABLED and i.get("enable"):
        verdict, reason = "FAIL", "enabled, must stay disabled"
    if i["name"].lower() not in EXPECTED:
        verdict, reason = "FAIL", "not in EXPECTED (scripts/check-indexers.sh)"
    if verdict == "FAIL":
        bad = 1
    freeleech = "n/a" if fl is None else ("on" if fl is True else "off")
    print(f"{verdict:4} {i['name']:<22} {i.get('privacy'):<12} "
          f"enabled={str(i.get('enable')).lower():<5} profile={p.get('name', '?')} ({state}) "
          f"freeleech-only={freeleech}{' books' if tagged else ''}{'  -- ' + reason if reason else ''}")
sys.exit(bad)
EOF
