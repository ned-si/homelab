# Tasks: media-home

Requirement numbers in brackets. A living area spec: the history of the area,
no open tasks. New work is an issue on the board, and a change spec when it
needs one ([README](../README.md)).

## Done

- [x] 1. Two TRaSH quality profiles via recyclarr; recyclarr 8 config. [1.1] (#355, #299)
- [x] 2. Prefer x264 and 5.1+ audio on top of TRaSH. [1.2] (#377)
- [x] 3. *arr apps wait for their database and restart on loss. (#328)
- [x] 4. Indexer policy and its check script; freeleech-only automatic grabs
      on private trackers; IPTorrents kept disabled. [2.1] (#362, #436, #459)
- [x] 5. Keep private-tracker torrents seeding. [2.2] (#438)
- [x] 6. Plex Watchlist import lists in Sonarr and Radarr. [1.4] (#439, #440)
- [x] 7. Bazarr with FR and EN subtitles. [1.3] (#433, #437)
- [x] 8. Keycloak SSO in front of the admin UIs; API-key requests skip it;
      qBittorrent 5.2 login fix. [3.1, 3.2] (#442, #445, #443)
- [x] 9. Audiobookshelf, Calibre-Web Automated, LazyLibrarian; the library as
      an inline NFS volume. [4] (#358, #369, #371, #367)
- [x] 10. Home Assistant with a Postgres recorder; Mosquitto with auth;
      Zigbee2MQTT scaled to 0. [5.1, 5.3, 5.4] (#385, #411, #414, #418, #426)
- [x] 11. Keycloak login for Home Assistant; reverse-proxy config in its
      store. [5.2] (#416, #420)
- [x] 12. Home Assistant metrics and the Home dashboard; home-automation docs.
      [5.5] (#417, #422)
- [x] 13. Page when Prowlarr indexers fail for 6 hours. [2.3] (#484)
- [x] 14. Remove the dead Prowlarr indexers from the expected set. [2.1] (#502)
- [x] 21. Subtitle policy: profiles `en-fr`, `en-fr-es`, `kids-fr`,
      `kids-fr-es`; auto tags `orig-es` and `kids-fr-es`; profiles set on
      every existing title; text over image subtitles; free providers; the
      nightly wanted search. [6.1-6.7] (#518)
- [x] 22. Backfill: a full subtitle re-index, then one wanted search over the
      whole library (`bazarr-nightly-backfill`). [6.4, 6.7]
- [x] 23. Subtitle coverage per language on the Usage dashboard. [6.8] (#518)

## Moved to the backlog (2026-10-26)

- 15. Moved to the backlog: #728 (Zigbee2MQTT to one replica).
- 16. Moved to the backlog: #729 (Frigate NVR for the cameras).
- 17. Not a task: devices are added as they arrive ([home-automation.md](../../../docs/home-automation.md)).
- 18. Moved to the backlog: #730 (Jellyfin on Keycloak SSO).
- 19. Moved to the backlog: #731 (Seerr as the media request front door).
- 20. Moved to the backlog: #732 (Paperless as the home for all documents).
