# 2026-10-10: House power loss

## Summary

The house lost mains power for about 30 minutes. Every node, the NAS and the
network went down together and the whole homelab was unavailable. Nothing
reported it: the reboots were found days later in the nodes' boot times, and
the cause was matched to the power loss on 2026-10-13.

| | |
| --- | --- |
| Start / end | 2026-10-10, within 08:17Z–09:02Z (the span of the nodes' reboots) |
| Detected by | nobody at the time; found afterwards from the nodes' boot times |
| Apps affected | all |
| Budget spent | not recorded per app; about 30 minutes of power loss is about 14% of each monthly budget, before recovery time |
| Data lost | none found |
| Trigger | a cluster-wide outage that no alert reported |

The cluster then ran Ubuntu with kubeadm on the same four nodes.

## Impact

Every public and LAN service was down while the power was off, and until the
nodes, the NAS and the apps were back. How long each app took to recover was
not measured.

## Timeline

| UTC | Event |
| --- | --- |
| 08:17–09:02 | the house is without power for about 30 minutes; all nodes reboot in this span |
| not recorded | services back; no notification was sent at any point |
| 2026-10-13 | the simultaneous reboot is investigated; the operator matches it to the power loss |

## Cause

Confirmed: loss of mains power to the house. Nothing in the homelab is on a
UPS, so the nodes, the NAS and both switches lost power at once.

Contributing:

- Alertmanager had no notification receiver, and there was no heartbeat
  outside the cluster, so a dead cluster could not report itself.
- The NAS does not start by itself when power returns; it needs its power
  button ([sre.md](../sre.md#toil-register)). Whether that was needed on this
  day is not recorded.

## What went well

- The nodes and the apps came back without a restore.
- The nightly restic backups to S3 bounded the loss had a volume been damaged.
  Postgres had no off-site WAL archive yet; that came three days later.

## What went badly

- Nobody knew the homelab had been down, and the cause took three days to
  establish.
- Every component shares one power circuit with no buffer.

## Where we got lucky

- No damaged volume or database was found after the unclean shutdown.

## Action items

| Action | Type | Status |
| --- | --- | --- |
| Push notifications to the phone through ntfy ([observability.md](../observability.md#notifications)) | detect | done |
| External heartbeat (healthchecks.io, delivered through ntfy) that alerts when the cluster stops reporting ([observability.md](../observability.md#heartbeat)) | detect | done |
| `HomelabNodeNotReady` and `HomelabNASUnreachable` alerts | detect | done |
| A UPS for the Turing Pi, the NAS and the basement switch, with a clean shutdown when it runs low | prevent | open |
| Start the NAS without its button (UPS, or a relay on the ATX power header) | mitigate | open |
