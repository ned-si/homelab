"""apps/paperless/config/apply.py against a fake Paperless API (no network)."""
from __future__ import annotations

import copy
import importlib.util
import json
import re
import urllib.error
import urllib.parse
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "apps" / "paperless" / "config" / "apply.py"
CONFIG = json.loads((ROOT / "apps" / "paperless" / "config" / "paperless.json").read_text())
CORPUS = ROOT / "tests" / "paperless" / "corpus"

spec = importlib.util.spec_from_file_location("paperless_apply", SRC)
apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply)

OWNED = {"document_types", "tags", "saved_views", "correspondents", "documents"}
AUTOMATION_USER = 1


class FakePaperless:
    """In-memory Paperless API: list, create, patch, bulk_edit; records every call."""

    def __init__(self):
        self.store = {k: {} for k in ("document_types", "tags", "custom_fields", "saved_views",
                                      "workflows", "correspondents", "documents", "groups",
                                      "users")}
        self.calls: list[tuple[str, str, dict | None]] = []
        self.next_id = 100
        self.failures: list[int | str] = []  # queued answers: a status, or "conn"

    def add(self, kind, **obj):
        self.next_id += 1
        obj.setdefault("id", self.next_id)
        if kind in OWNED:
            obj.setdefault("owner", None)
            obj.setdefault("permissions", copy.deepcopy(apply.NO_GRANTS))
        self.store[kind][obj["id"]] = obj
        return obj

    def __call__(self, method, url, headers, data):
        assert headers["Authorization"] == "Token t0k"
        parts = urllib.parse.urlsplit(url)
        body = json.loads(data) if data else None
        self.calls.append((method, parts.path, body))
        if self.failures:
            failure = self.failures.pop(0)
            if failure == "conn":
                raise urllib.error.URLError("connection refused")
            return failure, b'{"detail": "fake failure"}'
        segs = [s for s in parts.path.split("/") if s][1:]
        if not segs:
            return 200, b"{}"
        kind = segs[0]
        if kind == "documents" and segs[1:] == ["bulk_edit"]:
            return self._bulk_edit(body)
        if method == "GET":
            return 200, json.dumps({"count": len(self.store[kind]), "next": None,
                                    "results": list(self.store[kind].values())}).encode()
        if method == "POST":
            obj = {k: v for k, v in body.items() if k != "set_permissions"}
            if kind in OWNED and "owner" not in body:
                obj["owner"] = AUTOMATION_USER  # Paperless' default: the caller owns it
            self._grant(obj, body.get("set_permissions"))
            if kind == "workflows":
                for part in ("triggers", "actions"):
                    for item in obj[part]:
                        self.next_id += 1
                        item["id"] = self.next_id
            return 201, json.dumps(self.add(kind, **obj)).encode()
        if method == "PATCH":
            obj = self.store[kind][int(segs[1])]
            obj.update({k: v for k, v in body.items() if k != "set_permissions"})
            self._grant(obj, body.get("set_permissions"))
            return 200, json.dumps(obj).encode()
        return 405, b"{}"

    @staticmethod
    def _grant(obj, perms):
        if perms is None:
            return
        current = obj.setdefault("permissions", copy.deepcopy(apply.NO_GRANTS))
        for action, entry in perms.items():
            current[action] = {k: list(entry.get(k, [])) for k in ("users", "groups")}

    def _bulk_edit(self, body):
        assert body["method"] == "modify_custom_fields"
        params = body["parameters"]
        for doc_id in body["documents"]:
            doc = self.store["documents"][doc_id]
            fields = [f for f in doc["custom_fields"]
                      if f["field"] not in params["remove_custom_fields"]
                      and str(f["field"]) not in params["add_custom_fields"]]
            fields += [{"field": int(k), "value": v} for k, v in params["add_custom_fields"].items()]
            doc["custom_fields"] = fields
        return 200, b'"OK"'

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]


@pytest.fixture
def fake():
    return FakePaperless()


def client(fake, sleeps=None):
    clock = [0.0]

    def sleep(seconds):
        clock[0] += seconds
        if sleeps is not None:
            sleeps.append(seconds)
    return apply.Client("http://paperless:8000", "t0k", transport=fake, sleep=sleep,
                        clock=lambda: clock[0])


MEMBERS = {"editors": ["editor"], "readers": ["Reader@Example.invalid"]}


def run(fake, nightly=False, config=CONFIG, members=MEMBERS):
    log: list[str] = []
    changes = apply.run(client(fake), copy.deepcopy(config), nightly, log.append,
                        members=copy.deepcopy(members))
    return changes, log


def without_groups():
    config = copy.deepcopy(CONFIG)
    config.pop("groups")
    config["workflows"] = [w for w in config["workflows"] if w["name"] == "tax-relevant"]
    return config


# --- the configuration and the corpus -------------------------------------

def test_the_configuration_lints_clean():
    assert apply.lint(CONFIG) == []


def with_match(name, match):
    config = copy.deepcopy(CONFIG)
    next(t for t in config["document_types"] if t["name"] == name)["match"] = match
    return config


@pytest.mark.parametrize("match", [
    'quittance ticket de caisse Quittung',
    'Rechnungsnummer invoice number',
    '"numéro de facture" facture',
    '"ticket de caisse Quittung',
])
def test_lint_rejects_an_unquoted_phrase_or_a_generic_word(match):
    assert apply.lint(with_match("Receipt", match))


def test_lint_rejects_a_keyword_shared_by_two_document_types():
    errors = apply.lint(with_match("Invoice", '"numéro de facture" Kontoauszug'))
    assert any("Kontoauszug" in e and "Statement" in e for e in errors)


def test_a_bad_configuration_fails_before_any_request(fake):
    with pytest.raises(apply.ConfigError):
        run(fake, config=with_match("Invoice", "invoice number"))
    assert fake.calls == []


def corpus():
    out = []
    for path in sorted(CORPUS.glob("*.txt")):
        head, _, body = path.read_text(encoding="utf-8").partition("\n\n")
        meta = dict(line.split(": ", 1) for line in head.splitlines())
        expected = [] if meta["expected"] == "none" else [meta["expected"]]
        tags = meta.get("tags", "").split()
        out.append(pytest.param(expected, tags, body, id=path.stem))
    return out


@pytest.mark.parametrize("expected,tags,text", corpus())
def test_each_corpus_text_matches_exactly_its_expected_type(expected, tags, text):
    matched = [t["name"] for t in CONFIG["document_types"] if apply.matches(t, text)]
    assert matched == expected
    matched_tags = {t["name"] for t in CONFIG["tags"] if apply.matches(t, text)}
    assert set(tags) <= matched_tags


def test_the_corpus_covers_every_type_in_three_languages_and_the_qr_bills():
    names = {p.stem for p in CORPUS.glob("*.txt")}
    for t in CONFIG["document_types"]:
        if t["matching_algorithm"] != "none":
            for lang in ("fr", "de", "en"):
                assert f"{t['name'].lower()}-{lang}" in names
    assert {"qr-bill-fr", "qr-bill-de", "qr-bill-en"} <= names
    typographic = [p for p in CORPUS.glob("*.txt") if "’" in p.read_text(encoding="utf-8")]
    assert len(typographic) >= 3


@pytest.mark.parametrize("apostrophe", ["'", "’"])
def test_regex_types_accept_both_apostrophes(apostrophe):
    tax = next(t for t in CONFIG["document_types"] if t["name"] == "Tax")
    insurance = next(t for t in CONFIG["document_types"] if t["name"] == "Insurance")
    assert apply.matches(tax, f"Déclaration d{apostrophe}impôts 2025")
    assert apply.matches(insurance, f"Attestation d{apostrophe}assurance")


# --- applying the objects -------------------------------------------------

def test_first_run_creates_everything_unowned_without_grants(fake):
    changes, _ = run(fake)
    total = sum(len(CONFIG[k]) for k in ("groups", "document_types", "tags", "custom_fields",
                                          "saved_views", "workflows"))
    assert changes == total
    for method, path, body in fake.writes():
        kind = path.split("/")[2]
        if kind in ("document_types", "tags", "saved_views"):
            assert body["owner"] is None
            assert body["set_permissions"] == apply.NO_GRANTS
        else:  # groups, custom fields and workflows have no owner in Paperless
            assert "owner" not in body and "set_permissions" not in body
    assert all(o["owner"] is None for k in ("document_types", "tags", "saved_views")
               for o in fake.store[k].values())


def test_a_second_run_reports_zero_changes(fake):
    run(fake)
    before = len(fake.writes())
    changes, log = run(fake)
    assert changes == 0
    assert len(fake.writes()) == before
    assert log[-1] == "paperless-apply: 0 change(s)"


def test_saved_views_resolve_tags_and_custom_fields(fake):
    run(fake)
    views = {v["name"]: v for v in fake.store["saved_views"].values()}
    tags = {t["name"]: t["id"] for t in fake.store["tags"].values()}
    fields = {f["name"]: f["id"] for f in fake.store["custom_fields"].values()}
    assert views["Inbox"]["filter_rules"] == [{"rule_type": 6, "value": str(tags["inbox"])}]
    assert views["To pay"]["sort_field"] == f"custom_field_{fields['Due date']}"
    rule = views["Retention expired"]["filter_rules"][0]
    assert rule["rule_type"] == 42
    assert json.loads(rule["value"]) == [fields["Retain until"], "lt", "today"]
    wf = next(w for w in fake.store["workflows"].values() if w["name"] == "tax-relevant")
    types = {t["name"]: t["id"] for t in fake.store["document_types"].values()}
    assert sorted(wf["triggers"][0]["filter_has_any_document_types"]) == sorted(
        types[n] for n in ("Tax", "Statement", "Payslip", "Insurance"))
    assert wf["actions"][0]["assign_tags"] == [tags["tax-relevant"]]


def test_drift_is_corrected_with_owner_null_and_no_grants(fake):
    fake.add("tags", name="inbox", color="#e31a1c", is_inbox_tag=True, match="",
             matching_algorithm=0, is_insensitive=True, owner=7,
             permissions={"view": {"users": [7], "groups": []}, "change": {"users": [7], "groups": []}})
    fake.add("document_types", name="Receipt", match="receipt", matching_algorithm=1,
             is_insensitive=True)
    run(fake)
    patches = {(p.split("/")[2]): b for m, p, b in fake.writes() if m == "PATCH"}
    assert patches["tags"]["owner"] is None and patches["tags"]["set_permissions"] == apply.NO_GRANTS
    assert patches["document_types"]["match"].startswith("quittance")
    assert run(fake)[0] == 0


def test_unmanaged_objects_are_reported_and_never_deleted(fake):
    fake.add("tags", name="old-tag", match="", matching_algorithm=0, is_insensitive=True)
    _, log = run(fake)
    assert "unmanaged tags old-tag: not in paperless.json, left as is" in log
    assert all(m != "DELETE" for m, _, _ in fake.calls)


def test_a_changed_workflow_keeps_its_trigger_and_action_ids(fake):
    run(fake)
    wf = next(w for w in fake.store["workflows"].values() if w["name"] == "tax-relevant")
    ids = (wf["triggers"][0]["id"], wf["actions"][0]["id"])
    wf["order"] = 99
    run(fake)
    body = [b for m, p, b in fake.writes() if m == "PATCH" and "/workflows/" in p][-1]
    assert (body["triggers"][0]["id"], body["actions"][0]["id"]) == ids
    assert body["order"] == 20


# --- the nightly passes ---------------------------------------------------

def ids_of(fake, kind):
    return {o["name"]: o["id"] for o in fake.store[kind].values()}


def doc(fake, **kw):
    kw.setdefault("tags", [])
    kw.setdefault("custom_fields", [])
    return fake.add("documents", **kw)


def retain(fake, d):
    field = ids_of(fake, "custom_fields")["Retain until"]
    return [f["value"] for f in fake.store["documents"][d["id"]]["custom_fields"] if f["field"] == field]


def test_retain_until_follows_type_and_creation_date(fake):
    run(fake)
    types, field = ids_of(fake, "document_types"), ids_of(fake, "custom_fields")["Retain until"]
    receipt = doc(fake, document_type=types["Receipt"], created="2026-03-01")
    retyped = doc(fake, document_type=types["Contract"], created="2026-03-01",
                  custom_fields=[{"field": field, "value": "2028-03-01"}])
    moved = doc(fake, document_type=types["Invoice"], created="2025-06-30",
                custom_fields=[{"field": field, "value": "2031-01-15"}])
    untyped = doc(fake, document_type=None, created="2026-01-01",
                  custom_fields=[{"field": field, "value": "2027-01-01"}])
    leap = doc(fake, document_type=types["Receipt"], created="2024-02-29")
    plain = doc(fake, document_type=None, created="2026-01-01")
    run(fake, nightly=True)
    assert retain(fake, receipt) == ["2028-03-01"]
    assert retain(fake, retyped) == []  # Receipt re-typed to Contract loses its date
    assert retain(fake, moved) == ["2030-06-30"]  # a moved creation date moves it
    assert retain(fake, untyped) == []  # no type, no date
    assert retain(fake, leap) == ["2026-02-28"]
    assert retain(fake, plain) == []
    assert run(fake, nightly=True)[0] == 0


def test_permission_passes_are_skipped_without_the_readers_group(fake):
    run(fake, config=without_groups(), members={})
    fake.add("correspondents", name="x")
    _, log = run(fake, nightly=True, config=without_groups(), members={})
    assert "group readers missing: correspondent and document passes skipped" in log
    assert not [c for c in fake.writes() if "/correspondents/" in c[1]]


def test_correspondent_pass_grants_readers_view_and_keeps_other_grants(fake):
    run(fake)
    readers = ids_of(fake, "groups")["readers"]
    editor_owned = fake.add("correspondents", name="Bank", owner=5,
                            permissions={"view": {"users": [9], "groups": [3]},
                                         "change": {"users": [9], "groups": []}})
    shared = fake.add("correspondents", name="Insurer", owner=5,
                      permissions={"view": {"users": [], "groups": [readers]},
                                   "change": {"users": [], "groups": []}})
    _, log = run(fake, nightly=True)
    writes = [c for c in fake.writes() if "/correspondents/" in c[1]]
    assert [p for _, p, _ in writes] == [f"/api/correspondents/{editor_owned['id']}/"]
    body = writes[0][2]
    assert body == {"set_permissions": {"view": {"users": [9], "groups": sorted([3, readers])}}}
    assert fake.store["correspondents"][editor_owned["id"]]["owner"] == 5
    assert fake.store["correspondents"][editor_owned["id"]]["permissions"]["change"]["users"] == [9]
    assert not any("Bank" in line or "Insurer" in line for line in log)
    assert shared["permissions"]["view"]["groups"] == [readers]


def test_document_pass_gives_readers_view_iff_not_private(fake):
    run(fake)
    readers = ids_of(fake, "groups")["readers"]
    private = ids_of(fake, "tags")["private"]
    public = doc(fake, document_type=None, created="2026-01-01", owner=5)
    hidden = doc(fake, document_type=None, created="2026-01-01", owner=5, tags=[private],
                 permissions={"view": {"users": [], "groups": [readers]},
                              "change": {"users": [], "groups": []}})
    unhidden = doc(fake, document_type=None, created="2026-01-01", owner=5, tags=[])
    ok = doc(fake, document_type=None, created="2026-01-01", owner=5, tags=[private])
    run(fake, nightly=True)
    writes = {p: b for m, p, b in fake.writes() if m == "PATCH" and "/documents/" in p}
    assert set(writes) == {f"/api/documents/{d['id']}/" for d in (public, hidden, unhidden)}
    for body in writes.values():
        assert set(body) == {"set_permissions"} and set(body["set_permissions"]) == {"view"}
    assert fake.store["documents"][public["id"]]["permissions"]["view"]["groups"] == [readers]
    assert fake.store["documents"][hidden["id"]]["permissions"]["view"]["groups"] == []
    assert fake.store["documents"][ok["id"]]["permissions"]["view"]["groups"] == []
    assert all(d["owner"] == 5 for d in fake.store["documents"].values())
    assert run(fake, nightly=True)[0] == 0


# --- access: groups, members, workflows -------------------------------------

def user(fake, username, email="", groups=(), superuser=False, perms=()):
    return fake.add("users", username=username, email=email, groups=list(groups),
                    is_superuser=superuser, user_permissions=list(perms))


def test_groups_get_their_permissions_and_drift_is_corrected(fake):
    run(fake)
    groups = {g["name"]: g for g in fake.store["groups"].values()}
    want = {g["name"]: sorted(g["permissions"]) for g in CONFIG["groups"]}
    assert {n: g["permissions"] for n, g in groups.items()} == want
    groups["readers"]["permissions"] = groups["readers"]["permissions"] + ["add_document"]
    assert run(fake)[0] == 1
    assert sorted(fake.store["groups"][groups["readers"]["id"]]["permissions"]) == want["readers"]
    assert run(fake)[0] == 0


def test_readers_only_view_and_neither_group_administers():
    perms = {g["name"]: set(g["permissions"]) for g in CONFIG["groups"]}
    assert all(p.startswith("view_") or p.endswith("_uisettings") for p in perms["readers"])
    assert {"view_document", "view_uisettings", "view_savedview"} <= perms["readers"]
    assert {"add_document", "change_document", "view_uisettings", "view_savedview"} <= perms["editors"]
    admin = re.compile(r"_(user|group|permission|workflow\w*|applicationconfiguration|mailaccount"
                       r"|mailrule|storagepath|logentry|token\w*|socialapp)$")
    for name in ("editors", "readers"):
        assert not [p for p in perms[name] if admin.search(p)]
        # Git owns the taxonomy: no change rights on types, tags, fields or views.
        assert not [p for p in perms[name] if re.match(r"(add|change|delete)_(documenttype|tag|"
                                                       r"customfield|savedview)$", p)]


def test_listed_accounts_join_their_group_and_others_leave(fake):
    run(fake, members={})
    g = ids_of(fake, "groups")
    editor = user(fake, "editor", "editor@example.invalid")
    reader = user(fake, "reader", "reader@example.invalid")
    stale = user(fake, "someone", "someone@example.invalid", groups=[g["readers"], 77])
    admin = user(fake, "nedsi-admin", "editor@example.invalid", superuser=True)
    _, log = run(fake)
    users = fake.store["users"]
    assert users[editor["id"]]["groups"] == [g["editors"]]
    assert users[reader["id"]]["groups"] == [g["readers"]]  # matched by email, any case
    assert users[stale["id"]]["groups"] == [77]  # unmanaged groups are kept
    assert users[admin["id"]]["groups"] == []  # exempt accounts are never matched
    patches = [b for m, p, b in fake.writes() if "/users/" in p]
    assert all(set(b) == {"groups"} for b in patches)  # never the superuser flag or permissions
    text = "\n".join(log)
    assert not any(s in text for s in ("@example", "someone", "nedsi-admin "))
    assert "group readers: 1 listed account(s) found" in log
    assert run(fake)[0] == 0


def test_a_listed_account_without_a_login_yet_is_counted(fake):
    user(fake, "editor")
    _, log = run(fake)
    assert "group readers: 0 listed account(s) found, 1 not found (no Paperless login yet)" in log


def test_an_entry_matching_two_accounts_fails(fake):
    user(fake, "editor")
    user(fake, "reader-1", "reader@example.invalid")
    user(fake, "reader-2", "READER@example.invalid")
    with pytest.raises(apply.ConfigError, match="matches 2 accounts"):
        run(fake)
    assert not [p for _, p, _ in fake.writes() if "/users/" in p]


def test_superusers_and_direct_permissions_are_counted_except_the_exempt_accounts(fake):
    user(fake, "editor", superuser=True)
    user(fake, "other", perms=[12])
    for name in apply.EXEMPT_ACCOUNTS:
        user(fake, name, superuser=True)
    _, log = run(fake)
    assert any(line.endswith("2 account(s) other than nedsi-admin, automation, canary with the "
                             "superuser flag or direct permissions") for line in log)


@pytest.mark.parametrize("members,error", [
    ({"admins": ["x"]}, "1 key\\(s\\) not a group of paperless.json \\(editors, readers\\)"),
    ({"editors": ["x"], "readers": ["X"]}, "in both editors and readers"),
    ({"editors": ["automation"]}, "exempt account"),
    ({"readers": "x"}, "must be a list"),
    ({"readers": [""]}, "must be a list"),
])
def test_a_bad_member_list_fails_before_any_request(fake, members, error):
    with pytest.raises(apply.ConfigError, match=error):
        run(fake, members=members)
    assert fake.calls == []


def test_share_and_private_workflows_use_the_readers_group(fake):
    run(fake)
    g, tags = ids_of(fake, "groups"), ids_of(fake, "tags")
    wfs = {w["name"]: w for w in fake.store["workflows"].values()}
    share, private = wfs["share"], wfs["private"]
    assert share["triggers"] == [{"type": 1, "sources": [2, 4], "filter_filename": "*",
                                  "id": share["triggers"][0]["id"]}]
    assert share["actions"][0]["assign_view_groups"] == [g["readers"]]
    assert "assign_owner" not in share["actions"][0]  # the uploader stays the owner
    assert private["order"] == max(w["order"] for w in wfs.values())
    assert sorted(t["type"] for t in private["triggers"]) == [2, 3]
    assert all(t["filter_has_tags"] == [tags["private"]] for t in private["triggers"])
    assert private["actions"][0]["type"] == 2
    assert private["actions"][0]["remove_view_groups"] == [g["readers"]]
    assert private["actions"][0]["remove_change_groups"] == [g["readers"]]


def test_lint_rejects_a_workflow_with_an_unknown_group():
    config = copy.deepcopy(CONFIG)
    config["workflows"][0]["actions"][0]["assign_view_groups"] = ["nobody"]
    assert any("unknown group nobody" in e for e in apply.lint(config))


# --- waiting and retrying -------------------------------------------------

def test_waits_for_the_api_before_the_first_change(fake):
    fake.failures = ["conn", "conn", 503, 502]
    sleeps: list[float] = []
    apply.run(client(fake, sleeps), copy.deepcopy(CONFIG), False, lambda _: None)
    assert sleeps[:4] == [2.0, 4.0, 8.0, 16.0]
    assert [c[1] for c in fake.calls[:5]] == ["/api/tags/"] * 5
    assert all(c[0] == "GET" for c in fake.calls[:5])
    assert fake.calls[5][0] == "GET"  # the first object list, after the wait


def test_gives_up_waiting_after_ten_minutes(fake):
    fake.failures = [503] * 1000
    with pytest.raises(apply.ApiError, match="not ready"):
        apply.run(client(fake), copy.deepcopy(CONFIG), False, lambda _: None)
    assert fake.writes() == []


def test_a_rejected_token_fails_at_once(fake):
    fake.failures = [401]
    with pytest.raises(apply.ApiError, match="401"):
        apply.run(client(fake), copy.deepcopy(CONFIG), False, lambda _: None)
    assert len(fake.calls) == 1


def test_5xx_and_connection_errors_are_retried_three_times(fake):
    c = client(fake)
    fake.failures = [502, "conn", 500]
    assert c.request("GET", "/api/tags/")["results"] == []
    fake.failures = [502, 502, 502, 502]
    with pytest.raises(apply.ApiError, match="after 3 retries"):
        c.request("GET", "/api/tags/")
    assert len([x for x in fake.calls if x[1] == "/api/tags/"]) == 8


def test_a_4xx_is_not_retried(fake):
    c = client(fake)
    fake.failures = [400]
    with pytest.raises(apply.ApiError, match="400"):
        c.request("POST", "/api/tags/", {"name": "x"})
    assert len(fake.calls) == 1


def test_the_token_file_is_waited_for(tmp_path):
    path, clock = tmp_path / "token", [0.0]

    def sleep(seconds):
        clock[0] += seconds
        if clock[0] >= 30:
            path.write_text("t0k\n")
    assert apply.read_secret(str(path), sleep=sleep, clock=lambda: clock[0]) == "t0k"
    with pytest.raises(apply.ConfigError):
        apply.read_secret(str(tmp_path / "never"), timeout=60, sleep=sleep, clock=lambda: clock[0])


def test_the_api_version_is_pinned():
    seen = {}

    def transport(method, url, headers, data):
        seen.update(headers)
        return 200, b"{}"
    apply.Client("http://p:8000", "t", transport=transport).request("GET", "/api/")
    assert re.fullmatch(r"application/json; version=\d+", seen["Accept"])
