# Theater (media stack)

Namespace `theater`: Plex and Jellyfin serve the library; Sonarr (series),
Radarr (movies) and Lidarr (music) pick releases; Prowlarr manages indexers;
qBittorrent downloads; Bazarr fetches subtitles. Manifests are in
`apps/theater/`.

## Login

The admin UIs are on https://theater.lilalala.com behind a Keycloak login:

| Path | App |
|---|---|
| `/arr/sonarr`, `/arr/radarr`, `/arr/lidarr`, `/arr/prowlarr` | the *arr apps |
| `/arr/bazarr` | Bazarr |
| `/arr/lazylibrarian` | LazyLibrarian |
| `/arr/qbittorrent/` | qBittorrent WebUI (trailing slash required) |

One oauth2-proxy, `theater-sso` (`apps/theater/sso.yaml`), takes every
`/arr/*` path and `/oauth2` from the HTTPRoute `theater` and routes on by
path. Access needs membership of the Keycloak group `TheaterAdmins`; add
users to it in the Keycloak admin console (Groups). The client `theater-sso`
and the group are realm code (`platform/keycloak/realm/platform.conf`,
`proxy_clients`, and `clients.conf`); the PostSync Job
`keycloak-realm-settings` creates them and sets the client secret. The
session lasts a year, refreshed from the Keycloak session
([architecture.md](architecture.md#sessions)).

Each app keeps its own form login behind the proxy, so a login asks twice.
That local admin is the break-glass account when Keycloak is down: forward
the app's port and log in locally, for example

```sh
kubectl -n theater port-forward svc/sonarr 8989:8989
```

then open http://localhost:8989/arr/sonarr. Plex (`/`) and Jellyfin
(cinema.lilalala.com) are not behind the proxy: their TV apps cannot complete
an OIDC login. API calls between the apps (Prowlarr, Bazarr, Recyclarr,
LazyLibrarian, exportarr, the import lists, the *arr apps to qBittorrent) use
the in-cluster Services and never pass it.

`/arr/<app>/api/...` of the *arr apps, Bazarr and LazyLibrarian, and the
Sonarr and Radarr calendar feeds (`/arr/<app>/feed/...`) skip the Keycloak
login (`--skip-auth-route`), so mobile clients such as nzb360 or LunaSea work
with the app's API key, which each app still requires. qBittorrent's API is
not skipped: it takes a session login, not a key.

## Quality profiles

Recyclarr (`apps/theater/recyclarr.yaml`, CronJob `recyclarr-sync`, daily 06:00)
syncs TRaSH Guides profiles, custom formats and scores into Sonarr and Radarr.
Each app has two profiles, TRaSH guide profiles used as published and renamed:

| Profile | Sonarr (TRaSH) | Radarr (TRaSH) | Use |
|---|---|---|---|
| `HD-Original` | WEB-1080p | HD Bluray + WEB | Default: original audio |
| `HD-Kids-FR` | [French MULTi.VF] HD Bluray + WEB (1080p) | [French MULTi.VF] HD Bluray + WEB | Animation and children's titles: French audio required, MULTi preferred |

Both are 1080p without remux, upgrade within 1080p, and penalise x265 (HD) and
AV1 (TRaSH "Golden Rule HD" and "Unwanted Formats" groups). TRaSH defaults are
synced, plus the deviations below. VFF/VFQ ranking inside French releases stays
at the TRaSH default. The Sonarr English profile is WEB only; TRaSH has no
English Bluray + WEB 1080p profile for Sonarr.

### Deviations from TRaSH

Deliberate operator preferences, set in the `custom_formats` blocks of
`apps/theater/recyclarr.yaml`. They use TRaSH custom formats by `trash_id` and
override only the score, in both profiles of both apps:

| Custom format | TRaSH default in these profiles | Score here |
|---|---|---|
| `x264` | 0 | +50 |
| `x265 (HD)` | -10000 | -10000 (pinned) |
| `5.1 Surround`, `6.1 Surround`, `7.1 Surround` | 0 | +100 |

The bonuses are preferences, not blocks: a release without them still
qualifies, and they stay below a release group tier step plus the streaming
service bonus. They also act as upgrades: a 5.1 release of the same tier
replaces a stereo file, from public indexers only (see Indexers).

Check the scores after a sync (read-only; prints one line per profile and
custom format):

```sh
kubectl -n theater exec deploy/radarr -c radarr -- sh -c '
  K=$(grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2)
  curl -s -H "X-Api-Key: $K" http://127.0.0.1:7878/arr/radarr/api/v3/qualityprofile' \
  | jq -r '.[] | .name as $p | .formatItems[]
      | select(.name | test("x26[45]|Surround")) | "\($p) \(.name) \(.score)"'
```

Expected: `HD-Original` and `HD-Kids-FR` show the scores in the table. For
Sonarr use `deploy/sonarr`, container `sonarr`, port `8989`, path
`/arr/sonarr`.

Assign `HD-Kids-FR` per series or movie (Edit, Quality Profile). Nothing
reassigns titles automatically.

Profiles are matched by name: recyclarr's state directory is an `emptyDir`, so
every run adopts the profile whose name matches the config. To rename one,
rename it in Sonarr or Radarr first, then in the config.

Preview a config change against the live apps, without writing anything (from
a branch checkout; needs `yq`):

```sh
F=apps/theater/recyclarr.yaml
yq 'select(.kind == "ConfigMap") | .metadata.name = "recyclarr-config-preview"' "$F" \
  | kubectl -n theater apply -f -
kubectl -n theater create job recyclarr-preview --from=cronjob/recyclarr-sync \
  --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].args = ["sync", "--preview"]
        | .spec.template.spec.volumes[0].configMap.name = "recyclarr-config-preview"' \
  | kubectl -n theater apply -f -
kubectl -n theater wait --for=condition=complete --timeout=10m job/recyclarr-preview
kubectl -n theater logs job/recyclarr-preview
kubectl -n theater delete job/recyclarr-preview configmap/recyclarr-config-preview
```

Expected: one `Completed` line per app and no `[ERR]`. A wrong `trash_id` fails
the job.

## Subtitles

Bazarr (`apps/theater/bazarr.yaml`, https://theater.lilalala.com/arr/bazarr,
user `admin`, password in `apps/secrets/bazarr.sops.yaml`) downloads subtitles
for every series and movie in Sonarr and Radarr and saves them as external
files next to the video: `<video>.en.srt`, `<video>.fr.srt`,
`<video>.fr.forced.srt`.

| Language profile | Languages | Applies to |
|---|---|---|
| `EN` | English | Default, every title |
| `FR` | French, full and forced | Titles tagged `kids-fr` |

Sonarr and Radarr tag a title `kids-fr` automatically while its quality
profile is `HD-Kids-FR` (auto tagging rule `kids-fr (Bazarr FR)`), and Bazarr
assigns the `FR` profile to tagged titles at its next sync with them (hourly).
Providers, none of which needs an account: Podnapisi, Gestdown (Addic7ed proxy),
TVSubtitles, YIFY Subtitles, Sous-Titres.eu, Subsynchro. Embedded text
subtitles count as present.

The PostSync Job `bazarr-settings` applies all of this through the Bazarr,
Sonarr and Radarr APIs on every Argo CD sync of `theater`; UI changes to these
settings are overwritten then. Check its last run (read-only):

```sh
kubectl -n theater logs job/bazarr-settings
```

Expected: one `auto tag kids-fr` line each for sonarr and radarr, then
`bazarr: settings applied`. See also [subtitles](runbooks/subtitles.md).

## Plex watchlist

Sonarr and Radarr each have the import list `Plex Watchlist`: a series or
movie added to the Plex watchlist is added with the profile `HD-Original`,
monitored and searched for. The lists refresh every 6 hours. Change a title's
profile afterwards to `HD-Kids-FR` if needed.

The PostSync Job `arr-import-lists` (`apps/theater/arr-import-lists.yaml`)
writes both lists through the APIs on every Argo CD sync of `theater`; UI
changes to them are overwritten then. They read the watchlist with the Plex
account token in `apps/secrets/plex-token.sops.yaml` (key `PLEX_TOKEN`), the
server's `PlexOnlineToken`; reseal it if the server is claimed again. Check the
last run (read-only):

```sh
kubectl -n theater logs job/arr-import-lists
```

Expected: one `import list 'Plex Watchlist'` line each for sonarr and radarr.

## Indexers

Prowlarr syncs its indexers to Sonarr and Radarr (full sync). Policy: a
private or semi-private tracker is used automatically only for freeleech
releases, because other automatic grabs break its ratio rules.

- A private or semi-private indexer whose definition has a freeleech-only
  option (IPTorrents `freeLeechOnly`, Sharewood `freeleech`) has it on and uses
  the profile `Standard`: RSS and automatic search see freeleech releases only.
- One without that option (C411) uses the app profile `Manual only` (RSS off,
  automatic search off, interactive search on). Sonarr and Radarr receive it
  with RSS and automatic search off, so it is only used from Interactive
  Search.
- Public indexers use the profile `Standard` (everything on). They also carry
  the tag `books`, which is what Prowlarr's `LazyLibrarian` application syncs;
  a non-public indexer must never get it.
- YGG stays disabled. Its definition is no longer shipped by Prowlarr, so it
  cannot be edited until it is re-added.

Prowlarr keeps this in its database, not in git. Check it after adding an
indexer (read-only):

```sh
scripts/check-indexers.sh
```

Expected: one `ok` line per indexer, exit 0. A `FAIL` line names an enabled
private or semi-private indexer that is automatic without freeleech-only on,
or carries the `books` tag. Fix it in Prowlarr (Indexers, edit): turn the
freeleech-only option on, or set Sync Profile `Manual only` if the definition
has none. `WARN` (freeleech-only on, manual profile) does not fail.

qBittorrent has no global ratio or seeding-time limit and the categories
inherit that, so torrents seed until removed. Queueing is on with 10 active
torrents: beyond that, seeds are queued and stop uploading.

Private-tracker torrents are exempt. Add a manual grab from a private tracker
with the category `private` (saved under `torrents/private`). Every 10 minutes
the CronJob `qbittorrent-private-seed` (`apps/theater/qbittorrent-private.yaml`)
force-starts every torrent in `private` and every torrent qBittorrent flags as
private, including the *arr freeleech grabs. A forced torrent ignores the queue
and seeds until it is removed, so remove it only once the tracker's seeding
rule is met. Check the last run (read-only):

```sh
kubectl -n theater logs -l app.kubernetes.io/name=qbittorrent-private-seed --tail=1
```

Expected: `category private ok; <n> private torrent(s), <m> newly force-started`.

## Why it is like this

- One oauth2-proxy routing by path, not one per app or Gateway external
  auth: the apps share one host and URL bases, the Gateway API version here
  has no external-auth filter, and an Envoy filter injected into Cilium's
  Gateway would break on Cilium upgrades. The apps keep Forms login rather
  than `External` auth so their local admin stays usable as break-glass.
- Private torrents are force-started by a CronJob because qBittorrent has no
  per-category queue limit. The alternative, raising or removing the global
  queue, would also keep every public seed active.

- TRaSH profiles by `trash_id`, not hand-built: the guides maintain the release
  group tiers and scores, and recyclarr re-applies them nightly. The alternative,
  custom profiles in the UI, drifts and is not in git.
- The x264 and multichannel-audio preferences are score overrides on TRaSH
  custom formats, not custom formats of our own: TRaSH keeps maintaining the
  matching rules, and the deviation is a few lines in git.
- Two profiles only: one per audio need. Per-title choice stays manual because
  "animated" is not the same as "for children" and a bulk rule would get it
  wrong.
- Bazarr's subtitle language follows the quality profile through a tag, so
  choosing `HD-Kids-FR` for a title is the only per-title decision. Its
  settings are applied through the API rather than kept in a file because
  Bazarr stores profiles in its database. SQLite, not CloudNativePG: the
  database holds nothing that is not rebuilt from git and from Sonarr and
  Radarr, apart from the download history.
- Private trackers are automatic for freeleech only: a freeleech download does
  not count against the ratio, any other automatic grab can. Without a
  freeleech filter the tracker stays manual. Public indexers carry the rest of
  the automatic search.
