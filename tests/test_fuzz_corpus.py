"""tests/fuzz: every corpus input (seeds and past findings) passes its target, without Atheris."""
import sys

import pytest

from conftest import REPO

sys.path.insert(0, str(REPO / "tests" / "fuzz"))
import targets  # noqa: E402

CORPUS = REPO / "tests" / "fuzz" / "corpus"
INPUTS = sorted(p for p in CORPUS.glob("*/*") if p.is_file())


def test_every_target_has_a_corpus():
    assert sorted(p.name for p in CORPUS.iterdir() if p.is_dir()) == sorted(targets.TARGETS)


@pytest.mark.parametrize("path", INPUTS, ids=[str(p.relative_to(CORPUS)) for p in INPUTS])
def test_corpus_input(path):
    targets.TARGETS[path.parent.name](path.read_bytes())
