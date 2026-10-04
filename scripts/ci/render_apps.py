#!/usr/bin/env python3
"""Render every Argo CD Application source in scope, the way Argo would.

Scope, exactly (each item is active only when its paths exist):

  1. legacy   every `kind: Application` document under kubernetes/applications/**,
              plus the legacy root itself (`all-apps`: directory
              kubernetes/applications, recurse), whose directory is what Argo
              applies today; that render is what holds those Applications and
              the plain manifests next to them.
  2. root     the Applications reachable from clusters/homelab/root.yaml by
              following each git source as Argo does: root -> layer-* -> leaves.
              deploy/** directories hold only manifests.yaml and are read as
              plain YAML documents, never kustomized.
  3. files    every Application file under clusters/homelab/{infrastructure,
              platform,apps}/, including those excluded from their layer's
              kustomization, so inert content stays validated. An Application
              already rendered by (2) is rendered once.
  4. helm-cli every release in ci/helm-releases.yaml (helm-CLI managed releases,
              e.g. argocd and cilium), rendered with
              `helm template <release> <chart> --repo <repo> --version <version>
              -n <namespace> -f <values> --include-crds`.
              Format: `releases:` list of {name, repo, chart, version, release,
              namespace, values}, or a mapping name -> that entry.

clusters/homelab/legacy/** is skipped and reported as "skipped (legacy
artefact)". Directories with a KSOPS generator (viaduct.ai/v1 ksops) are skipped
and reported: CI has no age key and must never have one.

Source handling: helm (repoURL + chart + targetRevision, releaseName or the app
name, destination namespace, valueFiles with `$ref/...` resolved against this
checkout, then inline `values` / `valuesObject`, then parameters) ->
`helm template --include-crds`; git `path` in this repository -> a directory
read as plain documents (recursing when `directory.recurse`), `kubectl
kustomize` when it holds a kustomization, `helm template` when it holds a
Chart.yaml.

Output: <out>/<app>/manifests.yaml (legacy apps under <out>/legacy/<app>/,
helm-CLI releases under <out>/helm-releases/<name>/), <out>/index.json and
<out>/files.txt. stdout carries application names and object counts only: the
legacy inline Helm values contain credentials, so rendered content is never
printed, and errors print the failing command's first stderr line only.
Exit 1 on any render error.

Requires: python3 (stdlib only), yq v4, helm, kubectl (for kustomize).
"""
from __future__ import annotations

import argparse
import collections
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

THIS_REPO = {"https://github.com/ned-si/homelab", "git@github.com:ned-si/homelab"}
NEW_LAYERS = ("infrastructure", "platform", "apps")
MARKER = ".render_apps"


class RenderError(Exception):
    pass


def norm_repo(url: str) -> str:
    url = (url or "").strip().rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    return url


def is_this_repo(url: str) -> bool:
    extra = {norm_repo(u) for u in os.environ.get("RENDER_REPO_URLS", "").split() if u}
    return norm_repo(url) in THIS_REPO | extra


def first_line(text: str) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:300]
    return "(no output)"


def run(cmd: list[str], env: dict | None = None, cwd: str | None = None) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd)
    except FileNotFoundError as exc:
        raise RenderError(f"{cmd[0]} not found") from exc
    if p.returncode != 0:
        raise RenderError(f"{cmd[0]} {cmd[1] if len(cmd) > 1 else ''} failed: {first_line(p.stderr)}")
    return p.stdout


def yaml_docs(text: str) -> list[dict]:
    """Parse a multi-document YAML stream with yq; return the mapping documents."""
    if not text.strip():
        return []
    try:
        p = subprocess.run(["yq", "-o=json", "-I=0", "."], input=text, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RenderError("yq not found") from exc
    if p.returncode != 0:
        raise RenderError(f"yq could not parse YAML: {first_line(p.stderr)}")
    docs = []
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        doc = json.loads(line)
        if isinstance(doc, dict):
            docs.append(doc)
        elif isinstance(doc, list):  # a bare `List`-style array document
            docs.extend(d for d in doc if isinstance(d, dict))
    return docs


def file_docs(path: Path) -> list[dict]:
    try:
        return yaml_docs(path.read_text())
    except RenderError as exc:
        raise RenderError(f"{path}: {exc}") from exc


def is_application(doc: dict) -> bool:
    return doc.get("kind") == "Application" and str(doc.get("apiVersion", "")).startswith("argoproj.io/")


def sources_of(app: dict) -> list[dict]:
    spec = app.get("spec") or {}
    if spec.get("sources"):
        return list(spec["sources"])
    if spec.get("source"):
        return [spec["source"]]
    return []


class Renderer:
    def __init__(self, root: Path, out: Path, kube_version: str):
        self.root = root
        self.out = out
        self.kube_version = kube_version
        self.helm_home = Path(tempfile.mkdtemp(prefix="render-apps-helm-"))
        self.env = dict(os.environ)
        for key, sub in (("HELM_CACHE_HOME", "cache"), ("HELM_CONFIG_HOME", "config"), ("HELM_DATA_HOME", "data")):
            self.env.setdefault(key, str(self.helm_home / sub))
        self.tmp = Path(tempfile.mkdtemp(prefix="render-apps-values-"))

    def cleanup(self) -> None:
        shutil.rmtree(self.helm_home, ignore_errors=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- sources -------------------------------------------------------------
    def local_path(self, rel: str) -> Path:
        p = (self.root / rel).resolve()
        if self.root.resolve() not in p.parents and p != self.root.resolve():
            raise RenderError(f"path escapes the repository: {rel}")
        return p

    def helm_values_args(self, app_name: str, helm: dict, refs: dict[str, dict], chart_dir: Path | None) -> list[str]:
        args: list[str] = []
        for vf in helm.get("valueFiles") or []:
            if vf.startswith("$"):
                ref, _, rel = vf[1:].partition("/")
                if ref not in refs:
                    raise RenderError(f"valueFiles {vf}: no source with ref '{ref}'")
                if not is_this_repo(refs[ref].get("repoURL", "")):
                    raise RenderError(f"valueFiles {vf}: ref '{ref}' is not this repository")
                path = self.local_path(rel)
            elif chart_dir is not None:
                path = (chart_dir / vf).resolve()
            else:
                raise RenderError(f"valueFiles {vf}: relative value file on a remote chart")
            if not path.is_file():
                if helm.get("ignoreMissingValueFiles"):
                    continue
                raise RenderError(f"value file not found: {vf}")
            args += ["-f", str(path)]
        n = len(list(self.tmp.iterdir()))
        values = helm.get("values")
        if values:
            vpath = self.tmp / f"{n}-values.yaml"
            vpath.write_text(values if isinstance(values, str) else json.dumps(values))
            vpath.chmod(0o600)
            args += ["-f", str(vpath)]
        if helm.get("valuesObject"):
            vpath = self.tmp / f"{n}-values-object.json"
            vpath.write_text(json.dumps(helm["valuesObject"]))
            vpath.chmod(0o600)
            args += ["-f", str(vpath)]
        for param in helm.get("parameters") or []:
            flag = "--set-string" if param.get("forceString") else "--set"
            args += [flag, f"{param['name']}={param.get('value', '')}"]
        for fparam in helm.get("fileParameters") or []:
            args += ["--set-file", f"{fparam['name']}={self.local_path(fparam['path'])}"]
        return args

    def api_versions(self) -> list[str]:
        """Group/versions of the vendored CRD schemas, passed as --api-versions.

        Argo CD passes the live cluster's API versions to `helm template`; charts
        use them in `.Capabilities.APIVersions.Has` (Cilium refuses to render a
        ServiceMonitor without monitoring.coreos.com/v1). ci/schemas/ holds the
        CRDs the cluster serves, so its file names are the closest offline proxy.
        """
        if not hasattr(self, "_api_versions"):
            found = set()
            d = self.root / "ci/schemas"
            for f in sorted(d.glob("*_*_*.json")) if d.is_dir() else []:
                group, _kind, version = f.stem.rsplit("_", 2)
                if group != "apiextensions.k8s.io":
                    found.add(f"{group}/{version}")
            self._api_versions = sorted(found)
        return self._api_versions

    def helm_template(self, release: str, chart_args: list[str], namespace: str, extra: list[str], include_crds: bool) -> list[dict]:
        cmd = ["helm", "template", release, *chart_args, "--namespace", namespace or "default",
               "--kube-version", self.kube_version]
        for av in self.api_versions():
            cmd += ["--api-versions", av]
        if include_crds:
            cmd.append("--include-crds")
        return yaml_docs(run(cmd + extra, env=self.env))

    def render_helm_source(self, app_name: str, src: dict, namespace: str, refs: dict[str, dict]) -> list[dict]:
        helm = src.get("helm") or {}
        release = helm.get("releaseName") or app_name
        repo = src.get("repoURL", "")
        chart = src["chart"]
        version = str(src.get("targetRevision", ""))
        if not version:
            raise RenderError(f"chart {chart} has no targetRevision")
        if repo.startswith("oci://") or "://" not in repo:
            chart_args = [f"oci://{repo.removeprefix('oci://').rstrip('/')}/{chart}", "--version", version]
        else:
            chart_args = [chart, "--repo", repo, "--version", version]
        extra = self.helm_values_args(app_name, helm, refs, None)
        return self.helm_template(release, chart_args, namespace, extra, not helm.get("skipCrds"))

    def ksops_dir(self, d: Path) -> bool:
        for f in sorted(list(d.glob("*.yaml")) + list(d.glob("*.yml"))):
            try:
                text = f.read_text()
            except OSError:
                continue
            if "viaduct.ai/v1" in text and "ksops" in text:
                return True
        return False

    def render_dir(self, d: Path, directory: dict) -> list[dict]:
        recurse = bool(directory.get("recurse"))
        include = directory.get("include") or ""
        exclude = directory.get("exclude") or ""
        pattern = "**/*" if recurse else "*"
        docs: list[dict] = []
        for f in sorted(d.glob(pattern)):
            if not f.is_file() or f.suffix not in (".yaml", ".yml", ".json"):
                continue
            rel = str(f.relative_to(d))
            if include and not any(fnmatch.fnmatch(rel, g.strip()) for g in include.strip("{}").split(",")):
                continue
            if exclude and any(fnmatch.fnmatch(rel, g.strip()) for g in exclude.strip("{}").split(",")):
                continue
            docs.extend(file_docs(f))
        return docs

    def render_git_source(self, app_name: str, src: dict, namespace: str, refs: dict[str, dict]) -> tuple[list[dict], str | None]:
        if not is_this_repo(src.get("repoURL", "")):
            raise RenderError(f"git source {src.get('repoURL')} is not this repository")
        d = self.local_path(src["path"])
        if not d.is_dir():
            raise RenderError(f"path not found: {src['path']}")
        if any((d / k).is_file() for k in ("kustomization.yaml", "kustomization.yml", "Kustomization")):
            if self.ksops_dir(d):
                return [], f"skipped (KSOPS): {src['path']}"
            return yaml_docs(run(["kubectl", "kustomize", str(d)], env=self.env)), None
        if (d / "Chart.yaml").is_file():
            helm = src.get("helm") or {}
            release = helm.get("releaseName") or app_name
            extra = self.helm_values_args(app_name, helm, refs, d)
            return self.helm_template(release, [str(d)], namespace, extra, not helm.get("skipCrds")), None
        return self.render_dir(d, src.get("directory") or {}), None

    def render_app(self, app: dict) -> tuple[list[dict], list[str]]:
        name = app["metadata"]["name"]
        namespace = ((app.get("spec") or {}).get("destination") or {}).get("namespace") or "default"
        srcs = sources_of(app)
        if not srcs:
            raise RenderError("Application has no source")
        refs = {s["ref"]: s for s in srcs if s.get("ref")}
        docs: list[dict] = []
        notes: list[str] = []
        for src in srcs:
            if src.get("chart"):
                docs += self.render_helm_source(name, src, namespace, refs)
            elif src.get("path") is not None:
                got, note = self.render_git_source(name, src, namespace, refs)
                docs += got
                if note:
                    notes.append(note)
            elif src.get("ref"):
                continue  # a values-only source contributes no manifests
            else:
                raise RenderError("source has neither chart, path nor ref")
        return docs, notes

    def render_helm_release(self, name: str, entry: dict) -> list[dict]:
        for key in ("repo", "chart", "version", "namespace", "values"):
            if not entry.get(key):
                raise RenderError(f"ci/helm-releases.yaml entry {name} lacks {key}")
        values = self.local_path(entry["values"])
        if not values.is_file():
            raise RenderError(f"values file not found: {entry['values']}")
        chart_args = [entry["chart"], "--repo", entry["repo"], "--version", str(entry["version"])]
        return self.helm_template(entry.get("release") or name, chart_args, entry["namespace"], ["-f", str(values)], True)


def helm_release_entries(path: Path) -> list[tuple[str, dict]]:
    docs = file_docs(path)
    if not docs:
        return []
    top = docs[0]
    if isinstance(top.get("releases"), list):
        return [(e.get("name") or e.get("release"), e) for e in top["releases"]]
    return [(k, v) for k, v in top.items() if isinstance(v, dict)]


def layer_of(path: Path, root: Path) -> str | None:
    parts = path.relative_to(root).parts
    if len(parts) >= 3 and parts[0] == "clusters" and parts[2] in NEW_LAYERS:
        return parts[2]
    return None


def prepare_out(out: Path) -> None:
    if out.exists():
        if not (out / MARKER).exists() and any(out.iterdir()):
            raise SystemExit(f"render_apps: refusing to clear {out}: not a render_apps output directory")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / MARKER).write_text("render_apps output; safe to delete\n")
    out.chmod(0o700)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--repo-root", default=".")
    default_out = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()) / "render"
    ap.add_argument("--out", default=str(default_out))
    ap.add_argument("--scopes", default="1,2,3,4", help="comma list of scope items to render")
    ap.add_argument("--kube-version", default=os.environ.get("K8S_VERSION", "1.32.13"))
    args = ap.parse_args(argv)

    root = Path(args.repo_root).resolve()
    out = Path(args.out).resolve()
    scopes = {s.strip() for s in args.scopes.split(",") if s.strip()}
    prepare_out(out)
    r = Renderer(root, out, args.kube_version)

    # (key, app doc or helm entry, scope, origin, layer, kind)
    queue: list[tuple] = []
    errors = 0
    skipped: list[str] = []

    try:
        if "1" in scopes and (root / "kubernetes/applications").is_dir():
            legacy_root = {
                "apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
                "metadata": {"name": "all-apps", "namespace": "argo"},
                "spec": {"source": {"repoURL": "https://github.com/ned-si/homelab.git",
                                    "path": "kubernetes/applications", "directory": {"recurse": True}},
                         "destination": {"namespace": "argo"}},
            }
            queue.append((f"legacy/all-apps", legacy_root, "1", "kubernetes/applications (legacy root)", None, "app"))
            for f in sorted((root / "kubernetes/applications").rglob("*")):
                if f.is_file() and f.suffix in (".yaml", ".yml"):
                    for doc in file_docs(f):
                        if is_application(doc):
                            queue.append((f"legacy/{doc['metadata']['name']}", doc, "1",
                                          str(f.relative_to(root)), None, "app"))

        if "2" in scopes and (root / "clusters/homelab/root.yaml").is_file():
            for doc in file_docs(root / "clusters/homelab/root.yaml"):
                if is_application(doc):
                    queue.append((doc["metadata"]["name"], doc, "2", "clusters/homelab/root.yaml", None, "app"))

        scope3: list[tuple] = []
        if "3" in scopes:
            for layer in NEW_LAYERS:
                d = root / "clusters/homelab" / layer
                if not d.is_dir():
                    continue
                for f in sorted(d.rglob("*")):
                    if f.is_file() and f.suffix in (".yaml", ".yml"):
                        for doc in file_docs(f):
                            if is_application(doc):
                                scope3.append((doc["metadata"]["name"], doc, "3",
                                               str(f.relative_to(root)), layer, "app"))
        legacy_dir = root / "clusters/homelab/legacy"
        if legacy_dir.is_dir():
            for f in sorted(legacy_dir.rglob("*")):
                if f.is_file():
                    skipped.append(f"skipped (legacy artefact): {f.relative_to(root)}")

        if "4" in scopes and (root / "ci/helm-releases.yaml").is_file():
            for name, entry in helm_release_entries(root / "ci/helm-releases.yaml"):
                queue.append((f"helm-releases/{name}", entry, "4", "ci/helm-releases.yaml", None, "helm"))
    except RenderError as exc:
        print(f"ERROR discovery: {exc}")
        r.cleanup()
        return 1

    index: list[dict] = []
    done: dict[str, dict] = {}

    def process(item: tuple) -> None:
        nonlocal errors
        key, doc, scope, origin, layer, kind = item
        if key in done:
            entry = done[key]
            if scope not in entry["scope"].split("+"):
                entry["scope"] += f"+{scope}"
            if layer and not entry.get("layer"):
                entry["layer"] = layer
            return
        if kind == "helm":
            namespace = doc.get("namespace") or "default"
        else:
            namespace = ((doc.get("spec") or {}).get("destination") or {}).get("namespace") or "default"
        entry = {"app": key, "scope": scope, "origin": origin, "layer": layer, "namespace": namespace,
                 "objects": 0, "kinds": {}, "notes": [], "error": None, "children": []}
        done[key] = entry
        index.append(entry)
        try:
            if kind == "helm":
                docs, notes = r.render_helm_release(key.split("/", 1)[1], doc), []
            else:
                docs, notes = r.render_app(doc)
        except (RenderError, KeyError, TypeError) as exc:
            entry["error"] = str(exc)
            errors += 1
            print(f"ERROR {key}: {exc}")
            return
        entry["notes"] = notes
        entry["objects"] = len(docs)
        entry["kinds"] = dict(collections.Counter(f"{d.get('apiVersion')}/{d.get('kind')}" for d in docs))
        app_dir = out / key
        app_dir.mkdir(parents=True, exist_ok=True)
        # JSON documents, one per line, are valid YAML for kubeconform and exact for policy.
        with open(app_dir / "manifests.yaml", "w") as fh:
            for d in docs:
                fh.write("---\n" + json.dumps(d, sort_keys=True) + "\n")
        (app_dir / "manifests.yaml").chmod(0o600)
        for note in notes:
            print(f"{note} (app {key})")
        print(f"render {key}: {len(docs)} objects")
        # Scope 2: follow child Applications exactly as Argo would.
        if scope == "2" or "2" in entry["scope"].split("+"):
            for child in docs:
                if is_application(child):
                    cname = child["metadata"]["name"]
                    entry["children"].append(cname)
                    clayer = layer
                    if key.startswith("layer-"):
                        clayer = key.removeprefix("layer-")
                    process((cname, child, "2", f"child of {key}", clayer, "app"))

    for item in queue:
        process(item)
    for item in scope3:
        process(item)

    for line in skipped:
        print(line)
    with open(out / "index.json", "w") as fh:
        json.dump(index, fh, indent=1, sort_keys=True)
    with open(out / "files.txt", "w") as fh:
        for e in index:
            if not e["error"]:
                fh.write(str(out / e["app"] / "manifests.yaml") + "\n")
    total = sum(e["objects"] for e in index)
    n_skip = sum(1 for e in index if e["notes"]) + len(skipped)
    print(f"render: {len(index) - errors} applications rendered, {total} objects, "
          f"{n_skip} skipped, {errors} errors")
    r.cleanup()
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
