# Design: Scorecard hardening

## Branch protection (Requirement 1)

`ossf/scorecard-action` reads classic branch protection only with a token that has
Administration read; the default `GITHUB_TOKEN` can't, so the check shows `?`. Its
fine-grained token guide passes the token as `repo_token: ${{ secrets.SCORECARD_TOKEN }}`
alongside `publish_results: true`. The token only authenticates the API reads; the
published results are still signed with the job's OIDC token (`id-token: write`), so the
publishing restrictions stay as they are.

The token is a fine-grained PAT on this repository only, read-only, with a 180-day expiry.
It is rotated like the other API tokens: an `api-token` row in `ci/secret-rotation.tsv`
(checked by `scripts/ci/secret_rotation.py`, weekly `age`).

Expected result: a partial score, because `main` requires the `ci` check, signed commits and
linear history, but no approving review.

Rejected: moving `main` to repository rulesets, which the default token can read. The classic
protection is what `scripts/pr-merge.sh`, the runbooks and the auto-rollback token rely on;
changing it to raise a check is out of scope.

## Fuzzing (Requirement 2)

Atheris (Google's coverage-guided Python fuzzer, libFuzzer inside) runs in a plain GitHub
Actions job.

- Targets: `tests/fuzz/targets.py` holds one function per parser that takes bytes, decodes
  them as UTF-8 (invalid bytes replaced) and asserts properties:
  - `image_ref`: `IMAGE_LINE`, `DIGEST`, `parse_image`, `image_variant`, `is_lighter`;
  - `k8s_minor`: `k8s_minor`;
  - `hcl`: `hcl_blocks`, `hcl_block`, `hcl_strings`, `lock_statement` with the headers the
    `backup-bucket-lock` rule uses.

  The properties are the functions' contracts (no exception, results consistent with the
  input), and libFuzzer's `-timeout` catches a pathological regex or a loop that doesn't end.
- Harness: `tests/fuzz/fuzz.py <target> [libFuzzer flags]` imports the targets under
  `atheris.instrument_imports()`.
- Corpus: `tests/fuzz/corpus/<target>/`, small readable seeds from real repository shapes,
  plus every input that once failed. `tests/test_fuzz_corpus.py` replays the corpus through
  the same functions without Atheris, in the normal pytest run.
- Workflow `.github/workflows/fuzz.yaml`: on pull requests that touch
  `scripts/ci/repo_policy.py`, `scripts/ci/app_profiles.py`, `tests/fuzz/**`, the
  requirements or the workflow, 60 s per target; nightly and on demand, 10 min per target.
  New corpus entries go to a temporary copy; a failure prints the input as base64 in the
  step summary. It is not part of the required `ci` check: a fuzz finding is a bug to fix
  forward, not a merge gate for unrelated changes.
- Dependencies: `ci/requirements-fuzz.txt`, Atheris wheels pinned by sha256, installed with
  `--require-hashes --only-binary=:all:` into a venv.

Scorecard detects Python fuzzing by the line `import atheris` in a `.py` file when Python is
one of the repository's prominent languages (at least the average share of bytes; true
today). The detection follows from the real harness; nothing is added for it.

Rejected:
- ClusterFuzzLite: it needs `.clusterfuzzlite/Dockerfile` and builds an image from the
  OSS-Fuzz base images on every run. The repository builds no images and pins every image
  by digest; the OSS-Fuzz base images are tracked by moving tags.
- Hypothesis property tests: not coverage-guided, and Scorecard doesn't detect them for
  Python.

The Go blog/hub parsers get native `func FuzzXxx` tests when that code exists.

## Best Practices badge (Requirement 3)

The project is registered on bestpractices.dev. The answers for the passing level, each with
an evidence link into the repository, are in a local file for the operator, who submits
them. The README badge is added in its own PR once the badge is granted.

## Signed releases (Requirement 4)

No release before there is an artifact. The first one is the blog image: built in CI, signed
keyless with cosign, SLSA provenance, pushed to GHCR, a GitHub release with the
attestations. The blog's own spec carries this when it is written.

## Accepted gaps (Requirement 5)

`docs/decisions.md`, "No human gates", already names Code-Review; it gains Contributors.
