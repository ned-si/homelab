# Contributing

This repository is the configuration of a personal homelab, run by one
operator. Issues and pull requests are welcome.

## Reporting

- Bugs, questions and ideas: a GitHub issue,
  <https://github.com/ned-si/homelab/issues>.
- Security problems: privately, as described in [SECURITY.md](SECURITY.md).
  Never in a public issue.

## Proposing a change

1. Open a pull request against `main`. `main` is production: merging deploys.
2. One topic per pull request. Unrelated changes get their own branch.
3. The required `ci` check is the only gate. The maintainer merges a pull
   request once `ci` is green, as a squash merge.

## Requirements

- Every commit is signed.
- Commit subjects and pull request titles follow Conventional Commits and
  stay under 70 characters, as checked by
  [scripts/ci/check-title.sh](scripts/ci/check-title.sh).
- New functionality lands with its tests: pytest or bash tests in `tests/`,
  Go tests next to the code in `dashboard/` and `techradar/`.
- Style: the Google Go Style Guide as far as golangci-lint checks it
  (`dashboard/.golangci.yaml`), shellcheck for shell, strict yamllint for
  YAML.
- Never commit a secret. Secrets live only in SOPS-encrypted `*.sops.yaml`
  files ([docs/secrets.md](docs/secrets.md)).

## Running the checks

```sh
pre-commit run --all-files       # every local hook: Passed or Skipped
python3 -m pytest -q tests       # Python and bash tests: all passed
(cd dashboard && go test ./...)  # ok for every package
(cd techradar && go test ./...)
```

The four layers of checks, from local hooks to deploy-time smoke tests:
[docs/testing.md](docs/testing.md).
