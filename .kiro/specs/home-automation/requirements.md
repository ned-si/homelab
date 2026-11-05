---
kind: change
status: active
created: 2026-11-04
issue: 1072
---
# Requirements: home-automation

## Introduction

Home Assistant runs at `home.lilalala.com` with Keycloak login, a
Postgres recorder and backups (media-home Requirement 5), but the household
does not use it yet: Zigbee2MQTT is at 0 replicas (#728), no camera is
recorded locally (#729) and there is no dashboard for daily use.

This spec makes Home Assistant the one place where the household sees and
controls the house: lights with automations, indoor and outdoor; heating;
the indoor climate of every room; solar production, the heat pump and
solar-surplus charging of the car; plants; outdoor cameras and a video
doorbell; the garage door; the existing alarm system's sensors; the robot
vacuum, the mailbox and, optionally, the TV; a main Home dashboard with one
dashboard per area, on the phones and on a shared wall tablet. What the
household needs every day (the doorbell, the garage door, the vacuum, the
lamps and basic heating) keeps working when the cluster or Home Assistant
is down; the rest may wait for Home Assistant.

One rule covers every device: no paid cloud service, for anything in the
house (operator, 2026-11-05). Hardware is bought and run locally; a free
vendor cloud is used only where the feasibility table says there is no
local way.

Work is phased: what the current hardware allows first, purchases flagged
with a rough cost and made only once the operator approves them
([design](design.md#phases)).

Non-goals:
- Device inventory in git. Brands, models, counts and locations of
  devices, the network gear, and anything about the alarm and camera gear
  beyond its category, stay in the operator's local inventory file; the
  repo describes categories, integrations and rules (the repo is public).
- Replacing the alarm system or its monitoring. Home Assistant reads it; it
  never arms, disarms or becomes the alarm.
- Motorised blinds and air conditioning. The household has neither; they
  are deferred issues, and this spec only picks the protocol they must use
  (Requirement 12).
- Cloud recording of camera footage, or any camera vendor cloud.
- Indoor cameras: every camera is outdoors (operator, 2026-11-05).
- Paid cloud services and subscriptions of any kind, including pay-per-use
  vehicle APIs and command proxies.
- A voice assistant. Suggested in the design, a new issue if wanted.
- Per-appliance power metering and indoor (per-room) presence detection:
  not wanted. Presence here means "at home or not", from the phones.
- New smoke or water leak sensors: low priority. The existing smoke alarms
  get a feasibility row; nothing is bought for them.
- Network segmentation (VLANs, a separate camera network): not wanted
  (operator, 2026-11-05). The homelab does not trust the LAN: every UI
  needs a Keycloak login and the cluster's network policies admit only
  what each app needs. Cameras are kept off the internet on the device
  (Requirement 6.5).
- Publishing house data. The future public website may show some of it;
  the rules for that are in [design](design.md#public-data), and the
  website is its own roadmap item.

## Glossary

- **Device controller**: the vendor hub or controller a device already
  depends on (the lights' bridge, the heating controller, the inverter, the
  alarm panel). It keeps working without Home Assistant.
- **Inventory file**: the operator's local, git-ignored list of devices,
  models, counts and locations, with the label photos' findings and the
  network gear. Never committed, quoted or paraphrased into the repo.
- **Feasibility table**: the public table in `docs/home-automation.md`, one
  row per device category: the integration, local or cloud, what it can
  read and control, and the fallback. No models or counts.
- **Household notification**: a push from Home Assistant to a household
  member's companion app (plants, doors, cameras, alarm). Not an operator
  page.
- **Operator page**: an Alertmanager or watchdog notification to ntfy
  (`action: human`), about the platform.
- **Main Home dashboard**: the default Home Assistant dashboard for every
  user: a summary of each area, each tile linking to the area's dashboard.
  Not the Grafana "Home" dashboard, which keeps the long-term metrics.
- **Wall tablet**: a shared, always-on tablet showing a dashboard,
  logged in as a dedicated non-admin Home Assistant user.
- **House mode**: one Home Assistant selector, `home`, `away`, `night` or
  `vacation`, set from presence (the companion apps' `home` zone) and the
  time of day, and by hand from the dashboards. Automations read it.
- **NVR**: Frigate, the network video recorder that records the cameras
  and detects people and vehicles (#729).
- **Charge controller**: evcc, which sets the car's charging current from
  the solar surplus.

## Requirements

### Requirement 1: Feasibility is known before anything is bought

**User story:** As the operator, I want to know which of my devices work
with Home Assistant, locally or through a cloud, before I buy or replace
anything.

#### Acceptance criteria

1. FOR every device category in scope (lights, outdoor lights and motion
   sensors, heating, room climate sensors, solar, grid meter, heat pump, EV
   charger and car, plants, cameras, doorbell, garage door, alarm, smoke
   alarms, TV and streamer, robot vacuum, mailbox sensor, appliances, wall
   tablet), THE
   inventory file SHALL record the operator's label photos' findings, the
   matching integration, local or cloud, and what it can read and control.
2. THE feasibility table in `docs/home-automation.md` SHALL have one row per
   category with the integration, local or cloud, the fallback and the
   phase, and SHALL name no model, count or location.
3. A device category whose integration is cloud only SHALL say so in the
   table, with what happens when the cloud is down or rate-limits.
4. A purchase SHALL be listed in [design](design.md#purchases) with a rough
   cost and the phase that needs it before it is made; the operator approves
   it in chat.
5. NO device or integration SHALL need a paid cloud service or a
   subscription to do what this spec asks of it; a device that does is not
   bought, and an existing one is used only for what works without paying.
   (the feasibility table's local or cloud column, and each purchase row)

### Requirement 2: Lights with automations, and without Home Assistant

**User story:** As a household member, I want the lights to follow the day
and our presence, and the switches to work even when Home Assistant does
not.

#### Acceptance criteria

1. Home Assistant SHALL control every light through the lights' bridge,
   added by IP, locally (no cloud account in the path).
2. THE light automations SHALL cover at least: on at dusk when someone is
   home, off when everyone has left, a night mode, and a vacation mode that
   simulates presence.
3. WHEN Home Assistant is stopped, THE wall switches, the bridge's own
   schedules and the vendor app on the LAN SHALL still switch the lights.
   (test: the [fallback test](design.md#fallback-test), on a weekday)
4. A switch or sensor added later SHALL pair with the lights' bridge or
   bind directly to its target over Zigbee, never only through a Home
   Assistant automation, for any light a person needs to see by.

### Requirement 3: Heating from Home Assistant, on its own schedule without it

**User story:** As a household member, I want to see and change the heating
from the same app, and the house to stay warm whatever happens to Home
Assistant.

#### Acceptance criteria

1. Home Assistant SHALL show the temperature and setpoint of every heating
   zone and SHALL set the mode (schedule, away, boost) through the heating
   system's integration.
2. THE heating controller's own schedule SHALL stay the source of the
   daily program; Home Assistant SHALL only switch modes or override
   setpoints for a limited time, so a stopped Home Assistant leaves the
   heating on its schedule. (test: an override with an end time, then the
   [fallback test](design.md#fallback-test): the zone returns to its
   schedule)
3. WHEN a window contact in a zone reports open for 5 minutes, THE zone
   SHALL drop to its frost setpoint until the window closes. (phase 2,
   once contacts exist)
4. IF the heating integration is unavailable for 1 hour, THEN a household
   notification SHALL tell the admins; it SHALL NOT page the operator.

### Requirement 4: Energy in one view

**User story:** As the operator, I want solar production, grid import and
export, house consumption, the heat pump and the car's charging in one
energy view, so I see where the power goes and can use the solar surplus.

#### Acceptance criteria

1. Home Assistant's Energy dashboard SHALL show solar production, grid
   import and export, house consumption and EV charging power, from the
   inverter, meter, charger and charge controller integrations, read
   locally where the device allows it.
2. THE heat pump's power or energy and its operating mode SHALL be shown
   when its integration provides them.
3. A cloud integration with a request quota SHALL poll at an interval that
   uses at most half the daily quota, so manual changes still go through.
   (check: the interval and the quota in the feasibility table)
4. THE energy readings SHALL be kept by the recorder for 30 days and as
   long-term statistics (hourly) beyond, in the existing recorder database.

### Requirement 5: Plants watered on time

**User story:** As a household member, I want to see which plants need
water or light and be reminded, and the watering device to run safely on
its own.

#### Acceptance criteria

1. EVERY monitored plant SHALL be one device in Home Assistant with its
   moisture, light and battery readings and its thresholds; one overview
   SHALL list them, the ones out of range first.
2. WHEN a plant's moisture has stayed below its threshold for 6 hours, THE
   household member assigned to watering SHALL get one household
   notification per plant per day, sent between 08:00 and 20:00 (Zurich).
3. THE smart plug of the watering device SHALL switch off on its own after
   a maximum run time set on the plug or the device, and SHALL start off
   after a power cut, so a stopped Home Assistant can never leave water
   running.
4. A sensor that has not reported for 24 hours, or whose battery is below
   15%, and a robot vacuum consumable that is due, SHALL appear in a weekly
   household notification of devices to look at, not one notification per
   device.

### Requirement 6: Cameras recorded locally

**User story:** As a household member, I want the cameras recorded at home,
with a notification when a person is seen, and no footage in a vendor's
cloud.

#### Acceptance criteria

1. EVERY camera SHALL stream over RTSP or ONVIF on the LAN, with its
   vendor cloud, remote access and peer-to-peer features turned off.
2. THE NVR SHALL record every camera to a dedicated NAS dataset with a
   quota, keep motion recordings for 7 days, alerts for 30 days and
   detections for 14 days, and SHALL NOT copy footage off-site.
3. WHEN the NVR detects a person on a camera while the house is in away
   or night mode, THE household members SHALL get one household
   notification with a snapshot, at most one per camera per 5 minutes.
4. THE NVR SHALL have no route (no HTTPRoute, no LoadBalancer); the
   household watches cameras through Home Assistant, and the operator opens
   the NVR UI with `kubectl -n frigate port-forward svc/frigate 5000`
   through the tailnet API proxy. (a deliberate exception to "UIs public
   behind SSO", reason in [design](design.md#decided-defaults))
5. THE cameras and the doorbell SHALL have no internet access: a fixed
   address in `192.168.1.21`-`.49` with no gateway and no DNS server set on
   the device, cloud, P2P and UPnP off, and no port forward. (check: from
   the camera's own network test, or its log, an internet address fails)
6. EACH camera SHALL also record to its own storage card, so an NVR or
   Wi-Fi outage loses events in Home Assistant but not footage.
7. EACH camera position SHALL pass a 24-hour stream test on Wi-Fi before
   the next camera is bought: fewer than 5 reconnects of the record stream
   and the detection stream at its configured frame rate, from Frigate's
   camera statistics. ([design](design.md#wi-fi-for-cameras-and-devices))

### Requirement 7: The alarm system stays the alarm

**User story:** As a household member, I want the alarm's state and sensors
in Home Assistant without making the alarm depend on it.

#### Acceptance criteria

1. THE alarm panel SHALL keep its own sirens, monitoring and app; Home
   Assistant SHALL read its state (armed, disarmed, triggered) and, where
   the panel reports them, its door, window and motion sensors.
2. IF the panel offers a local protocol (SIA DC-09, a local API, or Zigbee
   sensors), THEN Home Assistant SHALL use it; a cloud-only panel SHALL be
   read through its cloud integration or not at all, as the feasibility
   table says.
3. Home Assistant SHALL NOT arm or disarm the panel. IF the panel's
   integration exposes arm or disarm actions, THEN no dashboard or
   automation uses them, and enabling them is a new issue.
4. WHEN the alarm triggers, THE household members SHALL get a critical
   household notification (sound through silent mode).

### Requirement 8: One Home dashboard, one dashboard per area

**User story:** As a household member, I want one screen that tells me how
the house is, and a tap to the details.

#### Acceptance criteria

1. THE main Home dashboard SHALL be the default for every user and SHALL
   show: alarm state, who is home, open doors and windows, lights on,
   heating mode, indoor temperature and the room with the highest CO2,
   power now (solar, grid, house, car), the car's charge mode, the garage
   door, plants needing water, mail waiting, the robot vacuum's state, the
   last camera or doorbell event and the weather; each tile SHALL link to
   its area's dashboard.
2. THERE SHALL be one dashboard each for lights, climate and energy
   (rooms, heating, solar, car), plants, security (cameras, doorbell,
   garage door, alarm, doors) and media (the vacuum, and the TV if it is
   integrated), plus a wall tablet dashboard and an admin-only system
   dashboard.
3. THE dashboards SHALL be readable on a phone in portrait and on the wall
   tablet in landscape without horizontal scrolling.
4. THE dashboards SHALL live in Home Assistant's storage, kept by its
   backups, not in git: they name rooms and devices. (decided default in
   design)

### Requirement 9: Phones and a wall tablet

**User story:** As a household member, I want Home Assistant on my phone
with the same login as everything else, and a tablet on the wall that
anyone at home can use.

#### Acceptance criteria

1. EACH household member SHALL use the Home Assistant companion app with
   server `https://home.lilalala.com` and log in through Keycloak; only the
   group `HomeAssistantAdmins` gets admin. (as today, media-home 5.2)
2. THE wall tablet SHALL log in once as a dedicated local, non-admin Home
   Assistant user with a generated password kept in the operator's password
   manager, show the wall tablet dashboard in kiosk mode, and stay logged in
   through its refresh token.
3. THE wall tablet SHALL keep its screen on only between 07:00 and 22:00
   (Zurich), or while motion is seen in front of it, and its charging SHALL
   be cycled through a smart plug to keep the battery between 20% and 80%.
4. THE wall tablet SHALL run a browser engine the current Home Assistant
   frontend supports; IF the existing tablet cannot, THEN it is replaced
   (purchase in phase 2).

### Requirement 10: Household notifications are not operator pages

**User story:** As the operator, I want household events on the household's
phones and platform problems on my pager, never mixed.

#### Acceptance criteria

1. Household notifications SHALL go only through the companion app's
   `notify` actions, to per-purpose notify groups (security, plants,
   house, admins), never to the operator's ntfy topic. (check: from the
   Home Assistant pod, `curl -m 5 https://ntfy.sh` fails once the `home`
   egress allow-list, #709, is enforced)
2. Alertmanager SHALL NOT route a house event (a plant, a door, a camera);
   platform problems of Home Assistant itself (down, backups, probes) stay
   operator pages as today.
3. Camera, doorbell and sensor notifications SHALL be rate-limited
   (Requirements 5.2, 5.4, 6.3, 14.3, 15.2, 19.2, 21.3) so no phone gets near the
   companion app's 500 pushes per day.
4. Only the alarm and safety sensors (smoke, water leak, if any are added)
   SHALL use critical notifications.

### Requirement 11: What the household needs works when the cluster is down

**User story:** As a household member, I want the doorbell, the garage
door, the vacuum, the lamps and the heating to work whatever happens to the
homelab; the extras can wait for Home Assistant.

#### Acceptance criteria

1. WITH Home Assistant scaled to 0 for 10 minutes, THE lamps, indoor and
   outdoor, SHALL switch from their switches and the bridge's app; THE
   heating SHALL follow its schedule and change its setpoint from its own
   controls; THE doorbell SHALL ring its chime and show and talk to the
   visitor in its own app on the LAN; THE garage door SHALL open and close
   from its wall button and remotes; and THE robot vacuum SHALL run from
   its own schedule and app. (test: the
   [fallback test](design.md#fallback-test), once per phase, on a weekday;
   the result in the PR)
2. THE functions of 11.1 SHALL NOT depend on an automation that exists only
   in Home Assistant; they run on their device or controller, and Home
   Assistant only adds to them.
3. Everything else (motion automations beyond the bridge, camera and
   doorbell notifications, plants, the mailbox, the dashboards, the wall
   tablet, solar-surplus charging, the TV) MAY stop while Home Assistant or
   the cluster is down.
4. AFTER Home Assistant comes back, ITS entities SHALL match the devices'
   state within 5 minutes without a manual step.

### Requirement 12: Devices added later fit without a redesign

**User story:** As the operator, I want to know what to buy next year so it
works locally with this setup.

#### Acceptance criteria

1. A new battery or mains sensor, plug, switch or blind motor SHALL be
   Zigbee (through Zigbee2MQTT) unless the feasibility table names a reason;
   Matter and Thread devices are not used until a Matter server design
   exists (decided default in design).
2. A new device with a Wi-Fi or Ethernet connection SHALL have an official,
   local Home Assistant integration or run ESPHome; cloud-only devices are
   not bought.
3. A new camera SHALL be an outdoor model on Wi-Fi (5 GHz capable) with
   mains power, support RTSP and ONVIF, H.264 or H.265, a second
   low-resolution stream for detection and a storage card, and work with
   its vendor cloud off. Battery cameras are not bought: they do not stream
   continuously.

### Requirement 13: Backups and privacy

**User story:** As the operator, I want every piece of configuration
restorable and no footage or inventory where it does not belong.

#### Acceptance criteria

1. THE Home Assistant config volume (integrations, dashboards, users,
   automations), the recorder, `zigbee2mqtt-data` and `evcc-data` SHALL be
   in the nightly restic snapshot and the CNPG backups, under the 24 h
   freshness rule.
2. THE NVR's configuration SHALL be a SOPS-encrypted Secret
   (`apps/secrets/frigate-config.sops.yaml`, key `config.yml`), mounted
   read-only, with generic camera names (`cam1`...`camN`); RTSP and MQTT
   credentials come from `FRIGATE_*` environment variables of the same
   Secret. Only non-camera settings (detector, retention) may be plain in
   `apps/frigate/`. The read-only mount is what turns editing the config
   from Frigate's UI off. THE event database (PVC `frigate-data`) and the
   recordings SHALL NOT be backed up; the config is the Secret.
3. No camera image, recording, device model, count or location SHALL appear
   in git, a pull request, an issue or a log shipped off the cluster.
4. A restore of the Home Assistant config volume from restic SHALL bring
   back the dashboards and integrations. (test: once, into a throwaway pod,
   before the spec closes)

### Requirement 14: Climate in every room

**User story:** As a household member, I want the temperature, humidity
and CO2 of every room, and a nudge to air a room before the air gets bad.

#### Acceptance criteria

1. EVERY indoor space of the inventory file, heated or not, SHALL have a
   sensor for temperature and humidity, and every
   living room, bedroom and office one for CO2 with an NDIR cell;
   estimated CO2 (eCO2, from VOC) does not count. THE corner where the
   cluster and the NAS stand SHALL have a temperature and humidity sensor
   too.
2. THE climate dashboard SHALL show each room's three readings and its
   24-hour history; the main Home dashboard shows the room with the highest
   CO2.
3. WHEN a room's CO2 stays above 1200 ppm for 15 minutes between 07:00 and
   22:00 (Zurich), THE house group SHALL get one household notification to
   air it, at most one per room per 2 hours; WHEN a room's humidity stays
   above 65% for 24 hours, one mould-risk notification per room per day.
4. THE readings SHALL be kept like the energy readings (Requirement 4.4).
5. THE server-corner temperature SHALL feed the homelab's alerting:
   Prometheus scrapes it from Home Assistant's `/api/prometheus`, and a
   rule pages the operator (`action: human`) WHEN it stays above 35 °C for
   15 minutes; above 30 °C for 30 minutes is an INFO event on the Grafana
   dashboards. A silent sensor is not a page: Home Assistant down already
   is one. (the rule and its test in `tests/`)

### Requirement 15: A video doorbell

**User story:** As a household member, I want to see who is at the door on
my phone and on the wall tablet, and talk to them from my phone at home.

#### Acceptance criteria

1. THE doorbell SHALL be a camera under Requirements 6 and 12.3 with a
   speaker and a microphone for two-way talk, on mains power (its bell
   wiring or a plug-in supply), and SHALL report a press through a local
   integration or ONVIF event; a doorbell that reports presses only
   through its cloud, needs a subscription, or whose app cannot reach it
   by its local address with P2P and cloud off, is not bought.
2. WHEN the doorbell is pressed, THE house group SHALL get one household
   notification with a snapshot within 5 seconds, at most one per
   30 seconds, THE wall tablet SHALL show its live view for 60 seconds,
   and, if the TV is integrated (Requirement 17), playback on the TV SHALL
   pause.
3. THE doorbell SHALL ring its own chime, and its vendor app SHALL show the
   visitor and talk to them over the LAN, without Home Assistant and
   without a cloud account. Two-way talk is the vendor app's, on the LAN.
   Talk from the wall tablet or from away needs WebRTC through Frigate's
   go2rtc, a new issue if wanted
   ([design](design.md#suggestions)).
4. A second doorbell at a second entrance, or the doorbell moved there, is the
   operator's choice after the first one is installed
   ([design](design.md#what-the-operator-decides)); it follows the same
   criteria.

### Requirement 16: Outdoor lights that follow motion

**User story:** As a household member, I want the outdoor lights to come
on when someone walks up at night, reliably, and to replace the current
outdoor lights.

#### Acceptance criteria

1. EVERY current outdoor fixture SHALL be replaced, and the new outdoor
   points of the inventory file SHALL be added, following the replacement
   plan in
   [design](design.md#outdoor-lighting); each outdoor light SHALL be on
   the lights' bridge or behind a Zigbee relay, and SHALL keep working from
   its wall switch.
2. EACH outdoor motion sensor SHALL be paired with the lights' bridge or
   bound directly to its lights over Zigbee, so motion turns them on
   between sunset and sunrise without Home Assistant, and off after
   3 minutes without motion.
3. Home Assistant SHALL add camera person detections as a second trigger at
   night, and SHALL include the outdoor lights in the vacation mode's
   presence simulation.

### Requirement 17: TV and streamer (optional)

**User story:** As a household member, I want the TV in the same app if it
is easy, and the lights to follow what we watch.

Optional (operator, 2026-11-05): the household is fine with the remotes or
the TV vendor's app, and has no preference between the TV's own apps and
the streamer. Task 11 is done when these criteria hold for the TV, or
skipped with the reason in the feasibility table.

#### Acceptance criteria

1. IF the TV has a local integration that works by IP, THEN Home Assistant
   SHALL read and control it: power, volume, source, playback state and
   play or pause. The streamer is added the same way only if the
   household uses it.
2. WHEN playback starts on the TV after sunset, THE TV's room SHALL switch
   to a film scene; WHEN it stops for 5 minutes, the previous scene comes
   back.
3. THE remotes, the vendor app and the TV's own apps SHALL keep working
   without Home Assistant.

### Requirement 18: Robot vacuum

**User story:** As a household member, I want the vacuum to run when
nobody is home and to tell us when it needs care.

#### Acceptance criteria

1. Home Assistant SHALL show the vacuum's state, battery and consumables
   through its integration.
2. WHEN the house mode becomes `away` on a day the vacuum has not run, THE
   vacuum SHALL start a full clean; it SHALL NOT start in night mode or
   while someone is home, and SHALL return to its dock when someone
   arrives.
3. A due consumable or a full bin SHALL go into the weekly digest
   (Requirement 5.4), not its own notification.

### Requirement 19: Mailbox sensor

**User story:** As a household member, I want to know when mail has
arrived.

#### Acceptance criteria

1. A sensor on the mailbox SHALL report each delivery; mail stays
   "waiting" on the main Home dashboard until the mailbox is emptied or a
   household member clears it from the dashboard.
2. THE house group SHALL get one household notification per day for the
   first delivery.
3. THE sensor SHALL run on a battery for at least a year, over Zigbee,
   with an outdoor-rated Zigbee router (repeater) near the mailbox where
   the link quality needs one; over Wi-Fi with ESPHome in deep sleep only
   if Zigbee still does not reach.

### Requirement 20: The car charges on solar surplus

**User story:** As the operator, I want the car to charge from the solar
surplus by default, and to charge fast when I ask.

#### Acceptance criteria

1. THE charge controller SHALL run as app `evcc` in namespace `evcc`, read
   solar production, grid power and the charger, and set the charging
   current; when the charger cannot be controlled, through the car, over a
   local Bluetooth proxy. No paid vehicle API or cloud command proxy SHALL
   be used (Requirement 1.5). THE evcc templates used (charger, vehicle,
   meters) SHALL need no sponsor token; the evcc docs' template page says
   so for each. IF a needed template requires one, THEN the operator
   decides in chat between a one-time sponsorship (a purchase,
   Requirement 1.4) and not using it.
2. THE modes SHALL be off, solar only, minimum plus solar, and fast;
   solar only is the default. A household member sets the mode from Home
   Assistant or from the charge controller's UI at `charge.lilalala.com`,
   behind Keycloak for `admins` and `household`
   ([household-access-groups](../household-access-groups/)).
3. Grid power SHALL come from the inverter's meter or the grid meter's
   customer interface, updated at least every 10 seconds; IF neither can,
   THEN a three-phase grid meter is bought (phase 2).
4. THE charge controller's configuration SHALL be a SOPS-encrypted Secret
   (`apps/secrets/evcc-config.sops.yaml`); its state is on the PVC
   `evcc-data`, backed up (Requirement 13.1).
5. Charge sessions and charging power SHALL reach Home Assistant through
   MQTT, and the car's charge state SHALL be on the energy dashboard.
6. WITH the charge controller stopped, THE car SHALL still charge when
   plugged in, at the current it was last given or the one set in the
   car's app.

### Requirement 21: Garage door

**User story:** As a household member, I want to see whether the garage
door is open and open it from my phone, and the door to work as today
whatever happens to Home Assistant.

#### Acceptance criteria

1. THE garage door opener kit the operator bought SHALL be connected in
   parallel with the opener's wall button, and Home Assistant SHALL read
   its open or closed state and open and close it through a local
   integration (its own local API, ESPHome or MQTT). A kit that works only
   through a cloud is not used for control. (the feasibility table row)
2. THE wall button and the remotes SHALL keep working without Home
   Assistant and without the kit. (Requirement 11.1)
3. WHEN the door has been open for 30 minutes, or is open at 22:00
   (Zurich), THE house group SHALL get one household notification; Home
   Assistant SHALL NOT close the door on its own.
4. THE open and close actions SHALL be on the household's phones only: the
   wall tablet user and dashboards shown on the tablet SHALL show the
   state without the control.
5. ANY authenticated Home Assistant user who has the control SHALL be
   able to open and close the door from anywhere, with no location check.
   The login of those users SHALL require OTP, and every open SHALL send
   one household notification naming who opened it. (check: the PR shows
   an open from a phone off the LAN and its notification)
