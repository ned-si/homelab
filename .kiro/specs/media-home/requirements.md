---
kind: area
status: living
created: 2026-10-16
---
# Requirements: media-home (as-is)

## Introduction

The household's films, series, music, books and home automation. Namespace
`theater` holds the media stack (Plex, Jellyfin, the *arr apps, Prowlarr,
qBittorrent, Bazarr, Recyclarr, LazyLibrarian); `books` holds Audiobookshelf
and Calibre-Web Automated; `home` holds Home Assistant, Mosquitto and
Zigbee2MQTT. This spec records what they do today. Detail:
[docs/theater.md](../../../docs/theater.md),
[docs/books.md](../../../docs/books.md),
[docs/home-automation.md](../../../docs/home-automation.md).

Non-goals:
- Backing up the media library or the audiobook files (re-acquirable).
- Subtitle providers that need an account or a paid API key.
- Device-specific Home Assistant setup in git (location, integrations and
  devices stay in its UI; the repo is public).

## Requirements

### Requirement 1: Releases picked by policy, not by hand

**User story:** As the operator, I want Sonarr and Radarr to grab the right
release on their own, in the audio the viewer needs.

#### Acceptance criteria

1. DAILY at 06:00, THE CronJob `recyclarr-sync` SHALL sync two TRaSH profiles
   per app, `HD-Original` and `HD-Kids-FR`; a wrong `trash_id` fails the job.
   (`apps/theater/recyclarr.yaml`)
2. THE profiles SHALL score `x264` +50, `x265 (HD)` -10000 and 5.1/6.1/7.1
   Surround +100 on top of TRaSH. (read-only score check in
   [theater.md](../../../docs/theater.md#deviations-from-trash))
3. WHEN a title uses `HD-Kids-FR`, Sonarr and Radarr SHALL tag it `kids-fr`
   and Bazarr SHALL also fetch forced French subtitles for it (Requirement 6).
   (PostSync Job `bazarr-settings`)
4. WHEN a title is added to the Plex watchlist, Sonarr or Radarr SHALL add it
   with `HD-Original` and search for it, within 6 hours. (PostSync Job
   `arr-import-lists`)

### Requirement 2: Private trackers stay healthy

**User story:** As the operator, I want private trackers used only in ways
that keep the account in good standing.

#### Acceptance criteria

1. A private or semi-private indexer SHALL be automatic only with
   freeleech-only on; without that option it SHALL be manual only; it SHALL
   never carry the `books` tag; indexers listed as must-stay-disabled SHALL be
   disabled. (`scripts/check-indexers.sh`: one `ok` per indexer, exit 0)
2. EVERY 10 minutes, THE CronJob `qbittorrent-private-seed` SHALL force-start
   every private torrent, so it seeds past the 10-active queue until removed.
   (`apps/theater/qbittorrent-private.yaml`)
3. IF Prowlarr indexers fail for 6 hours, THEN THE system SHALL page with
   `ArrIndexersFailing`. (`tests/prometheus/arr_test.yaml`)

### Requirement 3: Admin UIs behind SSO, clients still work

**User story:** As the operator, I want the admin UIs behind Keycloak while
TV and mobile clients keep working.

#### Acceptance criteria

1. THE oauth2-proxy `theater-sso` SHALL guard every `/arr/*` path of
   `theater.lilalala.com` for groups `admins` and `TheaterAdmins`.
   (`apps/theater/sso.yaml`, `platform/keycloak/realm/platform.conf`)
2. THE `/arr/<app>/api/...` paths and the Sonarr and Radarr feeds SHALL skip
   the SSO login and still require the app's API key. (`--skip-auth-route`)
3. Plex and Jellyfin SHALL stay off SSO so their TV apps can sign in.
4. WHEN `theater` syncs, ITS smoke hook SHALL get an answer from Sonarr,
   Radarr, Lidarr, Prowlarr, qBittorrent, Plex and Jellyfin.
   (`components/postsync-smoke`)

### Requirement 4: Books from acquisition to reader

**User story:** As a household member, I want ebooks and audiobooks in their
apps without manual file moves.

#### Acceptance criteria

1. WHEN LazyLibrarian finishes an ebook, THE file SHALL land in
   `books/ingest` and Calibre-Web Automated SHALL import it; audiobooks land
   in the Audiobookshelf library. ([books.md](../../../docs/books.md#acquisition))
2. LazyLibrarian SHALL get only indexers tagged `books`, which only public
   indexers carry. (`scripts/check-indexers.sh`)
3. Audiobookshelf and Calibre-Web SHALL log in through Keycloak clients
   `audiobookshelf` and `calibre-web`, with a local break-glass admin.

### Requirement 5: Home automation baseline

**User story:** As a household member, I want Home Assistant with one login
and its history kept.

#### Acceptance criteria

1. THE Home Assistant recorder SHALL use CNPG cluster
   `home-assistant-postgresql`, with WAL archiving, a daily base backup and a
   nightly `pg_dump` in `home/configs`. (`apps/home/database.yaml`,
   `cnpg-backup.yaml`, `backup.yaml`)
2. Home Assistant SHALL log in through Keycloak (`hass-oidc-auth`, public
   client `home-assistant`, PKCE); group `HomeAssistantAdmins` gets admin;
   the local `owner` stays as break-glass.
3. Mosquitto SHALL refuse anonymous clients; users come from the SOPS Secret
   `mosquitto-users`. (`apps/home/config/mosquitto/mosquitto.conf`)
4. Zigbee2MQTT SHALL stay at 0 replicas until its coordinator is online.
   (`apps/home/zigbee2mqtt.yaml`)
5. Prometheus SHALL scrape Home Assistant's `/api/prometheus` every 60 s for
   the "Home" dashboard. (ServiceMonitor `home/home-assistant`)

### Requirement 6: Subtitles for the whole library

**User story:** As a viewer, I want English and French subtitles on every
film and episode, and Spanish ones when Spanish is the original language.

#### Acceptance criteria

1. Bazarr SHALL want English and French subtitles for every series and movie
   (profile `en-fr`, the default).
2. WHEN a title's original language in Sonarr or Radarr is Spanish, Sonarr
   and Radarr SHALL tag it `orig-es` and Bazarr SHALL also want Spanish
   (profile `en-fr-es`).
3. WHEN a title is tagged `kids-fr`, Bazarr SHALL also want forced French
   (profile `kids-fr`, or `kids-fr-es` when it is also `orig-es`).
4. WHEN `theater` syncs and every night, THE profile of every existing series
   and movie SHALL be set from these rules, not only for new titles.
5. An embedded or external text subtitle (SRT, ASS) SHALL count as present;
   an image subtitle (PGS, VobSub) SHALL NOT, so Bazarr fetches a text one
   that Plex does not burn in.
6. Bazarr SHALL use only providers that need no account, and IF a provider
   rate-limits, THEN Bazarr SHALL pause it (built-in throttling).
7. EVERY night at 22:30 UTC, THE CronJob `bazarr-nightly` SHALL start Bazarr's
   wanted search for series and movies; Bazarr's own interval search SHALL be
   off.
8. THE Homelab / Usage dashboard SHALL show subtitle coverage per language
   for movies and episodes. Class INFO (`action: auto`): the nightly search is
   the remediation; nothing pages.
