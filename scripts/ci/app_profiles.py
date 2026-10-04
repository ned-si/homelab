#!/usr/bin/env python3
"""Assertion profiles for the two root Applications.

  root         clusters/homelab/root.yaml: name `root`, namespace `argo`, no
               finalizers, automated == {prune: false, selfHeal: true},
               targetRevision `main` (trunk-based), path deploy/clusters/homelab/bootstrap,
               repoURL equal to the config repository URL (`.git` stripped on
               both sides), `ServerSideApply=true` in syncOptions.
  legacy-root  clusters/homelab/legacy/all-apps.yaml: name `all-apps`, namespace
               `argo`, no finalizers, targetRevision = the 1877d3f pin, path
               kubernetes/applications, automated == {selfHeal: true} with no
               `prune` (with --no-automated: `automated` absent instead).

Used by scripts/ci/repo_policy.py on the files in git; the operator's local
apply-time tool applies the same profiles to what it pipes into kubectl, and
both share the fixtures in tests/fixtures/apps/.

CLI: app_profiles.py <profile> [--no-automated] <file>  -- exit 1 and one
line per failed assertion on stderr; no output on success.
"""
from __future__ import annotations

import json
import subprocess
import sys

CONFIG_REPO = "https://github.com/ned-si/homelab"
LEGACY_PIN = "1877d3fe42ff5f22b032603aa35464a3d9202d23"


def _norm(url: str) -> str:
    url = (url or "").strip().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def _common(doc: dict, name: str) -> list[str]:
    fails = []
    meta = doc.get("metadata") or {}
    if doc.get("kind") != "Application" or not str(doc.get("apiVersion", "")).startswith("argoproj.io/"):
        fails.append("not an argoproj.io Application")
    if meta.get("name") != name:
        fails.append(f"metadata.name is {meta.get('name')!r}, expected {name!r}")
    if meta.get("namespace") != "argo":
        fails.append(f"metadata.namespace is {meta.get('namespace')!r}, expected 'argo'")
    if meta.get("finalizers"):
        fails.append("metadata.finalizers must be absent")
    return fails


def check_root(doc: dict, repo_url: str = CONFIG_REPO) -> list[str]:
    fails = _common(doc, "root")
    spec = doc.get("spec") or {}
    src = spec.get("source") or {}
    sync = spec.get("syncPolicy") or {}
    if sync.get("automated") != {"prune": False, "selfHeal": True}:
        fails.append("syncPolicy.automated must be exactly {prune: false, selfHeal: true}")
    if src.get("targetRevision") != "main":
        fails.append(f"source.targetRevision is {src.get('targetRevision')!r}, expected 'main'")
    if src.get("path") != "deploy/clusters/homelab/bootstrap":
        fails.append(f"source.path is {src.get('path')!r}, expected 'deploy/clusters/homelab/bootstrap'")
    if _norm(src.get("repoURL", "")) != _norm(repo_url):
        fails.append("source.repoURL is not the config repository")
    if "ServerSideApply=true" not in (sync.get("syncOptions") or []):
        fails.append("syncPolicy.syncOptions lacks ServerSideApply=true")
    return fails


def check_legacy_root(doc: dict, no_automated: bool = False) -> list[str]:
    fails = _common(doc, "all-apps")
    spec = doc.get("spec") or {}
    src = spec.get("source") or {}
    sync = spec.get("syncPolicy") or {}
    if src.get("targetRevision") != LEGACY_PIN:
        fails.append(f"source.targetRevision is {src.get('targetRevision')!r}, expected the {LEGACY_PIN[:7]} pin")
    if src.get("path") != "kubernetes/applications":
        fails.append(f"source.path is {src.get('path')!r}, expected 'kubernetes/applications'")
    if no_automated:
        if "automated" in sync:
            fails.append("syncPolicy.automated must be absent (--no-automated)")
    elif sync.get("automated") != {"selfHeal": True}:
        fails.append("syncPolicy.automated must be exactly {selfHeal: true} (no prune)")
    return fails


PROFILES = {"root": check_root, "legacy-root": check_legacy_root}


def load_one(path: str) -> dict:
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", path], capture_output=True, text=True, check=True).stdout
    docs = [json.loads(line) for line in out.splitlines() if line.strip()]
    docs = [d for d in docs if isinstance(d, dict)]
    if len(docs) != 1:
        raise ValueError(f"{path}: expected exactly one document, found {len(docs)}")
    return docs[0]


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--no-automated"]
    if len(args) != 2 or args[0] not in PROFILES:
        print("usage: app_profiles.py root|legacy-root [--no-automated] <file>", file=sys.stderr)
        return 64
    doc = load_one(args[1])
    if args[0] == "legacy-root":
        fails = check_legacy_root(doc, no_automated="--no-automated" in argv)
    else:
        fails = check_root(doc)
    for f in fails:
        print(f"{args[0]}: {f}", file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
