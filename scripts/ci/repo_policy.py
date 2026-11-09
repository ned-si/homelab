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
  pod-hardening         every container of every rendered pod template meets the
                        checks of spec per-app-hardening or has a line in
                        ci/pod-hardening-gaps.txt (`<ns>/<kind>/<name>/<container>
                        <check> <reason>`, `*` as container for token). In
                        APP_NAMESPACES: probes (long-running containers),
                        seccomp, privilege-escalation, capabilities (drop ALL;
                        add only NET_BIND_SERVICE, or root-profile ones with a
                        non-root line), non-root. In every namespace outside
                        EXCLUDED_NAMESPACES of scripts/ci/kyverno.sh: token (a
                        Pod of the default ServiceAccount, or in APP_NAMESPACES
                        of an unbound one, sets automountServiceAccountToken:
                        false) and no binding grants a default ServiceAccount.
                        A stale, malformed or duplicate line fails, and so does
                        an Application under clusters/homelab/apps/ whose
                        namespace is not in APP_NAMESPACES
  cronjob-suspended / cronjob-guard / guard-modes / cronjob-active
                        new-layout CronJobs rendered from the apps and platform
                        layers are suspended, unless listed in
                        ci/active-cronjobs.txt, which must set `suspend: false`
                        and skip the guard; every list entry must be rendered.
                        All other CronJobs but ci/non-backup-cronjobs.txt are
                        guarded (initContainers[0] pending-guard, see
                        check_guard); ci/guard-modes.txt entries exist and use a
                        known mode
  restic-locks          every CronJob with a RESTIC_REPOSITORY sets
                        failedJobsHistoryLimit >= 1; in every rendered CronJob
                        command and ConfigMap script, `restic backup|check|forget|
                        prune|ls` carries --retry-lock on its line (or --no-lock),
                        `check`/`forget`/`prune` follow a `restic unlock` (or a
                        forget/prune), `backup` comes after one, and no unlock
                        uses --remove-all (docs/backups.md#locks)
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
  cilium-explicit-xds   infrastructure/cilium/values.yaml sets envoy.xdsMode: a
                        chart default change cannot leave the agent and Envoy on
                        different xDS modes (postmortem 2026-10-23)
  appproject-kinds      every object rendered by an Application of a rendered
                        AppProject is permitted by that project, as Argo CD
                        checks it at sync: a cluster-scoped kind is in
                        clusterResourceWhitelist (and not in its blacklist), a
                        namespaced kind passes namespaceResourceWhitelist /
                        Blacklist, and the Application's and every namespaced
                        object's namespace match a project destination (#820).
                        Scope comes from the built-in kinds, the rendered CRDs
                        and ci/crd-scopes.txt (CRDs an operator installs at
                        runtime); a kind none of them knows fails, and so does a
                        stale or contradicted list entry
  monitor-selected      every ServiceMonitor, PodMonitor, Probe and PrometheusRule
                        rendered carries release: kube-prometheus-stack, the label
                        Prometheus selects them by (unlabelled, Tetragon, Immich
                        and the CNPG operator were never scraped, 2026-10-26)
  spec-lifecycle        every .kiro/specs/<name>/requirements.md starts with a
                        header: kind change (status active or done) or area
                        (status living), a created date; done has a closed date
                        and no unticked task, living no unticked task, active an
                        issue; .kiro/specs/README.md links every spec
  pentest-roe           once docs/pentest/ exists: docs/pentest/README.md,
                        scope.yaml and scripts/pentest-scope-check.sh exist,
                        repo-policy.sh runs the scope check, and the README has
                        the sections of PENTEST_ROE_SECTIONS naming their terms
                        (banned credentials, setup credentials, the window, the
                        big-change paths) and a Tooling row with purpose,
                        availability and source for every PENTEST_TOOLS entry
  pentest-reports       once docs/pentest/ exists: docs/pentest/template.md has the
                        PENTEST_REPORT_SECTIONS; every other file at the top of
                        docs/pentest/ is README.md, scope.yaml or a report
                        <YYYY-MM-DD>-<pass>.md with those sections, a draft
                        advisory link, and findings rows with a severity, each
                        withheld row linking its issue
  pentest-runbooks      once docs/pentest/ exists: every PENTEST_RUNBOOKS runbook
                        names its boundary and terms; pentest-external.yaml is
                        workflow_dispatch only, checks the window in its first
                        step, uploads SARIF and no plaintext artifact;
                        pentest-schedule.yaml, when present, runs no scanner
  expected-ingresses    every <ns>/<name> in ci/expected-ingresses.txt is rendered
                        by the new layout
  alert-tests           every alert of a PrometheusRule under platform/ or apps/
                        is the alertname of an alert_rule_test in
                        tests/prometheus/*_test.yaml
  alert-runbooks        every `action: human` alert of a PrometheusRule under
                        platform/ or apps/ has annotation runbook_url
                        https://github.com/ned-si/homelab/blob/main/docs/runbooks/alerts/<alert>.md,
                        that file exists and docs/runbooks/alerts/README.md
                        links it; every other .md there names such an alert; an
                        `action: auto` alert with a runbook_url follows the same
                        form; every other alert on an `ntfy` line of
                        tests/alertmanager/routes.txt (but `category=security`)
                        is named in backticks in the README
  backup-slo-targets    the slo:backup_target:info records of
                        platform/kube-prometheus-stack/routes/backup-slo-targets.yaml
                        are exactly the ci/active-cronjobs.txt entries whose
                        name contains `-backup`
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
from fnmatch import fnmatchcase
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_profiles  # noqa: E402

# Built from parts so this file does not trip its own literal rules.
LAN_GONE = "192.168." + "2."
EXCLUDE_ANN = "external-dns.alpha.kubernetes.io/" + "exclude"
CONTROLLER_ANN = "external-dns.alpha.kubernetes.io/controller"
MONITOR_KINDS = {"ServiceMonitor", "PodMonitor", "Probe", "PrometheusRule"}
# Kubernetes API groups served by the apiserver itself; any other group needs a CRD.
BUILTIN_GROUPS = {"", "admissionregistration.k8s.io", "apiextensions.k8s.io", "apiregistration.k8s.io", "apps",
                  "authentication.k8s.io", "authorization.k8s.io", "autoscaling", "batch", "certificates.k8s.io",
                  "coordination.k8s.io", "discovery.k8s.io", "events.k8s.io", "flowcontrol.apiserver.k8s.io",
                  "internal.apiserver.k8s.io", "networking.k8s.io", "node.k8s.io", "policy",
                  "rbac.authorization.k8s.io", "resource.k8s.io", "scheduling.k8s.io", "storage.k8s.io",
                  "storagemigration.k8s.io"}
# The cluster-scoped kinds of those groups; every other built-in kind is namespaced.
BUILTIN_CLUSTER_KINDS = {
    ("", "Namespace"), ("", "Node"), ("", "PersistentVolume"), ("", "ComponentStatus"),
    ("admissionregistration.k8s.io", "MutatingWebhookConfiguration"),
    ("admissionregistration.k8s.io", "ValidatingWebhookConfiguration"),
    ("admissionregistration.k8s.io", "ValidatingAdmissionPolicy"),
    ("admissionregistration.k8s.io", "ValidatingAdmissionPolicyBinding"),
    ("admissionregistration.k8s.io", "MutatingAdmissionPolicy"),
    ("admissionregistration.k8s.io", "MutatingAdmissionPolicyBinding"),
    ("apiextensions.k8s.io", "CustomResourceDefinition"), ("apiregistration.k8s.io", "APIService"),
    ("authentication.k8s.io", "TokenReview"), ("authentication.k8s.io", "SelfSubjectReview"),
    ("authorization.k8s.io", "SubjectAccessReview"), ("authorization.k8s.io", "SelfSubjectAccessReview"),
    ("authorization.k8s.io", "SelfSubjectRulesReview"),
    ("certificates.k8s.io", "CertificateSigningRequest"), ("certificates.k8s.io", "ClusterTrustBundle"),
    ("flowcontrol.apiserver.k8s.io", "FlowSchema"), ("flowcontrol.apiserver.k8s.io", "PriorityLevelConfiguration"),
    ("internal.apiserver.k8s.io", "StorageVersion"),
    ("networking.k8s.io", "IngressClass"), ("networking.k8s.io", "IPAddress"), ("networking.k8s.io", "ServiceCIDR"),
    ("node.k8s.io", "RuntimeClass"),
    ("rbac.authorization.k8s.io", "ClusterRole"), ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    ("resource.k8s.io", "DeviceClass"), ("resource.k8s.io", "ResourceSlice"), ("resource.k8s.io", "DeviceTaintRule"),
    ("scheduling.k8s.io", "PriorityClass"),
    ("storage.k8s.io", "CSIDriver"), ("storage.k8s.io", "CSINode"), ("storage.k8s.io", "StorageClass"),
    ("storage.k8s.io", "VolumeAttachment"), ("storage.k8s.io", "VolumeAttributesClass"),
    ("storagemigration.k8s.io", "StorageVersionMigration"),
}
CRD_SCOPES = "ci/crd-scopes.txt"
DEFAULT_SERVER = "https://kubernetes.default.svc"
PROM_RELEASE = "kube-prometheus-stack"
SPEC_STATES = {("change", "active"), ("change", "done"), ("area", "living")}
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
CILIUM_VALUES = "infrastructure/cilium/values.yaml"
# What the backup bucket policy must deny to everyone (docs/backups.md#immutable-versions).
LOCK_ACTIONS = {"s3:DeleteObjectVersion", "s3:PutBucketVersioning", "s3:DeleteBucket"}
CI_WORKFLOW = ".github/workflows/ci.yaml"
# Pentest rules of engagement (spec pentest-programme, Requirements 1, 4, 5, 7).
PENTEST_DIR = "docs/pentest/"
PENTEST_README = "docs/pentest/README.md"
PENTEST_SCOPE = "docs/pentest/scope.yaml"
PENTEST_SCOPE_CHECK = "scripts/pentest-scope-check.sh"
# Paths whose change calls for an out-of-cycle run (Requirement 7.1).
PENTEST_BIG_CHANGE_PATHS = ("deploy/**/httproute-*.yaml", "deploy/**/gateway-*.yaml", "platform/keycloak/**",
                            "bootstrap/tailscale/**", "infrastructure/network-policies/**", "talos/**")
PENTEST_ROE_SECTIONS = {
    "Authorisation": ("#718", "scope.yaml"),
    "Runner": ("agent",),
    "Passes": ("External", "LAN", "pod", "Stolen session"),
    "Scope": ("scope.yaml", "--default-targets"),
    "Guardrails": ("`os:admin`", "admin kubeconfig", "BMC login", "Keycloak admin", "Tailscale admin",
                   "Cloudflare API token", "`gh` session", "AWS and NAS admin keys", "immich-data",
                   "backup bucket", "Rate-limit", "`pentest-setup`", "automation client", "OAuth client",
                   "GitHub App"),
    "Window": ("Monday to Friday", "09:00–16:59", "Europe/Zurich"),
    "Schedule": ("quarter", "`GITHUB_TOKEN`") + tuple(f"`{p}`" for p in PENTEST_BIG_CHANGE_PATHS),
    "Report flow": ("advisory", "never published", "docs/pentest/<date>-<pass>.md"),
    "Tooling": (),
}
PENTEST_TOOLS = ("scripts/tls-check.sh", "scripts/dast-zap.sh", "nmap", "testssl.sh", "nuclei", "kube-bench",
                 "trivy", "gitleaks", "kubectl auth can-i")
# Pentest reports (spec pentest-programme, Requirement 6).
PENTEST_TEMPLATE = "docs/pentest/template.md"
PENTEST_REPORT = re.compile(r"docs/pentest/\d{4}-\d{2}-\d{2}-(external|internal-lan|internal-pod|stolen-session)\.md")
PENTEST_REPORT_SECTIONS = ("Scope", "Tools", "Findings", "Not reached", "Alerts", "Teardown")
PENTEST_SEVERITIES = ("critical", "high", "medium", "low", "info")
PENTEST_ADVISORY = re.compile(r"https://github\.com/ned-si/homelab/security/advisories/GHSA(-[0-9a-z]{4}){3}")
PENTEST_ISSUE = re.compile(r"#\d+|/issues/\d+")
# Pentest runbooks and the external workflow (spec pentest-programme,
# Requirements 2 and 3). Each runbook names its boundary and the terms its
# requirement asks for; tasks 3 and 4 add theirs.
PENTEST_RUNBOOKS = {
    "docs/pentest/runbooks/external.md": (
        "Boundary:", "Internet to the Gateway", "80 and 443", "22000", "50000", "`scripts/tls-check.sh`",
        "`dast.yaml`", "`full_scan: true`", "`pentest-family`", "pentest-external.yaml", "GitHub-hosted runner"),
    "docs/pentest/runbooks/internal.md": (
        "Boundary:", "The LAN", "50000", "192.168.1.11:6443", "192.168.1.228", "BMC", "`pentest-pod`",
        "`theater`", "`pods/log`", "Kyverno", "the tailnet", "Keycloak"),
    "docs/pentest/runbooks/stolen-session.md": (
        "Boundary:", "The phone over a VPN", "`tag:pentest`", "`pentest-family`", "`household`",
        "never as the Mac's Tailscale client", "Revoke the Keycloak session", "Revoke the device"),
}
PENTEST_EXTERNAL_WORKFLOW = ".github/workflows/pentest-external.yaml"
PENTEST_SCHEDULE_WORKFLOW = ".github/workflows/pentest-schedule.yaml"
PENTEST_SCANNERS = ("nmap", "nuclei", "testssl", "zap", "docker run")
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
# The SELinux label of every iSCSI volume (docs/decisions.md, SELinux labels on CSI volumes).
ISCSI_PROVISIONER = "org.democratic-csi.iscsi"
ISCSI_SELINUX_OPTION = "context=system_u:object_r:ephemeral_t:s0"
# Pod Security levels, loosest first, and the file that sets them per namespace.
PSS_LEVELS = ("privileged", "baseline", "restricted")
NAMESPACES_FILE = "infrastructure/namespaces/namespaces.yaml"
# Homelab alert rules (docs/sre.md, Paging) and their promtool unit tests.
RULE_DIRS = ("platform/", "apps/")
PROMTOOL_TESTS = "tests/prometheus"
# Every paging alert links its runbook on main (docs/runbooks/alerts/README.md).
RUNBOOK_DIR = "docs/runbooks/alerts"
RUNBOOK_BASE = "https://github.com/ned-si/homelab/blob/main/" + RUNBOOK_DIR + "/"
AM_ROUTES = "tests/alertmanager/routes.txt"
# The restic CronJobs the backup-freshness SLO watches (docs/sre.md, RPO).
BACKUP_SLO_TARGETS = "platform/kube-prometheus-stack/routes/backup-slo-targets.yaml"
# restic lock handling (docs/backups.md#locks): commands that take a lock, and
# those whose lock is exclusive.
RESTIC_CMD = re.compile(r"(?:^|\$\()restic\s+([a-z]+)\b")
RESTIC_LOCKING = {"backup", "check", "forget", "prune", "ls"}
RESTIC_EXCLUSIVE = {"check", "forget", "prune"}
# pod-hardening (spec per-app-hardening): checks 1 to 5 run in these namespaces,
# check 6 (token) in every namespace the Kyverno webhooks do not exclude.
APP_NAMESPACES = ("books", "home", "immich", "keycloak", "mealie", "paperless", "syncthing", "theater")
APPS_DIR = "clusters/homelab/apps"
POD_GAPS = "ci/pod-hardening-gaps.txt"
KYVERNO_SH = "scripts/ci/kyverno.sh"
HARDENING_CHECKS = ("probes", "seccomp", "privilege-escalation", "capabilities", "non-root", "token")
# Capabilities a root-profile container (one with a non-root gap) may add back.
ROOT_CAPS = {"CHOWN", "DAC_OVERRIDE", "FOWNER", "KILL", "SETGID", "SETUID"}
LONG_RUNNING_KINDS = {"Deployment", "StatefulSet", "DaemonSet"}
GAP_REF = re.compile(r"^[a-z0-9-]+/[A-Za-z]+/[a-z0-9.-]+/(?:[a-z0-9.-]+|\*)$")


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

    @staticmethod
    def group_of(doc: dict) -> str:
        """API group of a manifest: postgresql.cnpg.io for postgresql.cnpg.io/v1, "" for the core group (v1)."""
        group, sep, _ = str(doc.get("apiVersion", "")).partition("/")
        return group if sep else ""

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
                if d.get("kind") == "Cluster" and self.group_of(d) == "postgresql.cnpg.io" \
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
                        or self.group_of(d) != "postgresql.cnpg.io":
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

    def rule_iscsi_selinux_label(self) -> None:
        # Talos cannot label a volume a CSI driver mounts; the StorageClass's
        # context= mount option does (docs/decisions.md, SELinux labels on CSI
        # volumes). Every iSCSI class must carry it.
        rule = "iscsi-selinux-label"
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") != "StorageClass" or d.get("provisioner") != ISCSI_PROVISIONER:
                    continue
                self.on(rule)
                if ISCSI_SELINUX_OPTION not in (d.get("mountOptions") or []):
                    self.fail(rule, f"{e['app']}: StorageClass {self.name_of(d)} lacks the mount option "
                                    f"{ISCSI_SELINUX_OPTION}")

    def rule_pod_security_labels(self) -> None:
        # Every namespace states its Pod Security level in git, so a rebuild
        # elsewhere enforces the same (spec pod-security-restricted, req. 4).
        rule = "pod-security-labels"
        path = self.root / NAMESPACES_FILE
        if not path.is_file():
            return
        self.on(rule)
        for d in yaml_file_docs(path):
            if d.get("kind") != "Namespace":
                continue
            labels = (d.get("metadata") or {}).get("labels") or {}
            got = {m: labels.get(f"pod-security.kubernetes.io/{m}") for m in ("enforce", "warn", "audit")}
            bad = [f"{m}={v}" for m, v in got.items() if v not in PSS_LEVELS]
            if bad:
                self.fail(rule, f"{NAMESPACES_FILE}: Namespace {self.name_of(d)} needs a level for "
                                f"{', '.join(bad)}")
                continue
            for m in ("warn", "audit"):
                if PSS_LEVELS.index(got[m]) < PSS_LEVELS.index(got["enforce"]):
                    self.fail(rule, f"{NAMESPACES_FILE}: Namespace {self.name_of(d)}: {m} {got[m]} is looser "
                                    f"than enforce {got['enforce']}")

    def rule_pod_hardening(self) -> None:
        # Spec per-app-hardening, requirement 1: every gap of a pod template is
        # listed in ci/pod-hardening-gaps.txt, and every line there is a gap.
        rule = "pod-hardening"
        gaps_path = self.root / POD_GAPS
        if not (gaps_path.is_file() or (self.root / KYVERNO_SH).is_file()):
            return
        self.on(rule)
        excluded: set[str] = set()
        if (self.root / KYVERNO_SH).is_file():
            m = re.search(r'^EXCLUDED_NAMESPACES="([^"]*)"', (self.root / KYVERNO_SH).read_text(), re.M)
            if not m:
                self.fail(rule, f'{KYVERNO_SH}: no EXCLUDED_NAMESPACES="..." line')
                return
            excluded = set(m.group(1).split())
        apps_dir = self.root / APPS_DIR
        for f in sorted(apps_dir.glob("*.y*ml")) if apps_dir.is_dir() else []:
            for d in yaml_file_docs(f):
                if d.get("kind") != "Application":
                    continue
                ns = str(((d.get("spec") or {}).get("destination") or {}).get("namespace") or "")
                if ns not in APP_NAMESPACES:
                    self.fail(rule, f"{self.name_of(d)}: namespace {ns or '(none)'} is not in APP_NAMESPACES; add it")

        pods: dict[str, tuple[str, str, dict]] = {}  # <ns>/<kind>/<name> -> (ns, kind, pod spec)
        bound: set[tuple[str, str]] = set()
        for e in self.entries():
            for d in self.docs_of(e):
                kind = d.get("kind")
                if kind in ("RoleBinding", "ClusterRoleBinding") and self.group_of(d) == "rbac.authorization.k8s.io":
                    own_ns = (d.get("metadata") or {}).get("namespace") or e.get("namespace")
                    for s in d.get("subjects") or []:
                        if s.get("kind") != "ServiceAccount":
                            continue
                        sns = s.get("namespace") or (own_ns if kind == "RoleBinding" else None)
                        if not sns:
                            continue
                        bound.add((sns, str(s.get("name"))))
                        if s.get("name") == "default" and sns not in excluded:
                            where = f"{kind} {own_ns + '/' if kind == 'RoleBinding' and own_ns else ''}{self.name_of(d)}"
                            self.fail(rule, f"{where} grants {sns}/default; give the Pod its own ServiceAccount")
                    continue
                pod = pod_spec_of(d)
                if pod is None:
                    continue
                ns = self.ns_of(d, e)
                pods.setdefault(f"{ns}/{kind}/{self.name_of(d)}", (ns, str(kind), pod))
        if not pods:
            return
        if not gaps_path.is_file():
            self.fail(rule, f"{POD_GAPS} not found; refusing to pass")
            return

        listed: dict[tuple[str, str], int] = {}
        for n, raw in enumerate(gaps_path.read_text().splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 2)
            where = f"{POD_GAPS}:{n}"
            if len(parts) < 3:
                self.fail(rule, f"{where}: malformed line (want: <namespace>/<kind>/<name>/<container> <check> "
                                "<reason>)")
                continue
            ref, check = parts[0], parts[1]
            if not GAP_REF.match(ref):
                self.fail(rule, f"{where}: malformed reference {ref} (want <namespace>/<kind>/<name>/<container>)")
                continue
            if check not in HARDENING_CHECKS:
                self.fail(rule, f"{where}: unknown check {check} (one of {', '.join(HARDENING_CHECKS)})")
                continue
            if (check == "token") != ref.endswith("/*"):
                self.fail(rule, f"{where}: {check} takes " + ("* as container" if check == "token"
                                                              else "a container name, not *"))
                continue
            if (ref, check) in listed:
                self.fail(rule, f"{where}: duplicate of line {listed[(ref, check)]}")
                continue
            listed[(ref, check)] = n

        found: dict[tuple[str, str], str] = {}
        for key, (ns, kind, pod) in sorted(pods.items()):
            sa = pod.get("serviceAccountName") or pod.get("serviceAccount") or "default"
            if ns not in excluded and pod.get("automountServiceAccountToken") is not False:
                if sa == "default":
                    found[(f"{key}/*", "token")] = "runs as ServiceAccount default with its token mounted"
                elif ns in APP_NAMESPACES and (ns, sa) not in bound:
                    found[(f"{key}/*", "token")] = (f"ServiceAccount {sa} is named by no RoleBinding or "
                                                    "ClusterRoleBinding and its token is mounted")
            if ns not in APP_NAMESPACES:
                continue
            psc = pod.get("securityContext") or {}
            sidecars = [c for c in pod.get("initContainers") or [] if c.get("restartPolicy") == "Always"]
            long_running = {c.get("name") for c in (pod.get("containers") or []) + sidecars} \
                if kind in LONG_RUNNING_KINDS else set()
            for c in (pod.get("initContainers") or []) + (pod.get("containers") or []):
                ref = f"{key}/{c.get('name')}"
                csc = c.get("securityContext") or {}
                if c.get("name") in long_running:
                    missing = [p for p in ("readinessProbe", "livenessProbe") if not c.get(p)]
                    if missing:
                        found[(ref, "probes")] = "no " + ", no ".join(missing)
                seccomp = (csc.get("seccompProfile") if "seccompProfile" in csc
                           else psc.get("seccompProfile")) or {}
                if seccomp.get("type") not in ("RuntimeDefault", "Localhost"):
                    found[(ref, "seccomp")] = f"seccompProfile.type is {seccomp.get('type') or 'unset'}"
                if csc.get("allowPrivilegeEscalation") is not False:
                    found[(ref, "privilege-escalation")] = "allowPrivilegeEscalation is not false"
                non_root = csc["runAsNonRoot"] if "runAsNonRoot" in csc else psc.get("runAsNonRoot")
                if non_root is not True:
                    found[(ref, "non-root")] = "runAsNonRoot is not true"
                allowed = {"NET_BIND_SERVICE"}
                if (ref, "non-root") in found and (ref, "non-root") in listed:
                    allowed |= ROOT_CAPS
                caps = csc.get("capabilities") or {}
                problems = [] if "ALL" in (caps.get("drop") or []) else ["drop lacks ALL"]
                extra = sorted(set(caps.get("add") or []) - allowed)
                if extra:
                    problems.append(f"add has {', '.join(extra)}")
                if problems:
                    found[(ref, "capabilities")] = "capabilities." + ", ".join(problems)

        for (ref, check), what in sorted(found.items()):
            if (ref, check) not in listed:
                self.fail(rule, f'{ref} fails {check} ({what}); fix it or add "{ref} {check} <reason>" to {POD_GAPS}')
        for (ref, check), n in sorted(listed.items(), key=lambda x: x[1]):
            if (ref, check) not in found:
                self.fail(rule, f"{POD_GAPS}:{n}: {ref} {check} is no longer a gap; remove the line")

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

    def rule_restic_locks(self) -> None:
        rule = "restic-locks"
        for e in self.entries():
            for d in self.docs_of(e):
                kind = d.get("kind")
                where = f"{e['app']}: {kind} {self.ns_of(d, e)}/{self.name_of(d)}"
                texts = []
                if kind == "ConfigMap":
                    texts = [(f"{where} key {k}", v) for k, v in sorted((d.get("data") or {}).items())
                             if isinstance(v, str)]
                elif kind == "CronJob":
                    spec = d.get("spec") or {}
                    pod = (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
                    containers = pod.get("containers") or []
                    if any("RESTIC_REPOSITORY" in {v.get("name") for v in c.get("env") or []} for c in containers):
                        self.on(rule)
                        limit = spec.get("failedJobsHistoryLimit")
                        if not isinstance(limit, int) or limit < 1:
                            self.fail(rule, f"{where}: failedJobsHistoryLimit is not at least 1")
                    for c in (pod.get("initContainers") or []) + containers:
                        words = [str(x) for x in (c.get("command") or []) + (c.get("args") or [])]
                        texts.append((f"{where} container {c.get('name')}", "\n".join(words)))
                for label, text in texts:
                    problems = check_restic_locks(text)
                    if problems or RESTIC_CMD.search(text):
                        self.on(rule)
                    for p in problems:
                        self.fail(rule, f"{label}: {p}")

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
                group, kind = self.group_of(d), d.get("kind")
                ns = self.ns_of(d, e)
                if group == "barmancloud.cnpg.io" and kind == "ObjectStore":
                    stores.add((ns, self.name_of(d)))
                if group != "postgresql.cnpg.io":
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

    def rule_cilium_explicit_xds(self) -> None:
        rule = "cilium-explicit-xds"
        values = self.root / CILIUM_VALUES
        if not values.is_file():
            return
        self.on(rule)
        envoy = re.search(r"^envoy:\n((?:[ #].*\n|\n)*)", values.read_text(), re.M)
        if not envoy or not re.search(r"^  xdsMode: \S+", envoy.group(1), re.M):
            self.fail(rule, f"{CILIUM_VALUES}: set envoy.xdsMode explicitly (the chart default changed in 1.20.4)")

    def rule_monitor_selected(self) -> None:
        rule = "monitor-selected"
        for e in self.entries():
            for d in self.docs_of(e):
                if d.get("kind") not in MONITOR_KINDS:
                    continue
                self.on(rule)
                if ((d.get("metadata") or {}).get("labels") or {}).get("release") != PROM_RELEASE:
                    self.fail(rule, f"{e['app']}: {d.get('kind')} {self.ns_of(d, e)}/{self.name_of(d)} has no label "
                                    f"release: {PROM_RELEASE}, so Prometheus ignores it")

    def rule_appproject_kinds(self) -> None:
        rule = "appproject-kinds"
        projects: dict[str, dict] = {}
        apps: dict[str, dict] = {}
        crds: dict[tuple[str, str], str] = {}
        for e in self.entries():
            for d in self.docs_of(e):
                group, kind = self.group_of(d), d.get("kind")
                if group == "argoproj.io" and kind == "AppProject":
                    projects[self.name_of(d)] = d.get("spec") or {}
                elif group == "argoproj.io" and kind == "Application":
                    apps[self.name_of(d)] = d.get("spec") or {}
                elif group == "apiextensions.k8s.io" and kind == "CustomResourceDefinition":
                    s = d.get("spec") or {}
                    crds[(str(s.get("group") or ""), str((s.get("names") or {}).get("kind") or ""))] = \
                        str(s.get("scope") or "")
        if not projects:
            return
        self.on(rule)
        listed: dict[tuple[str, str], str] = {}
        for ln in self.read_list(CRD_SCOPES) or []:
            parts = ln.split("#", 1)[0].split()
            if len(parts) != 3 or parts[2] not in ("Cluster", "Namespaced"):
                self.fail(rule, f"{CRD_SCOPES}: malformed line '{ln}' (want: <group> <Kind> Cluster|Namespaced)")
                continue
            listed[(parts[0], parts[1])] = parts[2]
        used: set[tuple[str, str]] = set()

        def scope(gk: tuple[str, str]) -> str | None:
            if gk[0] in BUILTIN_GROUPS:
                return "Cluster" if gk in BUILTIN_CLUSTER_KINDS else "Namespaced"
            if gk in crds:
                return crds[gk]
            if gk in listed:
                used.add(gk)
                return listed[gk]
            return None

        for e in self.entries():
            spec = apps.get(e["app"])
            if spec is None:
                continue
            pname = spec.get("project") or "default"
            proj = projects.get(pname)
            if proj is None:
                continue
            dest = spec.get("destination") or {}
            app_ns = str(dest.get("namespace") or "")
            where = f"{e['app']} (project {pname})"
            if not destination_permitted(proj, dest, app_ns):
                self.fail(rule, f"{where}: destination namespace {app_ns or '(none)'} is not in the AppProject "
                                "destinations")
            bad_kinds: dict[tuple[str, str, str, str], list[str]] = {}
            bad_ns: dict[str, list[str]] = {}
            for d in self.docs_of(e):
                gk = (self.group_of(d), str(d.get("kind") or ""))
                sc = scope(gk)
                if sc is None:
                    bad_kinds.setdefault((*gk, "unknown", ""), []).append(self.name_of(d))
                    continue
                if not kind_permitted(proj, gk, sc == "Namespaced"):
                    prefix = "cluster" if sc == "Cluster" else "namespace"
                    why = f"is in the AppProject {prefix}ResourceBlacklist" \
                        if in_resource_list(gk, proj.get(f"{prefix}ResourceBlacklist") or []) \
                        else f"is not in the AppProject {prefix}ResourceWhitelist"
                    bad_kinds.setdefault((*gk, sc, why), []).append(self.name_of(d))
                if sc == "Namespaced":
                    ns = str((d.get("metadata") or {}).get("namespace") or app_ns)
                    if ns and not destination_permitted(proj, dest, ns):
                        bad_ns.setdefault(ns, []).append(f"{gk[1]} {self.name_of(d)}")
            for (group, kind, sc, why), names in sorted(bad_kinds.items()):
                label = f"{group or 'core'}/{kind}"
                objs = f"{names[0]}" + (f" and {len(names) - 1} more" if len(names) > 1 else "")
                if sc == "unknown":
                    self.fail(rule, f"{where}: {label} ({objs}) has no known scope: no rendered CRD and no "
                                    f"{CRD_SCOPES} entry")
                else:
                    self.fail(rule, f"{where}: {'cluster-scoped' if sc == 'Cluster' else 'namespaced'} {label} "
                                    f"({objs}) {why}")
            for ns, objs in sorted(bad_ns.items()):
                more = f" and {len(objs) - 1} more" if len(objs) > 1 else ""
                self.fail(rule, f"{where}: namespace {ns} ({objs[0]}{more}) is not in the AppProject destinations")
        for gk, sc in sorted(listed.items()):
            name = f"{CRD_SCOPES}: {gk[0]} {gk[1]}"
            if gk in crds:
                self.fail(rule, f"{name} is a rendered CRD (scope {crds[gk]}); drop the entry")
            elif gk[0] in BUILTIN_GROUPS:
                self.fail(rule, f"{name} is a built-in group; drop the entry")
            elif gk not in used:
                self.fail(rule, f"{name} is not a rendered kind (stale entry)")

    def rule_spec_lifecycle(self) -> None:
        rule = "spec-lifecycle"
        specs = sorted({rel.split("/")[2] for rel in self.tracked()
                        if rel.startswith(".kiro/specs/") and rel.count("/") >= 3})
        if not specs:
            return
        self.on(rule)
        index = self.root / ".kiro/specs/README.md"
        index_text = index.read_text() if index.is_file() else ""
        for name in specs:
            where = f".kiro/specs/{name}"
            req = self.root / where / "requirements.md"
            m = re.match(r"---\n(.*?)\n---\n", req.read_text() if req.is_file() else "", re.S)
            if not m:
                self.fail(rule, f"{where}/requirements.md: no header (---, kind, status, created, ---)")
                continue
            head = dict(ln.split(":", 1) for ln in m.group(1).splitlines() if ":" in ln)
            head = {k.strip(): v.strip() for k, v in head.items()}
            kind, status = head.get("kind"), head.get("status")
            if (kind, status) not in SPEC_STATES:
                self.fail(rule, f"{where}: kind {kind!r} with status {status!r}; allowed: "
                                + ", ".join(f"{k} {s}" for k, s in sorted(SPEC_STATES)))
            for key in ("created",) + (("closed",) if status == "done" else ()):
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", head.get(key, "")):
                    self.fail(rule, f"{where}: {key} is not a YYYY-MM-DD date")
            if status == "active" and not re.fullmatch(r"\d+", head.get("issue", "")):
                self.fail(rule, f"{where}: an active spec names its issue (issue: <number>)")
            tasks = self.root / where / "tasks.md"
            if status in ("done", "living") and tasks.is_file():
                open_tasks = re.findall(r"^\s*- \[ \] (\S+)", tasks.read_text(), re.M)
                if open_tasks:
                    self.fail(rule, f"{where}: status {status} with unticked tasks {', '.join(open_tasks)} "
                                    "(tick them, or move them to an issue)")
            if f"]({name}/)" not in index_text:
                self.fail(rule, f".kiro/specs/README.md does not link {name}/")

    def rule_pentest_roe(self) -> None:
        rule = "pentest-roe"
        if not any(rel.startswith(PENTEST_DIR) for rel in self.tracked()):
            return
        self.on(rule)
        for rel in (PENTEST_README, PENTEST_SCOPE, PENTEST_SCOPE_CHECK):
            if not (self.root / rel).is_file():
                self.fail(rule, f"{rel} is missing")
        wrapper = self.root / "scripts/ci/repo-policy.sh"
        if wrapper.is_file() and PENTEST_SCOPE_CHECK not in wrapper.read_text():
            self.fail(rule, f"scripts/ci/repo-policy.sh does not run {PENTEST_SCOPE_CHECK}")
        readme = self.root / PENTEST_README
        if not readme.is_file():
            return
        sections: dict[str, str] = {}
        for part in re.split(r"^## ", readme.read_text(), flags=re.M)[1:]:
            title, _, body = part.partition("\n")
            sections[title.strip()] = body
        for title, needles in PENTEST_ROE_SECTIONS.items():
            if title not in sections:
                self.fail(rule, f"{PENTEST_README}: no section '## {title}'")
                continue
            for needle in needles:
                if needle not in sections[title]:
                    self.fail(rule, f"{PENTEST_README}: section '{title}' does not name {needle!r}")
        tooling = sections.get("Tooling", "")
        rows = {}
        for line in tooling.splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("|") else []
            if len(cells) >= 4 and not set(cells[0]) <= {"-", " "} and cells[0] != "Tool":
                rows[cells[0]] = cells
        for tool in PENTEST_TOOLS:
            row = next((c for name, c in rows.items() if f"`{tool}`" in name), None)
            if row is None:
                self.fail(rule, f"{PENTEST_README}: Tooling lists no `{tool}`")
            elif len(row) != 4 or not row[2] or row[3] not in ("in repo", "new"):
                self.fail(rule, f"{PENTEST_README}: Tooling row `{tool}` needs purpose, availability "
                                "and source (in repo or new)")

    def rule_pentest_reports(self) -> None:
        rule = "pentest-reports"
        tracked = [rel for rel in self.tracked() if rel.startswith(PENTEST_DIR)]
        if not tracked:
            return
        self.on(rule)

        def sections(rel: str) -> dict[str, str] | None:
            path = self.root / rel
            if not path.is_file():
                self.fail(rule, f"{rel} is missing")
                return None
            found: dict[str, str] = {}
            for part in re.split(r"^## ", path.read_text(), flags=re.M)[1:]:
                title, _, body = part.partition("\n")
                found[title.strip()] = body
            for title in PENTEST_REPORT_SECTIONS:
                if title not in found:
                    self.fail(rule, f"{rel}: no section '## {title}'")
            return found

        sections(PENTEST_TEMPLATE)
        top = {rel for rel in tracked if "/" not in rel[len(PENTEST_DIR):]}
        for rel in sorted(top - {PENTEST_README, PENTEST_SCOPE, PENTEST_TEMPLATE}):
            if not PENTEST_REPORT.fullmatch(rel):
                self.fail(rule, f"{rel}: a report is named docs/pentest/<YYYY-MM-DD>-<pass>.md, "
                                "<pass> one of external, internal-lan, internal-pod, stolen-session")
                continue
            found = sections(rel)
            if found is None:
                continue
            if not PENTEST_ADVISORY.search((self.root / rel).read_text()):
                self.fail(rule, f"{rel}: no link to its draft advisory "
                                "(https://github.com/ned-si/homelab/security/advisories/GHSA-...)")
            for line in found.get("Findings", "").splitlines():
                cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("|") else []
                if len(cells) < 7 or cells[0] == "ID" or set(cells[0]) <= {"-", " "}:
                    continue
                if cells[2].lower() not in PENTEST_SEVERITIES:
                    self.fail(rule, f"{rel}: finding {cells[0]} has severity {cells[2]!r}, "
                                    f"not one of {', '.join(PENTEST_SEVERITIES)}")
                if "withheld" in cells[3].lower() and not PENTEST_ISSUE.search(cells[6]):
                    self.fail(rule, f"{rel}: finding {cells[0]} is withheld and links no issue")
    def rule_pentest_runbooks(self) -> None:
        rule = "pentest-runbooks"
        if not any(rel.startswith(PENTEST_DIR) for rel in self.tracked()):
            return
        self.on(rule)
        for rel, needles in PENTEST_RUNBOOKS.items():
            path = self.root / rel
            if not path.is_file():
                self.fail(rule, f"{rel} is missing")
                continue
            text = path.read_text()
            for needle in needles:
                if needle not in text:
                    self.fail(rule, f"{rel} does not name {needle!r}")
        path = self.root / PENTEST_EXTERNAL_WORKFLOW
        if not path.is_file():
            self.fail(rule, f"{PENTEST_EXTERNAL_WORKFLOW} is missing")
        else:
            docs = yaml_file_docs(path)
            wf = docs[0] if docs else {}
            trigger = wf.get("on")
            keys = set(trigger) if isinstance(trigger, dict) else {trigger} if isinstance(trigger, str) \
                else set(trigger or [])
            if keys != {"workflow_dispatch"}:
                self.fail(rule, f"{PENTEST_EXTERNAL_WORKFLOW}: the only trigger is workflow_dispatch, "
                                f"not {', '.join(sorted(map(str, keys))) or 'none'}")
            steps = [st for job in (wf.get("jobs") or {}).values() for st in (job.get("steps") or [])]
            first = steps[0] if steps else {}
            if "TZ=Europe/Zurich" not in str(first.get("run", "")):
                self.fail(rule, f"{PENTEST_EXTERNAL_WORKFLOW}: the first step checks the window "
                                "(TZ=Europe/Zurich, Mon-Fri 09:00-16:59)")
            uses = [str(st.get("uses", "")) for st in steps]
            if not any("codeql-action/upload-sarif" in u for u in uses):
                self.fail(rule, f"{PENTEST_EXTERNAL_WORKFLOW}: findings leave the run as SARIF "
                                "(github/codeql-action/upload-sarif)")
            if any("upload-artifact" in u for u in uses):
                self.fail(rule, f"{PENTEST_EXTERNAL_WORKFLOW}: uploads an artifact; artifacts of this "
                                "repository are public")
        path = self.root / PENTEST_SCHEDULE_WORKFLOW
        if path.is_file():
            text = path.read_text().lower()
            for scanner in PENTEST_SCANNERS:
                if scanner in text:
                    self.fail(rule, f"{PENTEST_SCHEDULE_WORKFLOW}: names {scanner!r}; it only opens or "
                                    "comments on the pentest-run issue")

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

    def alert_rules(self) -> list[tuple[str, dict]]:
        """(file, rule) per alert rule of a PrometheusRule under RULE_DIRS."""
        out = []
        for rel in self.tracked():
            if not rel.startswith(RULE_DIRS) or not rel.endswith((".yaml", ".yml")):
                continue
            p = self.root / rel
            if not p.is_file() or "PrometheusRule" not in p.read_text(errors="replace"):
                continue
            for doc in yaml_file_docs(p):
                if doc.get("kind") != "PrometheusRule":
                    continue
                for group in (doc.get("spec") or {}).get("groups") or []:
                    out.extend((rel, r) for r in group.get("rules") or [] if r.get("alert"))
        return out

    def rule_alert_tests(self) -> None:
        rule = "alert-tests"
        alerts = self.alert_rules()
        if not alerts:
            return
        self.on(rule)
        tested = set()
        for p in sorted((self.root / PROMTOOL_TESTS).glob("*_test.yaml")):
            for doc in yaml_file_docs(p):
                for t in doc.get("tests") or []:
                    tested.update(a.get("alertname") for a in t.get("alert_rule_test") or [])
        seen = set()
        for rel, r in alerts:
            if r["alert"] not in tested and r["alert"] not in seen:
                seen.add(r["alert"])
                self.fail(rule, f"{rel}: {r['alert']} has no alert_rule_test in {PROMTOOL_TESTS}/*_test.yaml")

    def rule_alert_runbooks(self) -> None:
        rule = "alert-runbooks"
        rules = self.alert_rules()
        rb_dir = self.root / RUNBOOK_DIR
        if not rules and not rb_dir.is_dir():
            return
        self.on(rule)
        names = set()
        for rel, r in rules:
            alert, url = r["alert"], (r.get("annotations") or {}).get("runbook_url")
            want = f"{RUNBOOK_BASE}{alert}.md"
            if (r.get("labels") or {}).get("action") == "human":
                names.add(alert)
                if url != want:
                    self.fail(rule, f"{rel}: {alert} has {'runbook_url ' + url if url else 'no runbook_url'}, want {want}")
            elif url and url.startswith(RUNBOOK_BASE) and (url != want or not (rb_dir / f"{alert}.md").is_file()):
                self.fail(rule, f"{rel}: {alert} has runbook_url {url}, want {want} and that page")
        index = rb_dir / "README.md"
        index_text = index.read_text() if index.is_file() else ""
        for alert in sorted(names):
            if not (rb_dir / f"{alert}.md").is_file():
                self.fail(rule, f"{RUNBOOK_DIR}/{alert}.md is missing (runbook of an action: human alert)")
            if f"]({alert}.md)" not in index_text:
                self.fail(rule, f"{RUNBOOK_DIR}/README.md does not link {alert}.md")
        for p in sorted(rb_dir.glob("*.md")) if rb_dir.is_dir() else []:
            if p.name != "README.md" and p.stem not in names:
                self.fail(rule, f"{RUNBOOK_DIR}/{p.name} names no action: human alert")
        # The chart rules that page by name: a row in the index.
        routes = self.root / AM_ROUTES
        for ln in routes.read_text().splitlines() if routes.is_file() else []:
            parts = ln.split()
            if not parts or parts[0] != "ntfy" or "category=security" in parts[1:]:
                continue
            labels = dict(p.split("=", 1) for p in parts[1:] if "=" in p)
            alert = labels.get("alertname", "")
            if alert and alert not in names and f"`{alert}`" not in index_text:
                self.fail(rule, f"{AM_ROUTES}: {alert} pages but has no page and no row in {RUNBOOK_DIR}/README.md")

    def rule_backup_slo_targets(self) -> None:
        rule = "backup-slo-targets"
        p = self.root / BACKUP_SLO_TARGETS
        active = self.read_list("ci/active-cronjobs.txt")
        if not p.is_file() or active is None:
            return
        self.on(rule)
        want = {a for a in active if "-backup" in a.split("/", 1)[-1]}
        have = set()
        for doc in yaml_file_docs(p):
            for group in (doc.get("spec") or {}).get("groups") or []:
                for r in group.get("rules") or []:
                    if r.get("record") == "slo:backup_target:info":
                        labels = r.get("labels") or {}
                        have.add(f"{labels.get('namespace')}/{labels.get('cronjob')}")
        for x in sorted(want - have):
            self.fail(rule, f"{BACKUP_SLO_TARGETS}: no slo:backup_target:info for {x} (ci/active-cronjobs.txt)")
        for x in sorted(have - want):
            self.fail(rule, f"{BACKUP_SLO_TARGETS}: {x} is not a backup CronJob of ci/active-cronjobs.txt")

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
                     self.rule_iscsi_selinux_label, self.rule_pod_security_labels, self.rule_pod_hardening,
                     self.rule_cronjobs,
                     self.rule_restic_locks,
                     self.rule_root_profiles, self.rule_bootstrap_chart_versions, self.rule_cnpg_backup,
                     self.rule_backup_bucket_lock, self.rule_kiro_tracked, self.rule_cilium_explicit_xds,
                     self.rule_monitor_selected, self.rule_appproject_kinds, self.rule_spec_lifecycle,
                     self.rule_pentest_roe, self.rule_pentest_runbooks, self.rule_pentest_reports,
                     self.rule_expected_ingresses, self.rule_alert_tests, self.rule_alert_runbooks,
                     self.rule_backup_slo_targets, self.rule_k8s_version,
                     self.rule_image_bulky,
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


def check_restic_locks(text: str) -> list[str]:
    """The restic lock contract for one script (docs/backups.md#locks)."""
    problems = []
    last = None
    unlocked = False
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line.startswith("#"):
            continue
        for m in RESTIC_CMD.finditer(line):
            sub = m.group(1)
            if sub == "unlock":
                if "--remove-all" in line:
                    problems.append(f"line {n}: restic unlock --remove-all also removes live locks")
                last, unlocked = "unlock", True
                continue
            if sub not in RESTIC_LOCKING or "--no-lock" in line:
                continue
            if "--retry-lock" not in line:
                problems.append(f"line {n}: restic {sub} without --retry-lock on the same line")
            if sub in RESTIC_EXCLUSIVE and last not in ("unlock", "forget", "prune"):
                problems.append(f"line {n}: restic {sub} is not preceded by restic unlock")
            if sub == "backup" and not unlocked:
                problems.append(f"line {n}: restic backup before any restic unlock")
            if sub != "ls":
                last = sub
    return problems


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


def in_resource_list(gk: tuple[str, str], items: list) -> bool:
    """Argo CD's isResourceInList: group and kind both glob-match one entry."""
    return any(fnmatchcase(gk[0], str(i.get("group") or "")) and fnmatchcase(gk[1], str(i.get("kind") or ""))
               for i in items or [] if isinstance(i, dict))


def kind_permitted(proj: dict, gk: tuple[str, str], namespaced: bool) -> bool:
    """Argo CD's AppProject.IsGroupKindPermitted: an unset namespaced whitelist allows every kind, an empty one
    none; an empty cluster whitelist allows no kind."""
    if namespaced:
        wl = proj.get("namespaceResourceWhitelist")
        ok = wl is None or (len(wl) > 0 and in_resource_list(gk, wl))
        return ok and not in_resource_list(gk, proj.get("namespaceResourceBlacklist") or [])
    return in_resource_list(gk, proj.get("clusterResourceWhitelist") or []) \
        and not in_resource_list(gk, proj.get("clusterResourceBlacklist") or [])


def destination_permitted(proj: dict, dest: dict, namespace: str) -> bool:
    """An AppProject destination glob-matches the Application's server (or cluster name) and `namespace`."""
    server, name = dest.get("server"), dest.get("name")
    if server is None and name is None:
        server = DEFAULT_SERVER
    for item in proj.get("destinations") or []:
        if not isinstance(item, dict) or not fnmatchcase(namespace, str(item.get("namespace") or "")):
            continue
        if server is not None and item.get("server") and fnmatchcase(str(server), str(item["server"])):
            return True
        if name is not None and item.get("name") and fnmatchcase(str(name), str(item["name"])):
            return True
    return False


def pod_spec_of(doc: dict) -> dict | None:
    """The pod spec of a workload or Pod manifest, else None."""
    kind, spec = doc.get("kind"), doc.get("spec") or {}
    if doc.get("apiVersion") not in ("v1", "apps/v1", "batch/v1"):
        return None
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return (spec.get("template") or {}).get("spec") or {}
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    if kind == "Pod":
        return spec
    return None


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
