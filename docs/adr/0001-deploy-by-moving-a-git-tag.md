# ADR 0001 — Deploy by moving a git tag

**Status:** superseded on 2026-10-04 by trunk-based delivery: every
Application tracks `main`, a rollback is a revert pull request, and
`.github/workflows/cd.yaml` is removed. Automatic rollback (Argo CD
Notifications -> revert PR) is on the [roadmap](../roadmap.md). Kept for the
reasoning about self-heal and rollback races, which still applies.
**Date:** 2026-08-28
**Applies to:** `.github/workflows/cd.yaml`, every `Application` in
`clusters/homelab/`, `bootstrap/`

## Context

Every Application in this repo runs with:

```yaml
syncPolicy:
  automated:
    prune: true      # or false, per component
    selfHeal: true
```

`selfHeal: true` means the application controller re-applies
`spec.source.targetRevision` on every reconcile — by default every three
minutes, and immediately on any watched change.

That single fact invalidates the obvious CD design. With every Application
tracking `main`:

| Rollback attempt | Why it fails |
|---|---|
| `argocd app sync <app> --revision <good-sha>` | does not change `spec.source.targetRevision`. selfHeal re-applies `main` — the bad commit — within minutes. The rollback races the sync policy and loses. |
| `argocd app set <app> --revision main` (or to a SHA) | mutates an `Application` object that is itself managed by `root`/`layer-*` with selfHeal. The edit reads as drift and is reverted. |
| `--prune=false` on the rollback sync | moot. `automated.prune: true` prunes on the next reconcile regardless of what a CLI flag said once. |
| layer-by-layer health-gated sequencing | advisory only. Argo auto-syncs on its own timer whatever the pipeline is doing. |

The common shape of all four: they try to hold the cluster somewhere its own
declared desired state says it should not be. Anything built that way is a race
against a controller that never gets tired.

## Decision

**Make the desired state itself the thing that moves.**

A git tag named `deployed` is the revision every Application tracks — root, the
three layer app-of-apps, and every leaf. Nothing tracks a branch.

```
deploy    = move `deployed` forward, refresh, sync each layer, gate on health
rollback  = move `deployed` back
```

This works *with* selfHeal rather than against it: after a rollback, selfHeal is
the mechanism that *completes* the recovery instead of the mechanism that
defeats it. And there is exactly one mutation point, which is auditable
(`git log deployed`) and reversible with one command.

`main` and `deployed` are allowed to disagree:

- **`main`** is what has been reviewed.
- **`deployed`** is what has been verified against a live health gate.

The second of those is a claim about configuration, not a property of Argo CD,
and it is only true while the custom health checks in
`bootstrap/argocd-values.yaml` are present and actually executable — see the
first bullet under Consequences. If they are not, `deployed` means nothing more
than `main` does.

`cd.yaml` therefore files an **issue** on failure rather than pushing a revert
commit. A revert would erase the distinction, and a conflicting auto-revert is a
second problem to untangle while the first is still open.

### Consequences

- The health gate becomes load-bearing, so it has to be real. Argo CD reports
  any resource it has no health check for as **Healthy immediately**. Three
  things follow, and all three are part of this decision rather than extras:

  1. **`argoproj.io/Application` itself needs a health check.** Argo CD removed
     the built-in one in 1.8, and `root` and the three `layer-*` app-of-apps own
     nothing *but* Application objects. Without
     `resource.customizations.health.argoproj.io_Application`,
     `argocd app wait layer-apps --sync --health` returns Healthy in seconds no
     matter what the ~40 leaves are doing — a deploy in which everything is
     Degraded reports success and the tag stays moved. Upstream recommends
     restoring it for exactly this combination: app-of-apps plus sync waves.
  2. Seven single-instance CloudNativePG Clusters, the shared Gateway and
     fourteen HTTPRoutes are the leaf kinds Argo has no opinion about, and they
     are the ones whose failure is user-visible.
  3. **Those scripts run in a sandbox with the Lua standard libraries turned
     off** — `package`, `base`, `table` and a cut-down `os`, and nothing else,
     unless `resource.customizations.useOpenLibs.<group>_<kind>` says otherwise.
     A script that reaches for `string.find` does not degrade, it *errors*, and
     an erroring health script reports **Unknown**, which is the worst rank in
     Argo's health ordering and never converges. One such script therefore
     wedges the gate for its whole layer until the timeout, then triggers a
     rollback of a change that was probably fine. `useOpenLibs` is deliberately
     not used; the checks are written against base + table primitives instead,
     so the sandbox stays shut.

- Sync waves order a rollout; they do not gate it on health by themselves. Argo
  applies waves in ascending order and waits for wave *N* to be Synced and
  Healthy before starting *N+1* — but a kind with no health check is Healthy on
  arrival, so for such resources the wait is vacuous. Waves are a barrier only
  where health is genuinely assessable, which is the same point as above from
  the other direction.
- A failed deploy leaves the repo ahead of the cluster. The next push to `main`
  will try to deploy the same failing commit unless it is fixed or reverted, so
  the issue is labelled `needs-manual-review` and says so.
- CI must never be able to deploy without a gate. If
  `vars.CLUSTER_RUNNER_READY` is not `true`, `cd.yaml` **does not move the tag
  at all** and says why in a `::notice::`. The cluster stays on the last
  verified commit. An unverifiable deploy simply does not happen.
- Ordering within a rollout is a head start, not a barrier — see below.

### One-time setup

The tag must exist before any Application can resolve. Without it every sync
fails with `revision "deployed" not found`, including on a fresh bootstrap.

```sh
git tag deployed <commit-that-is-known-good>
git push origin refs/tags/deployed
```

Two settings to check once:

- **Tag protection.** A rule matching `deployed` that forbids force-pushes will
  break both deploy and rollback. Either exclude `deployed` or allow the
  Actions token to force-push it.
- **`bootstrap/variables.tf`** — `target_revision` defaults to `deployed`, and
  `bootstrap/terraform.tfvars.example` ships the override **commented out** so
  that copying the example inherits the default. Overriding it with a branch is
  for rebuilding a cluster that owns nothing yet; the root Application carries
  `automated: {prune: true, selfHeal: true}`, so a branch means the cluster
  follows every push to it, pruning as it goes, with no gate in front of it.

### Doing it by hand

The pipeline is a convenience, not a dependency. The same deploy, from a
laptop:

```sh
git tag --force deployed <sha>
git push --force origin refs/tags/deployed
argocd app get root --hard-refresh          # re-resolve the tag now
argocd app sync layer-infrastructure && argocd app wait layer-infrastructure --sync --health
argocd app sync layer-platform       && argocd app wait layer-platform       --sync --health
argocd app sync layer-apps           && argocd app wait layer-apps           --sync --health
```

The `--hard-refresh` is not optional. Argo caches the commit it resolved for
`deployed`; without it the sync gates on the manifests from *before* the tag
moved and passes.

## Alternatives rejected

**Track `main`, roll back by pinning.** The table above. Loses to selfHeal.

**Turn selfHeal off.** It is the property that makes a hand-edit to a live
object revert itself, which is most of the value of GitOps here. Trading it for
a rollback mechanism is trading the goal for the tool.

**Set `timeout.reconciliation: 0`** so nothing syncs without an explicit
refresh. This would make the layer ordering absolute instead of a head start,
which is genuinely tempting. Rejected because it silently breaks the manual
path: an operator who moves the tag by hand would see nothing happen, forever,
with no error anywhere. A CD design whose failure mode is "no feedback at all"
is worse than one whose failure mode is "converged sooner than the pipeline
expected".

**Argo CD `ApplicationSet` with a `git generator` per environment.** One
cluster, one environment. It adds a generator to reason about and changes
nothing about the rollback problem.

**Argo Rollouts.** Real canary and blue-green, and unusable here: almost every
workload holds a ReadWriteOnce volume (Plex, Immich, Paperless, Seafile,
Syncthing, the *arr apps, qBittorrent), so a second replica cannot mount what
the first one is holding. They are all deliberately `strategy: Recreate`. Worth
revisiting the first time a genuinely stateless multi-replica service lands
here.

**A second git repo for deployed state (the "GitOps promotion" pattern).** Two
repos, two review flows and a sync step between them, to express what one tag
expresses. Reasonable at 30 engineers; overhead at one.

## Notes

The layer ordering (`infrastructure` → `platform` → `apps`) is honest about its
own limits, and `cd.yaml` says so at the point where it does the refresh: every
leaf has `automated` sync, so a leaf picks up the new tag on its own
reconciliation timer whether or not the pipeline has refreshed it yet.
Refreshing in layer order gives infrastructure a head start; what actually
protects the rollout is the gate, which stops the job before the next layer is
refreshed and puts the tag back.

`clusters/homelab/apps/immich.yaml` is the one Application with **no**
`automated` block at all, so moving the tag never triggers it. Note that
`automated: {prune: false, selfHeal: false}` would *not* have achieved that:
`selfHeal` only governs re-syncing after cluster drift, and with an `automated`
block present a new git revision still auto-syncs. Omitting the block is the
only way to require a human, which an irreversible database migration deserves.
