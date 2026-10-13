# Staged Applications

Leaves that are written but not part of any layer yet, and not rendered by CI
either, because their content cannot pass the inert-by-default policy as it
stands:

- `backup-verify.yaml`: weekly restore tests of the restic and Postgres
  backups. Its two CronJobs need the `pending-guard` initContainer
  ([Backup CronJobs run only once reviewed](../../../docs/backups.md#why-it-is-like-this))
  before they can be enabled. Both halves can test today's backups: restic for
  files, the Barman Cloud plugin for the seven Postgres clusters
  ([docs/backups.md](../../../docs/backups.md#verification)). Enabling it also
  means removing the patch in `platform/secrets/kustomization.yaml` that drops
  its `s3-backup` Secret.

To enable one: move it into `clusters/homelab/<layer>/`, list it in that
layer's `kustomization.yaml`, and make CI pass (`scripts/ci/repo-policy.sh`).
