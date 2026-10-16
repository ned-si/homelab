# Tasks: Immich 3 migration

Each task is one PR or one recorded check. Requirement numbers in brackets.

- [x] 1. Read Immich's release notes (2.7.5 → latest 3.x) and the VectorChord migration docs;
      answer the design's open questions in this file. [2, 3]
- [x] 2. Record the baseline counts (images, videos, people, albums). [1.1, 1.2]
- [x] 3. Take a CNPG base backup and a `pg_dump`; check the dump lists cleanly. [2.1]
- [x] 4. Silence namespace `immich` with `scripts/maintenance-silence.sh`. [5.1]
- [x] 5. PR: switch `immich-db` to the VectorChord image (digest-pinned), update
      `shared_preload_libraries`, the repo-policy rule and the Renovate rule. Check CNPG Ready,
      extensions, archiving. [3.4, 4.2, 4.3] (#482; manual SQL before and after the restart)
- [x] 6. PR (only if required): Immich to the latest 2.x. Watch the server migrations. [3]
      (not required: 2.7.5 is the last 2.x; it rebuilt the vchordrq indexes)
- [x] 7. PR: Immich to the latest 3.x (server, ML, chart values). Watch the migrations. [3]
      (#485: v3.3.3, chart 0.13.4 OCI; 33 migrations, schema-check clean)
- [x] 8. Verify counts, 20 originals, search, phone API, thumbnails, Argo and the smoke
      hook. [1, 3]
- [x] 9. PR: remove the Renovate cap below 3. Expire the silence. [4.1, 5.1] (#488)
- [x] 10. PR: update `docs/runbooks/immich-upgrade.md` and `docs/migration-plan.md`. [5.2]
      (#488; `docs/migration-plan.md` does not exist, the runbook covers it)

Rollback path (only if task 8 fails for more than 30 min): restore the database from task 3
on the old image, Immich back to 2.7.5, verify counts, keep the cap. [2.2, 2.3]
