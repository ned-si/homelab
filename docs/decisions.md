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
"current", for a single-operator cluster where review and deploy happen
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
as a new cluster (kubeadm and Talos cannot be mixed in one cluster) once every
database has an off-site backup.

Why: Talos removes the hand-maintained node state (netplan, kube-vip manifest,
packages), but the move recreates every node, so it waits for backups that do
not live in the house.

Rejected: an in-place conversion, which does not exist.
