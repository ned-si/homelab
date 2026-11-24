"""Argo CD Notifications in bootstrap/argocd-values.yaml.

A sync that ends Healthy sets the commit status `argocd/<application>` on the
deployed revision of this repository (the homelab dashboard's lead time and
time to restore), next to the two rollback triggers. Every Application
gets all three through the default subscription.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VALUES = REPO / "bootstrap" / "argocd-values.yaml"
REPO_URL = "https://github.com/ned-si/homelab.git"


def yaml_json(text: str):
    out = subprocess.run(["yq", "-o=json", "."], input=text, check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def notifications() -> dict:
    return yaml_json(VALUES.read_text())["notifications"]


def trigger(name: str) -> list[dict]:
    return yaml_json(notifications()["triggers"][f"trigger.{name}"])


def template() -> dict:
    return yaml_json(notifications()["templates"]["template.argocd-commit-status"])["webhook"]["github-dispatch"]


def test_every_application_gets_the_three_triggers():
    subs = notifications()["subscriptions"]
    assert len(subs) == 1 and "selector" not in subs[0]
    assert subs[0]["recipients"] == ["github-dispatch"]
    assert set(subs[0]["triggers"]) == {"on-sync-failed", "on-health-degraded", "on-deployed"}


def test_on_deployed_fires_once_per_revision_on_a_healthy_sync():
    (cond,) = trigger("on-deployed")
    assert cond["when"] == (
        "app.status?.operationState?.phase == 'Succeeded' && app.status?.health?.status == 'Healthy'")
    assert "syncResult?.revision," in cond["oncePer"] and "syncResult?.revisions]" in cond["oncePer"]
    assert cond["send"] == ["argocd-commit-status"]


def test_rollback_triggers_are_unchanged():
    for name, template_name in (("on-sync-failed", "argo-degraded-sync-failed"),
                                ("on-health-degraded", "argo-degraded-health")):
        (cond,) = trigger(name)
        assert cond["send"] == [template_name]


def test_commit_status_goes_to_this_repository_revision():
    t = template()
    assert t["method"] == "POST"
    assert t["path"].startswith("/repos/ned-si/homelab/statuses/ {{-")
    assert "\n" not in t["path"]
    assert f'eq $s.repoURL "{REPO_URL}"' in t["path"]


def test_commit_status_body():
    body = template()["body"].replace("{{ .app.metadata.name }}", "immich")
    assert json.loads(body) == {
        "state": "success", "context": "argocd/immich", "description": "Synced"}


def test_every_application_tracks_this_repository():
    # The path picks the revision of REPO_URL; an Application without it would
    # get no status.
    for f in sorted((REPO / "clusters" / "homelab").rglob("*.yaml")):
        if f.name == "kustomization.yaml":
            continue
        for doc in f.read_text().split("\n---\n"):
            if "kind: Application\n" not in doc:
                continue
            spec = yaml_json(doc)["spec"]
            urls = [s["repoURL"] for s in spec.get("sources", [spec.get("source", {})])]
            assert REPO_URL in urls, f.name
