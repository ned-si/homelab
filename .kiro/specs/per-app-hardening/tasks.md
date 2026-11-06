# Tasks: per-app-hardening

One pull request per task, in this order where dependencies allow. Tasks
marked "weekday" restart an app, a database or a controller: they follow
"One application pull request, step by step" in [design.md](design.md),
merge in the weekday window, 24 hours apart from a network-policy (#709)
or Pod Security (#724, #1020) flip of the same namespace [8]. Each task
removes the lines it closes from `ci/pod-hardening-gaps.txt` and the
"Hardening (probes, ...) is a later, separate change" header comment from
the files it hardens [10.4]. A root-profile task of an image that switches
user records the stop check [8.4]. Requirement numbers in brackets.

## Open

- [ ] 1. `feat(ci): pod-hardening rule with its gaps file`: the rule
      `pod-hardening` in `scripts/ci/repo_policy.py` as in design.md, with
      `APP_NAMESPACES`; `ci/pod-hardening-gaps.txt` seeded from its
      findings on `main` (each line `#726 task <n>` or its lasting
      reason), the fixtures in `tests/test_repo_policy.py`, the rule in
      `docs/testing.md`. [1]
- [ ] 2. Weekday. qBittorrent: liveness probe, root profile with `KILL`,
      `SETGID`, `SETUID` (`UMASK=002`, NFS), token, the stop check; the
      "Prevention" section of `docs/runbooks/arr-qbittorrent.md` as it is
      now. [2, 3, 4, 8, 9]
- [ ] 3. Weekday. Paperless and its Valkey: probes (Valkey readiness and
      liveness; Paperless `tcpSocket` liveness and startup), profiles
      (Valkey non-root `999:1000`, Paperless non-root `1000:1000` per its
      rootless docs), tokens; the ownership check on its four PVCs; the
      kind boot of Valkey green; `scripts/psa-readiness.sh paperless`
      after the sync. [2, 3, 4, 8, 9]
- [ ] 4. Weekday. Mealie: `tcpSocket` liveness and startup probes,
      non-root `1000:1000`, token; `scripts/psa-readiness.sh mealie`. [2,
      3, 4, 8, 9]
- [x] 5. Weekday. Syncthing (StatefulSet): readiness and liveness on
      `/rest/noauth/health`, non-root `1000:1000` without `fsGroup`, token;
      stop if the ownership check finds other owners; the brief allows
      `kubectl -n syncthing delete pod syncthing-0` for a forced rollback
      after a revert (design.md "Error handling");
      `scripts/psa-readiness.sh syncthing`. [2, 3, 4, 8, 9] #1156
- [x] 6. Weekday. Immich Valkey and machine learning: Valkey probes and
      non-root `999:1000`, machine learning non-root `1000:1000`
      (`fsGroup` on `immich-machine-learning-cache` only if the check
      asks), tokens in `resources/` and, for the chart-created account,
      through the chart's pod options [4.3]; `forceRename` unchanged. [2,
      3, 4, 8, 9] #1166
- [x] 7. Weekday. Immich server: root profile (no `KILL`, `SETGID` or
      `SETUID` unless the log asks), token through the chart's pod
      options [4.3], the `non-root` gap line with operator decision 1 as
      its reason; nothing on `immich-data`; `scripts/psa-readiness.sh immich`
      quoted for #1020. [3, 4, 8, 9] #1183
- [ ] 8. Weekday. Keycloak: non-root `1000:0`, token on the Deployment
      (the `keycloak-realm-settings` Job already has it off); the admin
      kubeconfig checked before and after; a login to one OIDC app and one
      oauth2-proxy UI in the 30-minute comment;
      `scripts/psa-readiness.sh keycloak`. [3, 4, 8]
- [x] 9. Weekday. Sonarr and its exportarr sidecar: root profile for the
      app (`UMASK=002`, NFS), exportarr non-root `65532:65532` on the
      container, pod-level seccomp, token, the stop check. [3, 4, 8, 9]
      #1170
- [ ] 10. Weekday. Radarr, as task 9. [3, 4, 8, 9]
- [ ] 11. Weekday. Lidarr, as task 9. [3, 4, 8, 9]
- [ ] 12. Weekday. Prowlarr, as task 9. [3, 4, 8, 9]
- [ ] 13. Weekday. Bazarr: root profile (capabilities within the six,
      `UMASK=002` kept), token, the stop check. [3, 4, 8, 9]
- [ ] 14. Weekday. LazyLibrarian, as task 13. [3, 4, 8, 9]
- [ ] 15. Weekday. Jellyfin: liveness and startup probes; the root
      profile with its gap line naming operator decision 2; token. If
      Jellyfin is scaled to 0 or removed before this task, the task is
      ticked with that PR and its gap lines removed. [2, 3, 4, 8, 9]
- [ ] 16. Weekday. Plex: liveness and startup probes, root profile with
      its gap line, token, the stop check. [2, 3, 4, 8, 9]
- [ ] 17. Weekday. Calibre-Web: root profile with its gap line, token, the
      stop check. [3, 4, 8, 9]
- [ ] 18. Weekday. Tokens off on what is left in the apps layer (design.md
      "Tokens"), the `components/postsync-smoke` Job included. [4, 8]
- [ ] 19. Weekday. Tokens off on what is left in the platform and
      infrastructure layers, through chart values where a chart exposes
      it; `token` gap lines with the chart as reason where it does not.
      [4, 8]
- [ ] 20. Weekday. Barman Cloud plugin: a liveness probe on its Deployment
      through a patch in `platform/barman-cloud-plugin/kustomization.yaml`.
      [6]
- [ ] 21. Weekday. `home-assistant-postgresql`: the `plugin-barman-cloud`
      sidecar resources on ObjectStore `cnpg-backup` (sync wave below the
      Cluster), `spec.resources` only if the rule gives more than today's;
      after the sync the sidecar check on the instance Pods and, since the
      Cluster may not change, `kubectl cnpg restart` under the silence
      (allowed by the brief); `instances` at merge time, 24 hours apart
      from #917's change of the Cluster. [5.1, 5.5, 8, 9]
- [ ] 22. Weekday. `mealie-postgresql`: `spec.resources` and the sidecar
      resources, as task 21. [5.1, 5.5, 8, 9]
- [ ] 23. Weekday. The four `theater` Clusters and their sidecar, as task
      22. [5.1, 5.5, 8, 9]
- [ ] 24. Weekday. `keycloak-db`, as task 22, with the admin kubeconfig
      check. [5.1, 5.5, 8, 9]
- [ ] 25. Weekday. `immich-db`, as task 22; image unchanged; the last
      base backup under 24 hours old quoted. [5.1, 5.5, 8, 9]
- [ ] 26. `backup-verify`: the `verify-source` sidecar resources (sync
      wave as in task 21); the next weekly restore test passes. [5.2]
- [ ] 27. Weekday. cert-manager: requests and memory limits for the
      controller, cainjector and webhook in its values; probes where the
      chart exposes them, the rest listed for task 38. [5.3, 6]
- [ ] 28. Weekday. external-dns: requests and memory limit in its values.
      [5.3]
- [ ] 29. Weekday. democratic-csi: requests and memory limits for every
      container of the controller and the node DaemonSet, controller probes
      where the chart exposes them, under `scripts/maintenance-silence.sh
      democratic-csi`. [5.3, 6]
- [ ] 30. Weekday. SigNoz: requests, memory limit and probes for the
      ClickHouse operator in its values. [5.3, 6]
- [ ] 31. Weekday. Tetragon: requests and memory limits for every
      container the render shows without them, in
      `platform/tetragon` values. [5.3]
- [ ] 32. Weekday. node-exporter: `prometheus-node-exporter.resources` in
      `platform/kube-prometheus-stack/values.yaml`. [5.3]
- [ ] 33. Weekday. Prometheus and Alertmanager:
      `prometheus.prometheusSpec.resources`,
      `alertmanager.alertmanagerSpec.resources` and
      `prometheusOperator.prometheusConfigReloader.resources`; the live
      PolicyReports of both Pods `pass` after the sync. [5.3]
- [ ] 34. Weekday. `grafana-postgresql`, after #917 task 13: its sidecar
      resources, and `spec.resources` if task 13 left them unset, as task
      22. [5.4, 5.5, 8, 9]
- [ ] 35. `feat(scripts): kyverno-deny-readiness.sh per policy`: K1 and K2
      of design.md, read-only, `tests/bash/test_kyverno_deny_readiness.sh`;
      one live run for each of the two policies quoted in the pull
      request. [6.1]
- [ ] 36. `feat(monitoring): page on Kyverno denials`: `KyvernoDenied` in
      `kyverno-alerts.yaml`, its tests, its runbook
      `docs/runbooks/alerts/KyvernoDenied.md`, the runbook index,
      `docs/sre.md`, `tests/alertmanager/routes.txt`; the live 7-day query
      in the pull request. [7]
- [ ] 37. Weekday. `require-requests-limits` to Deny and `BLOCKING`, after
      #917 tasks 13 and 18 to 20 and tasks 21 to 34: readiness `READY`,
      the operator-built Pods with evidence (tuppr from its source), the
      PolicyExceptions of D7, the live Kyverno break-glass test if #1021
      has not run it, the dry run with a Pod without requests. [6, 8.6]
- [ ] 38. Weekday. `require-probes` to Deny and `BLOCKING`, after tasks 2
      to 17, 20, 27, 29 and 30: readiness `READY`, the PolicyExceptions of
      D7 (Grafana's sidecars, the cert-manager cainjector if its chart
      has no probes), the dry run with a Deployment without probes. [6,
      8.6]
- [ ] 39. Close: `docs/architecture.md`, `docs/threat-model.md` and
      `docs/testing.md` as built; `ci/pod-hardening-gaps.txt` holds only
      lasting reasons, each fixable one with an issue; no "Hardening
      (probes, ...)" header comment left under `apps/` or `platform/`;
      [gitops-delivery](../gitops-delivery/) task 19 points here;
      `status: done`, `closed:`; #726 closed with a comment on #1020
      listing the namespaces whose `psa-readiness.sh` reads `READY`. [10]
