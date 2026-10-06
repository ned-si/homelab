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
- it is why the `seafile` namespace has PSA `warn: baseline` rather than
  `restricted`

If Syncthing covers the use case, removing the `seafile` Application removes
three workloads, a database, two secrets and this runbook. That is a data
decision: export the libraries first.

## MariaDB 10.11 → 12.3

`apps/seafile/mariadb.yaml` runs `mariadb:10.11`, which is past end of life. The
target is `12.3` (current LTS).

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

2. **Stop Seafile** so nothing writes mid-upgrade. `kubectl scale` does not
   stick: the `seafile` Application self-heals within seconds. Set
   `replicas: 0` on the `seafile` Deployment in `apps/seafile/deployment.yaml`,
   `task render`, and merge that pull request first.

3. **Step through the majors.** Edit the tag in `apps/seafile/mariadb.yaml`,
   `task render`, merge the pull request, and wait for the pod to be Ready and
   the log to show the upgrade completing before the next one:

   ```
   mariadb:11.4  →  wait  →  mariadb:11.8  →  wait  →  mariadb:12.3
   ```

   After each step:
   ```sh
   kubectl -n seafile logs deploy/mariadb | grep -i upgrade
   ```

4. **Bring Seafile back:** revert the `replicas: 0` change in a pull request.

If you would rather not step through three upgrades: restore the dump from step 1
into a fresh, empty 12.3 datadir instead. Point the Deployment at a new PVC on
StorageClass `iscsi-retain` (keep `mariadb-pvc` untouched as the rollback), let
the new pod initialise, then load the dump with `mariadb < seafile-mariadb-*.sql`.

### Rotating the root password

`MARIADB_ROOT_PASSWORD` only applies when initialising an **empty** datadir. On a
live database, changing `apps/secrets/seafile-db.sops.yaml` will make Seafile fail
to connect while MariaDB keeps the old password. Rotate in SQL first:

```sh
kubectl -n seafile exec deploy/mariadb -- \
  mariadb -uroot -p'<OLD>' -e "SET PASSWORD FOR 'root'@'%' = PASSWORD('<NEW>');"
```

then update the Secret with `task secrets:edit -- apps/secrets/seafile-db.sops.yaml`.
The same Secret is read by both the MariaDB and the Seafile Deployments, so
there is one value to change.

## Seafile beyond 11.0

The image is `seafileltd/seafile-mc:11.0-latest`, a floating tag bounded to
`11.0.x`: it cannot cross a minor or major version on its own, but a restart can
pull a new patch. Pinning it by digest is on the [roadmap](../roadmap.md).

**Going past 11.0 is not a tag change.** Seafile requires running its upgrade
scripts inside the container, in order, one minor at a time
(`/opt/seafile/seafile-server-*/upgrade/upgrade_11.0_12.0.sh` and similar), with
the service stopped. Consult upstream's manual upgrade documentation before
touching the major version, and take both a database dump and a `/shared`
snapshot first.

Given the "do you still want Seafile?" question above, a major upgrade is a good
moment to decide whether to migrate the data out to Syncthing instead.
