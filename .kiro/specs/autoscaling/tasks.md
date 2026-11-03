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
      2.4, 4.1, 5.1, 5.2, 6.1, 6.2, 6.3, 7.1, 7.2, 10.3, 11.2]
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
      PDBs, `spec.replicas` out of git, CPU requests from 7-day peaks.
      Recorded check: no failed probe of `theater` over a scale-out and
      back. [2.1, 2.2, 2.3, 6.1, 6.3, 8.2, 9.1, 12.1]
- [ ] 7. Weekday. `keycloak-db` at `instances: 2`, required anti-affinity.
      Recorded: the replica streaming, its memory and NAS storage. [4.1,
      4.3]
- [ ] 8. Weekday. Keycloak: HPA 2 to 3, spread, PDB, `spec.replicas` out
      of git. Recorded checks: a cluster view of 2 members in the Keycloak
      log; a pod deleted, a session opened before still valid and a new
      login through the other pod; no failed probe of `auth`. [2.1, 2.2,
      2.3, 3.1, 3.2, 3.3, 9.1, 12.1]
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
- [ ] 13. Weekday. The Immich machine-learning cache off `ReadWriteOnce`,
      as open question 1 is answered. [6.1]
- [ ] 14. Weekday. ScaledObject for `immich-machine-learning` on the
      queues that call it, `minReplicaCount: 2`, `maxReplicaCount: 3`,
      `fallback.replicas: 2`, as open question 5 is answered. The PR
      records the image's compressed arm64 size and `/var` free on every
      node. Recorded check: a library scan moves it to 3 and back to 2, no
      failed probe of `media`. [10.2, 10.3, 11.1, 11.3, 12.1]
- [ ] 15. Weekday. Drain test, under a maintenance silence: drain the
      node of the `keycloak-db` primary and uncordon it. Recorded checks:
      `probe_success` of `auth`, `headlamp`, `hubble` and `argo` over the
      drain; the switchover of `keycloak-db`; the memory requests at every
      HA workload's maximum against three nodes' allocatable. [2.5, 4.2,
      9.2]
- [ ] 16. Weekday. Requests and limits of the platform layer from the
      script's output, after 8 days of history. [8.2]
- [ ] 17. Weekday. Requests and limits of `theater` and `books` from the
      script's output. [8.2]
- [ ] 18. Weekday. Requests and limits of the other apps (`immich`,
      `mealie`, `paperless`, `syncthing`, `home`) from the script's output;
      repo-policy rule `container-requests`. [8.2, 8.3]
- [ ] 19. Docs as built: `docs/architecture.md` (HA classes, scaled
      workloads), `docs/decisions.md` ("No scale to zero", "HA where an app
      supports it"), the roadmap theme, the `platform-talos` area spec;
      `ha-inventory` fails on a `pending` entry; header `status: done`,
      issue #917 closed. [1.3, 13.1]
