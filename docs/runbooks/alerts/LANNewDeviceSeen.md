# LANNewDeviceSeen

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/lan-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/lan-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A device with a fixed vendor MAC (`mac`) answered ARP at `ip` and was not
seen in the 30 days before. That is new hardware on the LAN, not a phone
rotating its private address. The alert resolves by itself after an hour.

## Confirm

```sh
q 'lan_device_present{random_mac="false", mac="<mac>"}'
```

Then find it:

- the router's DHCP client list (`http://192.168.1.1`), which names most
  devices;
- the vendor from the first three bytes of the MAC (an OUI lookup);
- the Homelab / LAN dashboard for when it first answered.

Expected: a device you recognise (a new TV, a guest's laptop, a replaced
node or NAS card).

## Fix

1. Yours: nothing to do. It stays known for 30 days after it was last seen.
2. Not yours: block its MAC on the router, and change the Wi-Fi password if
   it came in over Wi-Fi. When it first answered, and at which addresses:
   `kubectl -n monitoring logs deploy/lan-inventory | grep '<mac>'`
   (`mac first seen since start`).

## Resolved when

You know what the device is. The alert clears an hour after it fired.

## Links

- [observability.md: LAN inventory](../../observability.md#lan-inventory)
