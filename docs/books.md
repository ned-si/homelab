# Books

Namespace `books`, manifests in `apps/books/`, Argo CD Application `books`.
Acquisition (LazyLibrarian) runs in `theater`, see [Acquisition](#acquisition).

| App | URL | Purpose |
|---|---|---|
| Audiobookshelf | https://audiobooks.lilalala.com | Audiobooks and podcasts; Android and iOS apps |
| Calibre-Web Automated | https://ebooks.lilalala.com | The ebook library: read in the browser, OPDS, Kobo and KOReader sync |

## Storage

The library is on the TrueNAS share `192.168.1.228:/mnt/homelab/k8s/nfs`,
next to `media/` and `torrents/`, as an inline NFS volume in each Deployment
(like the theater apps). Pods mount subdirectories of `books/`:

| Directory | Used by |
|---|---|
| `books/audiobooks` | Audiobookshelf library "Audiobooks" (`/audiobooks`) |
| `books/podcasts` | Audiobookshelf library "Podcasts" (`/podcasts`) |
| `books/ebooks` | The Calibre library of Calibre-Web Automated (`/calibre-library`, `metadata.db` included) |
| `books/ingest` | Calibre-Web Automated drop folder (`/cwa-book-ingest`): files put here are imported into the library, then deleted |

Every directory belongs to uid 1000, gid 0, like `media/`. The NAS squashes
root, so create a missing one as uid 1000, for example from the Sonarr pod,
which mounts the share at `/data`:

```sh
kubectl -n theater exec deploy/sonarr -- su -s /bin/sh hotio -c 'mkdir -p /data/books/<dir>'
```

App state is on iSCSI: PVC `audiobookshelf-config` holds `config/` (SQLite
database) and `metadata/` (covers, cache, the app's own backups);
`calibre-web-config` holds Calibre-Web's `app.db` (users, settings, shelves)
and `processed_books/` (the originals of converted books).

Calibre-Web Automated runs with `NETWORK_SHARE_MODE=true`: the library's
SQLite database is on NFS, so WAL mode is off and the ingest folder is polled.

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

Calibre-Web Automated: Keycloak client `calibre-web` (confidential, redirect
URI `https://ebooks.lilalala.com/login/generic/authorized`). Its OAuth settings
are also in its database: Admin, Edit Basic Configuration, Feature
Configuration, Login type "Use OAuth", provider "Generic", metadata URL
`https://auth.lilalala.com/realms/homelab/.well-known/openid-configuration`,
client ID `calibre-web`, client secret from Keycloak, scopes
`openid profile email`. The local `admin` account stays as the break-glass
login; its password is in the operator's password manager. A new image
starts with `admin` / `admin123`: change it before anything else.

## Acquisition

LazyLibrarian (`apps/theater/lazylibrarian.yaml`, namespace `theater`) at
https://theater.lilalala.com/arr/lazylibrarian. Readarr is retired upstream,
so it is the book counterpart of Sonarr and Radarr. It sits in `theater`
with qBittorrent and mounts the share root, like the *arr apps.

| Kind | qBittorrent category | Finished files go to |
|---|---|---|
| Ebooks | `ebooks` | `books/ingest`, imported by Calibre-Web Automated |
| Audiobooks | `audiobooks` | `books/audiobooks`, the Audiobookshelf library |

An init container writes the paths, the qBittorrent connection, the login and
the API key into `config.ini` on every start, from the ConfigMap
`lazylibrarian-config` and the Secret `lazylibrarian`
(`apps/secrets/lazylibrarian.sops.yaml`). The rest (wanted authors, metadata
sources) is set in the UI.

Indexers come from Prowlarr's application `LazyLibrarian`, which syncs only
indexers tagged `books`. Only public indexers carry that tag
([theater.md](theater.md#indexers)). Check:

```sh
scripts/check-indexers.sh
```

Login: Keycloak through the theater SSO proxy ([theater.md](theater.md#login)),
then LazyLibrarian's own form login `admin` (it has no OIDC); the password is
in the operator's password manager and is the break-glass login. Its config is backed up nightly by
`theater-config-backup-lazylibrarian` (05:30) to `theater/configs`.

## Backups

CronJob `books-config-backup-audiobookshelf` (05:10) copies
`audiobookshelf-config` to the restic repository `books/configs`, without
`metadata/cache` and `metadata/logs`; `books-configs-prune` keeps it to the
retention in [backups.md](backups.md). The live SQLite file may be torn in
that copy. Restore from `metadata/backups/*.audiobookshelf`, the consistent
nightly backup the app writes itself (Settings, Backups, Restore).

CronJob `books-config-backup-calibre-web` (05:20) backs up the ebook library
(`books/ebooks`, tag `calibre-library`) and `calibre-web-config` (tag
`calibre-web`) to the same repository. `metadata.db` and `app.db` are live
SQLite files and may be torn in a copy; the book files are not. A torn
`metadata.db` is rebuilt from the book folders (Calibre, Library
maintenance, Restore database).

The audiobook and podcast files are not backed up, like the media library.

## Why it is like this

- One `books` namespace for the book apps: they share the library and its
  NFS volume. The alternative, adding them to `theater`, would mix two
  unrelated stacks in one Application.
- The NFS volume mounts the share root and pods narrow it with `subPath`,
  because the export is known to work at that path (the theater apps use it).
  Inline rather than a PV: the `infrastructure/nfs-storage/` layer is not
  deployed yet, and the theater apps are inline too.
