# Tasks: home-automation

One PR per task, in order unless a task says otherwise; each is safe on its
own. Live changes that restart Home Assistant, Zigbee2MQTT, Frigate or
evcc, or touch the NAS, run on a weekday during the day (Zurich).
Purchases wait for the operator's approval in chat
([design](design.md#purchases)). Device details stay in the operator's
local inventory file; PRs name categories and integrations only.
Automations, scripts, scenes and dashboards are built in the Home
Assistant UI; the PR describes the rule, not the entity IDs
([design](design.md#decided-defaults)).

## Phase 1: current hardware

- [ ] 1. Inventory and feasibility: the operator's label photos into the
      local inventory file; the feasibility table in
      `docs/home-automation.md` (one row per category: integration, local or
      cloud, fallback, phase; no models or counts), replacing the current
      Devices table. Device details of the categories already there (EV
      charger and car, appliances, robot vacuum, smoke alarms, the doorbell
      to buy) move to the inventory file and become generic rows (for
      example "EV charger: vendor integration, local, read-only"); the
      mermaid names categories, not vendors. Git history keeps the old
      table; a history rewrite is out of scope (secrets-hygiene owns it).
      The purchases the photos make necessary are listed back to the
      operator in chat with their prices, each one checked against
      Requirement 12. [1.1, 1.2, 1.3, 1.4, 12.2]
- [ ] 2. Zigbee online: the coordinator answering on TCP (the Raspberry Pi
      steps, or the network coordinator if the operator buys one); the
      mesh's 2.4 GHz channel fixed and the Zigbee channel set in the
      Zigbee2MQTT config before any pairing
      ([design](design.md#wi-fi-for-cameras-and-devices));
      `zigbee2mqtt` at one replica, `zigbee2mqtt-data` in
      `apps/home/backup.yaml` and `restic-targets.txt`. Closes #728. Check:
      the existing plant sensors report; a restic snapshot holds
      `zigbee2mqtt-data`. [12.1, 13.1]
- [ ] 3. Lights: the bridge integration by IP; the automations of 2.2 in
      the UI; presence from the companion app's `home` zone. Check: the
      [fallback test](design.md#fallback-test) (switches, bridge schedules
      and the vendor app with Home Assistant at 0 replicas), result in the
      PR. [2.1, 2.2, 2.3, 2.4]
- [ ] 4. Heating: the integration the model allows, overrides with an end
      time only, the unavailability notification to the admins; plug-in
      heaters only enabled or disabled by their plug. Check: an override,
      then the [fallback test](design.md#fallback-test): the zone returns
      to its schedule. [3.1, 3.2, 3.4]
- [ ] 5. Energy: inverter, meter, EV charger and heat pump integrations as
      available, the Energy dashboard, the polling interval within half of
      any cloud quota recorded in the feasibility table; whether grid power
      is available every 10 seconds, recorded for task 17. [4.1, 4.2, 4.3,
      4.4]
- [ ] 6. Plants: Plant Monitor pinned in the `custom-components` init
      container (as `auth_oidc`), one device per plant with OpenPlantbook
      thresholds, the overview, the watering reminder, the weekly battery
      and silent-sensor digest, in the UI. [5.1, 5.2, 5.4]
- [ ] 7. Notifications: the per-purpose notify scripts in the UI, critical
      only for the alarm and safety sensors, the cooldowns. Check: from the
      Home Assistant pod, `curl -m 5 https://ntfy.sh` fails once the `home`
      egress allow-list (#709) is enforced. [10.1, 10.2, 10.3, 10.4]
- [ ] 8. Dashboards: the main Home dashboard as default, the area
      dashboards, the admin-only System dashboard; screenshots with names
      blurred in the PR, or none. Tiles for devices of later tasks are
      added by those tasks. [8.1, 8.2, 8.3, 8.4]
- [ ] 9. Wall tablet trial: the local user `wall`, Fully Kiosk Browser with
      its PLUS licence and its integration, the tablet dashboard, screen on
      between 07:00 and 22:00 or by motion. Check: a day on the wall
      without a reload; if it fails, the tablet purchase goes to the
      operator with the classes in the design. [9.1, 9.2, 9.4]
- [ ] 10. Alarm: SIA (or the integration the feasibility table names),
      read-only: no arm or disarm action on any dashboard or automation; the
      critical notification on trigger. For SIA, the
      [receiver](design.md#sia-receiver): Service `home-assistant-sia`,
      LoadBalancer pinned to `192.168.1.202`, one TCP port equal to the
      integration's listening port, the `home` ingress allow-list admitting
      LAN sources on that port, no router port forward, the account ID and
      AES key in the UI, a row in the LoadBalancer table of
      `docs/networking.md`. Skipped with the reason in the feasibility
      table if the panel offers nothing. [7.1, 7.2, 7.3, 7.4]
- [ ] 11. TV and streamer: the TV's local integration and the streamer's
      remote and cast integrations, by IP; the TV switched on through the
      streamer; the film scene. Check: the remotes and the TV's apps work
      with Home Assistant at 0 replicas. [17.1, 17.2, 17.3]
- [ ] 12. Robot vacuum: the existing integration's entities on the media
      dashboard, the away-mode clean, docking on arrival, consumables in
      the weekly digest. [18.1, 18.2, 18.3, 5.4]

## Phase 2: small purchases

- [ ] 13. Watering and contacts: the watering plug with its maximum run
      time and power-on state off; window contacts and the window-open rule;
      the tablet's charging plug between 20% and 80%. Check: power the
      plug off and on: it stays off; the
      [fallback test](design.md#fallback-test). [3.3, 5.3, 9.3, 11.1]
- [ ] 14. Room climate: the sensors paired, the climate dashboard, the CO2
      and humidity notifications with their cooldowns. [14.1, 14.2, 14.3,
      14.4]
- [ ] 15. Mailbox: the sensor paired over Zigbee after a link-quality check
      in Zigbee2MQTT at the mailbox (a mains router nearby if needed), or
      ESPHome on Wi-Fi; mail waiting on the main Home dashboard; the daily
      notification. [19.1, 19.2, 19.3]
- [ ] 16. Outdoor lights: fixtures on the bridge or relays behind the
      current ones (electrician where needed), motion sensors bound
      directly, the off delay; the night camera trigger comes with task 19.
      Check: the [fallback test](design.md#fallback-test): motion turns the
      lights on at night with Home Assistant at 0 replicas. [16.1, 16.2,
      11.1]
- [ ] 17. Solar-surplus charging: app and namespace `evcc` (Application in
      `clusters/homelab/apps/`, arm64 image checked, restricted Pod
      Security), config as `apps/secrets/evcc-config.sops.yaml` with its
      `.example` and a `ci/secret-rotation.tsv` row, PVC `evcc-data` in
      the restic targets, MQTT user `evcc` (key in
      `apps/secrets/mosquitto-users.sops.yaml`, ACL `topic readwrite
      evcc/#`), the `evcc` allow-list, the route
      ([design](design.md#solar-surplus-charging)); the command proxy; the
      grid meter if task 5 found no grid power. Check: a solar-only charge
      follows the surplus for an hour; evcc at 0 replicas, the car still
      charges. [4.1, 11.4, 13.1, 20.1, 20.2, 20.3, 20.4, 20.5]

## Phase 3: cameras

- [ ] 18. Frigate: app and namespace `frigate` (non-root recipe first,
      else `baseline` with a PolicyException), `nodeSelector`
      `kubernetes.io/hostname: homelab-w-1`; the config as the SOPS Secret
      `apps/secrets/frigate-config.sops.yaml` with its `.example` (key
      `config.yml`, generic camera names `cam1`...`camN`, RTSP credentials
      as `FRIGATE_RTSP_*` variables), mounted with `subPath` at
      `/config/config.yml`, read-only, over the PVC `frigate-data`; only
      non-camera settings plain in `apps/frigate/`; retention 7/30/14 days;
      no route; the Frigate integration in Home Assistant pinned in the
      init container. The read-only mount is what turns UI editing off;
      Frigate has no switch for it. A Renovate rule for the Frigate image:
      patches automerge; minors and majors carry the `no-automerge` label,
      and their PR updates the Secret's `config.yml`, including its
      `version:`, from the release notes. MQTT user `frigate` (key in
      `apps/secrets/mosquitto-users.sops.yaml`, ACL `user frigate` /
      `topic readwrite frigate/#`), the same password as
      `FRIGATE_MQTT_PASSWORD` in the Frigate Secret, used as
      `{FRIGATE_MQTT_PASSWORD}`; a `ci/secret-rotation.tsv` row for it; the
      `frigate` and `home` allow-lists admit Frigate to Mosquitto on 1883
      and Home Assistant to Frigate on 5000. The operator creates the NAS
      dataset `homelab/k8s/nfs/frigate` (quota from the camera count plus
      30%, NFS export to `192.168.1.238`, `.239`, `.240`, `.247` only,
      `maproot` to the Frigate UID) in a weekday step listed in the PR's
      Blocked section; the PV is static NFS with `Retain`. No backup of the
      event database or recordings. The port-forward of Requirement 6.4 is
      tried once through the tailnet API proxy; if it fails, from a LAN
      host. Closes #729. [6.2, 6.4, 13.2]
- [ ] 19. Cameras and doorbell: the Wi-Fi check of each position (the
      result in the inventory file); then one camera at a time, each on
      RTSP/ONVIF with its cloud off, no gateway and no DNS, recording to
      its card, added to Frigate with a detection sub-stream, and its
      24-hour stream test before the next one is bought; the CPU trial
      with the first two (mean inference, skipped detections, CPU against
      the thresholds in the design, in the PR); the person notification in
      away and night mode; the night trigger for the outdoor lights; the
      doorbell's press notification, tablet view and TV pause. If the trial
      fails its threshold: the USB port on the worker confirmed, the
      accelerator, generic-device-plugin and its Kyverno PolicyException in
      the same task. Check: the [fallback test](design.md#fallback-test).
      [6.1, 6.3, 6.5, 6.6, 6.7, 11.1, 12.3, 15.1, 15.2, 15.3, 16.3]

## Close

- [ ] 20. The [fallback test](design.md#fallback-test) with every phase in
      place, a restic restore of `home-assistant-config` into a throwaway
      pod, `docs/home-automation.md` complete, the media-home area spec
      updated; the deferred issues opened (blinds, air conditioning, camera
      segmentation); then header `status: done`, `closed:`, issue #1072
      closed. [11.1, 11.2, 11.3, 13.3, 13.4]
