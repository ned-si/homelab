# Immich: server and database upgrades

Immich runs v3.x on chart 0.13.x (`oci://ghcr.io/immich-app/immich-charts/immich`)
with `immich-db` on `cloudnative-vectorchord:16.15-1.1.1` (PostgreSQL 16.15,
VectorChord 1.1.1, pgvector 0.8.6).

| What | Who updates it | Where |
|---|---|---|
| Server and machine-learning image (one tag) | Renovate, automerged on green CI | `apps/immich/values.yaml` |
| Chart | Renovate, automerged on green CI | `clusters/homelab/apps/immich.yaml` |
| Database image | by hand, this runbook | `apps/immich/resources/database.yaml` |

The `immich` Application syncs automatically. Every sync starts with a PreSync
base backup of `immich-db` and ends with the PostSync smoke check
(`apps/immich/resources/kustomization.yaml`). The server runs its schema
migrations on start; Immich does not support downgrades, so a server update is
fixed forward.

Never touch the PVC `immich-data` (the library) in any of this. Only the database
and the images change.

## Updating the database image

Renovate never proposes it (`.github/renovate.json5`, "Never update the Immich
database image") and CI pins it (`scripts/ci/repo_policy.py`, rule
`immich-db-image`).

### VectorChord update, same PostgreSQL major

Preconditions: Immich's accepted range covers the new release
(`VECTORCHORD_VERSION_RANGE` in the server's `server/src/constants.ts`, today
`>=0.3 <2`; pgvector `>=0.7 <0.9`), and a base backup under 24 h exists
(`kubectl -n immich get backups.postgresql.cnpg.io`).

1. Silence the namespace:
   ```sh
   scripts/maintenance-silence.sh immich 2h "immich-db image <tag>"
   ```
   Expected: `silenced namespace=immich for 2h: <id>`.
2. One PR: the new tag and index digest in `apps/immich/resources/database.yaml`,
   `IMMICH_DB_IMAGE` in `scripts/ci/repo_policy.py` and its test in
   `tests/test_repo_policy.py`, then `scripts/render-deploy.sh`. Get the digest
   with `docker buildx imagetools inspect ghcr.io/tensorchord/cloudnative-vectorchord:<tag>`.
3. After the merge CNPG restarts the instance. Wait for it:
   ```sh
   kubectl -n immich get cluster immich-db -o jsonpath='{.status.phase}{"\n"}'
   ```
   Expected: `Cluster in healthy state`.
4. Update the extension and rebuild the indexes, as the superuser:
   ```sh
   kubectl -n immich exec -i immich-db-1 -c postgres -- psql -U postgres -d app <<'SQL'
   ALTER EXTENSION vchord UPDATE;
   REINDEX INDEX face_index;
   REINDEX INDEX clip_index;
   SQL
   ```
   Expected: `ALTER EXTENSION`, `REINDEX`, `REINDEX`.
5. Verify (next section), then expire the silence:
   `scripts/maintenance-silence.sh --expire <id>`.

### PostgreSQL major

Not done yet. CNPG 1.26+ upgrades a major in place when `imageName` moves to a
new major (offline `pg_upgrade`); the extensions must exist in the new image
(`cloudnative-vectorchord:<major>-<vchord>`). Take a fresh base backup and a
`pg_dump -Fc` first. Rollback is a restore of that backup on the old image.

## Verify

```sh
kubectl -n immich exec immich-db-1 -c postgres -- psql -U postgres -d app -c '\dx'
kubectl -n immich get cluster immich-db \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl -n immich exec deploy/immich-server -- immich-admin schema-check
```

Expected: `vchord` and `vector` listed (plus `cube`, `earthdistance`, `pg_trgm`,
`unaccent`, `uuid-ossp`); `Ready=True ContinuousArchiving=True`; `Migrations are
up to date` and `No schema drift detected`.

Then, with an admin API key (`x-api-key`):

- `GET /api/server/statistics`: photos and videos not below the last count;
- `POST /api/search/smart` with `{"query":"beach"}` returns items;
- `GET /api/assets/<id>/original` returns 200 for a few of the key owner's assets
  (another user's asset returns 400 by design);
- `GET /api/server/version` and `/api/server/features` answer (the phone app).

The asset counts in the database are the reference: `backup-verify-postgres`
checks them weekly (`docs/backups.md`).

## The pgvecto.rs to VectorChord migration (done 2026-10-16)

Immich 3.0 dropped pgvecto.rs. `immich-db` moved from
`cloudnative-pgvecto.rs:16.5-v0.3.0` to `cloudnative-vectorchord:16.15-1.1.1`
(#482), then Immich from v2.7.5 / chart 0.9.3 to v3.3.3 / chart 0.13.4 (#485).
The VectorChord image has no pgvecto.rs, so it followed the manual path of
Immich's [pre-existing Postgres guide](https://docs.immich.app/administration/postgres-standalone) ("Migrating from pgvecto.rs").
Repeat it only to bring a pre-2026-10-16 backup forward:

1. On the old image, with pgvecto.rs still loaded:
   ```sql
   DROP INDEX IF EXISTS clip_index;
   DROP INDEX IF EXISTS face_index;
   ALTER TABLE smart_search ALTER COLUMN embedding SET DATA TYPE real[];
   ALTER TABLE face_search ALTER COLUMN embedding SET DATA TYPE real[];
   DROP EXTENSION vectors;
   DROP SCHEMA IF EXISTS vectors;
   ```
2. Switch `imageName` and `shared_preload_libraries` (`vectors.so` to `vchord.so`).
3. On the new image (768 is the CLIP model's dimension,
   `ViT-B-16-SigLIP-i18n-256__webli`; check it with
   `SELECT atttypmod FROM pg_attribute WHERE attrelid='smart_search'::regclass AND attname='embedding'`
   before step 1):
   ```sql
   CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
   ALTER TABLE smart_search ALTER COLUMN embedding SET DATA TYPE vector(768);
   ALTER TABLE face_search ALTER COLUMN embedding SET DATA TYPE vector(512);
   ```
4. Restart the server. Expected in its log: `Reindexed face_index` and
   `Reindexed clip_index`.

Chart 0.10+ details kept in `apps/immich/values.yaml`: the library stays mounted
at `/usr/src/app/upload` with `IMMICH_MEDIA_LOCATION` set (every asset path in the
database starts with it; another location makes the server rewrite them all),
both Deployments use `Recreate` (ReadWriteOnce volumes), and the ML cache keeps
its PVC name through `forceRename`. Immich 3 replaced
`MACHINE_LEARNING_PRELOAD__CLIP` with `..._CLIP__TEXTUAL` and `..._CLIP__VISUAL`.

## Rollback

There is no in-place rollback: the server migrated its schema and Immich does not
downgrade. The fallback is the pre-migration backup, on the old image, with
Immich v2.7.5:

- CNPG base backup `immich-db-pre-v3-20261016t074150z` (serverName `immich-db-t1`,
  WAL up to 2026-10-16 08:26 UTC is pgvecto.rs);
- `pg_dump -Fc` in the restic repository `immich/library`, tag `immich-db-dump`.

1. Remove `automated:` from `clusters/homelab/apps/immich.yaml` (PR), so
   self-heal does not fight the restore, and scale `immich-server` to 0.
2. Revert #485 and #482 in one PR (chart 0.9.3, v2.7.5, the old image), without
   merging it yet.
3. Recover into a new Cluster on `cloudnative-pgvecto.rs:16.5-v0.3.0` with
   `shared_preload_libraries: ["vectors.so"]` and
   `recoveryTarget.targetTime` before 08:26 UTC on 2026-10-16
   ([backups.md](../backups.md), the `immich-db-restored` example), or
   `pg_restore` the dump into an empty cluster on that image.
4. Point `DB_URL` at it (or swap it in under the name `immich-db`), merge the
   revert, restore `automated:`, and check the counts.

Anything uploaded after the migration exists only as files in the library and
has to be re-imported.
