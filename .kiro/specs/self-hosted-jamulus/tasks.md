# Tasks: self-hosted-jamulus

One PR per task, in order. Each task merges after its review round and is
checked live where it changes the cluster (operator, 2026-11-24: no
approval pauses). No task writes to the cluster outside Argo CD; the live
checks are read-only. "No new alerts" means `ALERTS{alertstate="firing"}`
holds the same alerts 15 minutes after the sync as before the merge.
Defaults: [requirements.md](requirements.md#decided-defaults).

- [x] 1. The image (**live**: the Kyverno policy only): `jamulus/Dockerfile`,
      `jamulus/jamulus-release-key.asc`, `jamulus/jamulus-ping`,
      `scripts/ci/jamulus-smoke.sh`, `scripts/ci/jamulus-check.sh`, the
      `jamulus` job in `ci.yaml` (and in `ci`'s `needs` and loop),
      `.github/workflows/jamulus-publish.yaml`, the Renovate custom
      manager and deploy rule, the `ci/image-signers.yaml` entry, the
      `jamulus` attestor and validation in `verify-own-images.yaml`,
      `task render`. Also open the two issues of [design, Found on the
      way](design.md#found-on-the-way): the stale `*.lilalala.com`
      record, and "vuln-enrich: count namespaces behind a forwarded
      LoadBalancer as exposed".
      Check: the `jamulus` job ran and passed on the PR; after the merge
      the `jamulus-publish` run is green and its log shows the cosign
      verify; `gh attestation verify
      oci://ghcr.io/ned-si/homelab-jamulus@<digest> --owner ned-si`
      passes; the `:main` index lists `linux/amd64` and `linux/arm64`;
      `verify-own-images` is Ready. Then the operator's GHCR step
      ([design, Operator steps](design.md#operator-steps)), checked with
      `curl -s -o /dev/null -w '%{http_code}\n'
      'https://ghcr.io/token?scope=repository:ned-si/homelab-jamulus:pull'`
      printing `200`. [1] (#1713)
- [x] 2. The app (**live**). Starts only when the GHCR check of task 1
      prints `200`; until then the run sends the parent a `warning`
      naming the operator step, and at the cutoff records tasks 2-6 as
      open, blocked on the operator. Files: namespace `jamulus`
      (`restricted`), the `project-apps` destination,
      `clusters/homelab/apps/jamulus.yaml`, `"jamulus"` in
      `APP_NAMESPACES` of `scripts/ci/repo_policy.py` (after `"immich"`),
      `apps/jamulus/` (ServiceAccount, Deployment with the digest of task
      1's run, Service on `192.168.1.202` without node ports, PostSync
      Job `jamulus-smoke`), `58-jamulus.yaml` and the switch in
      `90-enforcement.yaml`, `ci/kind-workloads.txt`,
      `tests/test_jamulus.py` (port, the exact args, directory options,
      node ports), `docs/networking.md` LoadBalancer table and the policy
      count in Network policy (three more), the README address row,
      `task render`. Check: Application `jamulus` Synced and Healthy; pod
      Running 1/1, 0 restarts; Job `jamulus-smoke` Complete; `kubectl -n
      jamulus get svc jamulus` shows `192.168.1.202`, `41124/UDP`, no node
      port; from the Mac `/usr/bin/printf
      '\000\000\351\003\000\004\000\000\000\000\000\157\140' | nc -u -w 3
      192.168.1.202 41124 | xxd -p` prints `0000e903000400000000006f60`;
      the namespace's three PSA labels are `restricted`; the `jamulus`
      policy report has no `fail` and `verify-own-images` is `pass`;
      `vector_log_events_total{namespace="jamulus"}` increases; no new
      alerts. [2, 3, 4.1, 4.2, 6.3] (#1720)
- [x] 3. Probe and alert (**live**): `platform/jamulus-probe/`,
      `clusters/homelab/platform/jamulus-probe.yaml`, the `jamulus-probe`
      policy in `88-monitoring.yaml` and its ingress rule in
      `58-jamulus.yaml`, `jamulus-alerts.yaml`,
      `tests/prometheus/jamulus_test.yaml`, the `routes.txt` line,
      `docs/runbooks/alerts/JamulusDown.md` and its index row, the
      `docs/sre.md` review row and no-SLO sentence, the exporter row in
      `docs/observability.md`, `tests/test_jamulus_probe.py`, the probe
      target and the `jamulus-ping` byte check in `tests/test_jamulus.py`,
      the `--once` step in `scripts/ci/jamulus-smoke.sh`, the policy count
      in `docs/networking.md`, Network policy (one more), `task render`.
      Check: `jamulus_up{target="192.168.1.202:41124"}` is 1 and
      `jamulus_clients` is 0; `python3
      platform/jamulus-probe/exporter.py --once 192.168.1.202:41124` from
      the Mac prints `up clients=0`; `JamulusDown` is in Prometheus's
      rules and inactive; no new alerts. [6.1, 6.2, 6.4, 6.5] (#1723)
- [x] 4. DNS (**live**): `sources: [gateway-httproute, service]` and
      `--service-type-filter=LoadBalancer` in
      `infrastructure/external-dns/values.yaml`, the hostname annotation on
      the Service, the DNS section and the port-forward table row of
      `docs/networking.md`, the header comment of
      `scripts/published-hostnames.sh`, `task render`. Check: `dig +short
      jam.lilalala.com @1.1.1.1` is the `--default-targets` address; `dig
      +short TXT a-jam.lilalala.com @1.1.1.1` names
      `service/jamulus/jamulus`; the external-dns log has no `error`
      since the sync; `dig +short media.lilalala.com @1.1.1.1` is
      unchanged; `scripts/pentest-scope-check.sh` still passes; no new
      alerts. If the operator has set the router rule, `--once
      jam.lilalala.com:41124` from the Mac prints `up` (UDP through NAT
      loopback); otherwise it prints `down` and that is expected. [5] (#1729)
- [x] 5. Pentest and threat model (**not live**): the
      `forwarded_ports` entry in `docs/pentest/scope.yaml`, the ping step
      in `pentest-external.yaml`, the row in
      `docs/pentest/runbooks/external.md`, `"41124"` in
      `PENTEST_RUNBOOKS` of `scripts/ci/repo_policy.py`, the Jamulus
      boundary in `docs/threat-model.md` (threat I with the player list
      read without joining, D with UDP reflection, and the residual that
      host and port are public; [design, Pentest and threat
      model](design.md#pentest-and-threat-model)). Check:
      `scripts/pentest-scope-check.sh` passes; `ci` (actionlint, repo
      policy) is green. [7] (#1734)
- [x] 6. Docs and done (**live** for the radar): `docs/jamulus.md`,
      `docs/runbooks/jamulus.md` (with the router rule and its phone check
      exactly as in [design, Operator steps](design.md#operator-steps),
      and the upstream key rule in the upgrade section), the per-player
      bandwidth in requirements.md from a real session, the README
      services row and docs index link, the Jamulus and SonoBus radar
      entries and the re-rendered page, `product.md` and `structure.md`,
      the `media-home` area spec. Then this spec's header `status: done`,
      `closed:`, its row moved to "Change specs, done" in
      `.kiro/specs/README.md`, and #1702 closed. Check: links resolve in
      `ci`; `curl -s https://techradar.nedsi.io/ | grep -c
      'Jamulus\|SonoBus'` is at least 2; a newcomer can connect from
      `docs/jamulus.md` alone. [4.3, 8] (#1745)

The operator's router rule is not a task: he sets it, as written in
[design, Operator steps](design.md#operator-steps), only when remote
players are wanted, and removes it when they are not.

The last task ticked sets `status: done`, `closed:`, and closes #1702.
