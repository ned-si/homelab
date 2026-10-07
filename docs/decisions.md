# Decisions

Cross-cutting decisions, one entry each: the decision, why, and the main
alternative rejected. Decisions that belong to one topic are at the end of that
topic's page ("Why it is like this"). When a decision changes, edit its entry
here; git history is the record.

Older code comments cite some of these by number:

| Cited as | Entry |
| --- | --- |
| ADR 0001 | [main is production](#main-is-production) (replaced the `deployed` tag) |
| ADR 0002 | [Adopt at parity, change afterwards](#adopt-at-parity-change-afterwards) |
| ADR 0007, ADR 0011 | [One shared Gateway](networking.md#why-it-is-like-this) (ingress-nginx removed) |
| ADR 0008 | [Backup CronJobs run only once reviewed](backups.md#why-it-is-like-this) |
| ADR 0012 | [LAN addressing is public](#lan-addressing-is-public) |

## main is production

Every Argo CD Application tracks `main`. A merge is a deployment: Argo CD
applies it within its 3-minute reconcile interval. A rollback is a revert pull
request. The only exception is `immich`, which has no automated sync, because an
Immich upgrade runs database migrations that cannot be undone.

Why: with `selfHeal: true` on every Application, the desired state in git is the
only lever that sticks; one branch keeps "what is merged" and "what runs" the
same thing. CI on every pull request and `scripts/pr-merge.sh` are the gate.

Rejected: a `deployed` tag that a CD workflow moved forward after a health
check. It needed a runner with access to the cluster and a second notion of
"current", for a cluster run by one person, where review and deploy happen
together.

## Adopt at parity, change afterwards

The layered tree took over every running object byte-for-byte: same images,
chart versions, names and values. Every behaviour change (an upgrade, a probe,
a security context, a new app) ships as its own pull request afterwards.

Why: an adoption that also changes things cannot be told apart from an adoption
that breaks things. Parity makes the takeover diff empty apart from tracking
labels, so any other line in it is a finding.

Rejected: migrating to the hardened manifests in the same step.

## No prune where a deletion is an outage

App leaves sync with `prune: true`. The root, the three layers, `namespaces`,
`cilium`, `democratic-csi` and every leaf that ships CRDs (cert-manager,
CloudNativePG, kube-prometheus-stack, Gateway API) do not prune. Every PVC,
CNPG Cluster, StatefulSet and Namespace carries
`argocd.argoproj.io/sync-options: Delete=false,Prune=false`. No Application
carries the cascading `resources-finalizer`. CI (`scripts/ci/repo_policy.py`)
enforces the last two.

Why: pruning a CRD deletes every object of that kind, pruning the CNI or the
CSI driver takes the network or every volume down, and deleting an Application
object by mistake must not delete its app. Data volumes also use reclaim policy
`Retain` ([backups.md](backups.md#reclaim-policy)).

Rejected: prune everywhere, which is tidier and one mistake away from losing
data.

## Hand-installed only where git cannot reach

Three things run outside Argo CD: the Argo CD Helm release itself (`argocd`,
upgraded with the Helm CLI from a merged commit), kube-vip (static pods on the
control planes) and the bootstrap Secrets (`sops-age`, the repository
credential). Cilium and democratic-csi were Helm CLI releases and are now
Argo CD Applications; a fresh cluster installs Cilium once by hand, then Argo CD
adopts it ([bootstrap.md](bootstrap.md)).

Why: each of the three is a bootstrap dependency of Argo CD itself.

Rejected: Argo CD managing its own release (an Argo CD outage could then block
its own repair).

## LAN addressing is public

The README and `docs/` list the LAN addresses of the router, nodes, NAS, API VIP
and LoadBalancer IPs.

Why: they are private RFC 1918 addresses, discoverable in seconds by anything
already on the LAN, and the runbooks need them to be copy-paste runnable. What
protects the cluster is authentication, network policy and the router, not the
addresses being unknown.

Rejected: placeholders everywhere, which makes every runbook a fill-in exercise
during an incident.

## Squash merge

`scripts/pr-merge.sh <pr>` squash-merges: one pull request is one commit on
`main` and one revert. `--ff` fast-forwards instead, for a pull request whose
commits must stay separate; it refuses when `main` is protected.

Why: with `main` deployed on merge, the unit of review, deployment and rollback
should be the same.

Rejected for now: rebase-merge, which keeps atomic commits on `main` but makes
every commit a deployment and every rollback a multi-commit revert.

## Automatic rollback

Argo CD Notifications sends a GitHub `repository_dispatch` (`argo-degraded`)
when any Application's sync fails or its health turns Degraded
(`bootstrap/argocd-values.yaml`), once per Application and revision, with the
revision of that Application's last sync. `.github/workflows/auto-rollback.yaml`
then opens a revert pull request titled `revert: <title> (auto)` with
auto-merge on, plus an issue, but only when every guard rail in
`scripts/ci/auto-rollback-decide.sh` holds: the commit is the newest on `main`,
merged under an hour ago, it changed a file of that Application, the
Application is not `cilium` or `democratic-csi`, and it would not be a second
automatic revert in a row. Otherwise it opens an issue (one per Application,
later reports are comments) with the reason. For the apps with a database, the
issue says a revert does not undo a schema migration: restore from backup.

Test without side effects: `gh workflow run auto-rollback.yaml -f app=<app>
-f revision=<sha>` (dry run by default) prints the decision and creates
nothing.

Turning it on is one step: create a fine-grained token (resource owner
`ned-si`, only `ned-si/homelab`, Contents, Pull requests and Issues read and
write), then

```sh
gh secret set AUTO_ROLLBACK_TOKEN --repo ned-si/homelab      # paste the token
# in secrets.local.env: AUTO_ROLLBACK_GITHUB_TOKEN=<the token>
rm platform/secrets/argocd-notifications.sops.yaml
scripts/seal-secrets-from-env.sh                             # re-seals that file only
```

and merge the re-sealed file. Until then the sealed value is a `PENDING`
sentinel: GitHub refuses the dispatch and nothing happens.

Why: Renovate automerges every update on green CI, so a bad update must be
undone without waiting for a person. The pull request goes through the same CI
and branch protection as any other; it is opened with the owner's token because
GitHub Actions may not open pull requests here, and one opened by
`GITHUB_TOKEN` would not start CI. Reverting the CNI or the CSI driver is
itself a risky deploy, and a broken Argo CD cannot deploy any revert, so those
stay with a person.

Rejected: Argo CD's own rollback to a previous sync (`selfHeal` from `main`
undoes it within minutes), and reverting whatever merged last (several merges
can land close together; the failure is pinned on the Application's own last
sync).

## No service mesh

No Istio, no Linkerd. Zero-trust networking and traffic observability are
built from Cilium, which is already the CNI: identity-based
`CiliumNetworkPolicy` (written, not enforced yet, see
[networking.md](networking.md#network-policy)), WireGuard transparent
encryption (not enabled yet) and Hubble (on in the agents; relay, UI and
metrics not enabled yet).

Why: a mesh adds a sidecar or proxy per pod and a second control plane on four
32 GB arm64 nodes, to deliver mostly what the CNI provides without them.

Rejected: a mesh now. Revisit if per-request retries or traffic splitting
across many services become a real need.

## kubeadm today, Talos later

The nodes run Ubuntu 22.04 with kubeadm. Talos is the planned replacement, built
as a new cluster (kubeadm and Talos cannot be mixed in one cluster) once the
current platform work is finished and every database has an off-site backup.

Why: Talos removes the hand-maintained node state (netplan, kube-vip manifest,
packages), but the move recreates every node, so it waits for backups that do
not live in the house.

Rejected: an in-place conversion, which does not exist.
