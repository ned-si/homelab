# Tasks: dashboard-database-engines

One PR per task, in order. PR bodies carry
`Spec: dashboard-database-engines#<n>`. Task 2 starts once
site-theme-language task 5 (the French dashboard, #1763) has merged: both
change the same template lines and the catalogue.

- [x] 1. Recording rules (**live**, not visible): the group
      `homelab.databases.engines` and the four restore rules of
      [design, Recording rules](design.md#recording-rules-task-1) in
      `platform/kube-prometheus-stack/routes/databases.yaml`, `task
      render`; the cases of acceptance criterion 1 in
      `tests/prometheus/databases_test.yaml`; `docs/backups.md`
      (Reading the results, What is not backed up). Branch
      `feat/database-engine-rules`. Check: acceptance criteria 1 and 2.
      [1.1-1.5] (#1773)
- [x] 2. Snapshot, collector and tiles (visible after task 3): snapshot
      version plus one with the nine keys of
      [design, The snapshot](design.md#the-snapshot-task-2), schema,
      `Validate` and fixtures; the collector queries and clamps;
      `engineTiles`, `sqliteBackupStatus`, the page's second paragraph
      and tiles, the changed PostgreSQL sentence; every string in both
      catalogues with the operator's French; goldens;
      `docs/homelab-dashboard.md` (Cards, Privacy rules, Status
      colours). Branch `feat/dashboard-database-engines`. Check:
      acceptance criteria 3-5. [2, 3, 4, 5] (#1792; French with #1763)
- [ ] 3. Deploy (**live** and visible): the digest of the image built
      from task 2's merge in both Deployments of
      `apps/homelab-dashboard/`, `task render`. Branch
      `chore/dashboard-engines-deploy`. Check: acceptance criterion 6.
      [2.1, 3.2]

The last task ticked sets `status: done`, `closed:`, moves the index row
to done and closes #1771.
