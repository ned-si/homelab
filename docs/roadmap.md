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
  timed disaster-recovery run (#723); automatic Postgres majors (#745);
  consistent SQLite backups (#746).
- **The NAS as a hardened dependency.** Scoped NFS exports and read-only
  media (#721), the failing cache device and the pending update (#719, #720,
  #722).
- **Proven, not assumed.** Chaos experiments tied to the SLOs (#733), a
  scoped pentest (#718).

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
