# Tasks: disaster-recovery-strategy

One PR per task, in order; each is safe on its own. Requirement numbers in
brackets. Each PR carries `Spec: disaster-recovery-strategy#<task>`.

## Open

- [ ] 1. Record the strategy: the `docs/decisions.md` entry "Disaster
      recovery: a cold site, rebuilt on rented nodes" (decision, reasons,
      warm and hot rejected, review conditions); the "Disaster scenarios"
      table in `docs/sre.md` with RPO and RTO per tier and an MTTR column
      reading "not measured"; the "Off-site inventory" and the "Rehearsal
      calendar" in `docs/backups.md`; the roadmap theme pointed at this spec.
      Waits for the operator's answers to open questions 1, 2 and 8.
      [1.1, 1.2, 2.1, 3.1, 3.2, 3.3, 4.1, 4.2, 6.1]
- [ ] 2. The rehearsal record: `ci/dr-scenarios.tsv`, `ci/dr-rehearsals.tsv`,
      `scripts/dr-mttr.sh` with its bash test; repo-policy rules
      `dr-rehearsals`, `dr-runbooks` and `dr-mttr-source` with their tests;
      `docs/runbooks/dr-rehearsal.md` (how to run, time and record a
      rehearsal; the pull request template, which names a missed RTO and opens
      its issue). [1.3, 2.2, 2.3, 6.2]
- [ ] 3. Results on the dashboard: CronJob `dr-rehearsal-report` in
      `backup-verify` (ConfigMap from the two files, the `dr-rebuild` runs from
      the public GitHub API, an egress rule to `api.github.com`); the
      "Disaster recovery" row on Homelab / Data protection;
      `DRRehearsalOverdue` with its promtool test, route test, runbook and the
      PAGE table in `docs/sre.md`. [6.3, 6.4, 7.2]
- [ ] 4. Break-glass check: `scripts/dr-offsite-check.sh` (the age key
      matches `.sops.yaml` and decrypts a sealed file, `talosconfig` reaches a
      node, `RESTIC_PASSWORD` opens `immich/library` with the verifier key,
      the state passphrase decrypts a state file; prompts for the AWS root
      sign-in and the emergency access); `docs/runbooks/operator-unavailable.md`;
      the first run recorded. Needs open questions 6 and 7 answered.
      [4.3, 4.4, 9.1, 9.2]
- [ ] 5. AWS account lost: `docs/runbooks/aws-account-lost.md` (new
      account, `bootstrap/tofu-state`, `bootstrap/aws-backup`,
      `bootstrap/github-oidc`, re-sealed keys, new `serverName`s, the Immich
      re-seed, the 24 h target). If open question 4 says build it now, the
      second copy of the Immich library and of a dump of every database at
      another provider, verified weekly by `backup-verify`; otherwise a
      `deferred` issue. [5.1, 5.2, 5.3]
- [ ] 6. Monthly rebuild from git in CI (#723, part 1):
      `.github/workflows/dr-rebuild.yaml` on the Talos QEMU harness of
      `scripts/ci/talos-upgrade-rehearsal.sh`, test secrets sealed to a CI
      key, infrastructure and platform layers Healthy, one step per phase.
      [7.1, 7.2]
- [ ] 7. The DR site: Talos config for rented arm64 nodes with its own
      cluster secrets, the DR tree (site-specific values, local storage,
      without the home-only parts), the rehearsal switches and the real-loss
      settings, repo-policy over its render; `docs/runbooks/site-lost.md`
      with the declaration rule and the return home. Needs open questions 3,
      5 and 10 answered. [1.4, 1.5, 8.1, 8.2, 8.3, 8.4]
- [ ] 8. First full rehearsal on the DR site (#723, part 2):
      `scripts/dr-rehearsal.sh` (preflight for requirement 8, a timer per
      tier, the nodes deleted on exit); every tier restored, the whole Immich
      library included; the line in `ci/dr-rehearsals.tsv`; the estimates in
      `docs/backups.md` and `docs/sre.md` replaced by the measured values.
      Closes #723. Monday to Friday, daytime. [2.4, 7.3, 8.1]
- [ ] 9. First node-replacement rehearsal: `homelab-w-1` reflashed with
      [node-replacement.md](../../../docs/runbooks/node-replacement.md),
      timed to `Ready` and to every tier 1 probe green; the line recorded; the
      runbook's estimate replaced. Monday to Friday, daytime, with a
      maintenance silence. [2.4, 6.2]
