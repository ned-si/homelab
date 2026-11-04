# Tasks: netpol-default-deny

One pull request per task. A flip changes one switch value (plus `deploy/`)
and follows "The flip, step by step" in [design.md](design.md); its body has
the gate values, the Jobs in the window, `## Rollback` (the exact `git revert`
and the break-glass command) and, after the sync, a comment with the checks
of Requirement 7.2. Tasks run in this order where their gates allow; a closed
gate moves on to the next application namespace (decision D4). Requirement
numbers in brackets.

## Open

- [ ] 1. `fix(monitoring): netpol readiness every 2 minutes`: `interval: 2m`
      for `netpol.ready` in `platform/kube-prometheus-stack/routes/netpol.yaml`,
      a promtool case at `eval_time: 8d10m` in
      `tests/prometheus/netpol_test.yaml`, the series table in
      `docs/networking.md`. Check after the sync: an instant query of
      `netpol:ready_to_enforce` returns 10 series at any time. [1.1, 1.2]
- [ ] 2. `docs(runbooks): network policy break-glass and flip`:
      `docs/runbooks/netpol-enforcement.md` (break-glass per layer, the train
      hold, the flip procedure, expected outputs), linked from
      `90-enforcement.yaml` and `docs/networking.md`; the live test on a
      scratch namespace with the admin kubeconfig only, its result and timing
      in the pull request. Before any flip. [5.6, 6.1, 6.2]
- [ ] 3. `feat(network): books allow-list, not enforced`:
      `infrastructure/network-policies/40-books.yaml` from
      `scripts/netpol-observe.sh books` and the manifests in `apps/` (one
      comment per rule), the `books` switch block (both `false`), `books` in
      the namespace list of `netpol.yaml` and its test. Starts the 7-day
      audit. [3.1, 4.4]
- [ ] 4. Flip `paperless` ingress, once the Paperless lane of the current run
      is done. [2, 4.1, 4.2, 7]
- [ ] 5. `mealie` residuals: identify the 2 ingress and 2 egress would-be
      drops per week (`netpol-observe.sh mealie --days 7`, then live); allow
      rules or intended drops in `50-mealie.yaml`. Skip when the gate is
      already open. [3]
- [ ] 6. Flip `mealie` ingress. [2, 4, 7]
- [ ] 7. Flip `mealie` egress, with a fresh OIDC login in the checks. [2, 4,
      5.4, 7]
- [ ] 8. Flip `books` ingress, 7 days after task 3. [2, 4, 7]
- [ ] 9. Flip `books` egress. [2, 4, 7]
- [ ] 10. Flip `syncthing` ingress (gate open on 2026-11-04). [2, 4, 7]
- [ ] 11. `syncthing` egress residuals: the private peer addresses and
      NAT-PMP as intended drops (decision D5), the 331 connections to the API
      server identified and allowed or dropped, in `60-syncthing.yaml`. [3]
- [ ] 12. Flip `syncthing` egress. [2, 4, 7]
- [ ] 13. `immich` rules before its flips: an explicit `kube-apiserver` ingress
      rule to the CloudNativePG operator's webhook port in `20-immich.yaml`
      (covered today only by the switch's `host` and `remote-node` rule), and the 7.6
      egress would-be drops per week identified. [3, 5.4]
- [ ] 14. Flip `immich` ingress, with the D12 dry run of
      `immich-db`. [2, 4, 5.4, 7]
- [ ] 15. Flip `immich` egress, with the D12 dry run of every Cluster
      (the operator's egress) and a fresh OIDC login. [2, 4, 5.4, 7]
- [ ] 16. `theater` residuals: the 3.9 ingress would-be drops per week, Plex
      and Jellyfin off 443, qBittorrent to `remote-node`, in `10-theater.yaml`
      or `15-theater-metrics.yaml`. [3]
- [ ] 17. Flip `theater` ingress. [2, 4, 7]
- [ ] 18. Flip `theater` egress, with the D12 dry run of the four Clusters.
      [2, 4, 5.4, 7]
- [ ] 19. Flip `paperless` egress, 7 days after tasks 4 to 6 of
      [paperless-documents](../paperless-documents/tasks.md) merge (decision
      D14). [2.2, 4, 7]
- [ ] 20. `feat(network): home allow-list, not enforced`: `70-home.yaml`
      (Home Assistant, Mosquitto, Zigbee2MQTT, `home-assistant-postgresql`
      with the CloudNativePG rules), switch, recording rules and test. [4.4,
      5.4]
- [ ] 21. Flip `home` ingress. [2, 4, 7]
- [ ] 22. Flip `home` egress. [2, 4, 5.4, 7]
- [ ] 23. `feat(network): backup-verify allow-list, not enforced`:
      `80-backup-verify.yaml` (reads of every database, S3, the restore
      scratch volumes' pods, the Pushgateway), switch, recording rules and
      test. [4.4]
- [ ] 24. Flip `backup-verify` ingress. [2, 4, 7]
- [ ] 25. Flip `backup-verify` egress, on a Sunday after the weekly restore
      tests or with one run started by hand. [2, 4, 7]
- [ ] 26. `feat(network): keycloak allow-list, not enforced`:
      `85-keycloak.yaml` (the Gateway, Prometheus, `keycloak-db` with the
      CloudNativePG rules, S3), switch, recording rules and test. [4.4, 5.4]
- [ ] 27. Flip `keycloak` ingress, with a login to one app per client type
      (OIDC app, oauth2-proxy UI). [2, 4, 7]
- [ ] 28. Flip `keycloak` egress. [2, 4, 5.4, 7]
- [ ] 29. `feat(network): monitoring allow-list, not enforced`:
      `88-monitoring.yaml` (Prometheus scrapes of every namespace, the nodes
      and the control plane; Alertmanager to ntfy.sh and the receivers;
      healthchecks.io; Grafana to Keycloak; the blackbox probes; the
      exporters), switch, recording rules and test. [4.4, 5.6]
- [ ] 30. Flip `monitoring` ingress. [2, 4, 7]
- [ ] 31. Flip `monitoring` egress, with `Watchdog` and the healthchecks.io
      check green after the sync and every scrape target `up` (L8). [2, 4, 7]
- [ ] 32. Close: `docs/networking.md`, the `90-enforcement.yaml` header and
      `docs/threat-model.md` describe the enforced state;
      [access-identity](../access-identity/) updated where it names the
      network boundary; `status: done`, `closed:`; #709 closed. [8]
