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
    assert policy(tmp_path, renders=[("legacy/all-apps", "1", None, "argo", [good])]).returncode == 0
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


def test_cronjobs_outside_apps_platform_and_legacy_are_ignored(tmp_path):
    job = cronjob(suspend=False, guard=False)
    r = policy(tmp_path, renders=[("legacy/all-apps", "1", None, "argo", [job]),
                                  ("infra-x", "2+3", "infrastructure", "kube-system", [job])])
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("fixture,needle", [
    ("root-ns-argocd.yaml", "metadata.namespace"),
    ("root-finalizer.yaml", "finalizers"),
    ("root-prune-true.yaml", "automated"),
    ("root-target-main.yaml", "targetRevision"),
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


def test_cilium_version_matches_helm_releases(tmp_path):
    app = ("apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: cilium, namespace: argo}\n"
           "spec:\n  sources:\n    - {repoURL: https://helm.cilium.io, chart: cilium, targetRevision: 1.16.3}\n")
    hr = "releases:\n  - {name: cilium, repo: https://helm.cilium.io, chart: cilium, version: 1.17.18}\n"
    r = policy(tmp_path, files={"clusters/homelab/infrastructure/cilium.yaml": app, "ci/helm-releases.yaml": hr})
    assert any("cilium-version" in f for f in fails(r))
    r = policy(tmp_path / "b", files={"clusters/homelab/infrastructure/cilium.yaml": app.replace("1.16.3", "1.17.18"),
                                      "ci/helm-releases.yaml": hr})
    assert r.returncode == 0, r.stdout


def test_no_cnpg_backup(tmp_path):
    cl = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": {"name": "db"},
          "spec": {"backup": {"barmanObjectStore": {}}}}
    sb = {"apiVersion": "postgresql.cnpg.io/v1", "kind": "ScheduledBackup", "metadata": {"name": "nightly"}}
    r = policy(tmp_path, renders=[("mealie", "2+3", "apps", "mealie", [cl, sb])])
    f = fails(r)
    assert any("has spec.backup" in x for x in f) and any("ScheduledBackup" in x for x in f)


def test_expected_ingresses(tmp_path):
    ing = {"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": {"name": "argo", "namespace": "argo"}}
    files = {"ci/expected-ingresses.txt": "# ns/name\nargo/argo\nmealie/mealie\n"}
    r = policy(tmp_path, files=files, renders=[("legacy-ingress", "2+3", "infrastructure", "argo", [ing])])
    assert fails(r) == ["FAIL expected-ingresses: Ingress mealie/mealie is not rendered by the new layout"]
