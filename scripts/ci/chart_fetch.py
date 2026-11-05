#!/usr/bin/env python3
"""Fetch a pinned Helm chart archive once, with retries, into a local cache.

Usage: chart_fetch.py <repoURL> <chart> <version>   prints the archive path

render_apps.py and vector-validate.sh template charts from the archive this
returns, so `helm template` itself never touches the network.

Cache: the directory $CHART_CACHE (required by the CLI). CI restores it with
actions/cache, keyed on the Application files and ci/helm-releases.yaml.
  <cache>/<id>/<chart>-<version>.tgz   id = sha256 of repo, chart and version
  <cache>/<id>/sha256                  the archive's sha256, written on fetch
A cached archive is used only when its sha256 matches that file and its
Chart.yaml names the pinned chart and version; anything else is deleted and
fetched again. Chart archives have no upstream checksum pin (HTTPS repos pin a
version, OCI charts a tag), so a fetch checks exactly what `helm template
--repo` checked before. A version that is not exact (a semver range) is
fetched fresh on every call, as Argo resolves it.

Fetch: `helm pull`, retried after CHART_FETCH_DELAYS seconds (default
5,15,45) when helm reports a transient error (HTTP 5xx or 429, timeout,
connection reset or refused, TLS handshake, EOF, DNS failure). Any other error
fails at once.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

EXACT = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$")
TRANSIENT = re.compile(
    r"(?<![\w.])(?:5\d\d|429)(?![\w.])|timeout|timed out|connection reset|connection refused"
    r"|tls handshake|\beof\b|temporary failure|no such host|server misbehaving"
    r"|too many requests|bad gateway|service unavailable",
    re.IGNORECASE,
)


PULLS = 0  # successful `helm pull` calls in this process


class FetchError(Exception):
    pass


def first_line(text: str) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:300]
    return "(no output)"


def delays() -> list[float]:
    raw = os.environ.get("CHART_FETCH_DELAYS", "5,15,45")
    return [float(d) for d in raw.split(",") if d.strip()]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def chart_meta(archive: Path) -> tuple[str, str]:
    """(name, version) from the archive's top-level Chart.yaml."""
    try:
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                parts = member.name.split("/")
                if len(parts) == 2 and parts[1] == "Chart.yaml" and member.isfile():
                    text = tar.extractfile(member).read().decode("utf-8", "replace")
                    break
            else:
                raise FetchError(f"{archive.name}: no Chart.yaml")
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise FetchError(f"{archive.name}: not a chart archive: {exc}") from exc
    fields = {}
    for key in ("name", "version"):
        m = re.search(rf"^{key}:\s*['\"]?([^'\"\s#]+)", text, re.MULTILINE)
        fields[key] = m.group(1) if m else ""
    return fields["name"], fields["version"]


def check_meta(archive: Path, chart: str, version: str, exact: bool) -> None:
    name, got = chart_meta(archive)
    if name != chart:
        raise FetchError(f"{archive.name}: Chart.yaml names {name!r}, expected {chart!r}")
    if exact and got.lstrip("v") != version.lstrip("v"):
        raise FetchError(f"{archive.name}: Chart.yaml version {got!r}, expected {version!r}")


def pull_args(repo: str, chart: str, version: str) -> list[str]:
    if repo.startswith("oci://") or "://" not in repo:
        return [f"oci://{repo.removeprefix('oci://').rstrip('/')}/{chart}", "--version", version]
    return [chart, "--repo", repo, "--version", version]


def pull(repo: str, chart: str, version: str, dest: Path, env: dict | None) -> Path:
    global PULLS
    cmd = ["helm", "pull", *pull_args(repo, chart, version), "--destination", str(dest)]
    waits = delays()
    for attempt in range(len(waits) + 1):
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        except FileNotFoundError as exc:
            raise FetchError("helm not found") from exc
        if p.returncode == 0:
            PULLS += 1
            break
        err = first_line(p.stderr)
        if attempt == len(waits) or not TRANSIENT.search(p.stderr or ""):
            raise FetchError(f"helm pull failed: {err}")
        print(f"chart_fetch: {chart} {version}: {err}; retry {attempt + 1}/{len(waits)} in {waits[attempt]:g}s",
              file=sys.stderr)
        time.sleep(waits[attempt])
    archives = sorted(dest.glob("*.tgz"))
    if len(archives) != 1:
        raise FetchError(f"helm pull {chart} {version}: expected one archive, found {len(archives)}")
    return archives[0]


def entry_id(repo: str, chart: str, version: str) -> str:
    return hashlib.sha256(f"{repo.rstrip('/')}\n{chart}\n{version}".encode()).hexdigest()[:16]


def cached(entry: Path, chart: str, version: str) -> Path | None:
    """The verified archive in a cache entry, or None (the entry is then removed)."""
    archives = sorted(entry.glob("*.tgz"))
    sums = entry / "sha256"
    try:
        if len(archives) == 1 and sums.is_file() and sums.read_text().strip() == sha256(archives[0]):
            check_meta(archives[0], chart, version, True)
            return archives[0]
    except (FetchError, OSError):
        pass
    shutil.rmtree(entry, ignore_errors=True)
    return None


def fetch(repo: str, chart: str, version: str, cache: Path, env: dict | None = None) -> Path:
    """Path of the archive of chart@version from repo, from the cache or fetched."""
    cache.mkdir(parents=True, exist_ok=True)
    exact = bool(EXACT.match(version))
    if exact:
        entry = cache / entry_id(repo, chart, version)
        if entry.is_dir():
            hit = cached(entry, chart, version)
            if hit is not None:
                return hit
    tmp = Path(tempfile.mkdtemp(prefix=".fetch-", dir=cache))
    try:
        archive = pull(repo, chart, version, tmp, env)
        check_meta(archive, chart, version, exact)
        if not exact:
            entry = Path(tempfile.mkdtemp(prefix=".range-", dir=cache))
            return Path(shutil.move(str(archive), entry / archive.name))
        (tmp / "sha256").write_text(sha256(archive) + "\n")
        tmp.rename(entry)
        return entry / archive.name
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def prune(cache: Path, keep: set[Path]) -> int:
    """Remove cache entries not in keep (entry directories), and every range or
    interrupted fetch; returns how many."""
    removed = 0
    for entry in sorted(cache.iterdir()) if cache.is_dir() else []:
        if entry.is_dir() and (entry.name.startswith(".") or entry.resolve() not in keep):
            shutil.rmtree(entry, ignore_errors=True)
            removed += 1
    return removed


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("\n\n", 2)[1], file=sys.stderr)
        return 64
    cache = os.environ.get("CHART_CACHE")
    if not cache:
        print("chart_fetch: CHART_CACHE is not set", file=sys.stderr)
        return 64
    try:
        print(fetch(*argv, Path(cache)))
    except FetchError as exc:
        print(f"chart_fetch: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
