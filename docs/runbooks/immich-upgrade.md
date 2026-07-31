# Immich: migrating from pgvecto.rs to VectorChord

**This is the one irreversible change in the restructure. Do not let Argo sync it
unattended.** The `immich` Application is deliberately configured with
`prune: false` and `selfHeal: false` for exactly this reason.

## What changed and why it is forced

Immich 3.0 **removed support for pgvecto.rs**. It now requires
[VectorChord](https://github.com/tensorchord/VectorChord) (`vchord`) and validates
the extension at startup, refusing to boot outside `vchord >= 0.3, < 2.0`.

| | Before | After |
|---|---|---|
| Immich | v2.3.1 | v3.1.0 |
| Chart | 0.10.3 | 0.13.1 |
| DB image | `cloudnative-pgvecto.rs:16.5-v0.3.0` | `cloudnative-vectorchord:17-1.1.0` |
| `shared_preload_libraries` | `vectors.so` | `vchord.so` |
| Extension | `vectors` | `vchord` (+ `vector` via CASCADE) |
| Postgres major | 16 | 17 |

So this is not a version bump. It is **an extension migration and a Postgres major
upgrade at the same time**, and it cannot be rolled back once Immich 3.x has
migrated its schema.

There is also a chart-layout change: immich-charts 0.13.x moved to the bjw-s
common library, so every values key is at a new path. The old values file would
have silently applied almost nothing.

## Before you start

- [ ] The cluster is reachable and healthy.
- [ ] You are not in a hurry. Reindexing a large library takes hours.
- [ ] You have somewhere to put a database dump that is **not** the cluster.

## 1. Back up, properly

A CloudNativePG PVC snapshot is not enough on its own, because you are changing
the Postgres major version — a restored PG16 volume will not start under a PG17
image. Take a logical dump:

```sh
kubectl -n immich exec immich-db-1 -- \
  pg_dump -U app -Fc app > immich-$(date +%F).dump

# Get it off the cluster.
ls -lh immich-*.dump
```

Also snapshot the library volume. It holds the actual photos and is the only
truly irreplaceable thing here:

```sh
kubectl -n immich get pvc immich-data
```

Take the snapshot on TrueNAS, or via a `VolumeSnapshot` (the `iscsi`
VolumeSnapshotClass is defined in `infrastructure/democratic-csi/values-iscsi.yaml`).

## 2. Decide: migrate in place, or rebuild

Because the Postgres major version changes as well, **rebuilding the database is
usually less painful than migrating it**, and Immich can regenerate everything
that matters.

What is actually stored in Postgres: albums, shared links, users, face/person
names, and the vector indexes. What is stored on disk: the photos and videos
themselves. A rebuild loses the former and keeps the latter, and Immich will
re-derive thumbnails, faces and embeddings from the files.

### Option A — rebuild (simpler, loses albums and person names)

```sh
# Scale Immich down so nothing writes during the swap.
kubectl -n immich scale deploy immich-server --replicas=0

# Delete the old cluster. THE PVC GOES WITH IT.
kubectl -n immich delete cluster immich-db

# Let Argo create the new VectorChord-based cluster.
argocd app sync immich
```

The new cluster's `postInitApplicationSQL` (see
`apps/immich/resources/database.yaml`) creates `vchord`, `cube` and
`earthdistance` on an empty database, which is the case this path is written for.

Then bring Immich up, log in, and run **Administration → Jobs → Smart Search →
"All"** plus **Face Detection → "All"** to rebuild the embeddings.

### Option B — migrate in place (keeps everything, more steps)

Only worth it if you have curated a lot of albums and named a lot of faces.

1. Stand up the new VectorChord cluster under a **different name**
   (`immich-db-v2`) so the old one stays intact.
2. Restore the logical dump into it:
   ```sh
   kubectl -n immich exec -i immich-db-v2-1 -- \
     pg_restore -U app -d app --no-owner < immich-$(date +%F).dump
   ```
   Expect errors on the `vectors` extension objects. They are expected — those
   are the pgvecto.rs types that no longer exist.
3. Install the new extension and drop the old one:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
   DROP EXTENSION IF EXISTS vectors CASCADE;
   DROP SCHEMA IF EXISTS vectors CASCADE;
   ```
   `CASCADE` on the drop removes the old embedding columns. That is intended —
   Immich rebuilds them.
4. Point `DB_HOSTNAME` in `apps/immich/values.yaml` at `immich-db-v2-rw`, commit,
   sync.
5. Let Immich run its migrations, then re-run Smart Search and Face Detection.
6. Once verified, delete `immich-db` and rename if you care about tidiness.

## 3. Verify

```sh
# Extension present and the right version?
kubectl -n immich exec immich-db-1 -- \
  psql -U app -d app -c "SELECT extname, extversion FROM pg_extension;"

# Immich booted? It refuses to start on a wrong extension version, so a
# running, ready pod is itself a meaningful signal.
kubectl -n immich get pods
kubectl -n immich logs deploy/immich-server | tail -30
```

Then in the UI: search for something by text (exercises CLIP + vchord), and open
the map view (exercises `earthdistance`).

## 4. Re-enable automation

Once you are satisfied, you may set `selfHeal: true` back on the `immich`
Application in `clusters/homelab/apps/immich.yaml`. Leave `prune: false` — the
library PVC is not something you want pruned by accident.

Renovate is configured to hold Immich majors behind
`dependencyDashboardApproval`, so this situation will not recur silently.

## If it goes wrong

The photos are on the library PVC and are untouched by any of the above. Worst
case, you rebuild the database from empty (Option A) and let Immich rescan. That
is slow but not lossy for the files themselves — which is why step 1 insists on
snapshotting the library volume separately from the database.
