#!/usr/bin/env python3
"""Paperless ingest canary: is a new upload findable within minutes?

Draws a one-page image with a random 12-digit number, converts it to PDF (so
OCR has to read it), uploads it through the API, polls a full-text search for
the number, records the seconds from upload to found, deletes the document,
empties it from the trash, and pushes the result to the Pushgateway
(job `paperless-canary`):

  paperless_canary_success                         1 found, 0 failed (last run)
  paperless_canary_duration_seconds                upload to found, or to the failure
  paperless_canary_last_run_timestamp_seconds      end of the last run
  paperless_canary_last_success_timestamp_seconds  end of the last success; not
                                                   pushed on a failure (POST keeps it)

Exit 0 when found and cleaned up, 1 otherwise (after the push).

Environment: PAPERLESS_API_URL (default http://paperless:8000), the `canary`
user's token in PAPERLESS_API_TOKEN or the file named by
PAPERLESS_API_TOKEN_FILE (default /secret/PAPERLESS_API_TOKEN), PUSHGATEWAY
(default http://pushgateway.backup-verify.svc:9091), CANARY_TIMEOUT seconds
(default 900). Needs Pillow and img2pdf (both in the paperless image).
Spec: .kiro/specs/paperless-documents (design.md "Findable within N minutes").
"""
from __future__ import annotations

import io
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, Optional

API_VERSION = "10"
POLL_SECONDS = 5
JOB = "paperless-canary"

Transport = Callable[[str, str, dict, Optional[bytes]], "tuple[int, bytes]"]


class CanaryError(Exception):
    pass


def make_pdf(number: str) -> bytes:
    """A4 at 150 dpi, the number in a 140 px font: digits only, no look-alikes."""
    import img2pdf
    from PIL import Image, ImageDraw, ImageFont

    image = Image.new("L", (1240, 1754), 255)
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default(size=140)
    left, top, right, bottom = draw.textbbox((0, 0), number, font=font)
    draw.text(((1240 - (right - left)) / 2, 600), number, fill=0, font=font)
    png = io.BytesIO()
    image.save(png, format="PNG", dpi=(150, 150))
    return img2pdf.convert(png.getvalue())


def urllib_transport(method: str, url: str, headers: dict, data: bytes | None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


class Api:
    def __init__(self, base: str, token: str, transport: Transport = urllib_transport):
        self.base = base.rstrip("/")
        self.token = token
        self.transport = transport

    def call(self, method: str, path: str, body: dict | None = None,
             data: bytes | None = None, content_type: str | None = None) -> object:
        headers = {"Authorization": f"Token {self.token}",
                   "Accept": f"application/json; version={API_VERSION}"}
        if body is not None:
            data, content_type = json.dumps(body).encode(), "application/json"
        if content_type:
            headers["Content-Type"] = content_type
        try:
            status, raw = self.transport(method, self.base + path, headers, data)
        except (urllib.error.URLError, OSError) as exc:
            raise CanaryError(f"{method} {path.split('?')[0]}: {exc}") from exc
        if status >= 300:
            raise CanaryError(f"{method} {path.split('?')[0]}: HTTP {status}")
        return json.loads(raw) if raw.strip() else None

    def upload(self, filename: str, title: str, pdf: bytes) -> None:
        boundary = "canary" + secrets.token_hex(12)
        parts = [
            f'--{boundary}\r\nContent-Disposition: form-data; name="title"\r\n\r\n{title}\r\n'.encode(),
            (f'--{boundary}\r\nContent-Disposition: form-data; name="document"; filename="{filename}"\r\n'
             "Content-Type: application/pdf\r\n\r\n").encode() + pdf + b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
        self.call("POST", "/api/documents/post_document/", data=b"".join(parts),
                  content_type=f"multipart/form-data; boundary={boundary}")

    def ids(self, query: dict) -> list[int]:
        found = self.call("GET", "/api/documents/?" + urllib.parse.urlencode({**query, "fields": "id"}))
        return [doc["id"] for doc in found["results"]]

    def remove(self, doc_id: int) -> None:
        self.call("DELETE", f"/api/documents/{doc_id}/")
        self.call("POST", "/api/trash/", {"action": "empty", "documents": [doc_id]})


def run(api: Api, number: str, pdf: bytes, timeout: float,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep) -> tuple[bool, float, str]:
    """(found, seconds, reason). Removes the document whether or not it was found."""
    title = f"canary {number}"
    start = clock()
    found: list[int] = []
    reason = ""
    try:
        api.upload(f"canary-{number}.pdf", title, pdf)
        while True:
            found = api.ids({"query": number})
            if found:
                break
            if clock() - start > timeout:
                reason = f"not findable after {int(timeout)} s"
                break
            sleep(POLL_SECONDS)
    except CanaryError as exc:
        reason = str(exc)
    seconds = clock() - start
    try:
        # Not indexed is not absent: the title finds a document the search missed.
        for doc_id in found or api.ids({"title__iexact": title}):
            api.remove(doc_id)
    except CanaryError as exc:
        reason = reason or f"cleanup: {exc}"
    return not reason, seconds, reason


def push_body(ok: bool, seconds: float, now: float) -> str:
    lines = [f"paperless_canary_success {int(ok)}",
             f"paperless_canary_duration_seconds {seconds:.1f}",
             f"paperless_canary_last_run_timestamp_seconds {int(now)}"]
    if ok:
        lines.append(f"paperless_canary_last_success_timestamp_seconds {int(now)}")
    return "\n".join(lines) + "\n"


def push(pushgateway: str, body: str, transport: Transport = urllib_transport) -> None:
    # POST replaces only the metrics in the body: a failure keeps the last success.
    status, _ = transport("POST", f"{pushgateway.rstrip('/')}/metrics/job/{JOB}",
                          {"Content-Type": "text/plain"}, body.encode())
    if status >= 300:
        raise CanaryError(f"push: HTTP {status}")


def read_token() -> str:
    token = os.environ.get("PAPERLESS_API_TOKEN", "")
    if not token:
        with open(os.environ.get("PAPERLESS_API_TOKEN_FILE", "/secret/PAPERLESS_API_TOKEN")) as f:
            token = f.read()
    return token.strip()


def main() -> int:
    api = Api(os.environ.get("PAPERLESS_API_URL", "http://paperless:8000"), read_token())
    number = str(secrets.randbelow(9 * 10**11) + 10**11)
    ok, seconds, reason = run(api, number, make_pdf(number),
                              float(os.environ.get("CANARY_TIMEOUT", "900")))
    print(f"PASS findable after {seconds:.0f} s" if ok else f"FAIL {reason} ({seconds:.0f} s)")
    try:
        push(os.environ.get("PUSHGATEWAY", "http://pushgateway.backup-verify.svc:9091"),
             push_body(ok, seconds, time.time()))
    except (CanaryError, urllib.error.URLError, OSError) as exc:
        print(f"FAIL {exc}")
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
