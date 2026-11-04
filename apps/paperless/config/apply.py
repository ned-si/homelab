#!/usr/bin/env python3
"""Apply paperless.json to Paperless-ngx through its REST API.

Upserts groups (with their model permissions), document types, tags, custom
fields, saved views and workflows by name: creates what is missing, updates
what differs, deletes nothing (an object in Paperless but not in the file is
reported). Document types, tags and saved views are written with
`owner: null` and no object grants, so every account with the model's view
permission sees them. Groups, custom fields and workflows have no owner in
Paperless.

The member list (the SOPS Secret `paperless-config`, one JSON value
`{"editors": [...], "readers": [...]}`) names the accounts of each managed
group by username or email. Listed accounts are put into their group, every
other account is taken out of the managed groups, and accounts other than
nedsi-admin, automation and canary that hold the superuser flag or direct
permissions are counted. Only counts are logged, never a username.

`--nightly` adds three passes over the documents and correspondents:
  - `Retain until` = creation date + the document type's period, or no date
    for a type kept forever, an unmanaged type or no type;
  - view for the group `readers` on every correspondent;
  - view for `readers` on a document if and only if it has no `private` tag.
The two permission passes are skipped while the group `readers` does not
exist. Correspondent and document names are never logged.

Before any change it lints the configuration (quoted phrases, no keyword in
two document types) and waits up to 10 minutes for `/api/`. Connection errors
and 5xx answers are retried three times; any 4xx fails at once.

Environment: PAPERLESS_API_URL (default http://paperless:8000), the
`automation` user's token, PAPERLESS_API_TOKEN or the file named by
PAPERLESS_API_TOKEN_FILE (default /secret/PAPERLESS_API_TOKEN), and the
member list in the file named by PAPERLESS_MEMBERS_FILE (default
/members/config.json); both files are waited for up to 10 minutes. Stdlib
only.
Spec: .kiro/specs/paperless-documents (design.md "Configuration as code").
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Optional

API_VERSION = "10"
ALGORITHMS = {"none": 0, "any": 1, "all": 2, "literal": 3, "regex": 4, "fuzzy": 5, "auto": 6}
NO_GRANTS = {"view": {"users": [], "groups": []}, "change": {"users": [], "groups": []}}
READERS = "readers"
# Accounts whose superuser flag or direct permissions are intended (design.md
# "Access"); they are never matched by the member list either.
EXEMPT_ACCOUNTS = ("nedsi-admin", "automation", "canary")
PRIVATE_TAG = "private"
RETAIN_FIELD = "Retain until"
RETRIES = 3
WAIT_SECONDS = 600
READY_PATH = "/api/tags/?page_size=1"

# Unquoted single words an `Any` rule must not contain: function words (an
# unquoted phrase such as `ticket de caisse` splits into them) and the generic
# words that appear in letters of every type (design.md "Matching rules").
GENERIC_WORDS = {
    "a", "an", "and", "au", "aux", "d", "de", "der", "des", "die", "das", "du", "en", "et",
    "für", "l", "la", "le", "les", "no", "of", "the", "to", "und", "von", "zu",
    "attestation", "certificat", "certificate", "contrat", "contract", "facture",
    "invoice", "number", "policy", "receipt", "rechnung", "statement",
}

GROUP_REFS = ("assign_view_groups", "assign_change_groups", "remove_view_groups", "remove_change_groups")

Transport = Callable[[str, str, dict, Optional[bytes]], "tuple[int, bytes]"]


class ApiError(Exception):
    pass


class ConfigError(Exception):
    pass


# --- matching, as Paperless does it (documents/matching.py) ---------------

def split_match(match: str) -> list[str]:
    """The terms of an `Any` rule: quoted phrases or single words."""
    return [(q or w).strip() for q, w in re.findall(r'"([^"]+)"|(\S+)', match)]


def term_pattern(term: str) -> str:
    return re.escape(re.sub(r"\s+", " ", term)).replace(r"\ ", r"\s+")


def matches(rule: dict, text: str) -> bool:
    """True when Paperless' rule (algorithm `any` or `regex`, case-insensitive) matches."""
    algorithm = rule["matching_algorithm"]
    if not rule.get("match", "").strip() or algorithm == "none":
        return False
    if algorithm == "any":
        return any(re.search(rf"\b{term_pattern(t)}\b", text, re.IGNORECASE)
                   for t in split_match(rule["match"]))
    if algorithm == "regex":
        return re.search(rule["match"], text, re.IGNORECASE) is not None
    raise ConfigError(f"unsupported matching algorithm {algorithm!r}")


def lint(config: dict) -> list[str]:
    """Errors in the configuration; empty when it may be applied."""
    errors = []
    for kind in ("document_types", "tags"):
        owners: dict[str, str] = {}
        for obj in config.get(kind, []):
            name, algorithm, match = obj["name"], obj["matching_algorithm"], obj.get("match", "")
            if algorithm not in ALGORITHMS:
                errors.append(f"{kind} {name}: unknown algorithm {algorithm}")
                continue
            if algorithm == "regex":
                try:
                    re.compile(match)
                except re.error as exc:
                    errors.append(f"{kind} {name}: bad regex: {exc}")
            if algorithm != "any":
                continue
            if match.count('"') % 2:
                errors.append(f"{kind} {name}: unbalanced quote")
            for quoted, word in re.findall(r'"([^"]+)"|(\S+)', match):
                if word and word.lower().strip("'’") in GENERIC_WORDS:
                    errors.append(f"{kind} {name}: unquoted generic word or phrase part {word!r}")
            for term in split_match(match):
                key = re.sub(r"\s+", " ", term.lower())
                if key in owners and owners[key] != name:
                    errors.append(f"{kind}: keyword {term!r} in both {owners[key]} and {name}")
                owners[key] = name
    names = [o["name"] for o in config.get("document_types", [])]
    groups = {o["name"] for o in config.get("groups", [])}
    for kind in ("groups", "document_types", "tags", "custom_fields", "saved_views", "workflows"):
        seen = [o["name"] for o in config.get(kind, [])]
        if len(seen) != len(set(seen)):
            errors.append(f"{kind}: duplicate name")
    for obj in config.get("document_types", []):
        years = obj.get("retain_years")
        if years is not None and (not isinstance(years, int) or years < 1):
            errors.append(f"document_types {obj['name']}: retain_years must be a positive integer or null")
    for wf in config.get("workflows", []):
        for trigger in wf.get("triggers", []):
            for t in trigger.get("filter_has_any_document_types", []):
                if t not in names:
                    errors.append(f"workflow {wf['name']}: unknown document type {t}")
        for action in wf.get("actions", []):
            for key in GROUP_REFS:
                for g in action.get(key, []):
                    if g not in groups:
                        errors.append(f"workflow {wf['name']}: unknown group {g}")
    return errors


def lint_members(members: dict, config: dict) -> list[str]:
    """Errors in the member list. Messages name groups, never an entry."""
    groups = [o["name"] for o in config.get("groups", [])]
    errors, seen = [], {}
    if not isinstance(members, dict):
        return ["member list: not a JSON object"]
    unknown = len(set(members) - set(groups))
    if unknown:
        errors.append(f"member list: {unknown} key(s) not a group of paperless.json "
                      f"({', '.join(groups)})")
    for group in groups:
        if group not in members:
            continue
        entries = members[group]
        if not isinstance(entries, list) or not all(isinstance(e, str) and e.strip() for e in entries):
            errors.append(f"member list: {group} must be a list of usernames or emails")
            continue
        for entry in entries:
            key = entry.strip().lower()
            if key in EXEMPT_ACCOUNTS:
                errors.append(f"member list: {group} lists an exempt account")
            elif key in seen and seen[key] != group:
                errors.append(f"member list: an entry is in both {seen[key]} and {group}")
            seen[key] = group
    return errors


# --- API client -------------------------------------------------------------

def urllib_transport(method: str, url: str, headers: dict, data: bytes | None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


class Client:
    def __init__(self, base: str, token: str, transport: Transport = urllib_transport,
                 sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.monotonic):
        self.base = base.rstrip("/")
        self.headers = {"Authorization": f"Token {token}",
                        "Accept": f"application/json; version={API_VERSION}",
                        "Content-Type": "application/json"}
        self.transport, self.sleep, self.clock = transport, sleep, clock

    def _once(self, method: str, path: str, body: Any) -> tuple[int, bytes]:
        data = None if body is None else json.dumps(body).encode()
        return self.transport(method, self.base + path, self.headers, data)

    def request(self, method: str, path: str, body: Any = None) -> Any:
        """One API call; connection errors and 5xx are retried RETRIES times."""
        for attempt in range(RETRIES + 1):
            try:
                status, raw = self._once(method, path, body)
            except (urllib.error.URLError, OSError) as exc:
                status, raw = 0, str(exc).encode()
            if 200 <= status < 300:
                return json.loads(raw) if raw.strip() else None
            if 400 <= status < 500:
                raise ApiError(f"{method} {path}: {status} {raw[:500].decode(errors='replace')}")
            if attempt < RETRIES:
                self.sleep(2 ** (attempt + 1))
        raise ApiError(f"{method} {path}: {status or 'no connection'} after {RETRIES} retries")

    def list(self, path: str) -> list[dict]:
        sep = "&" if "?" in path else "?"
        url, out = f"{path}{sep}page_size=1000", []
        while url:
            page = self.request("GET", url)
            out.extend(page["results"])
            nxt = page.get("next")
            url = None
            if nxt:
                parts = urllib.parse.urlsplit(nxt)
                url = parts.path + ("?" + parts.query if parts.query else "")
        return out

    def wait_ready(self, timeout: float = WAIT_SECONDS) -> None:
        """Wait for the API to answer 2xx; a 401 or 403 fails at once.

        Probes READY_PATH: `/api/` itself only redirects to the schema view,
        while a one-item tag list proves the token, the API and the database."""
        deadline, delay = self.clock() + timeout, 2.0
        while True:
            try:
                status, raw = self._once("GET", READY_PATH, None)
            except (urllib.error.URLError, OSError):
                status, raw = 0, b""
            if 200 <= status < 300:
                return
            if status in (401, 403):
                raise ApiError(f"GET {READY_PATH}: {status}: check the API token")
            if self.clock() + delay > deadline:
                raise ApiError(f"GET {READY_PATH}: not ready after {timeout:.0f} s (last status {status})")
            self.sleep(delay)
            delay = min(delay * 2, 30.0)


# --- desired state ----------------------------------------------------------

def grants(obj: dict) -> dict:
    perms = obj.get("permissions") or {}
    return {a: {k: sorted((perms.get(a) or {}).get(k) or []) for k in ("users", "groups")}
            for a in ("view", "change")}


def matching_payload(obj: dict) -> dict:
    return {"name": obj["name"], "match": obj.get("match", ""),
            "matching_algorithm": ALGORITHMS[obj["matching_algorithm"]],
            "is_insensitive": True}


def doc_type_payload(obj: dict, ids: dict) -> dict:
    return {**matching_payload(obj), "owner": None, "set_permissions": NO_GRANTS}


def tag_payload(obj: dict, ids: dict) -> dict:
    return {**matching_payload(obj), "color": obj.get("color", "#a6cee3"),
            "is_inbox_tag": bool(obj.get("is_inbox_tag", False)),
            "owner": None, "set_permissions": NO_GRANTS}


def group_payload(obj: dict, ids: dict) -> dict:
    return {"name": obj["name"], "permissions": sorted(obj.get("permissions", []))}


def field_payload(obj: dict, ids: dict) -> dict:
    out = {"name": obj["name"], "data_type": obj["data_type"]}
    if "extra_data" in obj:
        out["extra_data"] = obj["extra_data"]
    return out


def resolve_sort(sort: str | None, ids: dict) -> str | None:
    if sort and sort.startswith("custom_field:"):
        return f"custom_field_{ids['custom_fields'][sort.split(':', 1)[1]]}"
    return sort


def view_payload(obj: dict, ids: dict) -> dict:
    rules = []
    for rule in obj.get("filter_rules", []):
        if "tag" in rule:
            value = str(ids["tags"][rule["tag"]])
        elif "custom_field_query" in rule:
            name, op, arg = rule["custom_field_query"]
            value = json.dumps([ids["custom_fields"][name], op, arg])
        else:
            value = rule.get("value")
        rules.append({"rule_type": rule["rule_type"], "value": value})
    return {"name": obj["name"], "sort_field": resolve_sort(obj.get("sort_field"), ids),
            "sort_reverse": bool(obj.get("sort_reverse", False)), "filter_rules": rules,
            "owner": None, "set_permissions": NO_GRANTS}


def workflow_payload(obj: dict, ids: dict) -> dict:
    def refs(d: dict) -> dict:
        out = dict(d)
        for key in ("filter_has_any_document_types", "filter_has_not_document_types"):
            if key in out:
                out[key] = [ids["document_types"][n] for n in out[key]]
        for key in ("filter_has_tags", "filter_has_not_tags", "assign_tags", "remove_tags"):
            if key in out:
                out[key] = [ids["tags"][n] for n in out[key]]
        for key in GROUP_REFS:
            if key in out:
                out[key] = [ids["groups"][n] for n in out[key]]
        return out
    return {"name": obj["name"], "order": obj.get("order", 0), "enabled": obj.get("enabled", True),
            "triggers": [refs(t) for t in obj.get("triggers", [])],
            "actions": [refs(a) for a in obj.get("actions", [])]}


def _norm(value: Any) -> Any:
    if isinstance(value, list) and all(isinstance(v, (int, str)) for v in value):
        return sorted(str(v) for v in value)
    return value


def differs(kind: str, current: dict, payload: dict) -> bool:
    for key, want in payload.items():
        if key == "set_permissions":
            if grants(current) != grants({"permissions": want}):
                return True
        elif key == "permissions":
            if sorted(set(current.get(key) or [])) != sorted(set(want)):
                return True
        elif key == "extra_data":
            have = current.get("extra_data") or {}
            if any(have.get(k) != v for k, v in want.items()):
                return True
        elif key == "filter_rules":
            have = sorted((r["rule_type"], r.get("value")) for r in current.get("filter_rules", []))
            if have != sorted((r["rule_type"], r["value"]) for r in want):
                return True
        elif key in ("triggers", "actions"):
            have = current.get(key, [])
            if len(have) != len(want):
                return True
            for h, w in zip(have, want):
                if any(_norm(h.get(k)) != _norm(v) for k, v in w.items()):
                    return True
        elif current.get(key) != want:
            return True
    return False


KINDS = [
    ("groups", "/api/groups/", group_payload),
    ("document_types", "/api/document_types/", doc_type_payload),
    ("tags", "/api/tags/", tag_payload),
    ("custom_fields", "/api/custom_fields/", field_payload),
    ("saved_views", "/api/saved_views/", view_payload),
    ("workflows", "/api/workflows/", workflow_payload),
]


def apply_objects(client: Client, config: dict, log: Callable[[str], None]) -> tuple[int, dict]:
    """Upsert every configured object; returns (changes, ids by kind and name)."""
    changes, ids = 0, {}
    for kind, path, build in KINDS:
        query = "?full_perms=true" if kind in ("document_types", "tags", "saved_views") else ""
        current = {o["name"]: o for o in client.list(path + query)}
        ids[kind] = {n: o["id"] for n, o in current.items()}
        for obj in config.get(kind, []):
            payload = build(obj, ids)
            have = current.get(obj["name"])
            if have is None:
                created = client.request("POST", path, payload)
                ids[kind][obj["name"]] = created["id"]
                log(f"created {kind} {obj['name']}")
                changes += 1
            elif kind == "custom_fields" and have.get("data_type") != payload["data_type"]:
                raise ConfigError(f"custom field {obj['name']}: data_type is {have.get('data_type')} "
                                  f"in Paperless and cannot change")
            elif differs(kind, have, payload):
                if kind == "workflows":
                    for part in ("triggers", "actions"):
                        for new, old in zip(payload[part], have.get(part, [])):
                            new["id"] = old["id"]
                client.request("PATCH", f"{path}{have['id']}/", payload)
                log(f"updated {kind} {obj['name']}")
                changes += 1
        wanted = {o["name"] for o in config.get(kind, [])}
        for name in sorted(set(current) - wanted):
            log(f"unmanaged {kind} {name}: not in paperless.json, left as is")
    return changes, ids


# --- accounts ---------------------------------------------------------------

def member_pass(client: Client, members: dict, group_ids: dict, log: Callable[[str], None]) -> int:
    """Listed accounts into their managed group, everyone else out of the managed groups.

    An entry matches an account by username or email, case-insensitively; the
    exempt accounts are never matched. An entry that matches no account yet
    (no first login) is counted; one that matches two accounts fails."""
    managed = set(group_ids.values())
    users = client.list("/api/users/")
    wanted: dict[int, set] = {u["id"]: set() for u in users}
    # Counters keyed by the configured group names: nothing read from the
    # member list reaches the log.
    listed = {g: 0 for g in group_ids}
    found = {g: 0 for g in group_ids}
    for group in group_ids:
        for entry in members.get(group, []):
            listed[group] += 1
            key = entry.strip().lower()
            hits = [u for u in users if u["username"] not in EXEMPT_ACCOUNTS
                    and key in (u["username"].lower(), (u.get("email") or "").lower())]
            if len(hits) > 1:
                raise ConfigError(f"member list: an entry of {group} matches {len(hits)} accounts")
            if hits:
                wanted[hits[0]["id"]].add(group_ids[group])
                found[group] += 1
    changes = 0
    for user in users:
        have = set(user.get("groups") or [])
        want = (have - managed) | wanted[user["id"]]
        if want != have:
            client.request("PATCH", f"/api/users/{user['id']}/", {"groups": sorted(want)})
            changes += 1
    for group in sorted(group_ids):
        missing = listed[group] - found[group]
        log(f"group {group}: {found[group]} listed account(s) found"
            + (f", {missing} not found (no Paperless login yet)" if missing else ""))
    flagged = sum(1 for u in users if u["username"] not in EXEMPT_ACCOUNTS
                  and (u.get("is_superuser") or u.get("user_permissions")))
    log(f"accounts: {changes} membership change(s); {flagged} account(s) other than "
        f"{', '.join(EXEMPT_ACCOUNTS)} with the superuser flag or direct permissions")
    return changes


# --- nightly passes ---------------------------------------------------------

def add_years(day: datetime.date, years: int) -> datetime.date:
    try:
        return day.replace(year=day.year + years)
    except ValueError:  # 29 February
        return day.replace(year=day.year + years, day=28)


def retain_until(doc: dict, years_by_type: dict) -> str | None:
    years = years_by_type.get(doc.get("document_type"))
    if years is None or not doc.get("created"):
        return None
    return add_years(datetime.date.fromisoformat(doc["created"][:10]), years).isoformat()


def retain_pass(client: Client, docs: list[dict], years_by_type: dict, field_id: int,
                log: Callable[[str], None]) -> int:
    """Set `Retain until` from type and creation date; remove it where there is none."""
    by_value: dict[str | None, list[int]] = {}
    for doc in docs:
        want = retain_until(doc, years_by_type)
        have = [f for f in doc.get("custom_fields", []) if f["field"] == field_id]
        if want is None and not have:
            continue
        if have and want is not None and str(have[0].get("value")) == want:
            continue
        by_value.setdefault(want, []).append(doc["id"])
    for value in sorted(by_value, key=lambda v: v or ""):
        params = ({"add_custom_fields": {}, "remove_custom_fields": [field_id]} if value is None
                  else {"add_custom_fields": {str(field_id): value}, "remove_custom_fields": []})
        client.request("POST", "/api/documents/bulk_edit/",
                       {"documents": sorted(by_value[value]), "method": "modify_custom_fields",
                        "parameters": params})
    changed = sum(len(v) for v in by_value.values())
    log(f"retain until: {changed} document(s) changed")
    return changed


def readers_view(client: Client, path: str, obj: dict, readers: int, grant: bool) -> None:
    view = grants(obj)["view"]
    groups = sorted(set(view["groups"]) | {readers}) if grant else [g for g in view["groups"] if g != readers]
    client.request("PATCH", f"{path}{obj['id']}/",
                   {"set_permissions": {"view": {"users": view["users"], "groups": groups}}})


def correspondent_pass(client: Client, readers: int, log: Callable[[str], None]) -> int:
    """View for `readers` on every correspondent; names are neither read into logs nor changed."""
    changed = 0
    for c in client.list("/api/correspondents/?full_perms=true"):
        if readers not in grants(c)["view"]["groups"]:
            readers_view(client, "/api/correspondents/", c, readers, True)
            changed += 1
    log(f"correspondents: {changed} granted view for {READERS}")
    return changed


def document_pass(client: Client, docs: list[dict], readers: int, private: int | None,
                  log: Callable[[str], None]) -> int:
    """View for `readers` if and only if the document has no `private` tag."""
    changed = 0
    for doc in docs:
        want = private not in doc.get("tags", [])
        if (readers in grants(doc)["view"]["groups"]) != want:
            readers_view(client, "/api/documents/", doc, readers, want)
            changed += 1
    log(f"documents: {changed} {READERS} view(s) reconciled")
    return changed


def nightly(client: Client, config: dict, ids: dict, log: Callable[[str], None]) -> int:
    docs = client.list("/api/documents/?full_perms=true"
                       "&fields=id,document_type,created,tags,custom_fields,permissions")
    years = {ids["document_types"][o["name"]]: o.get("retain_years")
             for o in config.get("document_types", []) if o["name"] in ids["document_types"]}
    changes = retain_pass(client, docs, years, ids["custom_fields"][RETAIN_FIELD], log)
    groups = {g["name"]: g["id"] for g in client.list("/api/groups/")}
    if READERS not in groups:
        log(f"group {READERS} missing: correspondent and document passes skipped")
        return changes
    changes += correspondent_pass(client, groups[READERS], log)
    changes += document_pass(client, docs, groups[READERS], ids["tags"].get(PRIVATE_TAG), log)
    return changes


def run(client: Client, config: dict, nightly_mode: bool, log: Callable[[str], None] = print,
        members: dict | None = None) -> int:
    members = members or {}
    errors = lint(config) + lint_members(members, config)
    if errors:
        raise ConfigError("; ".join(errors))
    client.wait_ready()
    changes, ids = apply_objects(client, config, log)
    if config.get("groups"):
        changes += member_pass(client, members,
                               {o["name"]: ids["groups"][o["name"]] for o in config["groups"]}, log)
    if nightly_mode:
        changes += nightly(client, config, ids, log)
    log(f"paperless-apply: {changes} change(s)")
    return changes


def read_secret(path: str, timeout: float = WAIT_SECONDS,
                sleep: Callable[[float], None] = time.sleep,
                clock: Callable[[], float] = time.monotonic) -> str:
    """The content of a mounted Secret file. The Secrets sync in another
    Application, so on a first deploy the file can appear after the pod starts."""
    deadline = clock() + timeout
    while True:
        try:
            with open(path, encoding="utf-8") as fh:
                token = fh.read().strip()
            if token:
                return token
        except FileNotFoundError:
            pass
        if clock() >= deadline:
            raise ConfigError(f"nothing in {path} after {timeout:.0f} s")
        sleep(10)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "paperless.json"))
    parser.add_argument("--nightly", action="store_true", help="also run the document passes")
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as fh:
        config = json.load(fh)
    try:
        token = os.environ.get("PAPERLESS_API_TOKEN") or read_secret(
            os.environ.get("PAPERLESS_API_TOKEN_FILE", "/secret/PAPERLESS_API_TOKEN"))
        try:
            members = json.loads(read_secret(
                os.environ.get("PAPERLESS_MEMBERS_FILE", "/members/config.json")))
        except json.JSONDecodeError:
            raise ConfigError("member list: not valid JSON") from None
        client = Client(os.environ.get("PAPERLESS_API_URL", "http://paperless:8000"), token)
        run(client, config, args.nightly, members=members)
    except (ApiError, ConfigError) as exc:
        print(f"paperless-apply: FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
