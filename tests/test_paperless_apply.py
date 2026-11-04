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
                                      "workflows", "correspondents", "documents", "groups")}
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


def run(fake, nightly=False, config=CONFIG):
    log: list[str] = []
    changes = apply.run(client(fake), copy.deepcopy(config), nightly, log.append)
    return changes, log


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
    total = sum(len(CONFIG[k]) for k in ("document_types", "tags", "custom_fields",
                                          "saved_views", "workflows"))
    assert changes == total
    for method, path, body in fake.writes():
        kind = path.split("/")[2]
        if kind in ("document_types", "tags", "saved_views"):
            assert body["owner"] is None
            assert body["set_permissions"] == apply.NO_GRANTS
        else:  # custom fields and workflows have no owner in Paperless
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
    wf = next(iter(fake.store["workflows"].values()))
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
    wf = next(iter(fake.store["workflows"].values()))
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
    run(fake)
    fake.add("correspondents", name="x")
    _, log = run(fake, nightly=True)
    assert "group readers missing: correspondent and document passes skipped" in log
    assert not [c for c in fake.writes() if "/correspondents/" in c[1]]


def test_correspondent_pass_grants_readers_view_and_keeps_other_grants(fake):
    run(fake)
    readers = fake.add("groups", name="readers")["id"]
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
    readers = fake.add("groups", name="readers")["id"]
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
    assert apply.read_token(str(path), sleep=sleep, clock=lambda: clock[0]) == "t0k"
    with pytest.raises(apply.ConfigError):
        apply.read_token(str(tmp_path / "never"), timeout=60, sleep=sleep, clock=lambda: clock[0])


def test_the_api_version_is_pinned():
    seen = {}

    def transport(method, url, headers, data):
        seen.update(headers)
        return 200, b"{}"
    apply.Client("http://p:8000", "t", transport=transport).request("GET", "/api/")
    assert re.fullmatch(r"application/json; version=\d+", seen["Accept"])
