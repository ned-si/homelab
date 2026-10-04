"""scripts/ci/check-title.sh: Conventional Commits regex AND length < 70."""
import subprocess

import pytest

from conftest import SCRIPTS

CHECK = str(SCRIPTS / "check-title.sh")

# The reworded subjects planned for the restructure integration (all must pass).
PLANNED = [
    "feat(infra): declare namespaces and add SOPS secret bundles",
    "fix(apps): reconcile immutable fields and rollout strategy",
    "docs: add the staged migration plan from the running cluster",
    "feat(gitops): render manifests into deploy/ for Argo CD",
    "fix(cert-manager): reuse the live Secret and ACME account names",
    "feat(backup): create the S3 target as code on Glacier IR",
    "feat(backup): add VolumeSnapshot rollback points",
    "feat(backup): add the local NFS target and a second Immich repo",
    "feat(security): add Cilium NetworkPolicies, not enforced yet",
    "docs(runbooks): add a copy-paste restart guide",
    "feat(cd): track a deployed tag and allow Argo CD under PSS",
    "fix(secrets): resolve the age identity on macOS",
    "fix(secrets): stop doubling the democratic-csi SSH key armour",
    "feat(secrets): seal all twelve credentials and prove decryption",
    "fix(monitoring): start Alertmanager without a notification transport",
    "fix(ci): make pre-commit pass for shellcheck and private keys",
    "fix(ci): make the secrets-check hook actually strict",
    "fix(ci): make SAST findings readable and run both scanners",
    "docs: make the restart runbook findable without task",
    "security(ci): triage the 39 Trivy findings",
    "fix(ci): stop failing on SARIF uploads this repo cannot accept",
    "feat(theater): sync TRaSH Guides into Sonarr and Radarr",
]

GOOD = [
    "ci: add pinned CI gates for both repository layouts",
    "refactor!: adopt the layered GitOps tree at parity with live",
    "chore(argo): roll up Application health",
    "test(ops): add a read-only cluster smoke suite",
    "fix(lb): pin syncthing and qbittorrent LoadBalancer IPs (#38)",
]

BAD = [
    "Add CI",                                   # no type
    "ci: add CI.",                              # trailing dot
    "ci: add CI ",                              # trailing space
    "ci:add CI",                                # no space after colon
    "ci:  add CI",                              # leading space in summary
    "feature: add CI",                          # unknown type
    "ci(Scope): add CI",                        # upper-case scope
    "ci: a",                                    # summary too short for the regex
    "",                                         # empty
]


def check(subject: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", CHECK, subject], capture_output=True, text=True)


@pytest.mark.parametrize("subject", PLANNED + GOOD)
def test_passes(subject):
    r = check(subject)
    assert r.returncode == 0, r.stderr
    assert len(subject) < 70


def test_planned_count():
    assert len(PLANNED) == 22


@pytest.mark.parametrize("subject", BAD)
def test_fails(subject):
    assert check(subject).returncode == 1


def test_matching_75_char_subject_fails_on_length():
    subject = "feat(very-long-scope-name/for-the-length-test): add the thing to it now"
    subject = subject + "x" * (75 - len(subject))
    assert len(subject) == 75
    r = check(subject)
    assert r.returncode == 1
    assert "characters" in r.stderr
    assert "not a Conventional" not in r.stderr  # it matches the regex; length alone fails it


def test_69_chars_pass_70_fail():
    base = "docs(scope-x): " + "a" * 54
    assert len(base) == 69 and check(base).returncode == 0
    assert check(base + "b").returncode == 1


def test_summary_longer_than_60_fails_the_regex():
    assert check("docs: " + "a" * 61).returncode == 1
    assert check("docs: " + "a" * 60).returncode == 0


def test_usage():
    assert subprocess.run(["bash", CHECK], capture_output=True).returncode == 64
