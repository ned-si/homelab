# Roadmap

The direction, in a page. The items themselves are issues, one each,
labelled by area and kind and ordered on the board
([.kiro/specs/README.md](../.kiro/specs/README.md#the-board)); work in flight
is a change spec. Each item is its own pull request, or a spec of several,
with its own diff, test and rollback
([decisions.md](decisions.md#adopt-at-parity-change-afterwards)).

## Themes

In priority order, top first. The operator set this order on 2026-11-03
and put home automation fourth on 2026-11-04.

1. **Fix what is broken now.** The open bugs (#836, #943, #735) and the
   weekday issues: the snapshotter sidecar without snapshot CRDs (#944),
   namespaced Roles for backup-verify (#950), the barman-cloud plugin's
   cluster-wide RBAC (#951), the Paperless backup job's read-only root
   filesystem (#953), the renovate-next pause (#960), the NAS reboot (#962),
   Grafana restarting on every sync (#967).
2. **Paperless as the home for the household's documents** (#732). Today
   the documents are not managed, and documents and the time spent looking
   for them get lost.
3. **Tighten security.**
   - Least privilege at runtime: Kyverno enforces the 16 baseline policies;
     next the restricted set and PSA enforce (#724), per-app hardening
     (#726), image provenance (#725), default-deny network policies per
     namespace (#709).
   - Encrypted in transit inside the cluster: Cilium WireGuard between the
     nodes (#710), without a service mesh
     ([decisions.md](decisions.md#no-service-mesh)).
   - Secrets the cluster owns, keys nobody stores: OpenBao issues the
     cluster's own secrets through ESO, auto-unsealed by AWS KMS (#713);
     pods assume AWS roles with their service-account tokens (#714); every
     API key that has an API is created by IaC (#715). SOPS stays the
     bootstrap and break-glass store.
   - One identity: the Kubernetes API (#711), Headlamp (#712) and Jellyfin
     (#730) on Keycloak.
4. **Home automation in daily use** (#1072). Home Assistant runs the
   lights, heating, energy, plants, cameras and alarm sensors, with a main
   Home dashboard for the phones and a wall tablet, and the house keeps
   working when the cluster is down.
5. **The final version of observability and security monitoring.** Every
   metric and log answers a question (an SLO, an alert, a runbook, a
   detection, an audit) or is dropped or sampled; SigNoz with traces, or
   Honeycomb, as the one place for reliability and security signals, or
   neither (#801, #734); Prometheus keeps its 30 days (#905, #922);
   detection that contains a runtime threat automatically and captures the
   evidence (#803).
6. **A pentest to prove it works.** A scoped, technical pentest with a
   written report per run, from outside (the own IPs and domains) and from
   inside (the LAN, a compromised pod, a stolen session), its findings as
   issues: the homelab is secure, an intrusion is detected and blocked
   automatically (#718, spec PR #964).
7. **Website, blog and dashboard.** The public site with a blog (#971) and
   the homepage/dashboard (#817). Still to decide: a public demo dashboard,
   or everything private.
8. **Everything else.**
   - High availability and elastic where it can be: HPA for the stateless
     workloads, KEDA for event-driven scaling, VPA recommendations to size
     requests; no scale to zero (seconds of delay on the first request to
     save a few hundred MiB); bursting to cloud nodes stays a research note
     (#917, spec PR #963).
   - Recoverable from git alone: a monthly rebuild rehearsal in CI and a
     timed disaster-recovery run (#723); a written strategy around it: the
     scenarios (node, NAS, house, cloud account), RPO, RTO and measured MTTR
     per tier, and the standby choice with its cost and reasons (#918, spec
     PR #965); automatic Postgres majors (#745); consistent SQLite backups
     (#746); no stale restic lock can fail a backup (#919).
   - The NAS as a hardened dependency: scoped NFS exports and read-only
     media (#721), the failing cache device and the pending update (#719,
     #720, #722).
   - Chaos experiments tied to the SLOs (#733).
   - One push per problem (#915).
   - The rest of the open issues, by area below.

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
