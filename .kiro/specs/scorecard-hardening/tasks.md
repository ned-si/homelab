# Tasks: Scorecard hardening

Each task is one PR or one recorded check. Requirement numbers in brackets.

- [ ] 1. PR: this spec; Contributors as an accepted gap in `docs/decisions.md`. [5.1]
- [ ] 2. PR: `repo_token` from `SCORECARD_TOKEN` in the Scorecard workflow; the token's row in
      `ci/secret-rotation.tsv`. [1.1, 1.2, 1.3]
- [ ] 3. Check: the next Scorecard run scores Branch-Protection. [1.4]
- [ ] 4. PR: Atheris fuzz targets, corpus replay test, fuzz workflow (PR + nightly), pinned
      requirements. [2.1–2.6]
- [ ] 5. Check: the fuzz workflow runs green on the PR; record what the next Scorecard run
      reports for Fuzzing. [2.2, 2.7]
- [ ] 6. Local: the Best Practices passing answers with evidence links for the operator.
      [3.1]
- [ ] 7. PR (after the badge is granted): the README badge. [3.2]
- [ ] 8. Later, with the blog image: signed release, provenance, GHCR. [4.2]
