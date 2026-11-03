# Tasks: disaster-recovery-strategy

One PR per task, in order; each is safe on its own. Requirement numbers in
brackets. Each PR carries `Spec: disaster-recovery-strategy#<task>`. The
PR of the last task to merge sets the spec `done` and closes #918; the
`backups-dr` area spec update is in task 9.

## Open

- [ ] 1. Record the strategy: the `docs/decisions.md` entry "Disaster
      recovery: a cold site in the cloud, built on demand" (the decision;
      the monthly cost of cold, warm and hot at AWS, with Google Cloud and
      Hetzner for comparison, against the value of what is hosted and the
      RPO and RTO per tier; warm and hot rejected; AWS as the one recovery
      provider; the accepted risk that losing the AWS account with the
      house loses the backups, and its mitigation; the review
      conditions); the "Disaster scenarios" table in `docs/sre.md` with
      RPO and RTO per tier and an MTTR column reading "not measured"; the
      "Off-site inventory" and the "Rehearsal calendar" in
      `docs/backups.md`; the roadmap theme pointed at this spec. [1.1, 1.2, 2.1, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 5.4, 6.1]
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
      sign-in with the second MFA device, the AWS payment method's expiry,
      each item of the `homelab break-glass` folder and the emergency
      access; `tofu plan` on `bootstrap/dr-cloud/` from the
      password-manager copies once task 8 has merged);
      `docs/runbooks/operator-unavailable.md`; the operator's one-time
      set-up listed in the pull request (the folder, the second AWS root
      MFA device, the root mailbox's recovery codes, the Cloudflare
      token-creator token, the envelope with the two-step login recovery
      code, emergency access with a 2-day wait); the first run recorded.
      [4.3, 4.4, 5.3, 9.1, 9.2, 10.7]
- [ ] 5. AWS account lost or locked out: `docs/runbooks/aws-account-lost.md`
      (lockout first: lost MFA device, lost root password through the
      mailbox, suspended for billing; a closed account reopened within the
      90-day post-closure period; then the rebuild in a new account:
      `bootstrap/tofu-state`, `bootstrap/aws-backup`,
      `bootstrap/github-oidc`, re-sealed keys, new `serverName`s, the Immich
      re-seed, the 24 h target; a house lost at the same time waits for
      access, with the accepted-risk note). No second copy outside AWS.
      [5.1, 5.2, 5.3]
- [ ] 6. Monthly rebuild from git in CI (#723, part 1):
      `.github/workflows/dr-rebuild.yaml` on the Talos QEMU harness of
      `scripts/ci/talos-upgrade-rehearsal.sh`, test secrets sealed to a CI
      key, infrastructure and platform layers Healthy, one step per phase.
      [7.1, 7.2]
- [ ] 7. The site overlay, without any cloud resource: `components/site-dr`
      (storage behind the `iscsi` and `iscsi-retain` names with volume
      expansion, backed by the `aws-ebs-csi-driver` chart: gp3, encrypted,
      `WaitForFirstConsumer`, the home mount options,
      `controller.region: eu-central-1` and
      `controller.extraVolumeTags: {dr-site: homelab-dr, dr-mode: site}`);
      the metadata fence (two `CiliumClusterwideNetworkPolicy` objects,
      `egressDeny` to `169.254.169.254/32` for every pod but the EBS CSI
      driver's, `enableDefaultDeny` off); `immich-data` at 500Gi;
      `infrastructure/cilium/values-dr.yaml` with the Gateway on the host
      network of the labelled Gateway node only
      (`gatewayAPI.hostNetwork.nodes.matchLabels`) and
      `envoy.securityContext.capabilities.keepCapNetBindService: true` for
      80 and 443; Syncthing on a hostPort with the `syncthing-dr`
      PolicyException; the NAS-bound components out, with
      `HomelabNASUnreachable` and `HomelabNASDown` patched out of
      `homelab-outage` (`routes/outage-alerts.yaml`) and `homelab-nas`
      (`routes/nas-alerts.yaml`) whole; theater,
      SigNoz with Vector, `lan-inventory`, the Home Assistant stack and
      `backup-verify`'s Postgres restore out, with the rules
      `homelab-signoz` (`routes/signoz-trial.yaml`),
      `routes/lan-alerts.yaml` and the `SLOTargetProbeAbsent` rules of
      `cinema` and `theater`; the `internal-tcp`, `dns-router` and
      `public-https-gated` Probes out and the `cinema`, `home` and
      `signoz` targets of `public-https`; `ci/dr-active-cronjobs.txt` and
      `components/site-dr/backup-slo-targets.yaml` with its 7 backup
      CronJobs in place of the home targets; `volumeName` removed; the ebook library claim; CNPG
      `bootstrap.recovery` and new `serverName`s; the external-dns target
      as a value); `components/site-dr-drill` (the requirement 8 switches:
      the network-policy exception for OIDC to the Gateway node, no
      tailnet, no notifications, cert-manager without external-dns, its
      issuer reading the Secret `cloudflare-drill-token` that the drill
      script creates; `dr-mode: drill` on the CSI volume tags; the drill copies of the Secrets sealed to the real
      and rehearsal keys, with no Cloudflare token among them); a
      `.sops.yaml` rule for those copies; `clusters/dr/`; the DR render;
      repo-policy over it (the switches, the rehearsal-key recipients, no
      Cloudflare token in the drill component, the `dr-mode` value per
      render, both fence objects, none of the left-out rules, no Probe
      target in `192.168.1.0/24`, `cronjob-active` and `backup-slo-targets`
      with `ci/dr-active-cronjobs.txt`, the claims against the 28
      attachments of `m7g.2xlarge` minus the interface, the root volume and
      a margin of 3); `task render:check` proving the home render
      unchanged. No CoreDNS change: drill name resolution is task 9's Talos
      patch. [8.2, 8.3, 8.4, 8.7, 8.8, 8.9, 10.4, 10.9, 10.10]
- [ ] 8. The DR module: `bootstrap/dr-cloud/` for AWS `eu-central-1` (the
      state workspaces `drill` and `site`, any other refused by a
      `lifecycle.precondition` on `terraform_data.workspace_guard`, the
      drill switches derived from the name; every name from `local.prefix`
      (`homelab-dr-<workspace>`) or `name_prefix`, with repo-policy
      `dr-cloud-names`; VPC, public subnet and internet
      gateway; `m7g` nodes for the Full and DR shapes from Sidero Labs'
      Talos arm64 AMI, IMDSv2 with hop limit 2; the NLB
      `homelab-dr-<workspace>` with one Elastic IP and listeners on 80, 443
      and 22000 to the Gateway node; security groups: 50000 and 6443 from
      `var.operator_cidr` and no rule when it is empty (`site` only), the
      Gateway ports at the NLB from `var.operator_cidr` in `drill`; the
      instance profile with `AmazonEBSCSIDriverPolicy`; `default_tags`
      `dr-site=homelab-dr` and `dr-mode=<workspace>`;
      `backend_override.tf.example`); `scripts/dr-sweep.sh` and its bash
      test (`--check` lists with `dr-mode` and age; `--delete` removes only
      detached EBS volumes tagged `dr-mode=drill`, leaves `site`, untagged
      and attached ones, and fails on a `dr-mode=drill` instance, load
      balancer or Elastic IP left; `--delete --return-home` removes every
      detached DR or CSI-tagged volume and refuses unless
      `ci/dr-site-lost.txt` is on `origin/main` and the `site` state is
      empty); `talos/dr/talconfig.yaml`
      with its own secrets and schematic, the Gateway node label, no static
      hosts, checked by `scripts/ci/talos-validate.sh`; `tofu fmt -check`
      and `tofu validate` in `ci`; the module kept out of the `tofu`
      workflow's plan and apply; the daily leftover check in the `tofu`
      schedule with `ci/dr-site-lost.txt` as the real-loss switch and its
      four failure cases (the last: a `dr-mode` other than `drill` or
      `site`), its test and repo-policy `dr-site-lost`, and the
      read permissions it needs on the plan role in `bootstrap/github-oidc`;
      `docs/runbooks/site-lost.md` with the declaration rule and the file,
      the apply command with `TF_WORKSPACE=site` and the source of each
      input on a fresh machine, the restore order with the upgrade to the
      DR schematic and step 8's re-apply with `operator_cidr` empty once
      the tailnet is up, the capacity fallbacks, the move to the Full
      shape for a loss longer than two weeks, and the return home
      (`tofu destroy` in `site`, `dr-sweep.sh --delete --return-home`,
      then the pull request removing the file); a `tofu plan` in `default`
      shown failing; a one-hour smoke run of the DR shape in `drill` and
      `site` side by side (apply both, nodes `Ready`, NLB targets healthy,
      destroy both, sweep; about $0.90) that seeds the `dr-site` tag key, then the key activated as a
      cost allocation tag in the operator's one-time set-up. Monday to
      Friday, daytime. [1.4, 1.5, 7.4, 8.1, 8.8, 10.1, 10.2, 10.3, 10.5,
      10.6, 10.7, 10.8]
- [ ] 9. First DR drill (#723, part 2): `scripts/dr-rehearsal.sh` (preflight
      for requirement 8, the rehearsal key only; writes
      `talos/dr/drill/static-hosts.yaml`, one `StaticHostConfig` with the
      Gateway node's private address and every HTTPRoute host name of the
      DR render, applied with `--config-patch`, and checks from a pod that
      `auth.lilalala.com` resolves to it before Argo CD; the DR probes with
      `curl --resolve` against the DR Gateway; a timestamp per step; the
      per-drill Cloudflare token created with the nodes' addresses and a
      12 h expiry, written to the Secret `cloudflare-drill-token`; at step
      4, a pod in `default` fails to reach `169.254.169.254` while the EBS
      CSI controller is Running; on exit, the token deleted, `tofu destroy`
      in the `drill` workspace and `scripts/dr-sweep.sh --delete`; every
      `tofu` call with `TF_WORKSPACE=drill`; a bash test, run with
      `TF_WORKSPACE=site` exported and a stub `tofu`, that every call, the
      trap's included, gets `drill`);
      every tier restored, the whole Immich library included; MTTR per tier
      and the drill's cost from the bill in `ci/dr-rehearsals.tsv`; the
      estimates in `docs/backups.md` and `docs/sre.md` replaced by the
      measured values; the cost estimate in `docs/decisions.md` priced again
      in the AWS Pricing Calculator and checked against the drill's bill;
      the `backups-dr` area spec updated (scenarios,
      the off-site inventory, the calendar, the DR site). Closes #723.
      Monday to Friday, daytime.
      [2.4, 7.3, 7.4, 8.1, 8.5, 8.6, 8.8, 8.9, 10.8, 10.9]
- [ ] 10. First node-replacement rehearsal: `homelab-w-1` reflashed with
      [node-replacement.md](../../../docs/runbooks/node-replacement.md),
      timed to `Ready` and to every tier 1 probe green; the line recorded; the
      runbook's estimate replaced. Monday to Friday, daytime, with a
      maintenance silence. [2.4, 6.2]
