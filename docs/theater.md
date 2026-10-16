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
`<video>.fr.forced.srt`, `<video>.es.srt`. English and French on every title,
Spanish when it is the original language.

| Language profile | Languages | Applies to |
|---|---|---|
| `en-fr` | English, French | Default, every title |
| `en-fr-es` | English, French, Spanish | Titles tagged `orig-es` |
| `kids-fr` | English, French full and forced | Titles tagged `kids-fr` |
| `kids-fr-es` | English, French full and forced, Spanish | Titles tagged `kids-fr-es` |

Sonarr and Radarr tag titles with auto tagging rules: `kids-fr` while the
quality profile is `HD-Kids-FR`, `orig-es` while the original language is
Spanish, `kids-fr-es` for both. Bazarr gives a tagged title the first profile,
by ID, whose tag it carries at its hourly sync; `kids-fr-es` (ID 2) comes
before `kids-fr` (3) and `en-fr-es` (4).

Embedded and external text subtitles (SRT, ASS) count as present; image ones
(PGS, VobSub) do not, so Bazarr fetches a text subtitle that Plex shows
without burning it in. Providers, none of which needs an account: Gestdown
(Addic7ed's catalogue), TVSubtitles, YIFY Subtitles, Subtitulamos.tv, Subtis,
Sous-Titres.eu, Subsynchro. Bazarr pauses a provider that rate-limits it, and
retries a title with no result after 3 weeks, then weekly.

`settings.py` (ConfigMap `bazarr-config`) applies all of this through the
Bazarr, Sonarr and Radarr APIs; UI changes to these settings are overwritten:

- the PostSync Job `bazarr-settings`, on every Argo CD sync of `theater`: the
  auto tagging rules, the Bazarr settings, the profile of every title;
- the CronJob `bazarr-nightly`, at 22:30 UTC: the profile of every title, then
  Bazarr's wanted searches for series and movies. Bazarr's own interval search
  is off.

Check the last runs (read-only):

```sh
kubectl -n theater logs job/bazarr-settings
kubectl -n theater logs -l app.kubernetes.io/name=bazarr-nightly --tail=5
```

Expected: `bazarr-settings` prints one `auto tags` line each for sonarr and
radarr, `bazarr: settings applied`, then a `profiles set` line for series and
for movies; `bazarr-nightly` the two `profiles set` lines and
`bazarr: wanted searches started (series, movies)`. See also
[subtitles](runbooks/subtitles.md).

Coverage per language (movies and episodes) is on the Homelab / Usage
dashboard, row "Subtitles (Bazarr)", from the Deployment `subtitle-exporter`
([observability](observability.md)). It does not page: the nightly search is
the remediation.

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

Prowlarr syncs its indexers to Sonarr and Radarr (full sync). The set is
`EXPECTED` in `scripts/check-indexers.sh`:

| Indexer | Privacy | State |
|---|---|---|
| BT.etree, EBookBay, LimeTorrents, The Pirate Bay, Torrent9 | public | enabled, profile `Standard`, tag `books` |
| C411 | private | enabled, profile `Manual only` |
| IPTorrents | private | disabled (see below) |

An indexer whose definition Prowlarr no longer ships (System -> Status:
"Indexers have no definition") cannot be used or edited: remove it in
Prowlarr and from `EXPECTED`. A replacement definition is a new indexer, added
with new credentials.

Policy: a private or semi-private tracker is used automatically only for
freeleech releases, because other automatic grabs break its ratio rules.

- A private or semi-private indexer whose definition has a freeleech-only
  option (IPTorrents `freeLeechOnly`) has it on and uses the profile
  `Standard`: RSS and automatic search see freeleech releases only.
- One without that option (C411) uses the app profile `Manual only` (RSS off,
  automatic search off, interactive search on). Sonarr and Radarr receive it
  with RSS and automatic search off, so it is only used from Interactive
  Search.
- Public indexers use the profile `Standard` (everything on). They also carry
  the tag `books`, which is what Prowlarr's `LazyLibrarian` application syncs;
  a non-public indexer must never get it.
- IPTorrents is disabled: the tracker has locked the account, and any use,
  freeleech included, stays off until it restores access. Then enable it with
  `freeLeechOnly` on and the profile `Standard`, and remove it from
  `MUST_BE_DISABLED` in `scripts/check-indexers.sh`.

Prowlarr keeps this in its database, not in git. Check it after adding an
indexer (read-only):

```sh
scripts/check-indexers.sh
```

Expected: one `ok` line per indexer, exit 0. A `FAIL` line names an enabled
private or semi-private indexer that is automatic without freeleech-only on,
carries the `books` tag, or is enabled while listed as one that must stay
disabled (IPTorrents); or an indexer missing from Prowlarr or from
`EXPECTED`. Fix it in Prowlarr (Indexers, edit): turn the
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
