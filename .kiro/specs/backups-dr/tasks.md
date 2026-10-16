# Tasks: backups-dr

Requirement numbers in brackets. New work in this area adds a task here first.

## Done

- [x] 1. Point the restic backups at the S3 bucket, seal the credentials. [1.1] (#98)
- [x] 2. Staggered nightly schedule. [1.1] (#107)
- [x] 3. Document coverage, RPO/RTO and the tested restore; cold-start
      runbook. (#117, #108)
- [x] 4. Back up the database before every app sync. [3.1, 3.3] (#197, #201)
- [x] 5. CNPG IAM user scoped to `cnpg/`; the Barman Cloud plugin. [2.1] (#250, #255)
- [x] 6. WAL archiving and daily base backups for every CNPG cluster. [2.1]
      (#266, #269, #270, #271)
- [x] 7. PreSync base backups for `immich-db` and `keycloak-db`. [3.2] (#272)
- [x] 8. Alerts on CNPG backup and WAL archiving. [2.2] (#275)
- [x] 9. Hold CNPG Postgres majors until `serverName` follows. [2.3] (#277)
- [x] 10. Restore every CNPG cluster from the object store; document the CNPG
      backups. [4.1] (#284, #294)
- [x] 11. PreSync hooks follow the 24 h freshness rule. [3.1, 3.2] (#326)
- [x] 12. Scheduled restore tests deployed, with their fixes. [4.1-4.3]
      (#444, #447, #451, #432)
- [x] 13. Homelab / Data protection dashboard. [4.1] (#448)
- [x] 14. Bucket policy that makes versions immutable; CI roles may HeadBucket.
      [5.1] (#466, #462)
- [x] 15. Test the bucket version lock weekly and in CI. [5.2] (#481)
- [x] 16. Back up `grafana.db` nightly and verify it. [1.1] (#477)

## Open

Wave 3 adds a backup-freshness SLO: `.kiro/specs/wave3-*`.

- [ ] 17. Remove or replace the failing L2ARC device `nvd0` on the NAS pool.
- [ ] 18. Apply the pending TrueNAS update (the off-site backup now exists).
- [ ] 19. Restrict the NFS export `/mnt/homelab/k8s/nfs` to the node addresses
      ([runbook](../../../docs/runbooks/nfs-hardening.md)).
- [ ] 20. NAS NVMe cache: read the ARC hit rate and sync-write latency first;
      a single drive is L2ARC only (never a special vdev), SLOG only with
      power-loss protection.
- [ ] 21. DR rehearsal from zero: rebuild the cluster from git and restore
      the data from S3 end to end, timed against the RTO table in
      [sre.md](../../../docs/sre.md#rto-per-tier). The CI part is
      [gitops-delivery](../gitops-delivery/tasks.md) task 20.
