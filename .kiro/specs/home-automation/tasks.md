# Tasks: home-automation

One PR per task, in order unless a task says otherwise; each is safe on its
own. Live changes that restart Home Assistant or Zigbee2MQTT, or touch the
NAS, run on a weekday during the day (Zurich). Purchases wait for the
operator's approval in chat ([design](design.md#purchases)). Device
details stay in the operator's local inventory file; PRs name categories
and integrations only.

## Phase 1: current hardware

- [ ] 1. Inventory and feasibility: the operator's label photos into the
      local inventory file; the feasibility table in
      `docs/home-automation.md` (one row per category: integration, local or
      cloud, fallback, phase; no models or counts), replacing the current
      Devices table; the purchases the photos make necessary listed back to
      the operator in chat, each one checked against Requirement 12.
      [1.1, 1.2, 1.3, 1.4, 12.2]
- [ ] 2. Zigbee online: the coordinator answering on TCP (the Raspberry Pi
      steps, or the network coordinator if the operator buys one),
      `zigbee2mqtt` at one replica, `zigbee2mqtt-data` in
      `apps/home/backup.yaml` and `restic-targets.txt`. Closes #728. Check:
      the existing plant sensors report; a restic snapshot holds
      `zigbee2mqtt-data`. [12.1, 13.1]
- [ ] 3. Lights: the bridge integration by IP; the automations of 2.2;
      presence from the companion app's `home` zone. Check: the fallback
      test (switches, bridge schedules and the vendor app with Home
      Assistant at 0 replicas), result in the PR. [2.1, 2.2, 2.3, 2.4]
- [ ] 4. Heating: the integration the model allows, overrides with an end
      time only, the unavailability notification to the admins. Check: an
      override, then Home Assistant at 0: the zone returns to its schedule.
      [3.1, 3.2, 3.4]
- [ ] 5. Energy: inverter, meter and heat pump integrations as available,
      the Energy dashboard, the polling interval within half of any cloud
      quota recorded in the feasibility table. [4.1, 4.2, 4.3, 4.4]
- [ ] 6. Plants: Plant Monitor pinned in the `custom-components` init
      container (as `auth_oidc`), one device per plant with OpenPlantbook
      thresholds, the overview, the watering reminder, the weekly battery
      and silent-sensor digest. [5.1, 5.2, 5.4]
- [ ] 7. Notifications: the per-purpose notify scripts, critical only for
      the alarm and safety sensors, the cooldowns; a repo-policy rule that
      fails when `apps/home/config/` configures ntfy. [10.1, 10.2, 10.3,
      10.4]
- [ ] 8. Dashboards: the main Home dashboard as default, the area
      dashboards, the admin-only System dashboard; screenshots with names
      blurred in the PR, or none. [8.1, 8.2, 8.3, 8.4]
- [ ] 9. Wall tablet trial: the local user `wall`, Fully Kiosk Browser and
      its integration, the tablet dashboard, screen on by motion or daytime.
      Check: a day on the wall without a reload; if it fails, the tablet
      purchase goes to the operator. [9.1, 9.2, 9.4]
- [ ] 10. Alarm: SIA (or the integration the feasibility table names) as
      read-only, the code required to disarm, the critical notification on
      trigger. Skipped with the reason in the feasibility table if the
      panel offers nothing. [7.1, 7.2, 7.3, 7.4]

## Phase 2: small purchases

- [ ] 11. Watering and contacts: the watering plug with its maximum run
      time and power-on state off; window contacts and the window-open rule;
      the tablet's charging plug between 20% and 80%. Check: power the
      plug off and on: it stays off. [3.3, 5.3, 9.3]

## Phase 3: cameras

- [ ] 12. Frigate: app and namespace `frigate` (non-root recipe first,
      else `baseline` with a PolicyException), the NAS dataset with its
      1 TB quota as a static NFS PV (`Retain`), `frigate-config` on
      `iscsi-retain` in a nightly restic snapshot, retention 7/30/14 days,
      no public route, the Frigate integration in Home Assistant pinned in
      the init container. Closes #729. [6.2, 6.4, 13.2]
- [ ] 13. Cameras: each one on RTSP/ONVIF with its cloud off, recording to
      its card, added to Frigate with a detection sub-stream; the CPU trial
      with the first two (mean inference, skipped detections, CPU, in the
      PR); the person notification in away and night mode. If the trial
      fails its threshold, the accelerator and generic-device-plugin in the
      same task. [6.1, 6.3, 6.6, 12.3]
- [ ] 14. Camera segment: once the networking spec has the segment, the
      cameras moved onto it and the `frigate` allow-list updated. Check:
      a camera cannot reach the internet; Frigate still records. [6.5]

## Close

- [ ] 15. The fallback test of Requirement 11 with every phase in place,
      a restic restore of `home-assistant-config` into a throwaway pod,
      `docs/home-automation.md` complete, the media-home area spec updated;
      then header `status: done`, `closed:`, issue #1072 closed. [11.1,
      11.2, 11.3, 13.3, 13.4]
