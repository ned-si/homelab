# Seafile and MariaDB upgrades

Two things here need care, and one prior question worth asking.

## First: do you still want Seafile?

Seafile overlaps almost entirely with Syncthing, which this cluster also runs. It
is also the most awkward workload here:

- it needs its own MariaDB **and** memcached, so three workloads for one service
- its real configuration (`seahub_settings.py`, `ccnet.conf`, `seafile.conf`)
  lives **inside the `/shared` volume**, not in git — so it is the one app in this
  cluster that is not actually declaratively configured
- upgrades require running Seafile's own scripts inside the container; a tag
  change is not sufficient
- it is the reason the `seafile` namespace runs at PSA `baseline` rather than
  `restricted`

If Syncthing covers the use case, deleting `clusters/homelab/apps/seafile.yaml`
removes three workloads, a database, two secrets and this runbook. That is a real
simplification, and it is the recommendation — but it is a data decision, so it
was not made on your behalf.

If you keep it, read on.

## MariaDB 10.11 → 12.3

The old manifest pinned `mariadb:10.11`, which is past end of life. This repo
moves to `12.3` (current LTS).

**MariaDB does not support skipping major versions on an existing datadir.** You
cannot go 10.11 → 12.3 in one step. The supported path is one major at a time:
10.11 → 11.4 → 11.8 → 12.3, running `mariadb-upgrade` between each.

`MARIADB_AUTO_UPGRADE=true` is set in the manifest, which runs `mariadb-upgrade`
automatically on start — but it will not save you from a skipped major.

### Doing it

1. **Back up first.** This is a logical dump, not a snapshot, because you are
   crossing major versions:

   ```sh
   kubectl -n seafile exec deploy/mariadb -- \
     sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases' \
     > seafile-mariadb-$(date +%F).sql
   ```

   Get it off the cluster.

2. **Stop Seafile** so nothing writes mid-upgrade:

   ```sh
   kubectl -n seafile scale deploy seafile --replicas=0
   ```

3. **Step through the majors.** Edit the tag in `apps/seafile/mariadb.yaml`, commit,
   let Argo sync, and wait for the pod to be Ready and the log to show the upgrade
   completing, before moving to the next:

   ```
   mariadb:11.4  →  wait  →  mariadb:11.8  →  wait  →  mariadb:12.3
   ```

   After each step:
   ```sh
   kubectl -n seafile logs deploy/mariadb | grep -i upgrade
   ```

4. **Bring Seafile back:**

   ```sh
   kubectl -n seafile scale deploy seafile --replicas=1
   ```

If you would rather not step through three upgrades: restore the dump from step 1
into a fresh empty 12.3 datadir instead. Delete the `seafile-mariadb` PVC, let the
new pod initialise, then `mariadb < seafile-mariadb-*.sql`.

### Rotating the root password

`MARIADB_ROOT_PASSWORD` only applies when initialising an **empty** datadir. On a
live database, changing `apps/secrets/seafile-db.sops.yaml` will make Seafile fail
to connect while MariaDB keeps the old password. Rotate in SQL first:

```sh
kubectl -n seafile exec deploy/mariadb -- \
  mariadb -uroot -p'<OLD>' -e "SET PASSWORD FOR 'root'@'%' = PASSWORD('<NEW>');"
```

then update the Secret. Note the same Secret is read by both the MariaDB
Deployment and the Seafile Deployment, so there is one value to change, not two —
unlike the old repo, where the same password was pasted into two files.

## Seafile beyond 11.0

The image is pinned to `seafileltd/seafile-mc:11.0-latest` — a floating **minor**
tag. That is a documented exception to this repo's pin-everything rule, explained
in `apps/seafile/deployment.yaml`: Seafile does not publish patch tags for the
community image in a form Renovate can order, so a full pin would rot into a
manual chore.

The tag is bounded to `11.0.x`, so unlike the old `:latest` usages it cannot
silently cross a major version.

**Going past 11.0 is not a tag change.** Seafile requires running its upgrade
scripts inside the container, in order, one minor at a time
(`/opt/seafile/seafile-server-*/upgrade/upgrade_11.0_12.0.sh` and similar), with
the service stopped. Consult upstream's manual upgrade documentation before
touching the major version, and take both a database dump and a `/shared`
snapshot first.

Given the "do you still want Seafile?" question above, a major upgrade is a good
moment to decide whether to migrate the data out to Syncthing instead.
