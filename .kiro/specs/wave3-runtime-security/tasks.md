# Tasks: wave 3 runtime security (Kyverno audit, Tetragon observe)

Each task is one PR or one recorded check. Requirement numbers in brackets. One topic per
PR; CI is the gate; merge with `scripts/pr-merge.sh`. Before a change that restarts node
agents, run `scripts/maintenance-silence.sh <namespace> <duration> "<reason, PR #>"`.

- [x] 1. Answer the design's open questions in `design.md` (read-only: upstream repos and
      docs, `kyverno apply` locally over `deploy/`, the live cluster). [1.6, 2.1, 4.2, 6.4]
- [x] 2. (#563) PR `feat(policy): vendor the upstream Kyverno policies`: `scripts/kyverno-vendor.sh`,
      `policies/kyverno/upstream/` with `SOURCE`, Renovate regex manager, `renovate-render`
      hook, `scripts/ci/kyverno.sh` blocking list by name, replace the four homelab
      duplicates after the side-by-side comparison, updated CLI tests. CI only, nothing in
      the cluster yet. [1.2, 1.3, 1.4, 1.5]
- [x] 3. (#569) PR `feat(policy): map each policy to CIS, NIST and NSA/CISA`:
      `policies/kyverno/upstream/controls.yaml`, `tests/test_security_controls.py`, the
      controls section of `docs/threat-model.md` (with the wave 4 baseline counts). [3.1,
      3.3, 3.4]
- [x] 4. (#573) PR `feat(policy): Kyverno admission in Audit mode`: namespace `kyverno`, the
      Application (infrastructure layer), values (two controllers, `failurePolicy: Ignore`,
      timeout, exclusions, JSON logs, digests, resources, probes), AppProject kinds, the
      ValidatingPolicy and PolicyException schemas for kubeconform. Watch the first sync
      and the background scan. [1.1, 1.3, 1.6, 1.7, 2.1]
      Cold start (1.6): kind preprod installs no Helm chart, so it has no Kyverno webhook to
      scale to 0; the check is the live read-back that every Kyverno webhook is `Ignore`
      and skips the excluded namespaces (`docs/architecture.md`).
      First sync follow-up: the app stayed OutOfSync on the empty `labels: {}`
      of the `kyverno-api` subchart's CRDs; fixed with `kyverno-api.labels`
      (#673 used the wrong key, #679).
- [x] 4b. (#674) PR `feat(policy): PolicyExceptions for the expected findings`:
      `policies/kyverno/exceptions/` with a `homelab/reason` annotation each, written from
      the first live background scan, passed to the CLI in `scripts/ci/kyverno.sh`. [2.2]
- [x] 5. (#675) PR `feat(observability): Kyverno reports on the Security dashboard`:
      kube-state-metrics `customResourceState`, Kyverno scrape, dashboard rows,
      `KyvernoReportsStale` (human, warning) with promtool tests, runbook section,
      `routes.txt` line. [2.3, 2.4, 2.5, 5.3, 5.4]
- [x] 6. PR `feat(security): Tetragon in observe mode`: namespace `tetragon` (privileged,
      reason), Application, values (export allowlist on tmpfs, metric label filter,
      resources, digests, JSON), vendored library policies with `SOURCE` and
      `controls.yaml`, the enforcement-action check, Renovate manager. Silence `tetragon`
      for the first rollout. [3.2, 3.3, 4.1, 4.2, 4.3, 4.4, 4.5]
- [x] 7. (#703, the scrape fix #702; the rules are `platform/kube-prometheus-stack/routes/tetragon-alerts.yaml`, next to the other homelab rules) PR `feat(security): page on critical runtime detections`: `platform/tetragon/rules.yaml`
      (the four technique alerts with allowlists, `TetragonAgentMissing`), promtool tests
      with allowlisted negatives, runbook sections, `routes.txt` lines, the Security
      dashboard runtime row, `docs/sre.md` PAGE table. [4.6, 5.1, 5.2, 5.3, 5.4, 5.5]
- [x] 8. Observe 24 h, read-only: no runtime alert on known-good actors, Tetragon CPU and
      memory within limits, reports fresh. Record the result here. [4.1, 5.1]
      Result (2026-10-27): no runtime page from 2026-10-26 10:13Z to the Talos 1.14.5
      rollout at 09:59Z. The rollout restarted every pod, and the restarts paged:
      udevadm and container autoload requests, valkey `setpriv`, syncthing `setcap`, the
      Plex Tuner. #787 (no module-load page in a node's first 15 min) and #790 (explicit
      loads only, the restart actors allowlisted) fixed that, with promtool cases for each;
      nothing fired after #790 synced at 11:49Z. Tetragon 9-32m CPU and 143-161Mi per
      node (limit 512Mi), no restarts; 790 Kyverno reports, newest within the hour.
- [x] 9. (#691; 6.2 was #546, 6.3 already in `access.conf`) PR `feat(keycloak): brute-force protection and OTP for platform clients`:
      `platform.conf`, `apply.sh`, `access.conf` (`hubble`, `signoz` gated to `admins`
      when spec `wave3-network-logs` adds them, or here first), direct grants off with the
      PostSync read-back, bash tests, `docs/architecture.md`. [6.1, 6.2, 6.3, 6.4, 6.5]
- [x] 10. Tick this file and record the PR numbers. [all]
