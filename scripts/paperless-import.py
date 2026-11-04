#!/usr/bin/env python3
"""Import one source directory into Paperless through its API, as the editor.

    PAPERLESS_API_TOKEN=<editor's token> scripts/paperless-import.py \
        ~/homelab-backups/paperless-import/<source> [--limit N]

The directory name is the source: it must be generic (`mac`, `drive`) and its
tag `import:<source>` must already exist (paperless.json, created by
paperless-apply); the script stops before the first upload otherwise. Folder
names do not become tags. Each file, one at a time:

  - skipped as a duplicate when a document with its SHA-256 already exists
    (Paperless 3.4 consumes duplicates unless PAPERLESS_CONSUMER_DELETE_DUPLICATES
    is set, so the check is here), or when the same content came earlier in the run;
  - otherwise uploaded with the tag through /api/documents/post_document/ and
    its consumption task followed to the result: created, duplicate, failed.
    A failed upload is not retried; the next run's checksum lookup decides.

The local report (CSV: path, status, document id, reason class, reason) goes
to <import dir>/.reports/<source>-<UTC>.csv, or --report. Stdout has counts
only, never a file name: in = created + duplicates + failed, and the failures
by reason class. Exit 0 without failures, 1 with failures, 2 when it stops
before uploading.

Environment: PAPERLESS_API_TOKEN, PAPERLESS_URL (default
https://archive.lilalala.com). Stdlib only.
Spec: .kiro/specs/paperless-documents (design.md "Import").
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime
import hashlib
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Optional

API_VERSION = "10"
SOURCE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
RETRIES = 3
POLL_SECONDS = 3
TASK_TIMEOUT = 1800

Transport = Callable[[str, str, dict, Optional[bytes]], "tuple[int, bytes]"]


class ApiError(Exception):
    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


def urllib_transport(method: str, url: str, headers: dict, data: bytes | None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


class Api:
    def __init__(self, base: str, token: str, transport: Transport = urllib_transport,
                 sleep: Callable[[float], None] = time.sleep):
        self.base = base.rstrip("/")
        self.token = token
        self.transport = transport
        self.sleep = sleep

    def call(self, method: str, path: str, data: bytes | None = None,
             content_type: str | None = None, retries: int = RETRIES) -> object:
        headers = {"Authorization": f"Token {self.token}",
                   "Accept": f"application/json; version={API_VERSION}"}
        if content_type:
            headers["Content-Type"] = content_type
        where = f"{method} {path.split('?')[0]}"
        for attempt in range(retries + 1):
            try:
                status, raw = self.transport(method, self.base + path, headers, data)
            except (urllib.error.URLError, OSError) as exc:
                status, raw = 0, str(exc).encode()
            if status and status < 500:
                break
            if attempt < retries:
                self.sleep(2 ** attempt * 5)
        if not status:
            raise ApiError(f"{where}: connection error")
        if status >= 300:
            raise ApiError(f"{where}: HTTP {status}", status)
        return json.loads(raw) if raw.strip() else None

    def get(self, path: str, **query) -> dict:
        return self.call("GET", f"{path}?{urllib.parse.urlencode(query)}")

    def upload(self, path: Path, tag_id: int) -> str:
        boundary = "import" + secrets.token_hex(12)
        name = path.name.replace('"', "_")
        body = b"".join([
            f'--{boundary}\r\nContent-Disposition: form-data; name="tags"\r\n\r\n{tag_id}\r\n'.encode(),
            (f'--{boundary}\r\nContent-Disposition: form-data; name="document"; filename="{name}"\r\n'
             "Content-Type: application/octet-stream\r\n\r\n").encode(),
            path.read_bytes(),
            f"\r\n--{boundary}--\r\n".encode(),
        ])
        # No retry: a 5xx or a timeout can come after Paperless queued the
        # file, and a second POST would add a second document. The next run's
        # checksum lookup decides.
        return str(self.call("POST", "/api/documents/post_document/", body,
                             f"multipart/form-data; boundary={boundary}", retries=0))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files(directory: Path) -> list[Path]:
    """Regular files under the directory, hidden files and directories left out."""
    return sorted(p for p in directory.rglob("*")
                  if p.is_file() and not any(part.startswith(".")
                                             for part in p.relative_to(directory).parts))


def follow(api: Api, task_id: str, clock: Callable[[], float], sleep: Callable[[float], None],
           timeout: float = TASK_TIMEOUT) -> tuple[str, str, str, str]:
    """(status, document id, reason class, reason) of one consumption task."""
    start = clock()
    while True:
        found = api.get("/api/tasks/", task_id=task_id)["results"]
        task = found[0] if found else {}
        state = task.get("status")
        result = task.get("result_data") or {}
        if state == "success" and result.get("document_id"):
            return "created", str(result["document_id"]), "", ""
        if result.get("duplicate_of"):
            return "duplicate", str(result["duplicate_of"]), "", ""
        if state in ("success", "failure", "revoked"):
            reason = result.get("error_message") or result.get("reason") or state
            return "failed", "", f"task {state}", str(reason)
        if clock() - start > timeout:
            return "failed", "", "task timeout", f"no result after {int(timeout)} s"
        sleep(POLL_SECONDS)


def import_source(api: Api, directory: Path, report: Path, limit: int | None = None,
                  clock: Callable[[], float] = time.monotonic,
                  sleep: Callable[[float], None] = time.sleep,
                  out: Callable[[str], None] = print) -> int:
    source = directory.name
    if not SOURCE_NAME.match(source):
        out(f"stop: the source directory name must be generic (a-z, 0-9, -): {SOURCE_NAME.pattern}")
        return 2
    tags = api.get("/api/tags/", name__iexact=f"import:{source}")["results"]
    if len(tags) != 1:
        out(f"stop: tag import:{source} does not exist; add it to paperless.json and merge first")
        return 2
    tag_id = tags[0]["id"]

    rows, seen, uploads = [], {}, 0
    for path in source_files(directory):
        if limit is not None and uploads >= limit:
            break
        rel = str(path.relative_to(directory))
        try:
            digest = sha256(path)
            if digest in seen:
                row = ("duplicate", "", "", f"same content as {seen[digest]}")
            else:
                existing = api.get("/api/documents/", checksum__iexact=digest, fields="id")["results"]
                if existing:
                    row = ("duplicate", str(existing[0]["id"]), "", "already in Paperless")
                else:
                    uploads += 1
                    row = follow(api, api.upload(path, tag_id), clock, sleep)
                if row[0] != "failed":
                    seen[digest] = rel
        except ApiError as exc:
            kind = f"HTTP {exc.status}" if exc.status else "connection error"
            row = ("failed", "", f"upload {kind}", str(exc))
        except OSError as exc:
            row = ("failed", "", "unreadable file", exc.strerror or str(exc))
        rows.append((rel, *row))

    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["path", "status", "document_id", "reason_class", "reason"])
        writer.writerows(rows)

    counts = collections.Counter(r[1] for r in rows)
    out(f"import:{source}: in {len(rows)}, created {counts['created']}, "
        f"duplicates {counts['duplicate']}, failed {counts['failed']}")
    for reason, n in sorted(collections.Counter(r[3] for r in rows if r[1] == "failed").items()):
        out(f"  failed, {reason}: {n}")
    assert len(rows) == counts["created"] + counts["duplicate"] + counts["failed"]
    return 1 if counts["failed"] else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("directory", type=Path, help="one source subdirectory of the import directory")
    parser.add_argument("--limit", type=int, help="upload at most N files, then stop (a batch)")
    parser.add_argument("--report", type=Path, help="local CSV report (default: <import dir>/.reports/)")
    args = parser.parse_args(argv)
    token = os.environ.get("PAPERLESS_API_TOKEN", "").strip()
    if not token:
        print("stop: PAPERLESS_API_TOKEN is not set (the editor's API token)")
        return 2
    directory = args.directory.expanduser().resolve()
    if not directory.is_dir():
        print("stop: not a directory")
        return 2
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = args.report or directory.parent / ".reports" / f"{directory.name}-{stamp}.csv"
    api = Api(os.environ.get("PAPERLESS_URL", "https://archive.lilalala.com"), token)
    code = import_source(api, directory, report, args.limit)
    if code != 2:
        print(f"report: {report}")
    return code


if __name__ == "__main__":
    sys.exit(main())
