"""Fuzz targets for the parsers in scripts/ci/repo_policy.py.

Each target takes arbitrary bytes, decodes them as UTF-8 (invalid bytes
replaced) and asserts the parser's contract. An exception or a failed assert is
a finding. tests/fuzz/fuzz.py runs them under Atheris; tests/test_fuzz_corpus.py
replays tests/fuzz/corpus/<target>/ through them without Atheris.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "ci"))
import repo_policy as rp  # noqa: E402

# The headers the backup-bucket-lock rule passes to hcl_block/hcl_blocks.
HCL_HEADERS = (r'resource\s+"aws_s3_bucket_policy"\s+"backups"', r'data\s+"aws_iam_policy_document"\s+"bucket"',
               r"statement", r"condition", r"principals")
HCL_ATTRS = ("effect", "actions", "resources", "type", "identifiers", "policy")


def _text(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def image_ref(data: bytes) -> None:
    """IMAGE_LINE, DIGEST, parse_image, image_variant and is_lighter on one line or reference."""
    text = _text(data)
    for line in text.splitlines() or [text]:
        m = rp.IMAGE_LINE.match(line)
        if m:
            ref = m.group("ref")
            assert ref and not any(c.isspace() or c in "'\"#" for c in ref), ref
            check_ref(ref)
    check_ref(text)


def check_ref(ref: str) -> None:
    d = rp.DIGEST.search(ref)
    if d:
        # `$` also matches before one final newline.
        assert ref[d.end():] in ("", "\n") and len(d.group(0)) == len("@sha256:") + 64, ref
    parsed = rp.parse_image(ref)
    last = ref.split("@", 1)[0].rpartition("/")[2]
    assert (parsed is None) == (":" not in last), (ref, parsed)
    if parsed is None:
        return
    repo, tag = parsed
    assert isinstance(repo, str) and isinstance(tag, str)
    assert "/" not in tag and "@" not in tag, tag
    name = last.split(":", 1)[0]
    assert repo.endswith(name) and tag == last.split(":", 1)[1], (ref, parsed)
    variant = rp.image_variant(tag)
    assert variant <= rp.VARIANT_WORDS, variant
    if tag.isascii():
        assert rp.image_variant(tag.upper()) == variant, tag
    if rp.is_lighter(variant):
        assert variant & rp.LIGHT_VARIANTS, variant
    assert not rp.is_lighter(frozenset())


def k8s_minor(data: bytes) -> None:
    """k8s_minor: None, or a (major, minor) pair of digit strings that parses back to itself."""
    text = _text(data)
    got = rp.k8s_minor(text)
    if got is None:
        return
    major, minor = got
    assert major.isdigit() and minor.isdigit(), got
    assert rp.k8s_minor(f"{major}.{minor}") == got, got
    assert rp.k8s_minor(f"v{major}.{minor}.0") == got, got


def hcl(data: bytes) -> None:
    """hcl_blocks, hcl_block, hcl_strings and lock_statement on arbitrary text."""
    text = _text(data)
    for header in HCL_HEADERS:
        blocks = rp.hcl_blocks(text, header)
        assert len(blocks) <= text.count("{"), (header, len(blocks))
        for body in blocks:
            assert body in text, header
            assert isinstance(rp.lock_statement(body), bool)
            for attr in HCL_ATTRS:
                got = rp.hcl_strings(body, attr)
                assert got is None or all(isinstance(s, str) and '"' not in s for s in got), (attr, got)
        one = rp.hcl_block(text, header)
        assert one is None or (len(blocks) == 1 and one == blocks[0]), header
    assert isinstance(rp.lock_statement(text), bool)


TARGETS = {"image_ref": image_ref, "k8s_minor": k8s_minor, "hcl": hcl}
