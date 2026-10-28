# Specs

Two kinds of spec live here, and the header of each `requirements.md` says
which (repo-policy `spec-lifecycle` checks it):

```yaml
---
kind: change        # or area
status: active      # change: active or done; area: living
created: 2026-10-24
closed: 2026-10-30  # done only
issue: 750          # active change specs: the issue on the board
---
```

- A **change spec** is one bounded change: requirements, design, tasks, done
  when its tasks are. Named by outcome (`cilium-upgrades`, not a batch name).
  While `active` it has an issue on the [board](#the-board); when every task
  is ticked it becomes `done` with its `closed` date, and the issue closes.
- An **area spec** is `living`: how one area works today, each acceptance
  criterion naming its check, and the history of the area as ticked tasks
  with their PRs. It has no open tasks. New work in an area is an issue, and
  a change spec when it needs one; the area spec is updated when the change
  lands and alters how the area works.

Not a spec: one-liners and single PRs (the PR description is the spec, the
issue labelled `type/task`), research (`type/research`) and hands-on work by
the owner (`type/operator`). Deferred work is an issue labelled `deferred`
with the reason, never an unticked task.

## From idea to done

| Step | Where | Board column |
| --- | --- | --- |
| 1. An idea, a deferred item, a postmortem action | An issue: `area/*`, `type/*`, `blocked` or `deferred` if it waits | Backlog |
| 2. Picked up, `type/task` | Straight to step 4: the PR description is the spec | In progress |
| 2. Picked up, `type/spec` | A change spec: `requirements.md` (header `active`, `issue: <n>`), `design.md`, `tasks.md` | Spec drafted |
| 3. The owner reviews requirements and design | Review comments, then the spec PR merges | Spec drafted |
| 4. One PR per task | `Spec: <name>#<task>` (or `No-spec: <reason>`), CI the gate, `scripts/pr-merge.sh` | In progress |
| 5. Each PR merged | The task ticked with its PR number | In progress |
| 6. The last task ticked | Header `status: done`, `closed: <date>`; the issue closes; the area spec updated if the area changed | Done |

Anything learned on the way that is not this spec's job becomes a new issue
(step 1), not a task here.

## The board

[github.com/users/ned-si/projects/1](https://github.com/users/ned-si/projects/1), linked to the repository.

Every idea starts as an issue ([open issues](https://github.com/ned-si/homelab/issues)),
labelled by area (`area/*`) and by kind (`type/spec`, `type/task`,
`type/research`, `type/operator`), plus `blocked` or `deferred` when it
waits. The project board orders them: Backlog, Spec drafted, In progress,
Done.

An issue labelled `type/spec` gets a change spec when it is picked up; the
spec's header links the issue, the issue links the spec. PRs carry
`Spec: <name>#<task>` (or `No-spec: <reason>`), and each task is ticked with
its PR number when it merges.

## Index

Change specs, active:

| Spec | Created | Issue | Open |
| --- | --- | --- | --- |
| [alert-triage](alert-triage/) | 2026-10-27 | #762 | task 4: the webhook receiver |
| [cilium-upgrades](cilium-upgrades/) | 2026-10-24 | #750 | task 8: Cilium 1.20.4 through the rehearsal |
| [wave3-network-logs](wave3-network-logs/) | 2026-10-16 | #752 | allow-lists from flows, the SigNoz trial, the SELinux label rollout |

Change specs, done:

| Spec | Created | Closed |
| --- | --- | --- |
| [immich-v3-migration](immich-v3-migration/) | 2026-10-16 | 2026-10-16 |
| [scorecard-hardening](scorecard-hardening/) | 2026-10-16 | 2026-10-26 |
| [wave3-reliability](wave3-reliability/) | 2026-10-16 | 2026-10-16 |
| [wave3-runtime-security](wave3-runtime-security/) | 2026-10-17 | 2026-10-27 |

Area specs, living (the as-is retrofit of 2026-10-16, #506):

| Spec | Area |
| --- | --- |
| [access-identity](access-identity/) | Keycloak realm as code, per-app groups, sessions, Tailscale and Headlamp, secrets |
| [backups-dr](backups-dr/) | restic, CNPG Barman, the PreSync freshness rule, restore tests, bucket immutability |
| [gitops-delivery](gitops-delivery/) | Argo CD layers, render in PR, the CI gate, Renovate automerge, image pinning, auto-rollback |
| [media-home](media-home/) | the theater stack, books, Home Assistant |
| [observability-alerting](observability-alerting/) | SLOs and budgets, paging policy, quiet hours, dashboards |
| [platform-talos](platform-talos/) | nodes, Talos config as code, tuppr upgrades, the CI rehearsal, drift check, eMMC monitoring |

The `wave3-*` names predate the naming rule; they stay, because PRs and
commits reference them.
