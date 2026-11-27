# Contributing

This repository is the configuration of a personal homelab, run by one
operator. Issues and pull requests are welcome. Participation follows the
[Code of Conduct](CODE_OF_CONDUCT.md); how decisions are made and who does
what: [GOVERNANCE.md](GOVERNANCE.md).

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
- Major new functionality MUST add tests to the automated suite that CI
  runs: pytest or bash tests in `tests/`, Go tests next to the code in
  `dashboard/`, `techradar/` and `drumcharts/`.
- Every bug fix MUST land with a regression test in the same pull request:
  a test in an automated suite that CI runs (pytest, bash, Go, promtool,
  Kyverno, or a repo-policy rule with its fixture) that fails on the bug and
  passes with the fix, and names the pull request or issue it guards. When
  no sensible test exists (a one-off action, a value only the live system
  shows), the pull request says why under Tested
  ([docs/testing.md](docs/testing.md#regression-tests)).
- A change updates the docs it makes stale, in the same pull request.
- Style: the Google Go Style Guide as far as golangci-lint checks it
  (`dashboard/.golangci.yaml`), PEP 8 for Python as far as ruff checks it
  (`ruff.toml`), shellcheck for shell, strict yamllint for YAML, `tofu fmt`
  for OpenTofu (HCL).
- Never commit a secret. Secrets live only in SOPS-encrypted `*.sops.yaml`
  files ([docs/secrets.md](docs/secrets.md)).

## Developer Certificate of Origin

Contributions are accepted under the repository's [MIT licence](LICENSE).
Opening a pull request certifies the
[Developer Certificate of Origin 1.1](https://developercertificate.org/):
you wrote the change, or have the right to submit it under that licence.
`git commit -s` adds the matching `Signed-off-by` line; no CI check
enforces it.

## Set up

On macOS with Homebrew, from the repository root:

```sh
brew install go-task                # provides `task`
task tools                          # the CLI tools the hooks call: sops, kustomize, helm, ...
python3 -m venv ~/.venvs/homelab    # outside the tree, which does not ignore a venv
. ~/.venvs/homelab/bin/activate
pip install --require-hashes -r ci/requirements-ci.txt
pre-commit install                  # the pre-commit, commit-msg and pre-push hooks
```

Expected: pip ends with `Successfully installed`, and `pre-commit install`
prints one `pre-commit installed at .git/hooks/<type>` line per hook type
(`default_install_hook_types` in `.pre-commit-config.yaml`). For the Go
tests, install the Go release named on the `go` line of `dashboard/go.mod`.

## Running the checks

In a shell with the virtual environment active
(`. ~/.venvs/homelab/bin/activate`):

```sh
pre-commit run --all-files          # every local hook: Passed or Skipped
python3 -m pytest -q tests          # Python and bash tests: all passed
(cd dashboard && go test ./...)     # ok for every package
(cd techradar && go test ./...)
(cd drumcharts && go test ./...)
```

`drumcharts/` skips its page image test unless `DRUMCHARTS_DATA` is set,
as `scripts/ci/drumcharts-check.sh` does. `go build` keeps debug information;
the dashboard image strips it unless built with
`docker build --build-arg LDFLAGS= dashboard`. The four layers of checks, from
local hooks to deploy-time smoke tests: [docs/testing.md](docs/testing.md).
