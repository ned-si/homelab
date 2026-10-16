#!/usr/bin/env python3
"""Repository invariants checked over the checkout and the render_apps.py output.

Usage: repo_policy.py --render <render_apps output dir> [--repo-root .] [--base <rev>]

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
                        VectorChord image; one must exist while immich is in the tree
  no-resources-finalizer  no Application (in git or rendered) carries Argo's
                        resources-finalizer
  pvc-sync-options      new-layout renders: no PVC immich/immich-data; every other
                        PVC, and every CNPG Cluster in namespace immich, carries
                        argocd.argoproj.io/sync-options with Delete=false and
                        Prune=false
  no-external-dns-exclude  the external-dns `exclude` annotation (not a real
                        annotation in v0.15.0) appears in no non-doc file or render
  wildcard-route-dns    every HTTPRoute with a `*` hostname carries
                        external-dns.alpha.kubernetes.io/controller: none
  route-security-headers  every rule of an HTTPRoute attached to the `https`
                        listener has a ResponseHeaderModifier that sets
                        Strict-Transport-Security and X-Content-Type-Options
                        (docs/networking.md, Security headers)
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
  bootstrap-chart-versions  the chart version of each Application that adopts a
                        bootstrap release (cilium, argocd) and its helm_release
                        in bootstrap/main.tf equal its entry in
                        ci/helm-releases.yaml
  cnpg-backup           every rendered CNPG Cluster archives WAL through the Barman
                        Cloud plugin, has a ScheduledBackup and references a
                        rendered ObjectStore in its namespace; no Cluster uses
                        spec.backup.barmanObjectStore; every ScheduledBackup is
                        method: plugin, not suspended, and targets such a Cluster
  backup-bucket-lock    bootstrap/aws-backup/main.tf: aws_s3_bucket_policy.backups
                        uses data.aws_iam_policy_document.bucket, and that
                        document has a statement denying s3:DeleteObjectVersion,
                        s3:PutBucketVersioning and s3:DeleteBucket to principal
                        * on the bucket and its objects, without a condition
  kiro-tracked          no tracked file under .kiro/ outside .kiro/specs/ and
                        .kiro/steering/
  expected-ingresses    every <ns>/<name> in ci/expected-ingresses.txt is rendered
                        by the new layout
  k8s-version-match     K8S_VERSION and the KIND_NODE_IMAGE tag in
                        .github/workflows/ci.yaml are on the Kubernetes minor of
                        kubernetesVersion in talos/talconfig.yaml
  image-bulky-base      no `image:`/`imageName:` line under apps/, platform/,
                        infrastructure/, bootstrap/, clusters/ or talos/ runs a
                        full python, node, golang, ubuntu or debian image (no
                        alpine, slim or distroless variant)
  image-variant         (--base only) no such line moves an image to a tag
                        variant (alpine, slim, distroless, a Debian or Ubuntu
                        codename) that the base tree does not use for that
                        image; adding a light variant (alpine, slim, distroless,
                        minimal), with or without a distro codename, is free.
                        Reverts are exempt (--pr-title starting with
                        `revert`, or --pr-branch under auto-revert/): a revert
                        restores what ran before.
  image-digest          every tagged `image:`/`imageName:`/`reference:` line
                        under the same directories pins its tag by digest
                        (repo:tag@sha256:<index digest>). Renovate's image
                        manager captures the digest and moves tag and digest
                        together; it cannot add a missing one.

Every image rule accepts a line that carries `# image-policy: allow <reason>`.
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
IMMICH_DB_IMAGE = ("ghcr.io/tensorchord/cloudnative-vectorchord:16.15-1.1.1"
                   "@sha256:f5a17fa05faf25e81304ee95e9f920d8ae077ac4a4ef0a1251e09c7197cbb236")
CNPG_PLUGIN = "barman-cloud.cloudnative-pg.io"
# Applications that adopt a release the bootstrap installs with the helm CLI: name -> chart.
BOOTSTRAP_CHARTS = {"cilium": "cilium", "argocd": "argo-cd"}
GUARD_CMD = ["/bin/sh", "/guard/pending-guard.sh"]
GUARD_MODES = {"restic", "s3-creds", "always-block"}
LEGACY_PREFIXES = ("kubernetes/applications/", "iac/")
IPV4 = re.compile(r"(?<![0-9.])(\d{1,3}(?:\.\d{1,3}){3})(?![0-9.])")
# Only a literal IPv4 value counts as "setting" the public address.
DEFAULT_TARGETS = re.compile(r"--default-targets=(\d{1,3}(?:\.\d{1,3}){3})(?![0-9.])")
AWS_BACKUP_TF = "bootstrap/aws-backup/main.tf"
# What the backup bucket policy must deny to everyone (docs/backups.md#immutable-versions).
LOCK_ACTIONS = {"s3:DeleteObjectVersion", "s3:PutBucketVersioning", "s3:DeleteBucket"}
CI_WORKFLOW = ".github/workflows/ci.yaml"
# The only tracked parts of .kiro/; settings, hooks and skills stay local.
KIRO_TRACKED = (".kiro/specs/", ".kiro/steering/")
TALCONFIG = "talos/talconfig.yaml"
K8S_MINOR = re.compile(r"^v?(\d+)\.(\d+)(?:\.\d+)?$")
IMAGE_DIRS = ("apps/", "platform/", "infrastructure/", "bootstrap/", "clusters/", "talos/")
IMAGE_LINE = re.compile(r"^\s*-?\s*(?:image|imageName|reference):\s*['\"]?(?P<ref>[^\s'\"#]+)['\"]?\s*(?:#(?P<comment>.*))?$")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
IMAGE_ALLOW = re.compile(r"image-policy:\s*allow\s+\S")
# Tag tokens (digits stripped) that name an image variant.
VARIANT_WORDS = {"alpine", "slim", "distroless", "bookworm", "bullseye", "buster", "trixie",
                 "noble", "jammy", "focal", "ubi", "musl", "minimal"}
LIGHT_VARIANTS = {"alpine", "slim", "distroless", "minimal"}
CODENAMES = {"bookworm", "bullseye", "buster", "trixie", "noble", "jammy", "focal"}
BULKY_IMAGES = {"python", "node", "golang", "ubuntu", "debian"}
# Set by the Gateway on every rule of an HTTPRoute on the https listener.
ROUTE_HEADERS = {"strict-transport-security", "x-content-type-options"}


class Policy:
    def __init__(self, root: Path, render: Path, base: str | None = None, pr_title: str = "", pr_branch: str = ""):
        self.root = root
        self.render = render
        self.base = base
        self.pr_title = pr_title
        self.pr_branch = pr_branch
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
                if not self._keeps(d):
                    self.fail("pvc-sync-options", f"{e['app']}: PVC {ns}/{name} lacks {SYNC_OPTS_ANN}: Delete=false,Prune=false")
        # immich syncs automatically with prune: its database must survive a
        # render that drops it, like every PVC above.
        for e in self.entries(new_layout_only=True):
            for d in self.docs_of(e):
                if self.ns_of(d, e) != "immich" or d.get("kind") != "Cluster" \
                        or not str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io/"):
                    continue
                self.on("pvc-sync-options")
                if not self._keeps(d):
                    self.fail("pvc-sync-options", f"{e['app']}: Cluster immich/{self.name_of(d)} lacks "
                              f"{SYNC_OPTS_ANN}: Delete=false,Prune=false")

    @staticmethod
    def _keeps(d: dict) -> bool:
        ann = ((d.get("metadata") or {}).get("annotations") or {}).get(SYNC_OPTS_ANN, "")
        return {"Delete=false", "Prune=false"} <= {o.strip() for o in str(ann).split(",")}

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

    def rule_route_headers(self) -> None:
        rule = "route-security-headers"
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") != "HTTPRoute":
                    continue
                spec = d.get("spec") or {}
                if not any(p.get("sectionName") == "https" for p in spec.get("parentRefs") or []):
                    continue
                self.on(rule)
                for i, r in enumerate(spec.get("rules") or []):
                    names = set()
                    for f in r.get("filters") or []:
                        if f.get("type") == "ResponseHeaderModifier":
                            names |= {str(h.get("name", "")).lower()
                                      for h in (f.get("responseHeaderModifier") or {}).get("set") or []}
                    missing = sorted(ROUTE_HEADERS - names)
                    if missing:
                        self.fail(rule, f"{e['app']}: HTTPRoute {self.ns_of(d, e)}/{self.name_of(d)} rule {i} "
                                        f"does not set {', '.join(missing)} (ResponseHeaderModifier set)")

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

    def rule_bootstrap_chart_versions(self) -> None:
        rule = "bootstrap-chart-versions"
        hr = self.root / "ci/helm-releases.yaml"
        app_files = sorted((self.root / "clusters/homelab/infrastructure").glob("*.y*ml")) \
            if (self.root / "clusters/homelab/infrastructure").is_dir() else []
        if not hr.is_file() or not app_files:
            return
        want: dict[str, str] = {}
        docs = yaml_file_docs(hr)
        if docs:
            top = docs[0]
            entries = top.get("releases") if isinstance(top.get("releases"), list) else \
                [dict(v, name=k) for k, v in top.items() if isinstance(v, dict)]
            for ent in entries:
                name = ent.get("name") or ent.get("release")
                if name in BOOTSTRAP_CHARTS:
                    want[name] = str(ent.get("version", "")).lstrip("v")
        tf = self.root / "bootstrap/main.tf"
        if tf.is_file():
            for m in re.finditer(r'^resource\s+"helm_release"\s+"(\w+)"\s*\{(.*?)^\}', tf.read_text(), re.M | re.S):
                name = m.group(1)
                if name not in BOOTSTRAP_CHARTS or name not in want:
                    continue
                self.on(rule)
                v = re.search(r'^\s*version\s*=\s*"([^"]+)"', m.group(2), re.M)
                got_tf = v.group(1).lstrip("v") if v else ""
                if got_tf != want[name]:
                    self.fail(rule, f"bootstrap/main.tf: helm_release.{name} version {got_tf!r} != ci/helm-releases.yaml {want[name]}")
        for f in app_files:
            for d in yaml_file_docs(f):
                name = self.name_of(d)
                if d.get("kind") != "Application" or name not in BOOTSTRAP_CHARTS:
                    continue
                self.on(rule)
                chart = BOOTSTRAP_CHARTS[name]
                spec = d.get("spec") or {}
                srcs = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
                got = [str(s.get("targetRevision", "")).lstrip("v") for s in srcs if s.get("chart") == chart]
                if name not in want:
                    self.fail(rule, f"ci/helm-releases.yaml has no {name} entry")
                elif got != [want[name]]:
                    self.fail(rule, f"{f.relative_to(self.root)}: {chart} chart {got} != ci/helm-releases.yaml {want[name]}")

    def rule_cnpg_backup(self) -> None:
        clusters: dict[tuple[str, str], tuple[str, dict]] = {}
        scheduled: list[tuple[str, str, dict]] = []
        stores: set[tuple[str, str]] = set()
        for e in self.entries():
            for d in self.docs_of(e):
                api, kind = str(d.get("apiVersion", "")), d.get("kind")
                ns = self.ns_of(d, e)
                if api.startswith("barmancloud.cnpg.io/") and kind == "ObjectStore":
                    stores.add((ns, self.name_of(d)))
                if not api.startswith("postgresql.cnpg.io/"):
                    continue
                self.on("cnpg-backup")
                spec = d.get("spec") or {}
                if kind == "Cluster":
                    clusters[(ns, self.name_of(d))] = (e["app"], d)
                    if "barmanObjectStore" in (spec.get("backup") or {}):
                        self.fail("cnpg-backup", f"{e['app']}: Cluster {ns}/{self.name_of(d)} uses the in-tree "
                                                 "spec.backup.barmanObjectStore (use the Barman Cloud plugin)")
                if kind == "ScheduledBackup":
                    scheduled.append((e["app"], ns, d))
        backed_up: set[tuple[str, str]] = set()
        for app, ns, d in scheduled:
            spec = d.get("spec") or {}
            where = f"{app}: ScheduledBackup {ns}/{self.name_of(d)}"
            if spec.get("suspend") is True:
                self.fail("cnpg-backup", f"{where} is suspended")
            if spec.get("method") != "plugin" or (spec.get("pluginConfiguration") or {}).get("name") != CNPG_PLUGIN:
                self.fail("cnpg-backup", f"{where} is not method: plugin with pluginConfiguration.name: {CNPG_PLUGIN}")
            target = (ns, (spec.get("cluster") or {}).get("name") or "?")
            if target not in clusters or wal_archiver(clusters[target][1]) is None:
                self.fail("cnpg-backup", f"{where} targets {target[0]}/{target[1]}, which is not a rendered Cluster "
                                         "with the Barman Cloud plugin as WAL archiver")
            backed_up.add(target)
        for (ns, name), (app, d) in sorted(clusters.items()):
            plugin = wal_archiver(d)
            if plugin is None:
                self.fail("cnpg-backup", f"{app}: Cluster {ns}/{name} does not archive WAL through the "
                                         f"Barman Cloud plugin ({CNPG_PLUGIN}, isWALArchiver: true)")
                continue
            if (ns, name) not in backed_up:
                self.fail("cnpg-backup", f"{app}: Cluster {ns}/{name} archives WAL but has no ScheduledBackup")
            store = (plugin.get("parameters") or {}).get("barmanObjectName")
            if (ns, store) not in stores:
                self.fail("cnpg-backup", f"{app}: Cluster {ns}/{name} references ObjectStore {ns}/{store}, "
                                         "which is not rendered")

    def rule_backup_bucket_lock(self) -> None:
        rule = "backup-bucket-lock"
        tf = self.root / AWS_BACKUP_TF
        if not tf.is_file():
            return
        self.on(rule)
        text = tf.read_text()
        pol = hcl_block(text, r'resource\s+"aws_s3_bucket_policy"\s+"backups"')
        if pol is None:
            self.fail(rule, f"{AWS_BACKUP_TF}: no resource aws_s3_bucket_policy.backups")
        elif not re.search(r'^\s*policy\s*=\s*data\.aws_iam_policy_document\.bucket\.json\s*$', pol, re.M) \
                or not re.search(r'^\s*bucket\s*=\s*aws_s3_bucket\.backups\.id\s*$', pol, re.M):
            self.fail(rule, f"{AWS_BACKUP_TF}: aws_s3_bucket_policy.backups must set bucket = aws_s3_bucket.backups.id "
                            "and policy = data.aws_iam_policy_document.bucket.json")
        doc = hcl_block(text, r'data\s+"aws_iam_policy_document"\s+"bucket"')
        if doc is None:
            self.fail(rule, f"{AWS_BACKUP_TF}: no data aws_iam_policy_document.bucket")
            return
        if not any(lock_statement(s) for s in hcl_blocks(doc, r'statement')):
            self.fail(rule, f"{AWS_BACKUP_TF}: data.aws_iam_policy_document.bucket has no statement that denies "
                            f"{', '.join(sorted(LOCK_ACTIONS))} to principal * on the bucket and its objects "
                            "without a condition")

    def rule_kiro_tracked(self) -> None:
        rule = "kiro-tracked"
        self.on(rule)
        for rel in self.tracked():
            if rel.startswith(".kiro/") and not rel.startswith(KIRO_TRACKED):
                self.fail(rule, f"{rel}: only {' and '.join(KIRO_TRACKED)} are tracked under .kiro/")

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

    def rule_k8s_version(self) -> None:
        rule = "k8s-version-match"
        ci, tal = self.root / CI_WORKFLOW, self.root / TALCONFIG
        if not ci.is_file() or not tal.is_file():
            return
        self.on(rule)
        tal_docs = yaml_file_docs(tal)
        want = k8s_minor(str((tal_docs[0] if tal_docs else {}).get("kubernetesVersion", "")))
        if want is None:
            self.fail(rule, f"{TALCONFIG}: no kubernetesVersion of the form vX.Y.Z")
            return
        ci_docs = yaml_file_docs(ci)
        env = (ci_docs[0] if ci_docs else {}).get("env") or {}
        ref = str(env.get("KIND_NODE_IMAGE", "")).split("@", 1)[0]
        tag = ref.rsplit(":", 1)[1] if ":" in ref else ""
        for key, value in (("K8S_VERSION", str(env.get("K8S_VERSION", ""))), ("KIND_NODE_IMAGE", tag)):
            got = k8s_minor(value)
            if got != want:
                self.fail(rule, f"{CI_WORKFLOW}: env {key} is on minor {'.'.join(got) if got else '?'}, "
                                f"{TALCONFIG} kubernetesVersion on {'.'.join(want)}")

    def image_refs(self, rev: str | None = None) -> list[tuple[str, int, str, str, bool, bool]]:
        """(file, line, repo, tag, allowed, pinned) per image reference under IMAGE_DIRS, in the checkout or at `rev`."""
        hits: list[tuple[str, int, str]] = []
        if rev is None:
            for rel in self.tracked():
                if rel.startswith(IMAGE_DIRS) and rel.endswith((".yaml", ".yml")):
                    hits.extend((rel, n, line) for n, line in self.lines(rel))
        else:
            out = subprocess.run(["git", "-C", str(self.root), "grep", "-z", "-n", "-I", "-E",
                                  r"(image|imageName|reference):", rev, "--", *IMAGE_DIRS], capture_output=True)
            if out.returncode > 1:
                raise ValueError(rev)
            for rec in out.stdout.decode(errors="replace").splitlines():
                path, n, line = rec.split("\0", 2)
                rel = path[len(rev) + 1:]
                if rel.endswith((".yaml", ".yml")):
                    hits.append((rel, int(n), line))
        refs = []
        for rel, n, line in hits:
            m = IMAGE_LINE.match(line)
            parsed = parse_image(m.group("ref")) if m else None
            if parsed:
                refs.append((rel, n, parsed[0], parsed[1], bool(IMAGE_ALLOW.search(m.group("comment") or "")),
                             bool(DIGEST.search(m.group("ref")))))
        return refs

    def rule_image_bulky(self) -> None:
        rule = "image-bulky-base"
        self.on(rule)
        for rel, n, repo, tag, allowed, _ in self.image_refs():
            if repo in BULKY_IMAGES and not image_variant(tag) & LIGHT_VARIANTS and not allowed:
                self.fail(rule, f"{rel}:{n}: {repo}:{tag} is a full image; use its alpine, slim or distroless "
                                "variant or add `# image-policy: allow <reason>`")

    def rule_image_variant(self) -> None:
        rule = "image-variant"
        if not self.base:
            return
        if self.pr_title.lower().startswith("revert") or self.pr_branch.startswith("auto-revert/"):
            print(f"{rule}: skipped, the pull request is a revert")
            return
        self.on(rule)
        try:
            before = self.image_refs(self.base)
        except ValueError:
            self.fail(rule, f"base {self.base} is not in the checkout")
            return
        known: dict[str, set[frozenset]] = {}
        for _, _, repo, tag, _, _ in before:
            known.setdefault(repo, set()).add(image_variant(tag))
        for rel, n, repo, tag, allowed, _ in self.image_refs():
            v = image_variant(tag)
            if repo not in known or v in known[repo] or allowed:
                continue
            if any(b <= v and is_lighter(v - b) for b in known[repo]):
                continue
            was = " or ".join(sorted("-".join(sorted(b)) or "none" for b in known[repo]))
            self.fail(rule, f"{rel}:{n}: {repo} changes tag variant to {'-'.join(sorted(v)) or 'none'} "
                            f"(base: {was}); keep it or add `# image-policy: allow <reason>`")

    def rule_image_digest(self) -> None:
        rule = "image-digest"
        self.on(rule)
        for rel, n, repo, tag, allowed, pinned in self.image_refs():
            if not pinned and not allowed:
                self.fail(rule, f"{rel}:{n}: {repo}:{tag} has no digest; append @sha256:<index digest> "
                                "(`docker buildx imagetools inspect <image>`, the Digest line) "
                                "or add `# image-policy: allow <reason>`")

    def run(self) -> int:
        for rule in (self.rule_lan, self.rule_wan, self.rule_immich_db, self.rule_finalizer, self.rule_pvc,
                     self.rule_exclude_annotation, self.rule_wildcard_routes, self.rule_route_headers,
                     self.rule_cronjobs,
                     self.rule_root_profiles, self.rule_bootstrap_chart_versions, self.rule_cnpg_backup,
                     self.rule_backup_bucket_lock, self.rule_kiro_tracked,
                     self.rule_expected_ingresses, self.rule_k8s_version, self.rule_image_bulky,
                     self.rule_image_variant, self.rule_image_digest):
            rule()
        for f in self.fails:
            print(f)
        print(f"repo-policy: {len(self.active)} rule(s) active ({', '.join(self.active) or 'none'}), "
              f"{len(self.fails)} failure(s)")
        return 1 if self.fails else 0


def hcl_blocks(text: str, header: str) -> list[str]:
    """Bodies of the top-level blocks of `text` whose header matches `header` (`name "label" ... {`).

    Braces are counted outside comments and strings; `${...}` inside a string
    is balanced, so it needs no special case."""
    out, depth, i, n = [], 0, 0, len(text)
    head = re.compile(r"(?:^|(?<=\s))" + header + r"\s*\{")
    while i < n:
        c = text[i]
        if c == "#" or text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
            continue
        if text.startswith("/*", i):
            i = text.find("*/", i)
            i = n if i < 0 else i + 2
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if depth == 0:
            m = head.match(text, i)
            if m:
                body_start = m.end()
                j, d = body_start, 1
                while j < n and d:
                    if text[j] == '"':
                        k = j + 1
                        while k < n and text[k] != '"':
                            k += 2 if text[k] == "\\" else 1
                        j = k + 1
                        continue
                    if text[j] == "#":
                        k = text.find("\n", j)
                        j = n if k < 0 else k
                        continue
                    d += {"{": 1, "}": -1}.get(text[j], 0)
                    j += 1
                out.append(text[body_start:j - 1])
                i = j
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return out


def hcl_block(text: str, header: str) -> str | None:
    """The body of the one top-level block matching `header`, else None."""
    blocks = hcl_blocks(text, header)
    return blocks[0] if len(blocks) == 1 else None


def hcl_strings(body: str, attr: str) -> list[str] | None:
    """String items of `attr = [...]` or `attr = "..."` in a block body, else None."""
    m = re.search(r"^\s*" + attr + r"\s*=\s*(\[[^\]]*\]|\"[^\"]*\")", body, re.M)
    return re.findall(r'"([^"]*)"', m.group(1)) if m else None


def lock_statement(stmt: str) -> bool:
    """A bucket-policy statement that keeps every version: Deny LOCK_ACTIONS to principal * on the bucket and its
    objects, without a condition."""
    if hcl_strings(stmt, "effect") != ["Deny"] or hcl_blocks(stmt, "condition"):
        return False
    if not LOCK_ACTIONS <= set(hcl_strings(stmt, "actions") or []):
        return False
    resources = re.search(r"^\s*resources\s*=\s*\[(.*?)\]", stmt, re.M | re.S)
    if not resources or not re.search(r"(?:^|[\s,])aws_s3_bucket\.backups\.arn\s*(?:,|$)", resources.group(1), re.M) \
            or '"${aws_s3_bucket.backups.arn}/*"' not in resources.group(1):
        return False
    return any(hcl_strings(p, "type") == ["*"] and hcl_strings(p, "identifiers") == ["*"]
               for p in hcl_blocks(stmt, "principals"))


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


def parse_image(ref: str) -> tuple[str, str] | None:
    """(repository, tag) of an image reference, Docker Hub names without docker.io/ and library/; None if untagged."""
    ref = ref.split("@", 1)[0]
    head, _, last = ref.rpartition("/")
    if ":" not in last:
        return None
    name, tag = last.split(":", 1)
    repo = f"{head}/{name}" if head else name
    for prefix in ("docker.io/", "index.docker.io/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix):]
    if repo.startswith("library/"):
        repo = repo[len("library/"):]
    return repo, tag


def image_variant(tag: str) -> frozenset:
    """Variant words in a tag: python:3.14.8-alpine3.24 -> {alpine}, debian:bookworm-slim -> {bookworm, slim}."""
    return frozenset(w for w in (re.sub(r"\d+", "", t) for t in re.split(r"[-_.]", tag.lower()))
                     if w in VARIANT_WORDS)


def is_lighter(added: frozenset) -> bool:
    """Variant words added to a tag only make it lighter: a light variant, optionally with its distro codename."""
    return added <= LIGHT_VARIANTS | CODENAMES and bool(added & LIGHT_VARIANTS)


def k8s_minor(version: str) -> tuple[str, str] | None:
    """('1', '37') for 1.37, 1.37.1 or v1.37.1; None for anything else."""
    m = K8S_MINOR.match(version.strip())
    return (m.group(1), m.group(2)) if m else None


def wal_archiver(cluster: dict) -> dict | None:
    """The Barman Cloud plugin entry of a CNPG Cluster when it is the WAL archiver, else None."""
    for p in (cluster.get("spec") or {}).get("plugins") or []:
        if p.get("name") == CNPG_PLUGIN and p.get("isWALArchiver") is True:
            return p
    return None


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
    ap.add_argument("--base", help="git revision the image-variant rule compares against (the PR base)")
    ap.add_argument("--pr-title", default="", help="pull request title; a revert skips image-variant")
    ap.add_argument("--pr-branch", default="", help="pull request head branch; auto-revert/* skips image-variant")
    args = ap.parse_args(argv)
    return Policy(Path(args.repo_root).resolve(), Path(args.render).resolve(), args.base,
                  args.pr_title, args.pr_branch).run()


if __name__ == "__main__":
    sys.exit(main())
