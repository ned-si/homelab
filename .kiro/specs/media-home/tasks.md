# Tasks: media-home

Requirement numbers in brackets. New work in this area adds a task here first.

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

## Open

- [ ] 15. Zigbee2MQTT to 1 replica once the coordinator on the Raspberry Pi
      answers on TCP 20108; back up `zigbee2mqtt-data`.
- [ ] 16. Frigate NVR for the cameras (storage sizing; check RK3588 NPU/VPU
      support).
- [ ] 17. Add the house devices (plant sensors, thermostat, smoke alarms,
      cameras) as they arrive; Zigbee models preferred.
- [ ] 18. Jellyfin on Keycloak SSO through its SSO plugin; the TV keeps
      Quick Connect or a local login.
- [ ] 19. Seerr as the request front door once others request media: CNPG
      Postgres, per-user request rules, Keycloak login.
- [ ] 20. Paperless as the home for all documents: taxonomy, ingestion paths,
      OCR languages FR, EN, DE, then a bulk import. Its own spec in
      `.kiro/specs/`.
