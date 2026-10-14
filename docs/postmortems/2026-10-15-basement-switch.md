# 2026-10-15: LAN outage, cluster lost its storage

## Summary

For about 11 minutes the nodes lost their network links to the NAS and to
each other. Every iSCSI filesystem shut down, one control plane hung on
storage I/O, and several pods stayed stuck after the network came back. Full
recovery took until 06:17Z. The cause is the unmanaged switch in the basement
that carries the Turing Pi and the NAS.

| | |
| --- | --- |
| Start / end | 2026-10-15 01:13Z / 06:17Z (network back at about 01:24Z) |
| Detected by | the operator's machine could not reach the nodes during planned work; no alert was delivered (push notifications did not exist yet) |
| Apps affected | every app with an iSCSI volume, at different times |
| Budget spent | not recorded per app |
| Data lost | none found: database row counts and Immich asset counts matched, 20 of 20 sampled originals present |
| Trigger | 25% or more of a monthly budget; an automated action (automatic rollback) acted on the outage |

The cluster then ran on three Ubuntu control planes; the fourth node had been
removed from it and ran a single-node Talos test cluster.

## Impact

- 01:13Z to about 01:24Z: no app reachable from the LAN or the internet.
- After the network returned: pods whose iSCSI filesystem had shut down kept
  failing until they were deleted and restarted (01:45Z and 06:11Z), so some
  apps stayed down for hours.
- Noise: Argo CD opened three GitHub issues for failed syncs between 01:22Z
  and 01:24Z, and automatic rollback opened a revert pull request for the
  newest merge. The revert was closed unmerged, the issues closed.

## Timeline

| UTC | Event |
| --- | --- |
| 01:12 | last action of the Talos test work: a read-only NFS listing from the test node |
| 01:14:53–55 | all three control planes log iSCSI "No route to host" to the NAS within the same two seconds |
| 01:15:22 | one control plane's link goes down and up |
| 01:17:03 | another control plane's link comes back up |
| 01:17–01:21 | the operator's machine reaches the router but not the nodes, the BMC or the NAS |
| 01:22–01:24 | Argo CD reports failed syncs; issues and an automatic revert are opened |
| about 01:24 | network back |
| 01:36 | the hung control plane is power-cycled through the BMC (its console showed XFS log I/O errors) |
| 01:45 | stuck pods deleted per [runbooks/cold-start.md](../runbooks/cold-start.md) |
| 06:11 | remaining stuck pods deleted |
| 06:17 | three nodes Ready, every Application Synced and Healthy, every CNPG cluster healthy, smoke suite green |

## Cause

Confirmed: the consumer switch in the basement, which connects the Turing Pi
nodes and the NAS, dropped links. The router and the other switch upstream
stayed up, which is why the router answered and nothing behind the basement
switch did.

The Talos test node was the first suspect, because it was being worked on at
the time, and was ruled out:

- its configuration held no virtual IP and no LoadBalancer or L2 announcement
  addresses, only its own address;
- ARP for the API VIP and the Gateway address resolved to the Ubuntu nodes
  throughout;
- its own link never dropped, and it sent about 16 thousand packets in total
  (no storm).

From the switch to the user-visible failure: iSCSI sessions lost their path,
XFS shut the filesystems down, and the pods on them could not recover on
their own when the path returned. A control plane blocked on storage I/O hung
until it was power-cycled.

## What went well

- The data was intact. Backups and the restore checks were not needed.
- Ruling out the test node was quick, from its configuration, ARP and its
  link history.
- The cold-start runbook covered the stuck pods.

## What went badly

- No notification reached anyone; the outage was found by chance.
- Automatic rollback treated an outage as a bad deploy and opened a revert.
- One GitHub issue per failed Application: noise that stayed open after
  recovery.
- An unmanaged switch has no logs, so the cause rests on the link timings and
  the operator's knowledge of that switch.

## Where we got lucky

- The outage happened at night, during planned work, with someone watching.
- The automatic revert was not merged.

## Action items

| Action | Type | Status |
| --- | --- | --- |
| Automatic rollback holds back when several apps fail at once, a node is NotReady or the NAS is unreachable (`scripts/ci/auto-rollback-guard.sh`) | prevent | done |
| Failed deploys are alerts that resolve on their own, not GitHub issues ([observability.md](../observability.md#argo-cd-alerts)) | mitigate | done |
| Push notifications to the phone through ntfy, and an external heartbeat ([observability.md](../observability.md#notifications)) | detect | done |
| `HomelabNASUnreachable` and `HomelabNodeNotReady` alerts | detect | done |
| An alert on node link flaps and lost iSCSI sessions | detect | open |
| Replace the basement switch with a managed one (logs, port counters), on a UPS | prevent | open |
