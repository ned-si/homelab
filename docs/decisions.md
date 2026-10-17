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
request. That includes `immich`: its database gets a PreSync base backup
before every sync, and the one irreversible step (Immich 3.0 and VectorChord)
is held back by Renovate caps and done by hand.

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

Two things run outside Argo CD: the Talos machine configs (OS, etcd, control
plane and the API VIP, rendered from `talos/` and applied with `task talos:*`,
[talos.md](talos.md)) and the bootstrap Secrets (`sops-age`, the repository
credential). Cilium, democratic-csi and Argo CD itself are installed once by
hand on a fresh cluster, then adopted by their Applications
([bootstrap.md](bootstrap.md)). Argo CD manages its own Helm release through
the Application `argocd` (`clusters/homelab/infrastructure/argocd.yaml`,
infrastructure layer, sync wave -15): an Argo CD upgrade is a pull request like
any other. That Application self-heals but does not prune; if a sync breaks
Argo CD, the break-glass `helm upgrade` in that file's header repairs it.

Why: the Talos configs and the bootstrap Secrets are dependencies of Argo CD
itself, so it cannot apply them. Its own release can be adopted after the
first install, which removes the last hand-run upgrade.

Rejected: keeping the Argo CD release on the Helm CLI. Every upgrade was a
manual step outside review, and the release drifted from `main` between
upgrades.

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

## No human gates

Nothing waits for a person: Renovate automerges every update on green CI
(`.github/renovate.json5`), Argo CD deploys `main`, and a failed deploy is
reverted automatically ([Automatic rollback](#automatic-rollback)). The only
exclusions are technical caps with a stated reason and an upstream source: the
Immich database image (a VectorChord update or a PostgreSQL major is one-way),
majors of stateful data stores (Postgres, ClickHouse, ZooKeeper, Valkey/Redis,
MariaDB/MySQL: the pull request opens, a person merges it, because a store that
has run on the new major cannot go back; ClickHouse 26 for SigNoz, #559, was
the case), and versions a consumer does not support yet. Policy gates, once they exist, are Kyverno
policies, not approvals.

Why: one operator, and the goal is a system that updates and heals at any time.
An approval queue only ages until someone clicks it.

Accepted gap: OpenSSF Scorecard's Code-Review check (and the review part of
Branch-Protection) stays low. Every change is merged without a second reviewer,
because there is no second person. The compensating controls are signed
commits, the required `ci` check on a protected `main` with linear history,
CodeQL and secret scanning on every push, and automatic rollback. Scorecard's
Contributors check stays at 0 for the same reason: one maintainer, no
organisation behind the repository.

Rejected: Dependency Dashboard approval for database and Immich majors, which
left updates pending indefinitely; required self-reviews or a bot approver,
which raise the score without anyone reviewing.

## Deterministic first

Deterministic first; AI only where determinism isn't possible, and for
summaries, pull requests and text. Tests, CI checks, alert rules, thresholds,
backup verification and automatic rollback are scripts and rules with fixed
inputs and outputs. AI may draft commit messages, pull request descriptions,
docs and incident summaries; a deterministic check still gates what merges.

Why: a gate that answers differently on the same input cannot be trusted,
tested or debugged at 3 a.m. Drafting text is where AI saves time without
deciding anything.

Rejected: AI in the decision path (an AI judging whether to alert, merge or
revert).

## Database majors fix forward

A database image bump (CloudNativePG Postgres) automerges like any update.
Its server and backup client share one Renovate dependency, so `pg_dump`
always matches the server. Before every sync of an
app with a database, a PreSync hook runs its verified backup
([backups.md](backups.md#databases)); a failed backup fails the sync.

A major upgrades the data files in place (CloudNativePG runs `pg_upgrade`), so
it is not reverted: CloudNativePG rejects a lower major on an existing cluster,
and the revert's sync fails. A broken major is fixed forward: fix the
configuration on `main`, or restore the pre-sync dump into a new cluster
([backups.md](backups.md#how-to-restore)).

Why: an automatic restore after a failed upgrade could overwrite data written
since, and a restore that runs unwatched must be the rehearsed one, not a new
code path. The PreSync backup makes fixing forward always possible.

Rejected: automatic restore from the dump on rollback, and approval gates on
database majors.

## Automatic rollback

Argo CD Notifications sends a GitHub `repository_dispatch` (`argo-degraded`)
when any Application's sync fails or its health turns Degraded
(`bootstrap/argocd-values.yaml`), once per Application and revision, with the
revision of that Application's last sync. `.github/workflows/auto-rollback.yaml`
then opens a revert pull request titled `revert: <title> (auto)`, label
`auto-rollback`, with auto-merge on, but only when every guard rail in
`scripts/ci/auto-rollback-decide.sh` holds: the commit is the newest on `main`,
merged under an hour ago, it changed a file of that Application, the
Application is not `cilium` or `democratic-csi`, it would not be a second
automatic revert in a row, and there is no outage. Otherwise it does nothing
and writes the reason to the run summary. For the apps with a database, the
pull request says a revert does not undo a schema migration: restore from
backup.

The outage guard (`scripts/ci/auto-rollback-guard.sh`) waits 5 minutes, then
holds the revert back when 3 or more apps failed within 10 minutes (counted
from this workflow's runs, named `auto-rollback <app>`), a node is NotReady or
the NAS is unreachable (`HomelabNodeNotReady`, `HomelabNASUnreachable` in
`platform/kube-prometheus-stack/routes/outage-alerts.yaml`, read from the
ntfy.sh guard topic, the Actions secret `NTFY_TOPIC` plus `-guard`, which
quiet hours do not mute). In an outage every app
degrades at once and the newest merge is not the cause.

No GitHub issues: the failure is an alert (`homelab-argocd`,
[observability.md](observability.md#argo-cd-alerts)) that resolves on its own,
and the revert pull request is the record. Rejected: an issue per failure. It
stays open after the app recovers, and an outage opens one per app.

Test without side effects: `gh workflow run auto-rollback.yaml -f app=<app>
-f revision=<sha>` (dry run by default) prints the decision and creates
nothing.

It runs on a fine-grained token (resource owner `ned-si`, only
`ned-si/homelab`, Contents, Pull requests and Issues read and write), stored
as the Actions secret `AUTO_ROLLBACK_TOKEN` and sealed in
`platform/secrets/argocd-notifications.sops.yaml`. To rotate it:

```sh
gh secret set AUTO_ROLLBACK_TOKEN --repo ned-si/homelab      # paste the token
# in secrets.local.env: AUTO_ROLLBACK_GITHUB_TOKEN=<the token>
rm platform/secrets/argocd-notifications.sops.yaml
scripts/seal-secrets-from-env.sh                             # re-seals that file only
```

and merge the re-sealed file.

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
encryption (not enabled yet) and Hubble (metrics, relay and UI, see
[networking.md](networking.md#hubble)).

Why: a mesh adds a sidecar or proxy per pod and a second control plane on four
32 GB arm64 nodes, to deliver mostly what the CNI provides without them.

Rejected: a mesh now. Revisit if per-request retries or traffic splitting
across many services become a real need.

## Talos, built as a new cluster

The nodes run Talos Linux. Until October 2026 the cluster ran Ubuntu 22.04
with kubeadm, kube-vip for the API VIP and Ansible playbooks for the nodes.
Talos replaced it as a new cluster (kubeadm and Talos cannot be mixed in one
cluster), one node at a time on the same hardware and IPs, after every
database had an off-site backup. The data volumes stayed on the NAS and were
bound again as static PVs; the databases were recovered from their Barman
Cloud backups. The repository no longer carries the Ubuntu-era playbooks,
manifests or runbooks; git history does.

Why: Talos removes the hand-maintained node state (netplan, kube-vip manifest,
packages, kubeadm certificates). The whole node is one machine config in git.
It also replaced the vendor 5.10 kernel, which held Cilium below 1.18 and
Gateway API below 1.3.

Rejected: an in-place conversion, which does not exist.

## Drift detection without cluster credentials in GitHub

Each layer is reconciled where its credentials already live. Kubernetes
objects: Argo CD `selfHeal`. The AWS modules under `bootstrap/`: the `tofu`
workflow, with short-lived AWS credentials from GitHub OIDC, plans on pull
requests, applies on merge and corrects drift daily; it never applies a
destroy, and never applies the modules that grant its own access
([bootstrap.md](bootstrap.md#drift-detection)). Talos machine configs: a
daily CronJob in the cluster compares every node with the render of `main`
and alerts ([talos.md](talos.md#drift-check)).

Why: GitHub holds no kubeconfig or talosconfig, so a leaked workflow token or
a compromised action cannot reach the cluster. AWS through OIDC is a role
scoped to named resources, not a stored key.

Rejected: a self-hosted runner in the cluster with Kubernetes and Talos
credentials, and applying Talos config drift automatically (a config change
can reboot a node; the alert asks for `task talos:apply`).

## UIs public behind SSO, cluster APIs on the tailnet

Every web UI is a public HTTPRoute on the shared Gateway behind a Keycloak
login, gated by group (the client's own login flow and, for an oauth2-proxy,
its `allowedGroups`), with the security headers and the weekly DAST like any
other route. Only the cluster APIs stay off the internet: `kubectl` through
the Tailscale API server proxy, `talosctl` through each node's own Tailscale
(or the LAN); neither is ever on the Gateway
([remote-access.md](remote-access.md)). Headlamp moved to
`headlamp.lilalala.com` under this rule; the Hubble UI follows.

Why: a UI already has a strong login and per-group access, and one URL per
tool works from any device without the Tailscale app, with one redirect URI
per client. The APIs carry cluster-admin or `os:admin` credentials and have
no Keycloak in front, so the network stays their first boundary.

Rejected: tailnet-only UIs (the first Headlamp setup): two places to look
for a tool, a VPN on every device that opens one, and a corporate VPN on the
Mac that overlapped the tailnet range.

## SigNoz login: Keycloak first, Google only on a Workspace domain

SigNoz sits behind the Keycloak gate (oauth2-proxy, group `admins`) like every
UI, then asks for its own login. Self-registration is closed after setup.
SigNoz's own login is Google only when the operator's Google account is on a
Workspace domain he controls: one authenticated domain, that domain, `Enforce
SSO`, new users as VIEWER. Otherwise it is one local admin with the
password in SOPS. Either way the admin's email is the operator's real
address, so a later SSO login lands on the same user.

Why: the free edition of SigNoz has only one SSO method, Google bound to an
email domain, and it checks the token's `hd` claim. A personal Gmail account
has no `hd`, so `gmail.com` cannot work, and if it could it would admit any
Gmail user. A Workspace domain admits every account of that Workspace, which
for a one-person Workspace is the operator. Keycloak still stops everyone
else first.

Rejected: OIDC or SAML against Keycloak (Enterprise licence only), oauth2-proxy
alone (SigNoz has no trusted-header login), and Google as a Keycloak identity
provider for now (it changes the login of every UI, so it gets its own spec).
Details: [wave 3 design, answer 11](../.kiro/specs/wave3-network-logs/design.md#answers).

## SELinux labels on CSI volumes

Every iSCSI volume is mounted with
`context=system_u:object_r:ephemeral_t:s0`, the label Talos gives its own
user volumes, set as a StorageClass mount option and on each existing
PersistentVolume. One exception: the volume of `immich/immich-data` stays
unlabelled until the operator decides otherwise.

Why: Talos runs SELinux in permissive mode and cannot label a volume that a
CSI driver mounts. Without the label every file a pod touches is
`unlabeled_t`, and each access logs an AVC denial with five companion
records. On 2026-10-17 ClickHouse alone produced about 1,300 records a
second on one node, and shipping them to SigNoz made ClickHouse write more.
In enforcing mode those same accesses would fail, so labelled volumes are a
prerequisite of SELinux enforcing (wave 5, spec `platform-talos` task 13).

Rejected: dropping the records in Vector (hides the cause), turning SELinux
off (gives up enforcing mode) and `chcon` inside the volumes (a mount
without `context=` brings the old labels back).
Details: [wave 3 design](../.kiro/specs/wave3-network-logs/design.md#decisions).

## Seafile removed

Seafile was removed on 2026-10-16. Nobody used it: shared documents live in
Google Docs, files that must sync between devices in Syncthing, and paperwork
belongs in Paperless. It was the most complex app here (its own MariaDB and
memcached, its configuration inside the volume instead of git, a pinned
MariaDB 10.11 and a manual port to Seafile 12 ahead).

Kept as an archive: the restic repository `seafile/shared` (no new snapshots,
no prune, under the bucket policy; the last snapshots are `34f34ea0`, the
MariaDB dump, and `8838dac0`, the data and its configuration), and the two
zvols behind the PVs `pvc-2b0f41c1-041d-47a5-81cc-16371f05ea21` and
`pvc-2ed5ccbe-1e8d-4ab4-9ba1-8ac0bd74a126` with their claims in namespace
`seafile`. Delete the volumes after 2026-11-16 if nobody asks for them.

Rejected: upgrading to Seafile 12 to keep a file share no one opens.

## OTP for admins, client credentials for automation

Members of the `homelab` group `admins` need a TOTP code at every password
login (realm role `mfa-required`, conditional subflows in `browser-loa` and
every `access-<client>` flow), and so does every user of the `master` realm,
which is the Keycloak admin console (flow `browser-otp`). The household keeps
password-only logins, with OTP optional. Policy: TOTP, 6 digits, 30 s, SHA1.
All of it is in `platform/keycloak/realm/platform.conf`, applied by the
`keycloak-realm-settings` Job.

Automation does not log in as a person. The Job uses the master client
`realm-settings` (client credentials, master role `admin`, secret in
`platform/secrets/keycloak-automation.sops.yaml`); the admin password is only
its fallback on a new database, before that client exists, and the Job binds
`browser-otp` only after a client login works. No other client uses a
password grant or a service account today: Argo CD, Grafana, the apps and the
oauth2-proxies use the authorization code flow. Password grants (`direct
grant` flows) are unchanged.

Break-glass ([keycloak-otp.md](runbooks/keycloak-otp.md#break-glass)): the
`realm-settings` secret through `kubectl exec` and `kcadm.sh`, which deletes a
lost OTP credential; if that fails, Keycloak's `kc.sh bootstrap-admin
service` with the server stopped.

Why: a stolen admin password opens the admin console and every platform
tool; a second factor closes that. Moving the Job to its own client is what
makes OTP on the human admin possible: the same account cannot be both
OTP-protected in the browser and usable by a script with only a password.

Rejected: leaving the master realm password-only (the most powerful login
stays the weakest), OTP for every `homelab` user (the household does not use
authenticator apps), and removing OTP from the master `direct grant` flow so
the Job could keep the password (a password grant would bypass the OTP).
