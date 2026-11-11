# Tasks: netpol-default-deny

One pull request per task. A flip changes one switch value (plus `deploy/`)
and follows "The flip, step by step" in [design.md](design.md); its body has
the gate values, the Jobs in the window, `## Rollback` (the exact `git revert`
and the break-glass command) and, after the sync, a comment with the checks
of Requirement 7.2. Tasks run in this order where their gates allow; a closed
gate moves on to the next application namespace (decision D4). Requirement
numbers in brackets.

## Done

- [x] 1. `fix(monitoring): netpol readiness every 2m, with presence`:
      `interval: 2m` for `netpol.ready` in
      `platform/kube-prometheus-stack/routes/netpol.yaml`; the presence term
      (`netpol:would_drop:series` every minute, `netpol:would_drop:seen7d`
      its 7-day maximum, `netpol:ready_to_enforce` 1 only when `seen7d` is
      0); in `tests/prometheus/netpol_test.yaml` a case at
      `eval_time: 8d10m` and a case where a `match="all"` series appears
      once at value 1 and never changes (`increase7d` 0, `seen7d` above 0,
      ready 0); `scripts/netpol-observe.sh --days` lists every series
      present in the window (`max_over_time`) with its increase, and its
      test; the series table in `docs/networking.md`. Check after the sync:
      an instant query of `netpol:ready_to_enforce` returns 10 series at any
      time, and 0 for `syncthing` ingress and `paperless` egress (their
      once-only series of 2026-11-04). [1.1, 1.2, 1.4] (#1015)
- [x] 2. `docs(runbooks): network policy break-glass and flip`:
      `docs/runbooks/netpol-enforcement.md` (break-glass per layer, the
      merge hold of D6 with its auto-merge and other-runner steps, the flip
      procedure with the enforcement proof of D16, expected outputs), linked from
      `90-enforcement.yaml` and `docs/networking.md`; the live test on a
      scratch namespace with the admin kubeconfig only, its result and timing
      in the pull request. Before any flip. [5.6, 6.1, 6.2] (#1025)
- [x] 4. Flip `paperless` ingress, once the Paperless lane of the current run
      is done. [2, 4.1, 4.2, 7] (#1038)
- [x] 13. `immich` rules before its flips: an explicit `kube-apiserver` ingress
      rule to the CloudNativePG operator's webhook port in `20-immich.yaml`
      (covered today only by the switch's `host` and `remote-node` rule), and the 7.6
      egress would-be drops per week and the 4 egress presence series (3
      with no increase on 2026-11-04) identified. [3, 5.4] (#1059)

## Open

- [ ] 3. `feat(network): books allow-list, not enforced`:
      `infrastructure/network-policies/40-books.yaml` from
      `scripts/netpol-observe.sh books` and the manifests in `apps/` (one
      comment per rule), the `books` switch block (both `false`), `books` in
      the namespace list of `netpol.yaml` and its test. Starts the 7-day
      audit. [3.1, 4.4]
- [ ] 5. `mealie` residuals: identify the 2 ingress and 2 egress would-be
      drops per week and every presence series (2 per direction on
      2026-11-04, one of each with no increase) (`netpol-observe.sh mealie
      --days 7`, then live); allow rules or intended drops in
      `50-mealie.yaml`. Skip when the gate is already open. [3]
- [ ] 6. Flip `mealie` ingress. [2, 4, 7]
- [ ] 7. Flip `mealie` egress, with a fresh OIDC login in the checks. [2, 4,
      5.4, 7]
- [ ] 8. Flip `books` ingress, 7 days after task 3. [2, 4, 7]
- [ ] 9. Flip `books` egress. [2, 4, 7]
- [ ] 10. `syncthing` residuals, in `60-syncthing.yaml`: ingress, a rule
      from the `postsync-smoke` hook Job to Syncthing (seen once, invisible
      to the rate; port from the component and a live run); egress, the
      private peer addresses and NAT-PMP as intended drops (decision D5),
      the 331 connections to the API server identified and allowed or
      dropped, and every other presence series decided. [3, 2.2]
- [ ] 11. Flip `syncthing` ingress, with the `postsync-smoke` peers at a
      `match` other than `all` after task 10. [2, 4, 7]
- [ ] 12. Flip `syncthing` egress. [2, 4, 7]
- [ ] 14. Flip `immich` ingress, with the D12 dry run of
      `immich-db`. [2, 4, 5.4, 7]
- [ ] 15. Flip `immich` egress, with the D12 dry run of every Cluster
      (the operator's egress) and a fresh OIDC login. [2, 4, 5.4, 7]
- [ ] 16. `theater` residuals: the 3.9 ingress would-be drops per week, Plex
      and Jellyfin off 443, qBittorrent to `remote-node`, and every presence
      series (3 ingress and 18 egress on 2026-11-04, 2 and 8 with no
      increase), in `10-theater.yaml` or `15-theater-metrics.yaml`. [3]
- [ ] 17. Flip `theater` ingress. [2, 4, 7]
- [ ] 18. Flip `theater` egress, with the D12 dry run of the four Clusters.
      [2, 4, 5.4, 7]
- [ ] 19. Flip `paperless` egress, 7 days after tasks 4 to 6 of
      [paperless-documents](../paperless-documents/tasks.md) merge (decision
      D14), once the `paperless` to `world` series seen on 2026-11-04 is
      identified (`netpol-observe.sh paperless --since`) and allowed or
      listed as intended in `30-paperless.yaml`, in its own pull request
      first. [2.2, 3, 4, 7]
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

- [ ] 33. Platform namespaces (assessment P3, #1011): `87-platform-ingress.yaml`
  observes argo, kyverno, cert-manager, system-upgrade, trivy-system and
  democratic-csi from 2026-11-11. After 7 days, `netpol-observe.sh --days 7`
  per namespace, a rule or a reason for every `all` row, then flip ingress one
  namespace at a time, webhooks first checked with a server dry run. [2, 4, 7]
