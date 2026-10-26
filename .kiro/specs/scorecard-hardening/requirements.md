---
kind: change
status: done
created: 2026-10-16
closed: 2026-10-26
---
# Requirements: Scorecard hardening

## Introduction

OpenSSF Scorecard rates this repository 7.9 (v5.6.0, 2026-10-16). Some checks are
low by design, some can't be read with the default token, and some point at real
gaps. This feature closes the real gaps honestly: every check that rises does so
because the control exists, not because a file looks like it does.

Non-goals:
- Code-Review and Contributors. One maintainer, no human gates
  ([docs/decisions.md](../../../docs/decisions.md#no-human-gates)).
- A badge, a workflow or a file whose only purpose is to raise a check.
- Releases or packages before the repository builds a real artifact.

## Glossary

- **Scorecard**: the `ossf/scorecard-action` run in `.github/workflows/scorecard.yaml`,
  published to api.scorecard.dev.
- **Read token**: the repository secret `SCORECARD_TOKEN`, a fine-grained personal access
  token on this repository only (Administration, Contents and Metadata read).
- **Fuzz target**: a function that takes arbitrary bytes and checks properties of a parser
  in `scripts/ci/`.

## Requirements

### Requirement 1: Branch protection is visible

**User story:** As the operator, I want Scorecard to read the protection on `main`, so that
the score reflects the settings that exist.

#### Acceptance criteria

1. WHEN Scorecard runs, THE workflow SHALL pass the read token as `repo_token`.
2. THE workflow SHALL keep the publishing restrictions of `ossf/scorecard-action`
   (`id-token: write` for the OIDC signature, no workflow-level write permissions).
3. THE read token SHALL be listed in `ci/secret-rotation.tsv` as an `api-token`.
4. WHEN the next run after the change completes, THE Branch-Protection check SHALL have a
   score instead of `?`.

### Requirement 2: Parsers are fuzzed

**User story:** As the operator, I want the parsers that gate merges fuzzed, so that hostile or
malformed input fails a check instead of crashing or hanging it.

#### Acceptance criteria

1. THE repository SHALL have coverage-guided fuzz targets for the image-reference, Kubernetes
   version and HCL parsers in `scripts/ci/repo_policy.py`.
2. WHEN a pull request changes a fuzzed parser or a fuzz target, THE fuzz workflow SHALL run
   every target for a short time budget.
3. THE fuzz workflow SHALL run every target nightly for a longer budget.
4. IF a target crashes, hangs or breaks a property, THEN THE workflow SHALL fail and print the
   input.
5. WHEN a crash is fixed, THE input SHALL be committed to the corpus, and THE unit tests
   SHALL replay the whole corpus.
6. THE fuzz tooling SHALL be pinned by hash and SHALL NOT build a container image.
7. WHEN the next Scorecard run completes, THE Fuzzing check SHALL be reported as it is
   detected, with no change made only to trigger detection.

### Requirement 3: Best Practices badge

**User story:** As the operator, I want the OpenSSF Best Practices "passing" answers ready,
so that the self-certification is copy-paste.

#### Acceptance criteria

1. THE operator SHALL get an answer and an evidence link for every passing criterion, in a
   local file outside git.
2. WHEN the badge is granted, THE README SHALL show it.

### Requirement 4: Signed releases with the first artifact

**User story:** As the operator, I want release signing to start with the first real artifact,
so that Signed-Releases and Packaging measure something.

#### Acceptance criteria

1. WHILE the repository builds no artifact, THE repository SHALL publish no release.
2. WHEN the blog image is first published, THE pipeline SHALL sign it with cosign (keyless),
   attach SLSA provenance, publish it to GHCR and create a GitHub release with the
   attestations.

### Requirement 5: Accepted gaps are written down

**User story:** As a reader of the public repository, I want to know why some checks stay
low, so that a low score isn't mistaken for neglect.

#### Acceptance criteria

1. THE decision record SHALL name Code-Review and Contributors as accepted gaps, with the
   reason and the compensating controls.
