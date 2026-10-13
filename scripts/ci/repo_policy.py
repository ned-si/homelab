#!/usr/bin/env python3
"""Repository invariants checked over the checkout and the render_apps.py output.

Usage: repo_policy.py --render <render_apps output dir> [--repo-root .]

Every rule is active only when the paths it is about exist, so on a tree with
only the legacy layout the new-layout rules are vacuous. "Non-doc files" are the
tracked files outside docs/ that are not Markdown. Findings name files, lines,
objects and rule ids only; values are never printed.

  no-lan-192-168-2      no literal of the retired 192.168.2/24 LAN in non-doc files
  wan-ip-single-source  per layout (legacy = kubernetes/applications/ + iac/, new =
                        everything else), the external-dns `--default-targets`
                        value is set exactly once and its IPv4 literal appears in
                        no other non-doc line of that layout
  immich-db-image       every rendered CNPG Cluster immich-db runs the pinned
                        pgvecto.rs image; one must exist while immich is in the tree
  no-resources-finalizer  no Application (in git or rendered) carries Argo's
                        resources-finalizer
  pvc-sync-options      new-layout renders: no PVC immich/immich-data; every other
                        PVC carries argocd.argoproj.io/sync-options with
                        Delete=false and Prune=false
  no-external-dns-exclude  the external-dns `exclude` annotation (not a real
                        annotation in v0.15.0) appears in no non-doc file or render
  wildcard-route-dns    every HTTPRoute with a `*` hostname carries
                        external-dns.alpha.kubernetes.io/controller: none
  cronjob-suspended / cronjob-guard / guard-modes / cronjob-active
                        new-layout CronJobs rendered from the apps and platform
                        layers are suspended, unless listed in
                        ci/active-cronjobs.txt, which must set `suspend: false`
                        and skip the guard; every list entry must be rendered.
                        All other CronJobs but ci/non-backup-cronjobs.txt are
                        guarded (initContainers[0] pending-guard, see
                        check_guard); ci/guard-modes.txt entries exist and use a
                        known mode
  root-profiles         clusters/homelab/root.yaml and bootstrap/root-app.yaml pass
                        `root` and are the same Application;
                        clusters/homelab/legacy/all-apps.yaml passes `legacy-root`
  cilium-version        the cilium Application's chart version equals the cilium
                        entry of ci/helm-releases.yaml
  no-cnpg-backup        no rendered CNPG Cluster has spec.backup; no ScheduledBackup
  expected-ingresses    every <ns>/<name> in ci/expected-ingresses.txt is rendered
                        by the new layout
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_profiles  # noqa: E402

# Built from parts so this file does not trip its own literal rules.
LAN_GONE = "192.168." + "2."
EXCLUDE_ANN = "external-dns.alpha.kubernetes.io/" + "exclude"
CONTROLLER_ANN = "external-dns.alpha.kubernetes.io/controller"
SYNC_OPTS_ANN = "argocd.argoproj.io/sync-options"
IMMICH_DB_IMAGE = "ghcr.io/tensorchord/cloudnative-pgvecto.rs:16.5-v0.3.0"
GUARD_CMD = ["/bin/sh", "/guard/pending-guard.sh"]
GUARD_MODES = {"restic", "s3-creds", "always-block"}
LEGACY_PREFIXES = ("kubernetes/applications/", "iac/")
IPV4 = re.compile(r"(?<![0-9.])(\d{1,3}(?:\.\d{1,3}){3})(?![0-9.])")
# Only a literal IPv4 value counts as "setting" the public address.
DEFAULT_TARGETS = re.compile(r"--default-targets=(\d{1,3}(?:\.\d{1,3}){3})(?![0-9.])")


class Policy:
    def __init__(self, root: Path, render: Path):
        self.root = root
        self.render = render
        self.fails: list[str] = []
        self.active: list[str] = []
        self.index = json.loads((render / "index.json").read_text())
        self._renders: dict[str, list[dict]] = {}

    # -- helpers ---------------------------------------------------------------
    def fail(self, rule: str, detail: str) -> None:
        self.fails.append(f"FAIL {rule}: {detail}")

    def on(self, rule: str) -> None:
        if rule not in self.active:
            self.active.append(rule)

    def tracked(self) -> list[str]:
        # Tracked plus untracked-but-not-ignored: identical in CI, and a local run
        # before `git add` sees new files too.
        out = subprocess.run(["git", "-C", str(self.root), "ls-files", "-z", "--cached", "--others",
                              "--exclude-standard"], capture_output=True, check=True).stdout
        return sorted({p for p in out.decode().split("\0") if p})

    def non_doc_files(self) -> list[str]:
        return [p for p in self.tracked()
                if not p.startswith("docs/") and not p.endswith(".md") and (self.root / p).is_file()]

    def lines(self, rel: str):
        try:
            text = (self.root / rel).read_text(errors="replace")
        except (OSError, UnicodeDecodeError):
            return
        for n, line in enumerate(text.splitlines(), 1):
            yield n, line

    def docs_of(self, entry: dict) -> list[dict]:
        key = entry["app"]
        if key not in self._renders:
            path = self.render / key / "manifests.yaml"
            docs = []
            if path.is_file():
                for line in path.read_text().splitlines():
                    if line and line != "---":
                        docs.append(json.loads(line))
            self._renders[key] = docs
        return self._renders[key]

    def entries(self, new_layout_only: bool = False) -> list[dict]:
        out = []
        for e in self.index:
            if e.get("error"):
                continue
            scopes = set(e["scope"].split("+"))
            if new_layout_only and not (scopes & {"2", "3"}):
                continue
            out.append(e)
        return out

    @staticmethod
    def ns_of(doc: dict, entry: dict) -> str:
        return (doc.get("metadata") or {}).get("namespace") or entry.get("namespace") or "default"

    @staticmethod
    def name_of(doc: dict) -> str:
        return (doc.get("metadata") or {}).get("name") or "?"

    def read_list(self, rel: str) -> list[str] | None:
        p = self.root / rel
        if not p.is_file():
            return None
        return [ln.strip() for ln in p.read_text().splitlines() if ln.strip() and not ln.strip().startswith("#")]

    # -- rules -----------------------------------------------------------------
    def rule_lan(self) -> None:
        self.on("no-lan-192-168-2")
        for rel in self.non_doc_files():
            for n, line in self.lines(rel):
                if LAN_GONE in line:
                    self.fail("no-lan-192-168-2", f"{rel}:{n}")

    def rule_wan(self) -> None:
        groups: dict[str, list[tuple[str, int, str]]] = {"legacy": [], "new": []}
        files = self.non_doc_files()
        for rel in files:
            for n, line in self.lines(rel):
                for m in DEFAULT_TARGETS.finditer(line):
                    group = "legacy" if rel.startswith(LEGACY_PREFIXES) else "new"
                    groups[group].append((rel, n, m.group(1)))
        for group, hits in groups.items():
            if not hits:
                continue
            self.on("wan-ip-single-source")
            if len(hits) != 1:
                where = ", ".join(f"{r}:{n}" for r, n, _ in hits)
                self.fail("wan-ip-single-source", f"{group} layout sets --default-targets {len(hits)} times ({where})")
                continue
            rel0, n0, value = hits[0]
            literals = set(IPV4.findall(value))
            for rel in files:
                if (group == "legacy") != rel.startswith(LEGACY_PREFIXES):
                    continue
                for n, line in self.lines(rel):
                    if (rel, n) == (rel0, n0):
                        continue
                    if literals & set(IPV4.findall(line)):
                        self.fail("wan-ip-single-source", f"{group} layout repeats the --default-targets address at {rel}:{n}")

    def rule_immich_db(self) -> None:
        found = 0
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") == "Cluster" and str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io/") \
                        and self.name_of(d) == "immich-db":
                    found += 1
                    self.on("immich-db-image")
                    if (d.get("spec") or {}).get("imageName") != IMMICH_DB_IMAGE:
                        self.fail("immich-db-image", f"{e['app']}: Cluster immich-db does not run the pinned image")
        if not found and ((self.root / "kubernetes/applications/immich").is_dir() or (self.root / "apps/immich").is_dir()):
            self.on("immich-db-image")
            self.fail("immich-db-image", "no rendered CNPG Cluster immich-db while immich is in the tree")

    @staticmethod
    def _has_res_finalizer(doc: dict) -> bool:
        return any("resources-finalizer" in str(f) for f in (doc.get("metadata") or {}).get("finalizers") or [])

    def rule_finalizer(self) -> None:
        self.on("no-resources-finalizer")
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") == "Application" and self._has_res_finalizer(d):
                    self.fail("no-resources-finalizer", f"rendered by {e['app']}: Application {self.name_of(d)}")
        for rel in self.tracked():
            # deploy/ is covered through the render; tests/fixtures/ holds deliberate failures.
            if not rel.endswith((".yaml", ".yml")) or rel.startswith(("docs/", "deploy/", "tests/fixtures/")):
                continue
            if "resources-finalizer" not in (self.root / rel).read_text(errors="replace"):
                continue
            for d in yaml_file_docs(self.root / rel):
                if d.get("kind") == "Application" and self._has_res_finalizer(d):
                    self.fail("no-resources-finalizer", f"{rel}: Application {self.name_of(d)}")

    def rule_pvc(self) -> None:
        for e in self.entries(new_layout_only=True):
            for d in self.docs_of(e):
                if d.get("kind") != "PersistentVolumeClaim":
                    continue
                self.on("pvc-sync-options")
                ns, name = self.ns_of(d, e), self.name_of(d)
                if (ns, name) == ("immich", "immich-data"):
                    self.fail("pvc-sync-options", f"{e['app']}: renders PVC immich/immich-data (must stay out of every leaf)")
                    continue
                ann = ((d.get("metadata") or {}).get("annotations") or {}).get(SYNC_OPTS_ANN, "")
                opts = {o.strip() for o in str(ann).split(",")}
                if not {"Delete=false", "Prune=false"} <= opts:
                    self.fail("pvc-sync-options", f"{e['app']}: PVC {ns}/{name} lacks {SYNC_OPTS_ANN}: Delete=false,Prune=false")

    def rule_exclude_annotation(self) -> None:
        self.on("no-external-dns-exclude")
        for rel in self.non_doc_files():
            for n, line in self.lines(rel):
                if EXCLUDE_ANN in line:
                    self.fail("no-external-dns-exclude", f"{rel}:{n}")
        for e in self.entries():
            for d in self.docs_of(e):
                if EXCLUDE_ANN in ((d.get("metadata") or {}).get("annotations") or {}):
                    self.fail("no-external-dns-exclude", f"{e['app']}: {d.get('kind')} {self.ns_of(d, e)}/{self.name_of(d)}")

    def rule_wildcard_routes(self) -> None:
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") != "HTTPRoute":
                    continue
                self.on("wildcard-route-dns")
                hosts = (d.get("spec") or {}).get("hostnames") or []
                if any("*" in h for h in hosts):
                    ann = ((d.get("metadata") or {}).get("annotations") or {}).get(CONTROLLER_ANN)
                    if ann != "none":
                        self.fail("wildcard-route-dns",
                                  f"{e['app']}: HTTPRoute {self.ns_of(d, e)}/{self.name_of(d)} has a wildcard hostname without {CONTROLLER_ANN}: none")

    def rule_cronjobs(self) -> None:
        non_backup = self.read_list("ci/non-backup-cronjobs.txt")
        modes_lines = self.read_list("ci/guard-modes.txt")
        active_lines = self.read_list("ci/active-cronjobs.txt")
        non_backup_set = set(non_backup or [])
        active_set = set(active_lines or [])
        seen_active: set[str] = set()
        modes: dict[str, str] = {}
        for ln in modes_lines or []:
            parts = ln.split()
            if len(parts) != 2:
                self.on("guard-modes")
                self.fail("guard-modes", f"ci/guard-modes.txt: malformed line '{ln}'")
                continue
            modes[parts[0]] = parts[1]
        seen_guarded: set[str] = set()
        for e in self.entries(new_layout_only=True):
            if e.get("layer") not in ("apps", "platform"):
                continue
            for d in self.docs_of(e):
                if d.get("kind") != "CronJob":
                    continue
                key = f"{self.ns_of(d, e)}/{self.name_of(d)}"
                suspend = (d.get("spec") or {}).get("suspend")
                if key in active_set:
                    # Reviewed and running: it must say so explicitly, and the
                    # pending-guard does not apply (its credentials are real).
                    self.on("cronjob-active")
                    seen_active.add(key)
                    if suspend is not False:
                        self.fail("cronjob-active", f"{e['app']}: CronJob {key} is in ci/active-cronjobs.txt "
                                                    "but does not set suspend: false")
                    continue
                self.on("cronjob-suspended")
                if suspend is not True:
                    self.fail("cronjob-suspended", f"{e['app']}: CronJob {key} is not suspended")
                if key in non_backup_set:
                    continue
                self.on("cronjob-guard")
                seen_guarded.add(key)
                for problem in check_guard(d, modes.get(key)):
                    self.fail("cronjob-guard", f"{e['app']}: CronJob {key}: {problem}")
        if active_lines is not None:
            self.on("cronjob-active")
        for key in sorted(active_set - seen_active):
            self.fail("cronjob-active", f"ci/active-cronjobs.txt: {key} is not a rendered CronJob (stale entry)")
        if modes_lines is not None or modes:
            self.on("guard-modes")
        for key, mode in modes.items():
            if mode not in GUARD_MODES:
                self.fail("guard-modes", f"ci/guard-modes.txt: {key} has unknown mode '{mode}'")
            if key not in seen_guarded:
                self.fail("guard-modes", f"ci/guard-modes.txt: {key} is not a rendered guarded CronJob (stale entry)")

    def rule_root_profiles(self) -> None:
        found = {}
        for rel, profile in (("clusters/homelab/root.yaml", "root"), ("bootstrap/root-app.yaml", "root"),
                             ("clusters/homelab/legacy/all-apps.yaml", "legacy-root")):
            p = self.root / rel
            if not p.is_file():
                continue
            self.on("root-profiles")
            apps = [d for d in yaml_file_docs(p) if d.get("kind") == "Application"]
            if len(apps) != 1:
                self.fail("root-profiles", f"{rel}: expected exactly one Application, found {len(apps)}")
                continue
            found[rel] = apps[0]
            check = app_profiles.check_root if profile == "root" else app_profiles.check_legacy_root
            for problem in check(apps[0]):
                self.fail("root-profiles", f"{rel} ({profile}): {problem}")
        # bootstrap/root-app.yaml is the file applied by hand at bootstrap; it must be the same object as the root.
        a, b = found.get("clusters/homelab/root.yaml"), found.get("bootstrap/root-app.yaml")
        if a is not None and b is not None and a != b:
            self.fail("root-profiles", "bootstrap/root-app.yaml is not the same Application as clusters/homelab/root.yaml")

    def rule_cilium_version(self) -> None:
        hr = self.root / "ci/helm-releases.yaml"
        app_files = sorted((self.root / "clusters/homelab/infrastructure").glob("*.y*ml")) \
            if (self.root / "clusters/homelab/infrastructure").is_dir() else []
        if not hr.is_file() or not app_files:
            return
        want = None
        docs = yaml_file_docs(hr)
        if docs:
            top = docs[0]
            entries = top.get("releases") if isinstance(top.get("releases"), list) else \
                [dict(v, name=k) for k, v in top.items() if isinstance(v, dict)]
            for ent in entries:
                if (ent.get("name") or ent.get("release")) == "cilium":
                    want = str(ent.get("version", "")).lstrip("v")
        for f in app_files:
            for d in yaml_file_docs(f):
                if d.get("kind") != "Application" or self.name_of(d) != "cilium":
                    continue
                self.on("cilium-version")
                spec = d.get("spec") or {}
                srcs = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
                got = [str(s.get("targetRevision", "")).lstrip("v") for s in srcs if s.get("chart") == "cilium"]
                if want is None:
                    self.fail("cilium-version", "ci/helm-releases.yaml has no cilium entry")
                elif got != [want]:
                    self.fail("cilium-version", f"{f.relative_to(self.root)}: cilium chart {got} != ci/helm-releases.yaml {want}")

    def rule_cnpg_backup(self) -> None:
        for e in self.entries():
            for d in self.docs_of(e):
                api = str(d.get("apiVersion", ""))
                if not api.startswith("postgresql.cnpg.io/"):
                    continue
                self.on("no-cnpg-backup")
                if d.get("kind") == "Cluster" and "backup" in (d.get("spec") or {}):
                    self.fail("no-cnpg-backup", f"{e['app']}: Cluster {self.ns_of(d, e)}/{self.name_of(d)} has spec.backup")
                if d.get("kind") == "ScheduledBackup":
                    self.fail("no-cnpg-backup", f"{e['app']}: ScheduledBackup {self.ns_of(d, e)}/{self.name_of(d)} is rendered")

    def rule_expected_ingresses(self) -> None:
        wanted = self.read_list("ci/expected-ingresses.txt")
        if wanted is None:
            return
        self.on("expected-ingresses")
        have = set()
        for e in self.entries(new_layout_only=True):
            for d in self.docs_of(e):
                if d.get("kind") == "Ingress":
                    have.add(f"{self.ns_of(d, e)}/{self.name_of(d)}")
        for w in wanted:
            if w not in have:
                self.fail("expected-ingresses", f"Ingress {w} is not rendered by the new layout")

    def run(self) -> int:
        for rule in (self.rule_lan, self.rule_wan, self.rule_immich_db, self.rule_finalizer, self.rule_pvc,
                     self.rule_exclude_annotation, self.rule_wildcard_routes, self.rule_cronjobs,
                     self.rule_root_profiles, self.rule_cilium_version, self.rule_cnpg_backup,
                     self.rule_expected_ingresses):
            rule()
        for f in self.fails:
            print(f)
        print(f"repo-policy: {len(self.active)} rule(s) active ({', '.join(self.active) or 'none'}), "
              f"{len(self.fails)} failure(s)")
        return 1 if self.fails else 0


def check_guard(cj: dict, mode: str | None) -> list[str]:
    """The pending-guard contract for one guarded CronJob (mode = its ci/guard-modes.txt entry)."""
    problems = []
    pod = ((((cj.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    containers = pod.get("containers") or []
    if len(containers) != 1:
        return [f"has {len(containers)} containers; a guarded job needs exactly one (the guard's source)"]
    c = containers[0]
    inits = pod.get("initContainers") or []
    if not inits or inits[0].get("name") != "pending-guard":
        return ["initContainers[0] is not pending-guard"]
    g = inits[0]
    if g.get("image") != c.get("image"):
        problems.append("pending-guard image differs from containers[0]")
    if g.get("command") != GUARD_CMD:
        problems.append("pending-guard command is not [/bin/sh, /guard/pending-guard.sh]")
    if (g.get("envFrom") or []) != (c.get("envFrom") or []):
        problems.append("pending-guard envFrom differs from containers[0]")
    mounts = g.get("volumeMounts") or []
    guard_mounts = [m for m in mounts if m.get("mountPath") == "/guard"]
    rest = [m for m in mounts if m.get("mountPath") != "/guard"]
    if len(guard_mounts) != 1:
        problems.append(f"pending-guard has {len(guard_mounts)} mounts at /guard, expected 1")
    if rest != (c.get("volumeMounts") or []):
        problems.append("pending-guard volumeMounts (besides /guard) differ from containers[0]")
    want_env = list(c.get("env") or [])
    if mode is not None:
        want_env.append({"name": "GUARD_MODE", "value": mode})
    if (g.get("env") or []) != want_env:
        problems.append("pending-guard env is not containers[0] env" + (f" plus GUARD_MODE={mode}" if mode else ""))
    if mode is None and "RESTIC_REPOSITORY" not in {e.get("name") for e in c.get("env") or []}:
        problems.append("not in ci/guard-modes.txt and containers[0] has no RESTIC_REPOSITORY (restic mode needs it)")
    return problems


def yaml_file_docs(path: Path) -> list[dict]:
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], capture_output=True, text=True)
    if out.returncode != 0:
        return []
    docs = []
    for line in out.stdout.splitlines():
        if line.strip():
            d = json.loads(line)
            if isinstance(d, dict):
                docs.append(d)
    return docs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="repository policy")
    ap.add_argument("--render", required=True, help="render_apps.py output directory")
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args(argv)
    return Policy(Path(args.repo_root).resolve(), Path(args.render).resolve()).run()


if __name__ == "__main__":
    sys.exit(main())
