"""scripts/ci/image_provenance.py: collection, signer list, statuses and exit codes (fake cosign, no network)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap

import pytest

from conftest import REPO, SCRIPTS, write

import image_provenance as ip

D1 = "sha256:" + "1" * 64
D2 = "sha256:" + "2" * 64
D3 = "sha256:" + "3" * 64
ISSUER = "https://token.actions.githubusercontent.com"
SUBJECT = "https://github.com/acme/app/.github/workflows/release.yaml@refs/tags/v1.0.0"
OWN_SUBJECT = "https://github.com/ned-si/homelab/.github/workflows/site-publish.yaml@refs/heads/main"

# Fake cosign: FAKE_SIGNED lists repo@digest targets with a signature,
# FAKE_ATT those with attestations, FAKE_SUBJECT is the signing identity,
# FAKE_TRANSIENT makes every call fail with a 503.
FAKE_COSIGN = textwrap.dedent(
    """\
    #!/bin/bash
    echo "$*" >> "$FAKE_LOG"
    ref=${@: -1}
    if [ -n "${FAKE_TRANSIENT:-}" ]; then echo "GET https://registry: 503 Service Unavailable" >&2; exit 1; fi
    case "$1" in
      tree)
        case " $FAKE_SIGNED " in *" $ref "*)
          echo "└── 🔐 Signatures for an image tag: x.sig" ;;
        *) echo "No Supply Chain Security Related Artifacts found for image $ref" ;; esac
        case " $FAKE_ATT " in *" $ref "*) echo "└── 💾 Attestations for an image tag: x.att" ;; esac
        exit 0 ;;
      verify)
        case " $FAKE_SIGNED " in *" $ref "*) ;; *) echo "no signatures found" >&2; exit 1 ;; esac
        if [ -n "${FAKE_KEYED:-}" ]; then echo "no matching signatures: certificate missing" >&2; exit 1; fi
        want=""; prev=""
        for a in "$@"; do
          case "$prev" in --certificate-identity) want=$a ;; --certificate-identity-regexp) want=re:$a ;; esac
          prev=$a
        done
        case "$want" in
          re:*) echo "$FAKE_SUBJECT" | grep -Eq "${want#re:}" || { echo "none of the expected identities matched" >&2; exit 1; } ;;
          *) [ "$want" = "$FAKE_SUBJECT" ] || { echo "none of the expected identities matched" >&2; exit 1; } ;;
        esac
        printf '[{"optional":{"Issuer":"%s","Subject":"%s"}}]\\n' "$ISSUER" "$FAKE_SUBJECT"
        exit 0 ;;
    esac
    exit 64
    """
)


@pytest.fixture
def env(tmp_path, monkeypatch):
    cosign = tmp_path / "cosign"
    cosign.write_text(FAKE_COSIGN)
    cosign.chmod(0o755)
    monkeypatch.setenv("COSIGN_BIN", str(cosign))
    monkeypatch.setenv("DOCKER_BIN", str(tmp_path / "no-docker"))
    monkeypatch.setenv("FAKE_LOG", str(tmp_path / "cosign.log"))
    monkeypatch.setenv("ISSUER", ISSUER)
    monkeypatch.setenv("FAKE_SUBJECT", SUBJECT)
    monkeypatch.setenv("FAKE_SIGNED", "")
    monkeypatch.setenv("FAKE_ATT", "")
    monkeypatch.setattr(ip, "BACKOFF", (0, 0, 0))
    write(tmp_path, "deploy/apps/app/deployment-app.yaml", f"""\
        apiVersion: apps/v1
        kind: Deployment
        metadata: {{name: app, namespace: app}}
        spec:
          template:
            spec:
              containers:
                - name: app
                  image: ghcr.io/acme/app:1.0.0@{D1}
              initContainers:
                - name: init
                  image: docker.io/library/busybox:1.38.0@{D2}
        """)
    write(tmp_path, "deploy/apps/db/cluster-db.yaml", f"""\
        apiVersion: postgresql.cnpg.io/v1
        kind: Cluster
        metadata: {{name: db, namespace: db}}
        spec:
          imageName: ghcr.io/acme/app:1.0.0@{D1}
        """)
    write(tmp_path, "render/chart/manifests.yaml", f"""\
        ---
        {{"apiVersion": "v1", "kind": "Pod", "metadata": {{"name": "p"}}, "spec": {{"containers": [{{"image": "quay.io/x/y:2@{D3}"}}]}}}}
        """)
    return tmp_path


def signers(root, text):
    return write(root, "ci/image-signers.yaml", text)


def run(root, *extra):
    return subprocess.run([sys.executable, str(SCRIPTS / "image_provenance.py"), "--deploy", str(root / "deploy"),
                           "--render", str(root / "render"), "--signers", str(root / "ci/image-signers.yaml"),
                           "--json", str(root / "out.json"), *extra], capture_output=True, text=True)


def rows(root):
    return {r["repository"]: r for r in json.loads((root / "out.json").read_text())}


LISTED = f"""\
    - repository: busybox
      unsigned: no signature published
    - repository: ghcr.io/acme/app
      issuer: {ISSUER}
      subjectRegExp: ^https://github\\.com/acme/app/\\.github/workflows/release\\.yaml@refs/tags/v.+$
    - repository: quay.io/x/y
      unsigned: no signature published
    """


def test_collects_every_image_with_its_users(env):
    signers(env, "[]\n")
    r = run(env, "--offline")
    assert r.returncode == 0, r.stderr
    got = rows(env)
    assert set(got) == {"ghcr.io/acme/app", "busybox", "quay.io/x/y"}
    assert got["ghcr.io/acme/app"]["used_by"] == ["app/Deployment/app", "db/Cluster/db"]
    assert got["quay.io/x/y"]["used_by"] == ["-/Pod/p"]
    assert "registry calls: 0" in r.stdout


def test_verified_and_unsigned_listed_exit_0(env, monkeypatch):
    monkeypatch.setenv("FAKE_SIGNED", f"ghcr.io/acme/app@{D1}")
    monkeypatch.setenv("FAKE_ATT", f"ghcr.io/acme/app@{D1}")
    signers(env, LISTED)
    r = run(env)
    assert r.returncode == 0, r.stdout + r.stderr
    got = rows(env)
    assert got["ghcr.io/acme/app"]["status"] == "verified"
    assert got["ghcr.io/acme/app"]["attestations"] == "yes"
    assert got["busybox"]["status"] == "unsigned-listed"
    assert got["busybox"]["attestations"] == "no"
    # The tag is dropped and the registry kept as written.
    assert f"tree docker.io/library/busybox@{D2}" in (env / "cosign.log").read_text()


def test_mismatch_exits_1(env, monkeypatch):
    monkeypatch.setenv("FAKE_SIGNED", f"ghcr.io/acme/app@{D1}")
    monkeypatch.setenv("FAKE_SUBJECT", "https://github.com/evil/app/.github/workflows/x.yaml@refs/heads/main")
    signers(env, LISTED)
    r = run(env)
    assert r.returncode == 1
    assert rows(env)["ghcr.io/acme/app"]["status"] == "mismatch"
    assert "| mismatch |" in r.stdout


def test_listed_identity_without_signature_is_mismatch(env):
    signers(env, LISTED)
    assert run(env).returncode == 1
    assert rows(env)["ghcr.io/acme/app"]["detail"] == "no signature"


def test_signed_unlisted_reports_the_signer(env, monkeypatch):
    monkeypatch.setenv("FAKE_SIGNED", f"quay.io/x/y@{D3}")
    signers(env, "[]\n")
    r = run(env)
    assert r.returncode == 0, r.stderr
    got = rows(env)["quay.io/x/y"]
    assert (got["status"], got["issuer"], got["signer"]) == ("signed-unlisted", ISSUER, SUBJECT)
    assert rows(env)["busybox"]["status"] == "unsigned"


def test_key_based_signature(env, monkeypatch):
    monkeypatch.setenv("FAKE_SIGNED", f"quay.io/x/y@{D3}")
    monkeypatch.setenv("FAKE_KEYED", "1")
    signers(env, "[]\n")
    assert run(env).returncode == 0
    assert rows(env)["quay.io/x/y"]["signer"] == "key-based"


def test_transient_errors_retry_then_error(env, monkeypatch):
    monkeypatch.setenv("FAKE_TRANSIENT", "1")
    signers(env, "[]\n")
    monkeypatch.setattr(sys, "argv", ["x"])
    rc = ip.main(["--deploy", str(env / "deploy"), "--signers", str(env / "ci/image-signers.yaml"),
                  "--json", str(env / "out.json")])
    assert rc == 1
    assert {r["status"] for r in rows(env).values()} == {"error"}
    calls = (env / "cosign.log").read_text().splitlines()
    assert len(calls) == 2 * (len(ip.BACKOFF) + 1)


def test_no_digest_is_unsigned(env):
    write(env, "deploy/apps/x/pod-x.yaml", "kind: Pod\nmetadata: {name: x, namespace: x}\nspec: {containers: [{image: 'nginx:1.29'}]}\n")
    signers(env, "[]\n")
    assert run(env, "--offline").returncode == 0
    assert rows(env)["nginx"]["note"] == "no digest"


@pytest.mark.parametrize("text, msg", [
    ("- repository: busybox\n", "exactly one"),
    ("- repository: busybox\n  unsigned: ''\n", "reason"),
    ("- repository: docker.io/library/busybox\n  unsigned: x\n", "parse_image form"),
    ("- repository: busybox:1\n  unsigned: x\n", "without tag"),
    ("- repository: a/b\n  subject: s\n", "issuer"),
    ("- repository: a/b\n  issuer: http://x\n  subject: s\n", "issuer"),
    ("- repository: a/b\n  issuer: https://x\n  subjectRegExp: '('\n", "subjectRegExp"),
    ("- repository: a/b\n  unsigned: x\n  owner: me\n", "unknown keys"),
    ("- repository: a/b\n  unsigned: x\n- repository: a/b\n  unsigned: y\n", "duplicate"),
])
def test_signer_list_schema_errors_exit_2(env, text, msg):
    signers(env, text)
    r = run(env, "--offline")
    assert r.returncode == 2
    assert msg in r.stderr


def test_unparsable_manifest_exits_2(env):
    write(env, "deploy/apps/bad/x.yaml", "a: [\n")
    signers(env, "[]\n")
    assert run(env, "--offline").returncode == 2


def test_repo_signer_list_is_valid_and_complete():
    entries = ip.load_signers(REPO / "ci" / "image-signers.yaml")
    assert all(("unsigned" in e) != ("issuer" in e) for e in entries.values())
    assert list(entries) == sorted(entries)
    images = ip.collect(ip.manifest_files(REPO / "deploy", None))
    missing = {r["repository"] for r in images.values()} - set(entries)
    assert missing == set()
    assert entries["ghcr.io/ned-si/homelab-site"]["subject"] == OWN_SUBJECT
    assert os.access(SCRIPTS / "image_provenance.py", os.X_OK)
