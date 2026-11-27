""".github/renovate.json5: what Renovate decides for a given update, by its own rule order.

packageRules apply top to bottom and later rules win. `effective()` evaluates
the matchers this config uses; a dependency without a matcher's field does
not match, as in Renovate. Each test reproduces a Renovate bug that reached
main and names its pull request.
"""
import json
import re
import subprocess
from fnmatch import fnmatchcase

import pytest

from conftest import REPO

CONFIG = REPO / ".github/renovate.json5"


def json5(text):
    """The JSON5 subset of renovate.json5: comments, single quotes, bare keys, trailing commas."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            i = text.find("\n", i) if "\n" in text[i:] else n
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        elif c in "'\"":
            j, buf = i + 1, []
            while text[j] != c:
                if text[j] == "\\":
                    buf.append(json.loads(f'"\\{text[j + 1]}"') if text[j + 1] in "\"\\/bfnrtu" else text[j + 1])
                    j += 2
                else:
                    buf.append(text[j])
                    j += 1
            out.append(json.dumps("".join(buf)))
            i = j + 1
        elif re.match(r"[A-Za-z_$]", c):
            m = re.match(r"[A-Za-z_$][\w$-]*", text[i:])
            word = m.group(0)
            rest = text[i + len(word):].lstrip()
            out.append(json.dumps(word) if rest.startswith(":") else word)
            i += len(word)
        else:
            out.append(c)
            i += 1
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))


CFG = json5(CONFIG.read_text())


def matches(pattern, value):
    if pattern.startswith("!"):
        return not matches(pattern[1:], value)
    m = re.fullmatch(r"/(.*)/([a-z]*)", pattern)
    if m:
        return re.search(m.group(1), value, re.I if "i" in m.group(2) else 0) is not None
    return fnmatchcase(value, pattern)


def list_matches(patterns, value):
    pos = [p for p in patterns if not p.startswith("!")]
    neg = [p for p in patterns if p.startswith("!")]
    return (not pos or any(matches(p, value) for p in pos)) and all(matches(p, value) for p in neg)


FIELDS = {"matchPackageNames": "packageName", "matchDepNames": "depName", "matchDatasources": "datasource",
          "matchUpdateTypes": "updateType", "matchManagers": "manager", "matchFileNames": "fileName",
          "matchCurrentValue": "currentValue", "matchNewValue": "newValue"}


def effective(**dep):
    dep.setdefault("depName", dep.get("packageName"))
    out = {"enabled": True, "labels": list(CFG.get("labels", []))}
    for rule in CFG["packageRules"]:
        keys = [k for k in rule if k.startswith(("match", "exclude"))]
        unknown = set(keys) - set(FIELDS) - {"matchCurrentVersion"}
        assert not unknown, f"extend effective() for {unknown}"
        if "matchCurrentVersion" in rule and "currentVersion" not in dep:
            continue
        ok = True
        for k in keys:
            if k == "matchCurrentVersion":
                continue
            value = dep.get(FIELDS[k])
            pats = rule[k] if isinstance(rule[k], list) else [rule[k]]
            if value is None or not list_matches(pats, value):
                ok = False
                break
        if not ok:
            continue
        for k, v in rule.items():
            if k == "addLabels":
                out["labels"] += v
            elif not k.startswith(("match", "exclude")) and k != "description":
                out[k] = v
    return out


def topic(eff, dep_name):
    """commitMessageTopic rendered for the two forms the config uses."""
    t = eff["commitMessageTopic"]
    m = re.fullmatch(r"\{\{\{replace '(.*)' '' depName\}\}\}", t)
    if m:
        return re.sub(m.group(1).replace("\\\\", "\\"), "", dep_name)
    return t.replace("{{depName}}", dep_name)


def test_json5_reader_agrees_with_node():
    # The reader above is only a test helper; check it against a real JS parser when node is there.
    try:
        out = subprocess.run(["node", "-e", "const fs=require('fs');"
                              "process.stdout.write(JSON.stringify(new Function('return (' + "
                              "fs.readFileSync(process.argv[1],'utf8') + ')')()))", str(CONFIG)],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        pytest.skip("node not available")
    assert json.loads(out) == CFG


def test_cnpg_postgres_major_is_held_277():
    # #277: a CNPG major would overwrite the old timeline's WAL unless serverName moves with it.
    eff = effective(packageName="ghcr.io/cloudnative-pg/postgresql", datasource="docker", updateType="major")
    assert eff["enabled"] is False
    assert effective(packageName="ghcr.io/cloudnative-pg/postgresql", datasource="docker",
                     updateType="minor")["enabled"] is True


@pytest.mark.parametrize("pkg", ["docker.io/valkey/valkey", "docker.io/clickhouse/clickhouse-server", "mariadb"])
def test_data_store_majors_do_not_automerge_568(pkg):
    # #568: a data-store major rewrites its on-disk format; a revert cannot undo it.
    eff = effective(packageName=pkg, datasource="docker", updateType="major")
    assert eff["automerge"] is False and "no-automerge" in eff["labels"]
    assert effective(packageName=pkg, datasource="docker", updateType="patch")["automerge"] is True


@pytest.mark.parametrize("dep", ["cilium", "kubernetes-sigs/gateway-api"])
def test_cluster_networking_waits_and_merges_on_weekdays_902(dep):
    # #902: the 3-day hold of Cilium and Gateway API was lost (postmortem 2026-10-23).
    eff = effective(packageName=dep, depName=dep, datasource="helm", updateType="patch")
    assert eff["minimumReleaseAge"] == "3 days"
    assert eff["automergeSchedule"] == ["* 9-16 * * 1-5"]
    assert "automerge-weekdays" in eff["labels"]


def test_home_assistant_pip_pins_wait_994():
    # #994: a PyPI release HA's wheel index had not built yet kept Home Assistant from starting.
    eff = effective(packageName="joserfc", datasource="pypi", updateType="minor",
                    fileName="apps/home/home-assistant.yaml")
    assert eff["minimumReleaseAge"] == "3 days"


@pytest.mark.parametrize("current, new, enabled", [
    ("3.14.8-alpine3.24", "3.15.0", False),  # #394, fixed by #407
    ("3.14.8-alpine3.24", "3.15.0-alpine3.24", True),
    ("1.2-slim", "1.3", False),
    ("17-bookworm", "18-trixie", False),
])
def test_tag_variant_never_changes_407(current, new, enabled):
    # #407: an update moved python:*-alpine3.24 to the full Debian image.
    eff = effective(packageName="python", datasource="docker", updateType="minor", currentValue=current, newValue=new)
    assert eff["enabled"] is enabled


def test_docker_custom_managers_keep_tag_suffixes_406():
    # #406: semver-coerced versioning dropped the -alpine/-slim suffix of annotated image tags.
    docker = [m for m in CFG["customManagers"] if any("datasource=docker" in s for s in m["matchStrings"])]
    assert docker
    for m in docker:
        assert m["versioningTemplate"].endswith("{{else}}docker{{/if}}"), m["description"]


@pytest.mark.parametrize("dep, want", [
    ("ghcr.io/ned-si/homelab-dashboard", "ned-si/homelab-dashboard"),
    ("registry.k8s.io/kubectl", "kubectl"),
    ("docker.io/timberio/vector", "timberio/vector"),
])
def test_topic_drops_the_registry_host_664(dep, want):
    # #664: full ghcr.io/<org>/<image> topics pushed PR titles past 70 characters; they never merged.
    assert topic(effective(packageName=dep, datasource="docker", updateType="patch"), dep) == want


def test_yace_chart_title_fits_879():
    # #879: "chart prometheus-yet-another-cloudwatch-exporter" put the title at 79 characters.
    dep = "prometheus-yet-another-cloudwatch-exporter"
    t = topic(effective(packageName=dep, datasource="helm", updateType="minor"), dep)
    assert t == "chart yace"
    assert len(f"chore(deps): update {t} to v100.100.100 (#9999)") < 70


def test_renovate_train_can_turn_auto_merge_on_1069():
    # #1069: with contents: read, enablePullRequestAutoMerge failed and the train stopped.
    out = subprocess.run(["yq", "-o=json", ".", str(REPO / ".github/workflows/renovate-next.yaml")],
                         capture_output=True, text=True, check=True).stdout
    perms = json.loads(out)["jobs"]["next"]["permissions"]
    assert perms.get("contents") == "write" and perms.get("pull-requests") == "write"
