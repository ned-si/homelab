# Books

Namespace `books`, manifests in `apps/books/`, Argo CD Application `books`.

| App | URL | Purpose |
|---|---|---|
| Audiobookshelf | https://audiobooks.lilalala.com | Audiobooks and podcasts; Android and iOS apps |

## Storage

The library is on the TrueNAS share `192.168.1.228:/mnt/homelab/k8s/nfs`,
next to `media/` and `torrents/`, as an inline NFS volume in each Deployment
(like the theater apps). Pods mount subdirectories of `books/`:

| Directory | Used by |
|---|---|
| `books/audiobooks` | Audiobookshelf library "Audiobooks" (`/audiobooks`) |
| `books/podcasts` | Audiobookshelf library "Podcasts" (`/podcasts`) |

Every directory belongs to uid 1000, gid 0, like `media/`. The NAS squashes
root, so create a missing one as uid 1000, for example from the Sonarr pod,
which mounts the share at `/data`:

```sh
kubectl -n theater exec deploy/sonarr -- su -s /bin/sh hotio -c 'mkdir -p /data/books/<dir>'
```

App state is on iSCSI: PVC `audiobookshelf-config` holds `config/` (SQLite
database) and `metadata/` (covers, cache, the app's own backups).

## Login

Keycloak client `audiobookshelf` (realm `homelab`, confidential), redirect URIs
in `platform/keycloak/realm/clients.conf`. Audiobookshelf keeps its OIDC
settings in its database, so they are set once in Settings, Authentication:

- Issuer URL `https://auth.lilalala.com/realms/homelab`, then Auto-populate.
- Client ID `audiobookshelf`; client secret from Keycloak (Clients,
  audiobookshelf, Credentials).
- Allowed mobile redirect URIs: `audiobookshelf://oauth`.
- Auto register on. New users get the `user` role; give library access in
  Settings, Users.

The local `root` account stays as the break-glass login. Its password is in
the operator's password manager.

Mobile apps: server address `https://audiobooks.lilalala.com`, then "Login
with OpenID".

## Backups

CronJob `books-config-backup-audiobookshelf` (05:10) copies
`audiobookshelf-config` to the restic repository `books/configs`, without
`metadata/cache` and `metadata/logs`; `books-configs-prune` keeps it to the
retention in [backups.md](backups.md). The live SQLite file may be torn in
that copy. Restore from `metadata/backups/*.audiobookshelf`, the consistent
nightly backup the app writes itself (Settings, Backups, Restore).

The audiobook and podcast files are not backed up, like the media library.

## Why it is like this

- One `books` namespace for the book apps: they share the library and its
  NFS volume. The alternative, adding them to `theater`, would mix two
  unrelated stacks in one Application.
- The NFS volume mounts the share root and pods narrow it with `subPath`,
  because the export is known to work at that path (the theater apps use it).
  Inline rather than a PV: the `infrastructure/nfs-storage/` layer is not
  deployed yet, and the theater apps are inline too.
