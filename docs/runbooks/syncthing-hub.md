# Syncthing hub and spoke

The in-cluster Syncthing (namespace `syncthing`, GUI
`https://syncthing.lilalala.com`) is the only hub. Every other device syncs
each folder with the hub alone; no two devices know each other. A device
added, removed or compromised then changes one link, on the hub, instead of
one on every device.

The hub's settings live in its own `config.xml` on the PVC `syncthing-pvc`,
not in git: the repository only removes the GUI login
(`apps/syncthing/statefulset.yaml`). This page sets them by hand and checks
them.

Preconditions:

- The hub GUI, as a member of the Keycloak group `admins`.
- For the checks: `kubectl` over the tailnet
  ([remote-access.md](../remote-access.md)) and `jq`.
- On each device: its Syncthing GUI (desktop: `http://127.0.0.1:8384`;
  Android: the Syncthing-Fork app, same settings on the device and folder
  screens).

## The rules

| Where | Setting | Value |
| --- | --- | --- |
| Hub, every remote device, Sharing tab | Introducer | off |
| Hub, every remote device, Sharing tab | Auto Accept | off |
| Hub, every folder, Sharing tab | devices | the devices that need the folder |
| Device, Remote Devices | devices | the hub only |
| Device, the hub, Sharing tab | Introducer | off |
| Device, every folder, Sharing tab | devices | the hub only |

Syncthing never accepts a new device by itself: an unknown device shows as a
prompt in the GUI until someone adds or ignores it. A device skips that
prompt only when someone adds it by hand or an introducer brings it, which
is why Introducer stays off on both sides.

Introducer on the device's entry for the hub would make the hub introduce
every other device to it: the mesh this layout avoids.

## Discovery and relays

Both stay on, on the hub and the devices. They find an address for a device
that is already in the list and never add one, so they do not change who
talks to whom.

- Global discovery is how a device off the LAN finds the hub: the WAN address
  is dynamic ([wan-ip-change.md](wan-ip-change.md)).
- Relays are the fallback when a direct connection fails, for example a phone
  behind carrier NAT. The router forwards 22000 TCP and UDP to
  `192.168.1.201`, so most connections are direct (`tcp-client` or
  `quic-client` on the hub).
- The hub logs an IPv6 global-announce error (`network is unreachable`): the
  cluster has no IPv6, and the IPv4 announce works.
- Optional, on a device that lives on the LAN: hub, Edit, Advanced, Addresses
  `tcp://192.168.1.201:22000, dynamic`, so it dials the hub without
  discovery.

## 1. Check the hub

```sh
export KUBECONFIG=<admin-kubeconfig>
st() {
  kubectl -n syncthing exec syncthing-0 -c syncthing -- sh -c '
    k=$(sed -n "s:.*<apikey>\(.*\)</apikey>.*:\1:p" /var/syncthing/config/config.xml)
    wget -q -O- --header "X-API-Key: $k" "http://127.0.0.1:8384$1"' _ "$1"
}
st /rest/config/devices \
  | jq -r '.[] | "\(.name)\tintroducer=\(.introducer)\tautoAcceptFolders=\(.autoAcceptFolders)"'
st /rest/system/connections \
  | jq '[.connections[] | select(.connected)] | length'
```

The API key is read inside the pod and never leaves it. Expected: one line
per device, all with `introducer=false autoAcceptFolders=false` (the hub's
own entry included), then the number of connected devices.

If a line shows `true`: GUI, Remote Devices, that device, Edit, Sharing,
untick Introducer and Auto Accept, Save. No restart is needed. Run the check
again.

## 2. On each device

Before you start, the device and the hub show every shared folder as Up to
Date. Removing a remote device or unsharing a folder deletes no files.

1. Note the hub's device ID: hub GUI, Actions, Show ID.
2. Remote Devices: the hub is listed and Connected. If it is missing, Add
   Remote Device with that ID, then accept the device prompt on the hub.
3. Each folder, Edit, Sharing: tick the hub if it is not ticked, Save. The
   hub accepts no folder by itself: if it shows a prompt to share this
   folder with this device, accept it (Add for a folder the hub does not
   have, Share for one it has), keep the folder ID, and set its path under
   `/var/syncthing`. Wait until the hub shows the folder Up to Date for this
   device.
4. Each folder, Edit, Sharing: untick every device that is not the hub, Save.
   Do this only when the hub shares the folder with every device that needs
   it (hub GUI, the folder, Shared With), or the devices not on that list
   stop getting it.
5. Remote Devices, each device that is not the hub: Edit, Remove, Yes. A
   former peer not done yet still dials this device and then shows as a
   new-device prompt: ignore it, do not Add it.
6. Remote Devices, the hub: Edit, Sharing, untick Introducer and Auto Accept,
   Save.
7. Settings, Connections: Global Discovery and Enable Relaying on. Save.

Expected: Remote Devices lists the hub alone, Connected, and every folder is
Up to Date. On the hub, the device is Connected.

Do one device at a time. When every device is done, run step 1 again: the
connected count is at least what it was before.

## 3. A device that should not be there

A device that is retired or unknown: hub GUI, Remote Devices, that device,
Edit, Remove. It can no longer connect; if it tries, the hub shows a prompt,
and Ignore keeps it quiet.

## Rollback

- Hub: tick Introducer or Auto Accept again on that device (the values before
  are in the step 1 output you kept).
- Device: Add Remote Device with the removed peer's ID, and tick it again in
  each folder's Sharing tab. Both sides must add each other.
