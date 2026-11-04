# Tasks: home-automation

One PR per task, in order unless a task says otherwise; each is safe on its
own. Live changes that restart Home Assistant or Zigbee2MQTT, or touch the
NAS, run on a weekday during the day (Zurich). Purchases wait for the
operator's approval in chat ([design](design.md#purchases)). Device
details stay in the operator's local inventory file; PRs name categories
and integrations only. Automations, scripts, scenes and dashboards are
built in the Home Assistant UI; the PR describes the rule, not the entity
IDs ([design](design.md#decided-defaults)).

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
      operator in chat, each one checked against Requirement 12.
      [1.1, 1.2, 1.3, 1.4, 12.2]
- [ ] 2. Zigbee online: the coordinator answering on TCP (the Raspberry Pi
      steps, or the network coordinator if the operator buys one),
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
      any cloud quota recorded in the feasibility table. [4.1, 4.2, 4.3, 4.4]
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
      blurred in the PR, or none. [8.1, 8.2, 8.3, 8.4]
- [ ] 9. Wall tablet trial: the local user `wall`, Fully Kiosk Browser with
      its PLUS licence and its integration, the tablet dashboard, screen on
      by motion or daytime. Check: a day on the wall without a reload; if it
      fails, the tablet purchase goes to the operator with the classes in
      the design. [9.1, 9.2, 9.4]
- [ ] 10. Alarm: SIA (or the integration the feasibility table names),
      read-only: no arm or disarm action on any dashboard or automation; the
      critical notification on trigger. Skipped with the reason in the
      feasibility table if the panel offers nothing. [7.1, 7.2, 7.3, 7.4]

## Phase 2: small purchases

- [ ] 11. Watering and contacts: the watering plug with its maximum run
      time and power-on state off; window contacts and the window-open rule;
      the tablet's charging plug between 20% and 80%. Check: power the
      plug off and on: it stays off; the
      [fallback test](design.md#fallback-test). [3.3, 5.3, 9.3, 11.1]

## Phase 3: cameras

- [ ] 12. Frigate: app and namespace `frigate` (non-root recipe first,
      else `baseline` with a PolicyException); the config as the SOPS
      Secret `apps/frigate/secrets/frigate-config.sops.yaml` (key
      `config.yml`, generic camera names `cam1`...`camN`, RTSP credentials
      as `FRIGATE_RTSP_*` variables, UI editing off), only non-camera
      settings plain in `apps/frigate/`; retention 7/30/14 days; no route;
      the Frigate integration in Home Assistant pinned in the init
      container. The operator creates the NAS dataset
      `homelab/k8s/frigate` (quota from the camera count plus 30%, NFS
      export to `192.168.1.238`, `.239`, `.240`, `.247` only, `maproot` to
      the Frigate UID) in a weekday step listed in the PR's Blocked
      section; the PV is static NFS with `Retain`. No backup of the event
      database or recordings. Closes #729. [6.2, 6.4, 13.2]
- [ ] 13. Cameras: each one on RTSP/ONVIF with its cloud off, recording to
      its card, added to Frigate with a detection sub-stream; the CPU trial
      with the first two (mean inference, skipped detections, CPU against
      the thresholds in the design, in the PR); the person notification in
      away and night mode. If the trial fails its threshold: the USB port
      on the worker confirmed, the accelerator, generic-device-plugin and
      its Kyverno PolicyException in the same task. Check: the
      [fallback test](design.md#fallback-test). [6.1, 6.3, 6.6, 11.1, 12.3]
- [ ] 14. Camera segment: once the networking spec has the segment, the
      cameras moved onto it and the `frigate` allow-list updated. Check:
      a camera cannot reach the internet; Frigate still records. [6.5]

## Close

- [ ] 15. The [fallback test](design.md#fallback-test) with every phase in
      place, a restic restore of `home-assistant-config` into a throwaway
      pod, `docs/home-automation.md` complete, the media-home area spec
      updated; then header `status: done`, `closed:`, issue #1072 closed.
      [11.1, 11.2, 11.3, 13.3, 13.4]
