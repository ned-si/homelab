# Tasks: autoscaling

One PR per task, in order; each is safe on its own. Tasks marked
"weekday" restart an app and merge Monday to Friday, 09:00 to 17:00
Europe/Zurich [8.3].

## Open

- [ ] 1. Repo-policy rules `autoscale-floor`, `autoscale-targets` and
      `vpa-recommend-only` over the rendered objects, with a passing and a
      failing fixture each; no autoscaler exists yet, so they pass on
      `main`. [1.1, 1.2, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 6.3, 7.2]
- [ ] 2. VPA recommender: Application `vpa` in the platform layer, chart
      values with the updater and admission controller disabled, namespace
      `vpa`, CRD schemas in `ci/schemas/`. The PR records the image's
      `linux/arm64` manifest and compressed size. [3.1, 7.1, 7.2]
- [ ] 3. One `updateMode: "Off"` VPA per Deployment and StatefulSet of the
      apps and platform layers (not `signoz`, `logging`); repo-policy rule
      `vpa-coverage`; the recommendations in kube-state-metrics
      `customResourceState`. Recorded check: one
      `kube_vpa_recommendation_target` series per covered container and
      resource. [3.2, 3.3, 3.4]
- [ ] 4. `scripts/vpa-requests.sh` and `tests/bash/test_vpa_requests.sh`;
      the VPA report section in `docs/observability.md`. [4.1, 9.1]
- [ ] 5. Weekday. Requests and limits of the platform layer from the
      script's output, after 8 days of history (Keycloak, the
      oauth2-proxies, Headlamp, the exporters). [4.2]
- [ ] 6. Weekday. Requests and limits of `theater` and `books` from the
      script's output. [4.2]
- [ ] 7. Weekday. Requests and limits of the other apps (`immich`,
      `mealie`, `paperless`, `syncthing`, `home`) from the script's output;
      repo-policy rule `container-requests`. [4.2, 4.3]
- [ ] 8. KEDA: Application `keda` in the platform layer, namespace `keda`,
      no HTTP add-on, `APIService` in the platform AppProject, CRD schemas.
      The PR records the images' `linux/arm64` manifests and sizes.
      Recorded check: `v1beta1.external.metrics.k8s.io` `Available`.
      [6.1, 7.1, 7.2]
- [ ] 9. HPAs for `theater-sso`, `headlamp-sso`, `hubble-sso` and
      `headlamp`; `spec.replicas` out of git, topology spread. Recorded
      checks: the memory sum at `maxReplicas` against three nodes; no
      failed probe of `theater` over a scale-out and back. [2.3, 2.4, 5.1,
      5.2, 8.1]
- [ ] 10. Weekday. HPA for `keycloak`. Recorded checks: with two pods, one
      Infinispan cluster of two members in the Keycloak log, a login
      through each pod, no failed probe of `auth`. [5.1, 8.1, 8.3]
- [ ] 11. Weekday. The Immich machine-learning cache off `ReadWriteOnce`,
      as open question 2 is answered. [2.1, 8.3]
- [ ] 12. Weekday. ScaledObject for `immich-machine-learning` on the
      queues that call it, `minReplicaCount: 1`, `maxReplicaCount: 2`,
      `fallback.replicas: 1`. The PR records the image's compressed arm64
      size and the free eMMC on the nodes. Recorded check: a library scan
      moves it to 2 and back to 1, no failed probe of `media`. [6.2, 6.3,
      7.1, 8.1, 8.3]
- [ ] 13. Docs as built: `docs/architecture.md` (scaled workloads),
      `docs/decisions.md` ("No scale to zero"), the roadmap theme, the
      `platform-talos` area spec; header `status: done`, issue #917
      closed. [9.1]
