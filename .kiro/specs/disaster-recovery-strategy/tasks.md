# Tasks: disaster-recovery-strategy

One PR per task, in order; each is safe on its own. Requirement numbers in
brackets. Each PR carries `Spec: disaster-recovery-strategy#<task>`. The
PR of the last task to merge sets the spec `done` and closes #918; the
`backups-dr` area spec update is in task 9.

## Open

- [ ] 1. Record the strategy: the `docs/decisions.md` entry "Disaster
      recovery: a cold site in the cloud, built on demand" (the decision;
      the monthly cost of cold, warm and hot at AWS, Google Cloud and
      Hetzner against the value of what is hosted and the RPO and RTO per
      tier; warm and hot rejected; the review conditions); the "Disaster
      scenarios" table in `docs/sre.md` with RPO and RTO per tier and an
      MTTR column reading "not measured"; the "Off-site inventory" and the
      "Rehearsal calendar" in `docs/backups.md`; the roadmap theme pointed
      at this spec. [1.1, 1.2, 2.1, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 6.1]
- [ ] 2. The rehearsal record: `ci/dr-scenarios.tsv`, `ci/dr-rehearsals.tsv`
      (with `cost` and `currency` columns), `scripts/dr-mttr.sh` with its
      bash test; repo-policy rules `dr-rehearsals`, `dr-runbooks` and
      `dr-mttr-source` with their tests; `docs/runbooks/dr-rehearsal.md` (how
      to run, time and record a rehearsal; the pull request template, which
      names a missed RTO and opens its issue). [1.3, 2.2, 2.3, 6.2]
- [ ] 3. Results on the dashboard: CronJob `dr-rehearsal-report` in
      `backup-verify` (ConfigMap from the two files, the `dr-rebuild` runs from
      the public GitHub API, an egress rule to `api.github.com`); the
      "Disaster recovery" row on Homelab / Data protection, with the last
      drill's cost; `DRRehearsalOverdue` with its promtool test, route test,
      runbook and the PAGE table in `docs/sre.md`. [6.3, 6.4, 7.2]
- [ ] 4. Break-glass check: `scripts/dr-offsite-check.sh` (the age key
      matches `.sops.yaml` and decrypts a sealed file, `talosconfig` reaches a
      node, `RESTIC_PASSWORD` opens `immich/library` with the verifier key,
      the state passphrase decrypts a state file; prompts for the AWS root
      sign-in, the Hetzner sign-in, each item of the `homelab break-glass`
      folder and the emergency access; `tofu plan` on `bootstrap/dr-cloud/`
      from the password-manager copies once task 8 has merged);
      `docs/runbooks/operator-unavailable.md`; the operator's one-time
      set-up listed in the pull request (the folder, the second AWS root
      MFA device, the envelope, emergency access with a 2-day wait); the
      first run recorded. [4.3, 4.4, 9.1, 9.2, 10.7]
- [ ] 5. AWS account lost: `docs/runbooks/aws-account-lost.md` (new
      account, `bootstrap/tofu-state`, `bootstrap/aws-backup`,
      `bootstrap/github-oidc`, re-sealed keys, new `serverName`s, the Immich
      re-seed, the 24 h target); the second copy of the Immich library and
      of a dump of every database in Hetzner Object Storage (project
      `homelab-dr`), verified weekly by `backup-verify`. [5.1, 5.2, 5.3]
- [ ] 6. Monthly rebuild from git in CI (#723, part 1):
      `.github/workflows/dr-rebuild.yaml` on the Talos QEMU harness of
      `scripts/ci/talos-upgrade-rehearsal.sh`, test secrets sealed to a CI
      key, infrastructure and platform layers Healthy, one step per phase.
      [7.1, 7.2]
- [ ] 7. The site overlay, without any cloud resource: `components/site-dr`
      (storage behind the `iscsi` and `iscsi-retain` names with volume
      expansion, backed by `hcloud-csi`; `immich-data` at 500Gi;
      `infrastructure/cilium/values-dr.yaml` with the Gateway on the host
      network of the labelled Gateway node only
      (`gatewayAPI.hostNetwork.nodes.matchLabels`) and
      `envoy.securityContext.capabilities.keepCapNetBindService: true` for
      80 and 443; Syncthing on a hostPort with the `syncthing-dr`
      PolicyException; the NAS-bound components and alerts out; theater,
      SigNoz, the Home Assistant stack and `backup-verify`'s Postgres
      restore out; `volumeName` removed; the ebook library claim; CNPG
      `bootstrap.recovery` and new `serverName`s; the external-dns target
      as a value); `components/site-dr-drill` (the requirement 8 switches:
      the network-policy exception for OIDC to the Gateway node, no
      tailnet, no notifications, cert-manager without external-dns, the
      drill copies of the Secrets sealed to the real and rehearsal keys,
      with the drill Cloudflare token); a `.sops.yaml` rule for those
      copies; `clusters/dr/`; the DR render; repo-policy over it (the
      switches, the rehearsal-key recipients, the claims against
      Hetzner's 16-volume limit minus one free slot); `task render:check`
      proving the home render unchanged. No CoreDNS change: drill name
      resolution is task 9's Talos patch. [8.2, 8.3, 8.4, 8.7, 10.4]
- [ ] 8. The DR module: `bootstrap/dr-cloud/` for Hetzner, project
      `homelab-dr` (network, CAX nodes for the Full and DR shapes,
      addresses, firewall limited to `var.operator_cidr` and, in a drill,
      the Gateway ports too, the `hcloud-csi` token, the `dr-drill` label,
      the Talos snapshot adopted from `var.talos_snapshot_id` with a
      destroy-time delete, `backend_override.tf.example`);
      `scripts/dr-image.sh hcloud` (build, label, print the ID; `--delete`
      sweeps the project's volumes and snapshots); `talos/dr/talconfig.yaml`
      with its own secrets and schematic, the Gateway node label, no static
      hosts, checked by `scripts/ci/talos-validate.sh`; `tofu fmt -check`
      and `tofu validate` in `ci`; the module kept out of the `tofu`
      workflow's plan and apply, and the daily leftover check over the
      state and the project (read-only project token as an Actions
      secret); `docs/runbooks/site-lost.md` with the declaration rule, the
      apply command and the source of each input on a fresh machine, the
      restore order with the image step, the capacity fallbacks, the move
      to the Full shape for a loss longer than two weeks, and the return
      home. [1.4, 1.5, 8.1, 8.8, 10.1, 10.2, 10.3, 10.5, 10.6, 10.7]
- [ ] 9. First DR drill (#723, part 2): `scripts/dr-rehearsal.sh` (preflight
      for requirement 8, the rehearsal key only; writes
      `talos/dr/drill/static-hosts.yaml`, one `StaticHostConfig` with the
      Gateway node's private address and every HTTPRoute host name of the
      DR render, applied with `--config-patch`, and checks from a pod that
      `auth.lilalala.com` resolves to it before Argo CD; the DR probes with
      `curl --resolve` against the DR Gateway; a timestamp per step;
      `tofu destroy` and `scripts/dr-image.sh hcloud --delete` on exit);
      every tier restored, the whole Immich library included; MTTR per tier
      and the drill's cost from the bill in `ci/dr-rehearsals.tsv`; the
      estimates in `docs/backups.md` and `docs/sre.md` replaced by the
      measured values; the cost estimate in `docs/decisions.md` priced again
      in the Hetzner console; the `backups-dr` area spec updated (scenarios,
      the off-site inventory, the calendar, the DR site). Closes #723.
      Monday to Friday, daytime.
      [2.4, 7.3, 7.4, 8.1, 8.5, 8.6, 8.8]
- [ ] 10. First node-replacement rehearsal: `homelab-w-1` reflashed with
      [node-replacement.md](../../../docs/runbooks/node-replacement.md),
      timed to `Ready` and to every tier 1 probe green; the line recorded; the
      runbook's estimate replaced. Monday to Friday, daytime, with a
      maintenance silence. [2.4, 6.2]
