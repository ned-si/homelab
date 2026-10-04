# Staged Applications

Leaves that are written but not part of any layer yet, and not rendered by CI
either, because their content cannot pass the inert-by-default policy as it
stands:

- `backup-verify.yaml`: weekly restore tests of the restic and Postgres
  backups. Its two CronJobs need the `pending-guard` initContainer
  (ADR 0008) before they can be enabled, and they only make sense once off-site
  backups run.

To enable one: move it into `clusters/homelab/<layer>/`, list it in that
layer's `kustomization.yaml`, and make CI pass (`scripts/ci/repo-policy.sh`).
