# Tasks: Scorecard hardening

Each task is one PR or one recorded check. Requirement numbers in brackets.

- [x] 1. PR: this spec; Contributors as an accepted gap in `docs/decisions.md`. [5.1] (#511)
- [x] 2. PR: `repo_token` from `SCORECARD_TOKEN` in the Scorecard workflow; the token's row in
      `ci/secret-rotation.tsv`. [1.1, 1.2, 1.3] (#512; rows `actions-secret:<NAME>`)
- [x] 3. Check: the next Scorecard run scores Branch-Protection. [1.4]
      (4/10 on 855213b: deletion and force pushes blocked, admins included, PRs, up-to-date
      and status checks required; no approvers, by design)
- [x] 4. PR: Atheris fuzz targets, corpus replay test, fuzz workflow (PR + nightly), pinned
      requirements. [2.1–2.6] (#517)
- [x] 5. Check: the fuzz workflow runs green on the PR; record what the next Scorecard run
      reports for Fuzzing. [2.2, 2.7] (PR run: 3 targets × 60 s, no finding; Scorecard on
      8fe11c5: Fuzzing 10, "PythonAtherisFuzzer integration found: tests/fuzz/fuzz.py")
- [x] 6. Local: the Best Practices passing answers with evidence links for the operator.
      [3.1]
- [ ] 7. PR (after the badge is granted): the README badge. [3.2]
- [ ] 8. Later, with the blog image: signed release, provenance, GHCR. [4.2]
