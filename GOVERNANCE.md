# Governance

This repository is an over-engineered homelab, run for fun by one
maintainer, `@ned-si`, who makes the final decision on everything in it.
AI agents and Renovate do most of the implementation, through pull
requests that pass the same `ci` check as any other.

## How decisions are made

1. Every piece of work starts as an issue on the
   [board](https://github.com/users/ned-si/projects/1), labelled by area
   (`area/*`) and kind (`type/*`). The maintainer sets the priorities: the
   order on the board and the themes in [docs/roadmap.md](docs/roadmap.md).
2. A `type/spec` issue gets a change spec in `.kiro/specs/<name>/`
   (requirements, design with the rejected alternatives, tasks), which the
   maintainer approves before the first pull request
   ([.kiro/specs/README.md](.kiro/specs/README.md#from-idea-to-done)).
3. Each change is one pull request on one topic. The required `ci` check is
   the only gate: a green pull request merges, a red one does not
   ([docs/decisions.md](docs/decisions.md#no-human-gates)).
4. Decisions that cut across the repository are recorded in
   [docs/decisions.md](docs/decisions.md), one entry each with the reason and
   the alternative rejected; topic decisions in the "Why it is like this"
   section of their doc.

A disagreement or a proposal goes in an issue. The maintainer decides and
writes the reason there.

## Roles and responsibilities

| Role | Who | Responsibilities |
| --- | --- | --- |
| Maintainer | `@ned-si` | Priorities and roadmap; approves specs; merges; holds the credentials and keys (GitHub, the age key, the cloud and DNS accounts); handles security reports ([SECURITY.md](SECURITY.md)); enforces the [Code of Conduct](CODE_OF_CONDUCT.md) |
| AI agents | Run by the maintainer | Work from the maintainer's briefs and specs; open pull requests; merge only through `scripts/pr-merge.sh`, only on a green `ci` |
| Designated successor | A trusted person with write access, chosen by the maintainer | Takes over the project and its accounts if the maintainer cannot act ([Continuity](#continuity)); no maintainer duties until then |
| Trusted collaborator | A trusted person with write access, chosen by the maintainer | Issues and pull requests like any contributor; no maintainer duties |
| Renovate | The hosted Renovate app | Opens update pull requests; automerges on a green `ci` ([docs/dependencies.md](docs/dependencies.md)) |
| Contributors | Anyone | Issues and pull requests under [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) |

## Continuity

The bus factor is one, by design: there is no second maintainer, and a
second person reviewing changes would be a human gate. For the project to
continue without the maintainer, someone else needs:

- access to the GitHub account `ned-si`, or to be its designated successor,
  to create and close issues, accept changes and publish;
- the age private key, which decrypts every secret in git
  ([docs/secrets.md](docs/secrets.md#the-key));
- the cloud, DNS and domain accounts the cluster depends on;
- [docs/bootstrap.md](docs/bootstrap.md) and the backups
  ([docs/backups.md](docs/backups.md)) to rebuild from git.

A designated successor, a trusted person with write access, can take over
the project and its accounts within days: the GitHub account through
GitHub's account successor feature, and the other accounts and the age key
with the credentials the successor already holds for emergencies. The
collaborator list is not public, so this document names no one.

## Why it is like this

- One maintainer: this is one person's homelab. Rejected: a second
  maintainer and human review of changes, which the OpenSSF Best Practices
  Gold level asks for, because they contradict "no human gates".
- Decisions in issues, specs and `docs/decisions.md` rather than meetings:
  every decision leaves a public record next to the code it changed.
