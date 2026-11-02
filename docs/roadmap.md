# Roadmap

The direction, in a page. The items themselves are issues, one each,
labelled by area and kind and ordered on the board
([.kiro/specs/README.md](../.kiro/specs/README.md#the-board)); work in flight
is a change spec. Each item is its own pull request, or a spec of several,
with its own diff, test and rollback
([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).

## Themes

- **Least privilege at runtime.** Kyverno enforces the 16 baseline policies;
  next the restricted set and PSA enforce (#724), per-app hardening (#726),
  default-deny network policies per namespace (#709), image provenance
  (#725).
- **Encrypted in transit inside the cluster.** Cilium WireGuard between the
  nodes (#710), without a service mesh
  ([decisions.md](decisions.md#no-service-mesh)).
- **Secrets the cluster owns, keys nobody stores.** OpenBao issues the
  cluster's own secrets through ESO, auto-unsealed by AWS KMS (#713); pods
  assume AWS roles with their service-account tokens (#714); every API key
  that has an API is created by IaC (#715). SOPS stays the bootstrap and
  break-glass store.
- **One identity.** The Kubernetes API (#711), Headlamp (#712) and Jellyfin
  (#730) on Keycloak.
- **Recoverable from git alone.** A monthly rebuild rehearsal in CI and a
  timed disaster-recovery run (#723); a written strategy around it: the
  scenarios (node, NAS, house, cloud account), RPO, RTO and measured MTTR
  per tier, and cold, warm or hot standby compared on cost, with the choice
  and its reasons (#918); automatic Postgres majors (#745); consistent
  SQLite backups (#746); no stale restic lock can fail a backup (#919).
- **Only the data we use, in as few places as possible.** Every metric and
  log answers a question (an SLO, an alert, a runbook, a detection, an
  audit) or is dropped or sampled; SigNoz as the one place for reliability
  and security signals, or not (#801); Prometheus keeps its 30 days (#905,
  #922).
- **Elastic where it can be.** HPA for the stateless workloads, KEDA for
  event-driven scaling and scale to zero of idle apps, VPA recommendations
  to size requests; bursting to cloud nodes stays a research note (#917).
- **Pages a person can close.** One push per problem (#915), and an
  acknowledgement from the phone: an action on the ntfy push that opens a
  prefilled Alertmanager silence behind Keycloak (#916).
- **The NAS as a hardened dependency.** Scoped NFS exports and read-only
  media (#721), the failing cache device and the pending update (#719, #720,
  #722).
- **Proven, not assumed.** Chaos experiments tied to the SLOs (#733); a
  scoped, technical pentest with a written report per run, from outside
  (the own IPs and domains) and from inside (the LAN, a compromised pod, a
  stolen session), its findings as issues (#718).

Issues by area: [networking](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fnetworking),
[identity](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fidentity),
[secrets](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fsecrets),
[security](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fsecurity),
[nas](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fnas),
[backups](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fbackups),
[delivery](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fdelivery),
[platform](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fplatform),
[observability](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fobservability),
[media](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fmedia),
[home](https://github.com/ned-si/homelab/issues?q=is%3Aopen+label%3Aarea%2Fhome).

## Versions Renovate cannot move alone

Renovate automerges every other update on green CI
([decisions.md](decisions.md#no-human-gates)). By hand:

- The Immich database image (VectorChord or PostgreSQL major):
  [runbooks/immich-upgrade.md](runbooks/immich-upgrade.md#updating-the-database-image).
- `democraticcsi/democratic-csi` runs `latest` pinned by digest until it is
  pinned to a release tag (#747).
