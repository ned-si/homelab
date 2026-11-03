# Tasks: autoscaling

One PR per task, in order; each is safe on its own. Tasks marked
"weekday" restart an app or a database and merge Monday to Friday, 09:00
to 17:00 Europe/Zurich [12.3]. Each HA task removes the `pending` marks of
its workloads from `ci/ha-inventory.yaml`.

## Open

- [ ] 1. `ci/ha-inventory.yaml` with every workload as in design.md (the
      HA changes `pending`), and the repo-policy rules `ha-inventory`,
      `ha-replicas`, `autoscale-floor`, `autoscale-targets` and
      `vpa-recommend-only` over the rendered objects, with a passing and a
      failing fixture each; they pass on `main`. [1.1, 1.2, 2.1, 2.2, 2.3,
      2.4, 2.6, 4.1, 5.1, 5.2, 6.1, 6.2, 6.3, 7.1, 7.2, 10.3, 11.2]
- [ ] 2. VPA recommender: Application `vpa` in the platform layer, chart
      values with the updater and admission controller disabled, namespace
      `vpa`, CRD schemas in `ci/schemas/`. The PR records the image's
      `linux/arm64` manifest and compressed size. [7.1, 11.1, 11.2]
- [ ] 3. One `updateMode: "Off"` VPA per Deployment and StatefulSet of the
      apps and platform layers (not `signoz`, `logging`); repo-policy rule
      `vpa-coverage`; the recommendations in kube-state-metrics
      `customResourceState`. Recorded check: one
      `kube_vpa_recommendation_target` series per covered container and
      resource. [7.2, 7.3, 7.4]
- [ ] 4. `scripts/vpa-requests.sh` and `tests/bash/test_vpa_requests.sh`;
      the VPA report section in `docs/observability.md`. [8.1, 13.1]
- [ ] 5. KEDA: Application `keda` in the platform layer, namespace `keda`,
      no HTTP add-on, 2 replicas of the operator and the metrics API
      server, PDBs, `APIService` in the platform AppProject, CRD schemas.
      The PR records the images' `linux/arm64` manifests and sizes.
      Recorded check: `v1beta1.external.metrics.k8s.io` `Available`.
      [10.1, 11.1, 11.2]
- [ ] 6. Weekday. The SSO proxies and frontends: HPAs (2 to 3) for
      `theater-sso`, `headlamp-sso`, `hubble-sso` and `headlamp`;
      `hubble-ui` and `hubble-relay` at 2 in the Cilium values; spread,
      PDBs, `spec.replicas` out of git, CPU requests from 7-day peaks; the
      public probe `https://headlamp.lilalala.com/ping` in
      `platform/blackbox-exporter/probes/probes.yaml`. Recorded check: no
      failed probe of `theater` over a scale-out and back. [2.1, 2.2, 2.3,
      2.5, 6.1, 6.3, 8.2, 9.1, 12.1]
- [ ] 7. Weekday. `keycloak-db` at `instances: 2`, required anti-affinity.
      Recorded: the replica streaming, its memory and NAS storage. [4.1,
      4.3]
- [ ] 8. Weekday. Keycloak: HPA 2 to 3, spread, PDB, `spec.replicas` out
      of git; CPU and memory requests from the 7-day peak (the Deployment
      has none); the headless Service `keycloak-discovery` with
      `publishNotReadyAddresses: true` and `-Djgroups.dns.query` pointed at
      it. Recorded checks: a cluster view of 2 members in the Keycloak log,
      after one pod is deleted and after both are deleted together; a pod
      deleted, a session opened before still valid and a new login through
      the other pod; no failed probe of `auth`. [2.1, 2.2, 2.3, 3.1, 3.2,
      3.3, 8.2, 9.1, 12.1]
- [ ] 9. Weekday. Infrastructure controllers at 2 with PDBs and spread:
      cert-manager (controller, cainjector, webhook), Kyverno (admission,
      reports, cleanup), metrics-server, and the democratic-csi controller
      once its CSI sidecars are confirmed to run with leader election (if
      not, its inventory entry becomes `none` with that reason). [2.1, 2.2,
      2.3]
- [ ] 10. Argo CD: `argocd-server` and `argocd-repo-server` at 2, the
      ApplicationSet controller at 2 with leader election, PDBs and spread,
      in `bootstrap/argocd-values.yaml`. [2.1, 2.2, 2.3]
- [ ] 11. Platform: the CloudNativePG operator, Alertmanager and the
      blackbox exporter at 2, PDBs and spread. Recorded check: Alertmanager
      reports 2 cluster members. [2.1, 2.2, 2.3]
- [ ] 12. Weekday. The six app databases (`home-assistant`, `mealie`,
      `sonarr`, `radarr`, `lidarr`, `prowlarr`) at `instances: 2`, required
      anti-affinity. Recorded: memory and NAS storage added. [4.1, 4.3]
- [ ] 13. Weekday. Grafana on PostgreSQL (answered question 11): a
      CloudNativePG cluster `grafana-postgresql` in `monitoring` at
      `instances: 2` with the Barman Cloud plugin, its backup-SLO target
      and restore test like the other clusters; Grafana at 2 replicas on
      it with spread and a PDB; its persistence and the `grafana-backup`
      CronJob removed, with what refers to them:
      `ci/active-cronjobs.txt`,
      `platform/kube-prometheus-stack/routes/backup-slo-targets.yaml`, the
      `grafana-db` line of `platform/backup-verify/scripts/restic-targets.txt`,
      the comment in `scripts/set-backup-target.sh`, `grafana/data` in
      `restic_repos` of `bootstrap/aws-backup/main.tf` marked `# retained`
      (its snapshots keep the old `grafana.db`), and the Grafana rows of
      `docs/backups.md`, `docs/observability.md` and `docs/secrets.md`
      (`agent-readonly` now kept in `grafana-postgresql`). After the sync,
      `agent-readonly` re-created as Viewer with a new token through the
      Grafana API, the token written to its file under
      `~/homelab-backups/agent/` and never printed. Recorded: memory and
      NAS storage added, dashboards present, an operator login through
      Keycloak, a read-only query with the new token. [2.1, 2.2, 2.3, 2.6,
      4.1, 4.3]
- [ ] 14. Weekday. `immich-db` at `instances: 2`, required anti-affinity,
      same pinned image (answered question 10); a fresh backup first.
      Recorded: the replica streaming, its memory and NAS storage. [4.1,
      4.3]
- [ ] 15. Weekday. Immich machine learning at 2 replicas (answered
      questions 5 and 9): the cache on a static `ReadWriteMany` NFS volume
      on the NAS, `strategy: RollingUpdate` with `maxSurge: 1` and
      `maxUnavailable: 0` instead of `Recreate`, spread across nodes with
      the worker preferred, a PDB, a CPU request from the 7-day peak and a
      CPU limit of 4 cores. The PR records the image's compressed arm64
      size and `/var` free on every node. Recorded checks: a rollout keeps
      one pod Ready throughout; smart search answers; no failed probe of
      `media`. [2.1, 2.2, 2.3, 2.6, 6.1, 11.3, 12.3]
- [ ] 16. Weekday. ScaledObject for `immich-machine-learning` as in
      design.md (KEDA trigger): `redis` triggers on the `smartSearch`,
      `faceDetection` and `ocr` wait lists after their names are listed
      read-only, `minReplicaCount: 2`, `maxReplicaCount: 3`,
      `fallback.replicas: 2`; `spec.replicas` out of git; the Valkey
      ingress from `keda` in `20-immich.yaml`. The PR records `/var` free
      on every node. Recorded checks: the ScaledObject `Ready`, the flow
      from `keda` to Valkey allowed by the new rule (requirement 10.4); a
      library scan moves it to 3 and back to 2, the queue drains faster at
      3 (or the ScaledObject goes and ML stays at 2), no failed probe of
      `media`. [6.3, 10.2, 10.3, 10.4, 11.3, 12.1]
- [ ] 17. Weekday. Drain test, under a maintenance silence: drain the
      node of the `keycloak-db` primary and uncordon it. Recorded checks:
      `probe_success` of `auth`, `headlamp`, `hubble` and `argo` over the
      drain; the switchover of `keycloak-db`; the memory requests at every
      HA workload's maximum against three nodes' allocatable. [2.5, 4.2,
      9.2]
- [ ] 18. Weekday. Requests and limits of the platform layer from the
      script's output, after 8 days of history. [8.2]
- [ ] 19. Weekday. Requests and limits of `theater` and `books` from the
      script's output. [8.2]
- [ ] 20. Weekday. Requests and limits of the other apps (`immich`,
      `mealie`, `paperless`, `syncthing`, `home`) from the script's output;
      repo-policy rule `container-requests`. [8.2, 8.3]
- [ ] 21. Docs as built: `docs/architecture.md` (HA classes, scaled
      workloads), `docs/decisions.md` ("No scale to zero", "HA where an app
      supports it"), the roadmap theme, and the area specs this changes:
      `platform-talos` (spread and PDBs under tuppr's drains),
      `access-identity` (the Keycloak cluster), `backups-dr` (CloudNativePG
      replicas, backups from the standby, `grafana-postgresql`),
      `gitops-delivery` (Argo CD HA), `observability-alerting`
      (Alertmanager cluster, the `headlamp` probe); `ha-inventory` fails on
      a `pending` entry; header `status: done`, issue #917 closed. [1.3,
      13.1]
