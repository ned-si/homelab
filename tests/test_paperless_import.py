"""scripts/paperless-import.py against a fake Paperless API (no network)."""
from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
import urllib.parse
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("paperless_import", ROOT / "scripts" / "paperless-import.py")
imp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp)

TAG_ID = 42


class FakePaperless:
    """Tags, a checksum lookup and consumption tasks; `outcomes` maps file content to a result."""

    def __init__(self, tags=("import:mac",), existing=(), outcomes=None, upload_status=200):
        self.tags = list(tags)
        self.existing = {hashlib.sha256(c).hexdigest(): 900 + i for i, c in enumerate(existing)}
        self.outcomes = outcomes or {}
        self.upload_status = upload_status
        self.tasks: dict[str, dict] = {}
        self.uploads: list[tuple[bytes, bytes]] = []
        self.polls = 0

    def __call__(self, method, url, headers, data):
        assert headers["Authorization"] == "Token t0k"
        parts = urllib.parse.urlsplit(url)
        q = dict(urllib.parse.parse_qsl(parts.query))
        if parts.path == "/api/tags/":
            hits = [{"id": TAG_ID, "name": t} for t in self.tags if t == q["name__iexact"]]
            return 200, json.dumps({"results": hits}).encode()
        if parts.path == "/api/documents/":
            doc = self.existing.get(q["checksum__iexact"])
            return 200, json.dumps({"results": [{"id": doc}] if doc else []}).encode()
        if parts.path == "/api/documents/post_document/":
            if self.upload_status != 200:
                return self.upload_status, b"{}"
            tags = data.split(b'name="tags"\r\n\r\n')[1].split(b"\r\n")[0]
            content = data.split(b"application/octet-stream\r\n\r\n")[1].rsplit(b"\r\n--", 1)[0]
            self.uploads.append((tags, content))
            task_id = f"task-{len(self.uploads)}"
            self.tasks[task_id] = self.outcomes.get(content, {"document_id": 100 + len(self.uploads)})
            return 200, json.dumps(task_id).encode()
        if parts.path == "/api/tasks/":
            self.polls += 1
            if self.polls % 2:  # every task is still pending on its first poll
                return 200, json.dumps({"results": [{"status": "started"}]}).encode()
            result = self.tasks[q["task_id"]]
            status = "failure" if "error_message" in result or "duplicate_of" in result else "success"
            return 200, json.dumps({"results": [{"status": status, "result_data": result}]}).encode()
        raise AssertionError(f"unexpected {method} {url}")


def source(tmp_path, files, name="mac"):
    directory = tmp_path / name
    for rel, content in files.items():
        p = directory / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)
    return directory


def run(fake, directory, tmp_path, limit=None):
    lines: list[str] = []
    api = imp.Api("https://archive.example", "t0k", transport=fake, sleep=lambda s: None)
    report = tmp_path / "report.csv"
    code = imp.import_source(api, directory, report, limit, clock=lambda: 0.0,
                             sleep=lambda s: None, out=lines.append)
    rows = list(csv.DictReader(report.open())) if report.exists() else []
    return code, lines, rows


def test_uploads_with_the_tag_and_follows_each_task(tmp_path):
    directory = source(tmp_path, {"Bank Letter 2019.pdf": b"a", "sub/scan.jpg": b"b", ".DS_Store": b"x"})
    fake = FakePaperless()
    code, lines, rows = run(fake, directory, tmp_path)
    assert code == 0
    assert fake.uploads == [(str(TAG_ID).encode(), b"a"), (str(TAG_ID).encode(), b"b")]
    assert [(r["path"], r["status"], r["document_id"]) for r in rows] == [
        ("Bank Letter 2019.pdf", "created", "101"), ("sub/scan.jpg", "created", "102")]
    assert lines == ["import:mac: in 2, created 2, duplicates 0, failed 0"]


def test_stops_before_any_upload_without_the_tag(tmp_path):
    fake = FakePaperless(tags=["import:drive"])
    code, lines, rows = run(fake, source(tmp_path, {"a.pdf": b"a"}), tmp_path)
    assert code == 2
    assert fake.uploads == [] and rows == []
    assert lines == ["stop: tag import:mac does not exist; add it to paperless.json and merge first"]


def test_refuses_a_non_generic_source_name(tmp_path):
    code, lines, _ = run(FakePaperless(), source(tmp_path, {"a.pdf": b"a"}, name="Jane Docs"), tmp_path)
    assert code == 2 and lines[0].startswith("stop: the source directory name must be generic")


def test_duplicates_failures_and_counts_only_on_stdout(tmp_path):
    directory = source(tmp_path, {
        "already.pdf": b"old", "copy-1.pdf": b"same", "copy-2.pdf": b"same",
        "broken.pdf": b"bad", "server-dup.pdf": b"dup"})
    fake = FakePaperless(existing=[b"old"], outcomes={
        b"bad": {"error_message": "broken.pdf: unsupported file"},
        b"dup": {"duplicate_of": 7}})
    code, lines, rows = run(fake, directory, tmp_path)
    assert code == 1
    by_path = {r["path"]: (r["status"], r["document_id"], r["reason_class"]) for r in rows}
    assert by_path == {
        "already.pdf": ("duplicate", "900", ""),
        "broken.pdf": ("failed", "", "task failure"),
        "copy-1.pdf": ("created", by_path["copy-1.pdf"][1], ""),
        "copy-2.pdf": ("duplicate", "", ""),
        "server-dup.pdf": ("duplicate", "7", ""),
    }
    assert [u[1] for u in fake.uploads] == [b"bad", b"same", b"dup"]
    assert lines == ["import:mac: in 5, created 1, duplicates 3, failed 1", "  failed, task failure: 1"]
    assert not any(name in "\n".join(lines) for name in ("already", "broken", "copy", "server"))


def test_refused_upload_is_a_failure(tmp_path):
    code, lines, rows = run(FakePaperless(upload_status=403), source(tmp_path, {"a.pdf": b"a"}), tmp_path)
    assert code == 1
    assert rows[0]["reason_class"] == "upload HTTP 403"
    assert lines[1] == "  failed, upload HTTP 403: 1"


def test_limit_counts_uploads_only(tmp_path):
    directory = source(tmp_path, {"1.pdf": b"old", "2.pdf": b"b", "3.pdf": b"c"})
    fake = FakePaperless(existing=[b"old"])
    code, lines, rows = run(fake, directory, tmp_path, limit=1)
    assert code == 0
    assert [r["status"] for r in rows] == ["duplicate", "created"]
    assert len(fake.uploads) == 1


def test_upload_is_not_retried_after_5xx(tmp_path):
    fake = FakePaperless(upload_status=502)
    calls = []

    def transport(method, url, headers, data):
        calls.append((method, urllib.parse.urlsplit(url).path))
        return fake(method, url, headers, data)

    code, lines, rows = run(transport, source(tmp_path, {"a.pdf": b"a"}), tmp_path)
    assert code == 1
    assert calls.count(("POST", "/api/documents/post_document/")) == 1
    assert rows[0]["reason_class"] == "upload HTTP 502"


def test_same_content_after_a_failed_upload_is_uploaded(tmp_path):
    directory = source(tmp_path, {"1.pdf": b"same", "2.pdf": b"same"})
    fake = FakePaperless(upload_status=502)
    statuses = iter([502, 200])
    real = fake.__call__

    def transport(method, url, headers, data):
        if urllib.parse.urlsplit(url).path == "/api/documents/post_document/":
            fake.upload_status = next(statuses)
        return real(method, url, headers, data)

    code, lines, rows = run(transport, directory, tmp_path)
    assert code == 1
    assert [(r["path"], r["status"]) for r in rows] == [("1.pdf", "failed"), ("2.pdf", "created")]
    assert lines[0] == "import:mac: in 2, created 1, duplicates 0, failed 1"


def test_retries_5xx_then_fails(tmp_path):
    calls = []

    def transport(method, url, headers, data):
        calls.append(url)
        return 503, b""

    api = imp.Api("https://archive.example", "t0k", transport=transport, sleep=lambda s: None)
    with pytest.raises(imp.ApiError, match="HTTP 503"):
        api.get("/api/tags/", name__iexact="import:mac")
    assert len(calls) == imp.RETRIES + 1
