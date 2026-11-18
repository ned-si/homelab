#!/usr/bin/env python3
"""Inventory of who signs the images the cluster runs (.kiro/specs/image-provenance/design.md#inventory-task-1).

Reads every image reference (string values under `image` or `imageName`) in
deploy/ and, with --render, in the render_apps.py output, and asks cosign,
read-only, whether each digest is signed, by whom, and whether it carries
attestations. ci/image-signers.yaml says per repository who should sign it,
or why it is unsigned.

Status per image: verified (signed by the listed identity), mismatch (listed
identity, signature missing or not by it), signed-unlisted (signed, no listed
identity), unsigned-listed (no signature, listed as unsigned), unsigned (no
signature, not listed, or no digest), error (registry calls failed after the
retries).

Exit 1 on any mismatch or error, 2 on a signer-list or manifest parse error,
else 0. --offline makes no registry call and lists images with their entry.
COSIGN_BIN and DOCKER_BIN override the binaries (tests use fakes).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from repo_policy import parse_image  # noqa: E402

STATUSES = ("mismatch", "error", "unsigned", "signed-unlisted", "unsigned-listed", "verified")
IMAGE_KEYS = ("image", "imageName")
ENTRY_KEYS = {"repository", "issuer", "subject", "subjectRegExp", "unsigned"}
TRANSIENT = re.compile(r"timeout|timed out|connection reset|\b429\b|too many requests|toomanyrequests|\b5\d\d\b", re.I)
BACKOFF = (10, 30, 60)
CALL_TIMEOUT = 60
OWN_PREFIX = "ghcr.io/ned-si/"


class SchemaError(Exception):
    pass


class Transient(Exception):
    pass


def load_signers(path: Path) -> dict[str, dict]:
    """repository -> entry; SchemaError naming the entry on any rule of the design."""
    try:
        data = yaml.safe_load(path.read_text()) or []
    except (OSError, yaml.YAMLError) as e:
        raise SchemaError(f"{path}: {e}") from e
    if not isinstance(data, list):
        raise SchemaError(f"{path}: a list of entries expected")
    out: dict[str, dict] = {}
    for i, e in enumerate(data):
        where = f"{path} entry {i + 1}"
        if not isinstance(e, dict):
            raise SchemaError(f"{where}: a mapping expected")
        repo = e.get("repository")
        if not isinstance(repo, str) or not repo:
            raise SchemaError(f"{where}: repository is required")
        where = f"{path} {repo}"
        unknown = set(e) - ENTRY_KEYS
        if unknown:
            raise SchemaError(f"{where}: unknown keys {sorted(unknown)}")
        if "@" in repo or (parse_image(repo) is not None):
            raise SchemaError(f"{where}: repository without tag or digest")
        normal = parse_image(repo + ":x")
        if normal is None or normal[0] != repo:
            raise SchemaError(f"{where}: not in parse_image form (want {normal[0] if normal else '?'})")
        if repo in out:
            raise SchemaError(f"{where}: duplicate repository")
        has_id = "subject" in e or "subjectRegExp" in e
        if ("subject" in e) and ("subjectRegExp" in e):
            raise SchemaError(f"{where}: subject and subjectRegExp are exclusive")
        if has_id == ("unsigned" in e):
            raise SchemaError(f"{where}: exactly one of subject/subjectRegExp or unsigned")
        if "unsigned" in e:
            if not isinstance(e["unsigned"], str) or not e["unsigned"].strip():
                raise SchemaError(f"{where}: unsigned needs a reason")
            if "issuer" in e:
                raise SchemaError(f"{where}: issuer without a subject")
        else:
            issuer = e.get("issuer")
            if not isinstance(issuer, str) or not issuer.startswith("https://"):
                raise SchemaError(f"{where}: issuer must be an https:// URL")
            if "subjectRegExp" in e:
                try:
                    re.compile(str(e["subjectRegExp"]))
                except re.error as err:
                    raise SchemaError(f"{where}: subjectRegExp: {err}") from err
            elif not isinstance(e["subject"], str) or not e["subject"]:
                raise SchemaError(f"{where}: subject must be a string")
        out[repo] = e
    return out


def walk_images(node, found: list[str]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k in IMAGE_KEYS and isinstance(v, str) and v.strip():
                found.append(v.strip())
            else:
                walk_images(v, found)
    elif isinstance(node, list):
        for v in node:
            walk_images(v, found)


def manifest_files(deploy: Path | None, render: Path | None) -> list[Path]:
    files: list[Path] = []
    if deploy:
        files += sorted(deploy.rglob("*.yaml"))
    if render:
        files += sorted(render.rglob("manifests.yaml"))
    return files


def collect(files: list[Path]) -> dict[str, dict]:
    """key -> {ref, repository, digest, note, used_by}; SchemaError on an unparsable document."""
    images: dict[str, dict] = {}
    for f in files:
        try:
            docs = list(yaml.safe_load_all(f.read_text()))
        except yaml.YAMLError as e:
            raise SchemaError(f"{f}: {str(e).splitlines()[0]}") from e
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            meta = doc.get("metadata") or {}
            user = f"{meta.get('namespace') or '-'}/{doc.get('kind', '?')}/{meta.get('name', '?')}"
            found: list[str] = []
            walk_images(doc, found)
            for ref in found:
                parsed = parse_image(ref)
                digest = ref.split("@", 1)[1] if "@" in ref else ""
                if parsed is None:
                    named = parse_image(ref.split("@", 1)[0] + ":x")
                    key, repo, note = ref, named[0] if named else ref, "no tag"
                elif not digest:
                    key, repo, note = ref, parsed[0], "no digest"
                else:
                    key, repo, note = f"{parsed[0]}@{digest}", parsed[0], ""
                row = images.setdefault(key, {"ref": ref, "repository": repo, "digest": digest,
                                              "note": note, "used_by": set()})
                row["used_by"].add(user)
    return images


def target(ref: str, digest: str) -> str:
    """repo@digest as written in the manifest, tag dropped."""
    name = ref.split("@", 1)[0]
    head, _, last = name.rpartition("/")
    last = last.split(":", 1)[0]
    return f"{head}/{last}@{digest}" if head else f"{last}@{digest}"


class Runner:
    def __init__(self, cosign: str, docker: str | None, sleep=time.sleep):
        self.cosign, self.docker, self.sleep, self.calls = cosign, docker, sleep, 0

    def run(self, argv: list[str]) -> subprocess.CompletedProcess:
        """Run a registry call; retries transient failures; Transient when they are exhausted."""
        last = None
        for attempt in range(len(BACKOFF) + 1):
            self.calls += 1
            try:
                p = subprocess.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT)
            except subprocess.TimeoutExpired:
                p = subprocess.CompletedProcess(argv, 124, "", f"timeout after {CALL_TIMEOUT}s")
            if p.returncode == 0 or not TRANSIENT.search(p.stderr or ""):
                return p
            last = p
            if attempt < len(BACKOFF):
                print(f"retry {attempt + 1} in {BACKOFF[attempt]}s: {argv[1]} {argv[-1]}: "
                      f"{(p.stderr or '').strip().splitlines()[-1][:200]}", file=sys.stderr)
                self.sleep(BACKOFF[attempt])
        raise Transient((last.stderr or "").strip())


def tree_info(out: str) -> tuple[bool, bool]:
    """(signed, attestations) from `cosign tree` output."""
    low = out.lower()
    # Classic tags (.sig, .att, .sbom) or OCI referrers (cosign/sign/v1, cosign/attest/v1).
    signed = "signatures for" in low or "cosign/sign/" in low
    att = "attestations for" in low or "sboms for" in low or "cosign/attest/" in low or "in-toto" in low
    return signed, att


def identity_args(entry: dict) -> list[str]:
    args = ["--certificate-oidc-issuer", entry["issuer"]]
    if "subjectRegExp" in entry:
        return args + ["--certificate-identity-regexp", entry["subjectRegExp"]]
    return args + ["--certificate-identity", entry["subject"]]


def signer_of(stdout: str) -> tuple[str, str]:
    try:
        first = json.loads(stdout)[0]
        opt = first.get("optional") or {}
        return str(opt.get("Issuer") or "unknown"), str(opt.get("Subject") or "unknown")
    except (ValueError, IndexError, KeyError, TypeError, AttributeError):
        return "unknown", "unknown"


def index_attestations(runner: Runner, ref: str) -> bool:
    p = runner.run([runner.docker, "buildx", "imagetools", "inspect", "--raw", ref])
    if p.returncode != 0:
        return False
    try:
        manifests = json.loads(p.stdout).get("manifests") or []
    except ValueError:
        return False
    return any((m.get("annotations") or {}).get("vnd.docker.reference.type") == "attestation-manifest"
               for m in manifests)


def check(row: dict, entry: dict | None, runner: Runner | None) -> None:
    """Fill status, signer, attestations, detail of one image."""
    row.update(signer="", attestations="", detail="")
    listed_id = entry is not None and "unsigned" not in entry
    if listed_id:
        row["signer"] = entry.get("subject") or entry.get("subjectRegExp")
    if row["note"]:
        row["status"] = "mismatch" if listed_id else "unsigned"
        row["detail"] = row["note"]
        return
    if runner is None:
        row["status"] = "listed" if entry else "unlisted"
        return
    ref = target(row["ref"], row["digest"])
    try:
        t = runner.run([runner.cosign, "tree", ref])
        if t.returncode != 0:
            raise Transient((t.stderr or "").strip())
        signed, att = tree_info(t.stdout)
        if row["repository"].startswith(OWN_PREFIX) and runner.docker:
            att = att or index_attestations(runner, ref)
        row["attestations"] = "yes" if att else "no"
        if not signed:
            row["status"] = "mismatch" if listed_id else ("unsigned-listed" if entry else "unsigned")
            if listed_id:
                row["detail"] = "no signature"
            return
        if listed_id:
            v = runner.run([runner.cosign, "verify", *identity_args(entry), ref])
            row["status"] = "verified" if v.returncode == 0 else "mismatch"
            if v.returncode != 0:
                row["detail"] = (v.stderr or "").strip()[:300]
            return
        v = runner.run([runner.cosign, "verify", "--certificate-identity-regexp", ".*",
                        "--certificate-oidc-issuer-regexp", ".*", "--output", "json", ref])
        row["status"] = "signed-unlisted"
        if v.returncode == 0:
            row["issuer"], row["signer"] = signer_of(v.stdout)
        else:
            row["signer"] = "key-based"
    except Transient as e:
        row["status"] = "error"
        row["detail"] = str(e)[:300]


def short(digest: str) -> str:
    return digest.replace("sha256:", "")[:12] if digest else "-"


def report(rows: list[dict], calls: int, offline: bool) -> str:
    order = {s: i for i, s in enumerate(STATUSES + ("unlisted", "listed"))}
    rows = sorted(rows, key=lambda r: (order.get(r["status"], 99), r["repository"], r["digest"]))
    lines = ["| Repository | Digest | Status | Signer | Attestations | Used by |",
             "| --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        signer = r.get("signer") or ""
        if r["status"] == "signed-unlisted" and signer != "key-based":
            signer += " (add a signer-list entry)"
        if r.get("detail"):
            signer = f"{signer} {r['detail']}".strip().replace("|", "/").replace("\n", " ")
        used = ", ".join(sorted(r["used_by"]))
        lines.append(f"| {r['repository']} | {short(r['digest'])} | {r['status']} | {signer} | "
                     f"{r.get('attestations') or '-'} | {used} |")
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    lines.append("")
    lines.append("Counts: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda kv: order.get(kv[0], 99))))
    lines.append(f"Images: {len(rows)}; registry calls: {0 if offline else calls}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--deploy", default="deploy", help="rendered manifests (default deploy)")
    ap.add_argument("--render", help="render_apps.py output directory")
    ap.add_argument("--signers", default="ci/image-signers.yaml")
    ap.add_argument("--json", help="write the rows as JSON to this file")
    ap.add_argument("--offline", action="store_true", help="no registry call")
    a = ap.parse_args(argv)

    try:
        signers = load_signers(Path(a.signers))
        images = collect(manifest_files(Path(a.deploy) if a.deploy else None, Path(a.render) if a.render else None))
    except SchemaError as e:
        print(f"image_provenance: {e}", file=sys.stderr)
        return 2

    runner = None
    if not a.offline:
        cosign = os.environ.get("COSIGN_BIN") or shutil.which("cosign")
        if not cosign:
            print("image_provenance: cosign not found (or use --offline)", file=sys.stderr)
            return 2
        runner = Runner(cosign, os.environ.get("DOCKER_BIN") or shutil.which("docker"))

    rows = list(images.values())
    for row in rows:
        check(row, signers.get(row["repository"]), runner)

    print(report(rows, runner.calls if runner else 0, a.offline), end="")
    if a.json:
        Path(a.json).write_text(json.dumps(
            [{**r, "used_by": sorted(r["used_by"])} for r in sorted(rows, key=lambda r: (r["repository"], r["digest"]))],
            indent=2) + "\n")
    return 1 if any(r["status"] in ("mismatch", "error") for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
