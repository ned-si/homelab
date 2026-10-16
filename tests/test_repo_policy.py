"""scripts/ci/repo_policy.py: one fixture per rule (failing), plus clean trees (passing)."""
import copy
import json
import subprocess
import sys

import pytest

from conftest import FIXTURES, SCRIPTS, git_init, write

LAN_GONE = "192.168." + "2.0/24"
EXCLUDE = "external-dns.alpha.kubernetes.io/" + "exclude"


def policy(tmp_path, files=None, renders=None):
    root, out = tmp_path / "repo", tmp_path / "render"
    root.mkdir(parents=True, exist_ok=True)
    for rel, text in (files or {"README.md": "x\n"}).items():
        write(root, rel, text)
    git_init(root)
    out.mkdir(parents=True, exist_ok=True)
    index = []
    for app, scope, layer, ns, docs in renders or []:
        index.append({"app": app, "scope": scope, "layer": layer, "namespace": ns, "error": None,
                      "objects": len(docs), "notes": [], "kinds": {}, "children": [], "origin": "test"})
        (out / app).mkdir(parents=True, exist_ok=True)
        (out / app / "manifests.yaml").write_text("".join("---\n" + json.dumps(d) + "\n" for d in docs))
    (out / "index.json").write_text(json.dumps(index))
    r = subprocess.run([sys.executable, str(SCRIPTS / "repo_policy.py"), "--render", str(out), "--repo-root", str(root)],
                       capture_output=True, text=True)
    return r


def fails(r):
    return [ln for ln in r.stdout.splitlines() if ln.startswith("FAIL ")]


def cronjob(name="backup", ns="mealie", suspend=True, guard=True, containers=1, mode=None,
            restic=True, guard_first=True):
    c = {"name": "backup", "image": "restic/restic:0.17.3", "command": ["/bin/sh", "-c", "run"],
         "env": [{"name": "RESTIC_REPOSITORY", "value": "s3:x"}] if restic else [{"name": "OTHER", "value": "y"}],
         "envFrom": [{"secretRef": {"name": "s3-backup"}}],
         "volumeMounts": [{"name": "data", "mountPath": "/data"}]}
    pod = {"containers": [copy.deepcopy(c) for _ in range(containers)], "initContainers": []}
    if guard:
        g = {"name": "pending-guard", "image": c["image"], "command": ["/bin/sh", "/guard/pending-guard.sh"],
             "env": copy.deepcopy(c["env"]) + ([{"name": "GUARD_MODE", "value": mode}] if mode else []),
             "envFrom": copy.deepcopy(c["envFrom"]),
             "volumeMounts": copy.deepcopy(c["volumeMounts"]) + [{"name": "guard", "mountPath": "/guard"}]}
        pod["initContainers"].append(g)
    dump = {"name": "dump", "image": "postgres:16", "command": ["pg_dump"]}
    if guard_first:
        pod["initContainers"].append(dump)
    else:
        pod["initContainers"].insert(0, dump)
    return {"apiVersion": "batch/v1", "kind": "CronJob", "metadata": {"name": name, "namespace": ns},
            "spec": {"suspend": suspend, "schedule": "0 3 * * *",
                     "jobTemplate": {"spec": {"template": {"spec": pod}}}}}


def test_clean_tree_passes(tmp_path):
    r = policy(tmp_path)
    assert r.returncode == 0, r.stdout
    assert fails(r) == []


def test_lan_literal_fails_outside_docs_only(tmp_path):
    r = policy(tmp_path, files={"ci/proof.yaml": f"cidr: {LAN_GONE}\n", "docs/net.md": f"was {LAN_GONE}\n"})
    assert fails(r) == ["FAIL no-lan-192-168-2: ci/proof.yaml:1"]


def test_wan_ip_single_source(tmp_path):
    ip = ".".join(["203", "0", "113", "7"])
    files = {"kubernetes/applications/external-dns.yaml": f"args: [--default-targets={ip}]\n"}
    assert policy(tmp_path, files=files).returncode == 0
    files["kubernetes/applications/other.yaml"] = f"target: {ip}\n"
    r = policy(tmp_path / "b", files=files)
    assert any("wan-ip-single-source" in f and "other.yaml:1" in f for f in fails(r))
    files2 = {"kubernetes/applications/a.yaml": f"- --default-targets={ip}\n",
              "kubernetes/applications/b.yaml": f"- --default-targets={ip}\n"}
    r = policy(tmp_path / "c", files=files2)
    assert any("sets --default-targets 2 times" in f for f in fails(r))


def test_wan_ip_counted_per_layout(tmp_path):
    ip = ".".join(["203", "0", "113", "7"])
    files = {"kubernetes/applications/external-dns.yaml": f"- --default-targets={ip}\n",
             "infrastructure/external-dns/values.yaml": f"- --default-targets={ip}\n"}
    assert policy(tmp_path, files=files).returncode == 0


def test_immich_db_image(tmp_path):
    good = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": {"name": "immich-db"},
            "spec": {"imageName": "ghcr.io/tensorchord/cloudnative-pgvecto.rs:16.5-v0.3.0"}}
    assert not [f for f in fails(policy(tmp_path, renders=[("legacy/all-apps", "1", None, "argo", [good])]))
                if "immich-db-image" in f]
    bad = copy.deepcopy(good)
    bad["spec"]["imageName"] = "ghcr.io/tensorchord/cloudnative-vectorchord:16"
    r = policy(tmp_path / "b", renders=[("legacy/all-apps", "1", None, "argo", [bad])])
    assert any("immich-db-image" in f for f in fails(r))
    r = policy(tmp_path / "c", files={"apps/immich/values.yaml": "x: 1\n"})
    assert any("no rendered CNPG Cluster immich-db" in f for f in fails(r))


def test_resources_finalizer(tmp_path):
    app = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
           "metadata": {"name": "x", "finalizers": ["resources-finalizer.argocd.argoproj.io"]}}
    r = policy(tmp_path, renders=[("layer-apps", "2", None, "argo", [app])])
    assert any("no-resources-finalizer" in f for f in fails(r))
    r = policy(tmp_path / "b", files={"clusters/homelab/apps/x.yaml": (FIXTURES / "apps/root-finalizer.yaml").read_text()})
    assert any("no-resources-finalizer: clusters/homelab/apps/x.yaml" in f for f in fails(r))


def test_pvc_rules_new_layout_only(tmp_path):
    data = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "immich-data", "namespace": "immich"}}
    plain = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "cfg", "namespace": "mealie"}}
    ok = copy.deepcopy(plain)
    ok["metadata"]["annotations"] = {"argocd.argoproj.io/sync-options": "Delete=false,Prune=false"}
    # Legacy render (scope 1) is exempt.
    assert policy(tmp_path, renders=[("legacy/all-apps", "1", None, "argo", [data, plain])]).returncode == 0
    r = policy(tmp_path / "b", renders=[("immich", "2+3", "apps", "immich", [data, plain, ok])])
    f = fails(r)
    assert any("renders PVC immich/immich-data" in x for x in f)
    assert any("PVC mealie/cfg lacks" in x for x in f)
    assert len(f) == 2


def test_immich_cluster_keeps_prune_guard(tmp_path):
    db = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": {"name": "db", "namespace": "immich"}}
    kept = copy.deepcopy(db)
    kept["metadata"]["annotations"] = {"argocd.argoproj.io/sync-options": "Delete=false,Prune=false"}
    other = copy.deepcopy(db)
    other["metadata"]["namespace"] = "scratch"
    r = policy(tmp_path, renders=[("immich", "2+3", "apps", "immich", [db, other])])
    assert [x for x in fails(r) if "pvc-sync-options" in x] == \
        ["FAIL pvc-sync-options: immich: Cluster immich/db lacks argocd.argoproj.io/sync-options: Delete=false,Prune=false"]
    r = policy(tmp_path / "b", renders=[("immich", "2+3", "apps", "immich", [kept, other])])
    assert not [x for x in fails(r) if "pvc-sync-options" in x]


def test_exclude_annotation_anywhere(tmp_path):
    r = policy(tmp_path, files={"infrastructure/gateway/route.yaml": f"annotations:\n  {EXCLUDE}: \"true\"\n"})
    assert any("no-external-dns-exclude: infrastructure/gateway/route.yaml:2" in f for f in fails(r))


def test_wildcard_route_needs_controller_none(tmp_path):
    route = {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
             "metadata": {"name": "redirect", "namespace": "gateway"}, "spec": {"hostnames": ["*.example.org"]}}
    r = policy(tmp_path, renders=[("gateway", "2+3", "infrastructure", "gateway", [route])])
    assert any("wildcard-route-dns" in f for f in fails(r))
    route["metadata"]["annotations"] = {"external-dns.alpha.kubernetes.io/controller": "none"}
    assert policy(tmp_path / "b", renders=[("gateway", "2+3", "infrastructure", "gateway", [route])]).returncode == 0


def test_https_route_needs_security_headers(tmp_path):
    hdrs = {"type": "ResponseHeaderModifier", "responseHeaderModifier": {"set": [
        {"name": "Strict-Transport-Security", "value": "max-age=31536000"},
        {"name": "X-Content-Type-Options", "value": "nosniff"}]}}
    route = {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
             "metadata": {"name": "app", "namespace": "app"},
             "spec": {"parentRefs": [{"name": "shared", "sectionName": "https"}], "hostnames": ["app.example.org"],
                      "rules": [{"filters": [hdrs]}, {"backendRefs": []}]}}
    r = policy(tmp_path, renders=[("app", "2+3", "apps", "app", [route])])
    assert [f for f in fails(r) if "route-security-headers" in f] == [
        "FAIL route-security-headers: app: HTTPRoute app/app rule 1 does not set "
        "strict-transport-security, x-content-type-options (ResponseHeaderModifier set)"]
    route["spec"]["rules"][1]["filters"] = [hdrs]
    assert policy(tmp_path / "b", renders=[("app", "2+3", "apps", "app", [route])]).returncode == 0
    # The :80 redirect route is exempt.
    redirect = {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
                "metadata": {"name": "r", "namespace": "gateway"},
                "spec": {"parentRefs": [{"name": "shared", "sectionName": "http"}], "rules": [{}]}}
    assert policy(tmp_path / "c", renders=[("gw", "2+3", "infrastructure", "gateway", [redirect])]).returncode == 0


GUARD_FILES = {"ci/non-backup-cronjobs.txt": "theater/recyclarr\n",
               "ci/guard-modes.txt": "backup-verify/backup-verify-files s3-creds\n"}


def guarded_tree(tmp_path, jobs, files=None):
    verify = cronjob("backup-verify-files", "backup-verify", mode="s3-creds", restic=False)
    recyclarr = cronjob("recyclarr", "theater", guard=False, restic=False)
    return policy(tmp_path, files=files or GUARD_FILES,
                  renders=[("apps-x", "2+3", "apps", "default", jobs + [recyclarr]),
                           ("backup-verify", "3", "platform", "backup-verify", [verify])])


def test_guarded_cronjobs_pass(tmp_path):
    r = guarded_tree(tmp_path, [cronjob()])
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("job,needle", [
    (cronjob(suspend=False), "is not suspended"),
    (cronjob(guard=False), "initContainers[0] is not pending-guard"),
    (cronjob(guard_first=False), "initContainers[0] is not pending-guard"),
    (cronjob(containers=2), "has 2 containers"),
    (cronjob(restic=False), "no RESTIC_REPOSITORY"),
    (cronjob(mode="s3-creds"), "env is not containers[0] env"),
])
def test_guard_rule_failures(tmp_path, job, needle):
    r = guarded_tree(tmp_path, [job])
    assert any(needle in f for f in fails(r)), r.stdout


def test_listed_job_without_guard_mode_fails(tmp_path):
    verify = cronjob("backup-verify-files", "backup-verify", mode=None, restic=False)
    r = policy(tmp_path, files=GUARD_FILES, renders=[("backup-verify", "3", "platform", "backup-verify", [verify])])
    assert any("plus GUARD_MODE=s3-creds" in f for f in fails(r)), r.stdout


def test_stale_and_unknown_guard_modes(tmp_path):
    files = dict(GUARD_FILES)
    files["ci/guard-modes.txt"] += "backup-verify/gone always-block\nbackup-verify/backup-verify-files bogus\n"
    r = guarded_tree(tmp_path, [cronjob()], files=files)
    f = fails(r)
    assert any("backup-verify/gone is not a rendered guarded CronJob" in x for x in f)
    assert any("unknown mode 'bogus'" in x for x in f)


def test_active_cronjob_runs_without_guard(tmp_path):
    files = dict(GUARD_FILES, **{"ci/active-cronjobs.txt": "# reviewed\nmealie/live\n"})
    r = guarded_tree(tmp_path, [cronjob(), cronjob("live", suspend=False, guard=False)], files=files)
    assert r.returncode == 0, r.stdout
    assert "cronjob-active" in r.stdout


@pytest.mark.parametrize("suspend", [True, None])
def test_active_cronjob_must_say_suspend_false(tmp_path, suspend):
    files = dict(GUARD_FILES, **{"ci/active-cronjobs.txt": "mealie/live\n"})
    job = cronjob("live", suspend=suspend, guard=False)
    if suspend is None:
        del job["spec"]["suspend"]
    r = guarded_tree(tmp_path, [job], files=files)
    assert any("cronjob-active" in f and "mealie/live" in f and "suspend: false" in f for f in fails(r)), r.stdout


def test_stale_active_cronjob_entry(tmp_path):
    files = dict(GUARD_FILES, **{"ci/active-cronjobs.txt": "mealie/gone\n"})
    r = guarded_tree(tmp_path, [cronjob()], files=files)
    assert fails(r) == ["FAIL cronjob-active: ci/active-cronjobs.txt: mealie/gone is not a rendered CronJob (stale entry)"]


def test_unlisted_unsuspended_cronjob_still_fails(tmp_path):
    files = dict(GUARD_FILES, **{"ci/active-cronjobs.txt": "mealie/live\n"})
    r = guarded_tree(tmp_path, [cronjob("live", suspend=False, guard=False), cronjob("other", suspend=False)],
                     files=files)
    assert any("CronJob mealie/other is not suspended" in f for f in fails(r)), r.stdout


def test_cronjobs_outside_apps_platform_and_legacy_are_ignored(tmp_path):
    job = cronjob(suspend=False, guard=False)
    r = policy(tmp_path, renders=[("legacy/all-apps", "1", None, "argo", [job]),
                                  ("infra-x", "2+3", "infrastructure", "kube-system", [job])])
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("fixture,needle", [
    ("root-ns-argocd.yaml", "metadata.namespace"),
    ("root-finalizer.yaml", "finalizers"),
    ("root-prune-true.yaml", "automated"),
    ("root-target-deployed.yaml", "targetRevision"),
])
def test_root_profile_in_git(tmp_path, fixture, needle):
    r = policy(tmp_path, files={"clusters/homelab/root.yaml": (FIXTURES / "apps" / fixture).read_text()})
    assert any(f.startswith("FAIL root-profiles: clusters/homelab/root.yaml (root)") and needle in f for f in fails(r)), r.stdout


@pytest.mark.parametrize("fixture,needle", [
    ("legacy-root-ns-argocd.yaml", "metadata.namespace"),
    ("legacy-root-finalizer.yaml", "finalizers"),
    ("legacy-root-prune-true.yaml", "automated"),
    ("legacy-root-target-main.yaml", "targetRevision"),
])
def test_legacy_root_profile_in_git(tmp_path, fixture, needle):
    r = policy(tmp_path, files={"clusters/homelab/legacy/all-apps.yaml": (FIXTURES / "apps" / fixture).read_text()})
    assert any("legacy-root" in f and needle in f for f in fails(r)), r.stdout


def test_good_roots_pass(tmp_path):
    r = policy(tmp_path, files={"clusters/homelab/root.yaml": (FIXTURES / "apps/root.yaml").read_text(),
                                "clusters/homelab/legacy/all-apps.yaml": (FIXTURES / "apps/legacy-root.yaml").read_text()})
    assert r.returncode == 0, r.stdout


def _bootstrap_app(name, repo, chart, version):
    return ("apiVersion: argoproj.io/v1alpha1\nkind: Application\n"
            f"metadata: {{name: {name}, namespace: argo}}\n"
            f"spec:\n  sources:\n    - {{repoURL: {repo}, chart: {chart}, targetRevision: {version}}}\n")


HELM_RELEASES = ("releases:\n"
                 "  - {name: argocd, repo: https://argoproj.github.io/argo-helm, chart: argo-cd, version: 10.10.3}\n"
                 "  - {name: cilium, repo: https://helm.cilium.io, chart: cilium, version: 1.20.2}\n")


@pytest.mark.parametrize("name,repo,chart,good,bad", [
    ("cilium", "https://helm.cilium.io", "cilium", "1.20.2", "1.17.18"),
    ("argocd", "https://argoproj.github.io/argo-helm", "argo-cd", "10.10.3", "10.2.2"),
])
def test_bootstrap_chart_versions_match_helm_releases(tmp_path, name, repo, chart, good, bad):
    rel = f"clusters/homelab/infrastructure/{name}.yaml"
    r = policy(tmp_path, files={rel: _bootstrap_app(name, repo, chart, bad), "ci/helm-releases.yaml": HELM_RELEASES})
    assert any("bootstrap-chart-versions" in f and chart in f for f in fails(r)), r.stdout
    r = policy(tmp_path / "b", files={rel: _bootstrap_app(name, repo, chart, good), "ci/helm-releases.yaml": HELM_RELEASES})
    assert r.returncode == 0, r.stdout


def _main_tf(argocd, cilium):
    return (f'resource "helm_release" "cilium" {{\n  chart   = "cilium"\n  version = "{cilium}"\n}}\n\n'
            f'resource "helm_release" "argocd" {{\n  chart   = "argo-cd"\n  version   = "{argocd}"\n}}\n')


@pytest.mark.parametrize("argocd,cilium,needle", [
    ("10.10.5", "1.20.2", "helm_release.argocd"),
    ("10.10.3", "1.17.18", "helm_release.cilium"),
])
def test_bootstrap_main_tf_matches_helm_releases(tmp_path, argocd, cilium, needle):
    app = _bootstrap_app("argocd", "https://argoproj.github.io/argo-helm", "argo-cd", "10.10.3")
    files = {"clusters/homelab/infrastructure/argocd.yaml": app, "ci/helm-releases.yaml": HELM_RELEASES}
    r = policy(tmp_path, files=dict(files, **{"bootstrap/main.tf": _main_tf(argocd, cilium)}))
    assert any("bootstrap-chart-versions" in f and needle in f for f in fails(r)), r.stdout
    r = policy(tmp_path / "b", files=dict(files, **{"bootstrap/main.tf": _main_tf("10.10.3", "1.20.2")}))
    assert r.returncode == 0, r.stdout


def test_bootstrap_chart_without_helm_releases_entry(tmp_path):
    hr = "releases:\n  - {name: cilium, repo: https://helm.cilium.io, chart: cilium, version: 1.20.2}\n"
    app = _bootstrap_app("argocd", "https://argoproj.github.io/argo-helm", "argo-cd", "10.10.3")
    r = policy(tmp_path, files={"clusters/homelab/infrastructure/argocd.yaml": app, "ci/helm-releases.yaml": hr})
    assert "FAIL bootstrap-chart-versions: ci/helm-releases.yaml has no argocd entry" in fails(r), r.stdout


def cnpg_set():
    plugin = "barman-cloud.cloudnative-pg.io"
    cl = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": {"name": "db"},
          "spec": {"plugins": [{"name": plugin, "isWALArchiver": True,
                                "parameters": {"barmanObjectName": "cnpg-backup"}}]}}
    store = {"apiVersion": "barmancloud.cnpg.io/v1", "kind": "ObjectStore", "metadata": {"name": "cnpg-backup"}}
    sb = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "ScheduledBackup", "metadata": {"name": "db-daily"},
          "spec": {"cluster": {"name": "db"}, "method": "plugin", "pluginConfiguration": {"name": plugin}}}
    return cl, store, sb


def cnpg_fails(tmp_path, docs):
    return [x for x in fails(policy(tmp_path, renders=[("mealie", "2+3", "apps", "mealie", docs)])) if "cnpg-backup" in x]


def test_cnpg_backup_plugin_set_passes(tmp_path):
    assert cnpg_fails(tmp_path, list(cnpg_set())) == []


def test_cnpg_backup_in_tree_barman_fails(tmp_path):
    cl, store, sb = cnpg_set()
    cl["spec"]["backup"] = {"barmanObjectStore": {}}
    assert any("in-tree" in x for x in cnpg_fails(tmp_path, [cl, store, sb]))


def test_cnpg_backup_non_plugin_scheduled_backup_fails(tmp_path):
    cl, store, sb = cnpg_set()
    sb["spec"]["method"] = "barmanObjectStore"
    assert any("is not method: plugin" in x for x in cnpg_fails(tmp_path, [cl, store, sb]))


def test_cnpg_backup_scheduled_backup_without_archiving_cluster_fails(tmp_path):
    cl, store, sb = cnpg_set()
    del cl["spec"]["plugins"]
    assert any("not a rendered Cluster" in x for x in cnpg_fails(tmp_path, [cl, store, sb]))


def test_cnpg_backup_cluster_without_plugin_fails(tmp_path):
    cl, _, _ = cnpg_set()
    del cl["spec"]["plugins"]
    assert any("does not archive WAL" in x for x in cnpg_fails(tmp_path, [cl]))


def test_cnpg_backup_suspended_scheduled_backup_fails(tmp_path):
    cl, store, sb = cnpg_set()
    sb["spec"]["suspend"] = True
    assert any("is suspended" in x for x in cnpg_fails(tmp_path, [cl, store, sb]))


def test_cnpg_backup_plugin_cluster_without_scheduled_backup_fails(tmp_path):
    cl, store, _ = cnpg_set()
    assert any("has no ScheduledBackup" in x for x in cnpg_fails(tmp_path, [cl, store]))


def test_cnpg_backup_missing_object_store_fails(tmp_path):
    cl, _, sb = cnpg_set()
    assert any("is not rendered" in x for x in cnpg_fails(tmp_path, [cl, sb]))


def test_expected_ingresses(tmp_path):
    ing = {"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": {"name": "argo", "namespace": "argo"}}
    files = {"ci/expected-ingresses.txt": "# ns/name\nargo/argo\nmealie/mealie\n"}
    r = policy(tmp_path, files=files, renders=[("legacy-ingress", "2+3", "infrastructure", "argo", [ing])])
    assert fails(r) == ["FAIL expected-ingresses: Ingress mealie/mealie is not rendered by the new layout"]


def k8s_tree(k8s="1.37.1", node="v1.37.0", talos="v1.37.1"):
    ci = (f"name: ci\nenv:\n  K8S_VERSION: \"{k8s}\"\n"
          f"  KIND_NODE_IMAGE: kindest/node:{node}@sha256:{'0' * 64}\n")
    return {".github/workflows/ci.yaml": ci, "talos/talconfig.yaml": f"clusterName: x\nkubernetesVersion: {talos}\n"}


def test_k8s_version_match_passes(tmp_path):
    r = policy(tmp_path, files=k8s_tree())
    assert r.returncode == 0, r.stdout
    assert "k8s-version-match" in r.stdout


@pytest.mark.parametrize("kw,key", [
    ({"k8s": "1.32.13"}, "K8S_VERSION"),
    ({"node": "v1.32.11"}, "KIND_NODE_IMAGE"),
    ({"talos": "v1.38.0"}, "K8S_VERSION"),
])
def test_k8s_version_mismatch_fails(tmp_path, kw, key):
    r = policy(tmp_path, files=k8s_tree(**kw))
    assert any(f.startswith("FAIL k8s-version-match: .github/workflows/ci.yaml: env " + key) for f in fails(r)), r.stdout


DIGEST = "@sha256:" + "0" * 64


def deployment(image, comment="", digest=DIGEST):
    return f"spec:\n  containers:\n    - name: app\n      image: {image}{digest}{comment}\n"


@pytest.mark.parametrize("line,bad", [
    ("image: example/app:1.0" + DIGEST, False),
    ("image: 'example/app:1.0" + DIGEST + "'", False),
    ("image: example/app:1.0", True),
    ("imageName: ghcr.io/cloudnative-pg/postgresql:18.6", True),
    ("reference: ghcr.io/siderolabs/talosctl:v1.14.3", True),
    ("image: example/app:1.0@sha256:abc", True),
    ("image: example/app:1.0  # image-policy: allow frozen", False),
    ("image: siderolabs/sbc-rockchip", False),
])
def test_image_digest(tmp_path, line, bad):
    files = {"apps/x/d.yaml": f"spec:\n  {line}\n", "docs/x.yaml": "image: example/app:1.0\n",
             "tests/fixtures/apps/x.yaml": "image: example/app:1.0\n"}
    r = policy(tmp_path, files=files)
    got = [f for f in fails(r) if "image-digest" in f]
    assert bool(got) == bad, r.stdout
    if bad:
        assert got[0].startswith("FAIL image-digest: apps/x/d.yaml:2: ")


@pytest.mark.parametrize("image,bad", [
    ("docker.io/library/python:3.15.0", True),
    ("python:3.15.0-alpine3.24", False),
    ("node:24", True),
    ("node:24-alpine", False),
    ("golang:1.26-bookworm", True),
    ("ubuntu:26.04", True),
    ("debian:trixie-slim", False),
    ("gcr.io/distroless/python3-debian13:nonroot", False),
    ("ghcr.io/example/python:3.15.0", False),
])
def test_image_bulky_base(tmp_path, image, bad):
    r = policy(tmp_path, files={"platform/x/deployment.yaml": deployment(image), "docs/x.yaml": deployment("node:24")})
    got = [f for f in fails(r) if "image-bulky-base" in f]
    assert bool(got) == bad, r.stdout
    if bad:
        assert got[0].startswith("FAIL image-bulky-base: platform/x/deployment.yaml:4: ")


def test_image_bulky_base_allow_comment(tmp_path):
    files = {"apps/x/d.yaml": deployment("python:3.15.0", "  # image-policy: allow needs glibc wheels")}
    assert policy(tmp_path, files=files).returncode == 0
    files = {"apps/x/d.yaml": deployment("python:3.15.0", "  # image-policy: allow")}
    assert any("image-bulky-base" in f for f in fails(policy(tmp_path / "b", files=files)))


def variant_policy(tmp_path, before, after, *extra):
    """Commit `before` as the base, write `after` over it, run with --base HEAD."""
    root = tmp_path / "repo"
    r = policy(tmp_path, files=before)
    assert r.returncode == 0, r.stdout
    subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.org",
                    "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"], check=True)
    for rel, text in after.items():
        write(root, rel, text)
    out = tmp_path / "render"
    return subprocess.run([sys.executable, str(SCRIPTS / "repo_policy.py"), "--render", str(out),
                           "--repo-root", str(root), "--base", "HEAD", *extra], capture_output=True, text=True)


@pytest.mark.parametrize("old,new,bad", [
    ("python:3.14.8-alpine3.24", "python:3.15.0-alpine3.24", False),
    ("python:3.14.8-alpine3.24", "python:3.15.0-alpine3.25", False),
    ("docker.io/library/python:3.14.8-alpine3.24", "docker.io/library/python:3.15.0", True),
    ("debian:bookworm-slim", "debian:trixie-slim", True),
    ("memcached:1.6.45", "memcached:1.6.45-alpine", False),
    ("postgres:18-bookworm", "postgres:18-bookworm-slim", False),
    ("ghcr.io/cloudnative-pg/postgresql:18.6", "ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie", False),
    ("ghcr.io/cloudnative-pg/postgresql:18.6", "ghcr.io/cloudnative-pg/postgresql:18.6-trixie", True),
    ("example/app:1.0-bookworm", "example/app:1.0-slim-trixie", True),
    ("example/app:1.0-alpine", "example/app:1.1-slim", True),
    ("plexinc/pms-docker:1.43.4.10903-e5521bd8c", "plexinc/pms-docker:1.43.5.11000-0abc1234d", False),
])
def test_image_variant(tmp_path, old, new, bad):
    r = variant_policy(tmp_path, {"apps/x/d.yaml": deployment(old)}, {"apps/x/d.yaml": deployment(new)})
    got = [f for f in fails(r) if "image-variant" in f]
    assert bool(got) == bad, r.stdout
    assert "image-variant" in r.stdout


@pytest.mark.parametrize("extra,exempt", [
    (["--pr-title", "fix(keycloak): put keycloak-db back on the 17.11 image"], False),
    (["--pr-title", "revert: fix(cnpg): minimal images (auto)"], True),
    (["--pr-title", 'Revert "fix(cnpg): minimal images"'], True),
    (["--pr-branch", "auto-revert/d52a5f6b2f36"], True),
    (["--pr-branch", "fix/auto-revert-docs"], False),
])
def test_image_variant_reverts_are_exempt(tmp_path, extra, exempt):
    old = "ghcr.io/cloudnative-pg/postgresql:17.11-minimal-trixie"
    r = variant_policy(tmp_path, {"apps/x/d.yaml": deployment(old)},
                       {"apps/x/d.yaml": deployment("ghcr.io/cloudnative-pg/postgresql:17.11")}, *extra)
    assert (r.returncode == 0) == exempt, r.stdout
    assert ("image-variant: skipped" in r.stdout) == exempt


def test_image_variant_allow_and_new_image(tmp_path):
    before = {"apps/x/d.yaml": deployment("example/app:1.0-alpine")}
    after = {"apps/x/d.yaml": deployment("example/app:1.1", "  # image-policy: allow upstream dropped alpine"),
             "apps/y/d.yaml": deployment("other/app:2.0")}
    assert variant_policy(tmp_path, before, after).returncode == 0


def test_image_variant_unknown_base(tmp_path):
    r = policy(tmp_path, files={"apps/x/d.yaml": deployment("example/app:1.0")})
    out = tmp_path / "render"
    r = subprocess.run([sys.executable, str(SCRIPTS / "repo_policy.py"), "--render", str(out),
                        "--repo-root", str(tmp_path / "repo"), "--base", "0" * 40], capture_output=True, text=True)
    assert fails(r) == [f"FAIL image-variant: base {'0' * 40} is not in the checkout"], r.stdout


def test_k8s_version_missing_in_talconfig_fails(tmp_path):
    files = k8s_tree()
    files["talos/talconfig.yaml"] = "clusterName: x\n"
    r = policy(tmp_path, files=files)
    assert fails(r) == ["FAIL k8s-version-match: talos/talconfig.yaml: no kubernetesVersion of the form vX.Y.Z"]
