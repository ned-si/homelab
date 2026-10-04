"""scripts/ci/render_apps.py: every source shape and every scope item."""
import json

from conftest import need_kubectl, read_render, run_render, write

LEGACY_HELM_APP = """\
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inline
  namespace: argo
spec:
  project: default
  source:
    repoURL: https://charts.example.org
    chart: inline-chart
    targetRevision: v1.2.3
    helm:
      releaseName: inline-release
      values: |
        replicas: 2
  destination:
    server: https://kubernetes.default.svc
    namespace: inline-ns
"""

PLAIN_CM = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: plain
  namespace: legacy
data:
  a: "1"
"""


def legacy_tree(root):
    write(root, "kubernetes/applications/plain/cm.yaml", PLAIN_CM)
    write(root, "kubernetes/applications/inline.yaml", LEGACY_HELM_APP)


def new_tree(root):
    # root -> layer-apps -> leaves, all through deploy/ manifests.yaml files
    write(root, "clusters/homelab/root.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: root, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, targetRevision: deployed, path: deploy/clusters/homelab/bootstrap}
          destination: {namespace: argo}
        """)
    write(root, "deploy/clusters/homelab/bootstrap/manifests.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: layer-apps, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, targetRevision: deployed, path: deploy/clusters/homelab/apps}
          destination: {namespace: argo}
        ---
        apiVersion: argoproj.io/v1alpha1
        kind: AppProject
        metadata: {name: apps, namespace: argo}
        spec: {}
        """)
    leaf = """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: multi, namespace: argo}
        spec:
          sources:
            - repoURL: https://charts.example.org
              chart: multi-chart
              targetRevision: 0.1.0
              helm:
                valueFiles: [$values/apps/multi/values.yaml]
            - repoURL: https://github.com/ned-si/homelab.git
              targetRevision: deployed
              ref: values
            - repoURL: https://github.com/ned-si/homelab
              targetRevision: deployed
              path: deploy/apps/multi
          destination: {namespace: multi-ns}
        """
    write(root, "deploy/clusters/homelab/apps/manifests.yaml", leaf)
    write(root, "clusters/homelab/apps/multi.yaml", leaf)
    write(root, "clusters/homelab/apps/kustomization.yaml", "resources: [multi.yaml]\n")
    write(root, "apps/multi/values.yaml", "fromValuesFile: true\n")
    write(root, "deploy/apps/multi/manifests.yaml", """\
        apiVersion: v1
        kind: Service
        metadata: {name: multi}
        spec: {ports: [{port: 80}]}
        ---
        apiVersion: v1
        kind: ConfigMap
        metadata: {name: multi-extra}
        """)
    # Excluded from its layer kustomization, still rendered (scope 3).
    write(root, "clusters/homelab/platform/excluded.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: excluded, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, targetRevision: deployed, path: deploy/platform/excluded}
          destination: {namespace: excluded}
        """)
    write(root, "deploy/platform/excluded/manifests.yaml", PLAIN_CM)
    # KSOPS application: skipped and reported.
    write(root, "clusters/homelab/apps/secrets.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: secrets-apps, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, targetRevision: deployed, path: apps/secrets}
          destination: {namespace: default}
        """)
    write(root, "apps/secrets/kustomization.yaml", "generators: [secret-generator.yaml]\n")
    write(root, "apps/secrets/secret-generator.yaml", """\
        apiVersion: viaduct.ai/v1
        kind: ksops
        metadata: {name: gen}
        files: [x.sops.yaml]
        """)
    # Legacy root artefact: skipped.
    write(root, "clusters/homelab/legacy/all-apps.yaml", "kind: Application\n")


def test_legacy_directory_and_inline_values(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    legacy_tree(root)
    r = run_render(root, out)
    assert r.returncode == 0, r.stdout + r.stderr
    # The legacy root directory renders the plain manifest and the child Application.
    kinds = sorted(d["kind"] for d in read_render(out, "legacy/all-apps"))
    assert kinds == ["Application", "ConfigMap"]
    # The child helm app: release name, namespace, version, inline values, CRDs.
    call = fake_helm.read_text().strip()
    assert call.startswith("template inline-release inline-chart --repo https://charts.example.org --version v1.2.3")
    assert "--namespace inline-ns" in call and "--include-crds" in call and "--kube-version 1.32.13" in call
    cm = read_render(out, "legacy/inline")[0]
    assert cm["metadata"]["name"] == "inline-release"
    assert "replicas: 2" in cm["data"]["values"]
    # stdout: names and counts only, never values.
    assert "replicas" not in r.stdout
    assert "render legacy/inline: 1 objects" in r.stdout


def test_new_layout_root_traversal_multisource_ksops_and_exclusions(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    new_tree(root)
    r = run_render(root, out)
    assert r.returncode == 0, r.stdout + r.stderr
    index = {e["app"]: e for e in json.loads((out / "index.json").read_text())}
    assert set(index) == {"root", "layer-apps", "multi", "excluded", "secrets-apps"}
    assert index["root"]["children"] == ["layer-apps"]
    assert index["layer-apps"]["children"] == ["multi"]
    # multi is reached through the root (2) and its file (3): rendered once.
    assert index["multi"]["scope"] == "2+3"
    assert fake_helm.read_text().count("multi-chart") == 1
    assert index["multi"]["layer"] == "apps"
    # $values resolved against the checkout, plus the deploy/ manifests.yaml directory.
    multi = read_render(out, "multi")
    assert [d["kind"] for d in multi] == ["ConfigMap", "Service", "ConfigMap"]
    assert "fromValuesFile: true" in multi[0]["data"]["values"]
    assert index["excluded"]["scope"] == "3" and index["excluded"]["layer"] == "platform"
    assert index["secrets-apps"]["objects"] == 0
    assert "skipped (KSOPS): apps/secrets (app secrets-apps)" in r.stdout
    assert "skipped (legacy artefact): clusters/homelab/legacy/all-apps.yaml" in r.stdout


def test_manifests_yaml_only_directory_is_not_kustomized(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    write(root, "clusters/homelab/apps/d.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: d, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, path: deploy/apps/d}
          destination: {namespace: d}
        """)
    write(root, "deploy/apps/d/manifests.yaml", PLAIN_CM + "---\n" + PLAIN_CM.replace("plain", "plain2"))
    r = run_render(root, out)
    assert r.returncode == 0, r.stdout
    assert [d["metadata"]["name"] for d in read_render(out, "d")] == ["plain", "plain2"]


def test_kustomization_directory_uses_kubectl_kustomize(tmp_path, fake_helm):
    need_kubectl()
    root, out = tmp_path / "repo", tmp_path / "out"
    write(root, "clusters/homelab/apps/k.yaml", """\
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {name: k, namespace: argo}
        spec:
          source: {repoURL: https://github.com/ned-si/homelab.git, path: apps/k}
          destination: {namespace: k}
        """)
    write(root, "apps/k/kustomization.yaml", "namespace: k-ns\nresources: [cm.yaml]\n")
    write(root, "apps/k/cm.yaml", PLAIN_CM)
    r = run_render(root, out)
    assert r.returncode == 0, r.stdout
    assert read_render(out, "k")[0]["metadata"]["namespace"] == "k-ns"


def test_helm_releases_entry(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    write(root, "ci/helm-releases.yaml", """\
        releases:
          - name: cilium
            repo: https://helm.cilium.io
            chart: cilium
            version: 1.17.18
            release: cilium
            namespace: kube-system
            values: infrastructure/cilium/values.yaml
        """)
    write(root, "infrastructure/cilium/values.yaml", "kubeProxyReplacement: true\n")
    r = run_render(root, out)
    assert r.returncode == 0, r.stdout
    call = fake_helm.read_text().strip()
    assert call.startswith("template cilium cilium --repo https://helm.cilium.io --version 1.17.18 --namespace kube-system")
    assert "--include-crds" in call
    assert call.endswith(f"-f {root / 'infrastructure/cilium/values.yaml'}")
    assert "kubeProxyReplacement: true" in read_render(out, "helm-releases/cilium")[0]["data"]["values"]


def test_render_error_exits_1(tmp_path, fake_helm, monkeypatch):
    root, out = tmp_path / "repo", tmp_path / "out"
    legacy_tree(root)
    monkeypatch.setenv("FAKE_HELM_FAIL", "1")
    r = run_render(root, out)
    assert r.returncode == 1
    assert "ERROR legacy/inline: helm template failed: Error: chart not found" in r.stdout


def test_missing_value_file_is_an_error(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    new_tree(root)
    (root / "apps/multi/values.yaml").unlink()
    r = run_render(root, out)
    assert r.returncode == 1
    assert "ERROR multi: value file not found" in r.stdout


def test_refuses_to_clear_a_foreign_directory(tmp_path, fake_helm):
    root, out = tmp_path / "repo", tmp_path / "out"
    legacy_tree(root)
    out.mkdir()
    (out / "precious").write_text("x")
    r = run_render(root, out)
    assert r.returncode != 0
    assert (out / "precious").exists()
