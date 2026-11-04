"""apps/paperless/canary/canary.py against a fake Paperless API (no network)."""
from __future__ import annotations

import importlib.util
import json
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("paperless_canary", ROOT / "apps" / "paperless" / "canary" / "canary.py")
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)

NUMBER = "123456789012"


class FakePaperless:
    """Consumes the upload after `index_after` searches; records every call."""

    def __init__(self, upload_status=200, index_after=2, consumed=True):
        self.upload_status = upload_status
        self.index_after = index_after
        self.consumed = consumed
        self.searches = 0
        self.calls: list[tuple[str, str, dict]] = []

    def __call__(self, method, url, headers, data):
        assert headers["Authorization"] == "Token t0k"
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        self.calls.append((method, parts.path, query))
        if parts.path == "/api/documents/post_document/":
            assert b'name="title"\r\n\r\ncanary 123456789012' in data
            assert b'filename="canary-123456789012.pdf"' in data
            return self.upload_status, b'"task-id"'
        if parts.path == "/api/documents/" and "query" in query:
            self.searches += 1
            hit = self.consumed and self.searches > self.index_after
            return 200, json.dumps({"results": [{"id": 7}] if hit else []}).encode()
        if parts.path == "/api/documents/" and "title__iexact" in query:
            return 200, json.dumps({"results": [{"id": 7}] if self.consumed else []}).encode()
        if method == "DELETE" and parts.path == "/api/documents/7/":
            return 204, b""
        if parts.path == "/api/trash/":
            assert json.loads(data) == {"action": "empty", "documents": [7]}
            return 200, b'{"result": "OK"}'
        raise AssertionError(f"unexpected {method} {url}")


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def run(fake, timeout=900):
    clock = Clock()
    api = canary.Api("http://paperless:8000", "t0k", transport=fake)
    return canary.run(api, NUMBER, b"%PDF-fake", timeout, clock=clock, sleep=clock.sleep)


def removed(fake):
    return [(m, p) for m, p, _ in fake.calls if m == "DELETE" or p == "/api/trash/"]


def test_found_measured_and_removed():
    fake = FakePaperless(index_after=2)
    ok, seconds, reason = run(fake)
    assert (ok, reason) == (True, "")
    assert seconds == 2 * canary.POLL_SECONDS
    assert removed(fake) == [("DELETE", "/api/documents/7/"), ("POST", "/api/trash/")]


def test_not_findable_fails_and_removes_by_title():
    fake = FakePaperless(index_after=10**6)
    ok, seconds, reason = run(fake, timeout=60)
    assert not ok
    assert reason == "not findable after 60 s"
    assert seconds > 60
    assert removed(fake) == [("DELETE", "/api/documents/7/"), ("POST", "/api/trash/")]


def test_refused_upload_fails_without_removal():
    fake = FakePaperless(upload_status=403, consumed=False)
    ok, _, reason = run(fake)
    assert not ok
    assert reason == "POST /api/documents/post_document/: HTTP 403"
    assert removed(fake) == []


def test_push_keeps_last_success_on_failure():
    assert canary.push_body(True, 42.0, 1000) == (
        "paperless_canary_success 1\n"
        "paperless_canary_duration_seconds 42.0\n"
        "paperless_canary_last_run_timestamp_seconds 1000\n"
        "paperless_canary_last_success_timestamp_seconds 1000\n")
    assert "last_success" not in canary.push_body(False, 900.0, 1000)
    sent = []
    canary.push("http://pg:9091/", "x 1\n", transport=lambda *a: sent.append(a) or (200, b""))
    assert sent[0][:2] == ("POST", "http://pg:9091/metrics/job/paperless-canary")
