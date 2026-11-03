# Tasks: disaster-recovery-strategy

One PR per task, in order; each is safe on its own. Requirement numbers in
brackets. Each PR carries `Spec: disaster-recovery-strategy#<task>`.

## Open

- [ ] 1. Record the strategy: the `docs/decisions.md` entry "Disaster
      recovery: a cold site in the cloud, built on demand" (the decision;
      the monthly cost of cold, warm and hot at AWS, Google Cloud and
      Hetzner against the value of what is hosted and the RPO and RTO per
      tier; warm and hot rejected; the review conditions); the "Disaster
      scenarios" table in `docs/sre.md` with RPO and RTO per tier and an
      MTTR column reading "not measured"; the "Off-site inventory" and the
      "Rehearsal calendar" in `docs/backups.md`; the roadmap theme pointed
      at this spec. The calendar waits for open question 4.
      [1.1, 1.2, 2.1, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 6.1]
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
      sign-in, the recovery provider's sign-in and the emergency access);
      `docs/runbooks/operator-unavailable.md`; the first run recorded. Needs
      open questions 2 and 3 answered. [4.3, 4.4, 9.1, 9.2]
- [ ] 5. AWS account lost: `docs/runbooks/aws-account-lost.md` (new
      account, `bootstrap/tofu-state`, `bootstrap/aws-backup`,
      `bootstrap/github-oidc`, re-sealed keys, new `serverName`s, the Immich
      re-seed, the 24 h target). When the recovery provider is not AWS, the
      second copy of the Immich library and of a dump of every database in
      its object storage, verified weekly by `backup-verify`; otherwise a
      `deferred` issue. Needs open question 1 answered. [5.1, 5.2, 5.3]
- [ ] 6. Monthly rebuild from git in CI (#723, part 1):
      `.github/workflows/dr-rebuild.yaml` on the Talos QEMU harness of
      `scripts/ci/talos-upgrade-rehearsal.sh`, test secrets sealed to a CI
      key, infrastructure and platform layers Healthy, one step per phase.
      [7.1, 7.2]
- [ ] 7. The site overlay, without any cloud resource: `components/site-dr`
      (storage behind the `iscsi` and `iscsi-retain` names, the Gateway on
      the host network, Syncthing on a hostPort, the NAS-bound components and
      alerts out, `volumeName` removed, CNPG `bootstrap.recovery` and new
      `serverName`s, the external-dns target as a value);
      `components/site-dr-drill` (the requirement 8 switches);
      `clusters/dr/`; the DR render; repo-policy over it; `task render:check`
      proving the home render unchanged. The CSI driver follows open
      question 1. [8.2, 8.3, 8.4, 10.4]
- [ ] 8. The DR module: `bootstrap/dr-cloud/` for the recovery provider
      (network, arm64 Talos nodes for the Full and DR shapes, addresses,
      firewall limited to `var.operator_cidr`, the CSI permission, the
      `dr-drill` label); `talos/dr/talconfig.yaml` with its own secrets and
      schematic, checked by `scripts/ci/talos-validate.sh`; `tofu fmt
      -check` and `tofu validate` in `ci`; the module kept out of the `tofu`
      workflow's plan and apply, and the daily leftover check;
      `docs/runbooks/site-lost.md` with the declaration rule, the restore
      order, the capacity fallbacks and the return home. Needs open
      questions 1 and 5 answered. [1.4, 1.5, 8.1, 10.1, 10.2, 10.3, 10.5, 10.6]
- [ ] 9. First DR drill (#723, part 2): `scripts/dr-rehearsal.sh` (preflight
      for requirement 8, a timestamp per step, `tofu destroy` on exit);
      every tier restored, the whole Immich library included; MTTR per tier
      and the drill's cost from the bill in `ci/dr-rehearsals.tsv`; the
      estimates in `docs/backups.md` and `docs/sre.md` replaced by the
      measured values; the cost estimate in `docs/decisions.md` priced again
      for the provider with its calculator. Closes #723. Monday to Friday,
      daytime. [2.4, 7.3, 7.4, 8.1]
- [ ] 10. First node-replacement rehearsal: `homelab-w-1` reflashed with
      [node-replacement.md](../../../docs/runbooks/node-replacement.md),
      timed to `Ready` and to every tier 1 probe green; the line recorded; the
      runbook's estimate replaced. Monday to Friday, daytime, with a
      maintenance silence. [2.4, 6.2]
