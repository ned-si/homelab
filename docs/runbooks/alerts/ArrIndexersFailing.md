# ArrIndexersFailing

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/arr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/arr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prowlarr reports indexers that have failed for more than 6 hours
(`source="IndexerLongTermStatusCheck"`) or that have no definition any more
(`IndexerNoDefinitionCheck`): usually an expired login or cookie, a locked
account, or a site that is gone. Searches skip them.

## Confirm

`https://theater.lilalala.com/arr/prowlarr` → System → Status names the
indexers. From the Mac:

```sh
q 'prowlarr_system_health_issues == 1'
scripts/check-indexers.sh
```

Expected while it fires: the health source at `1`. `check-indexers.sh`
checks the private-indexer policy (exit 0 when it holds), not the failures.

## Fix

1. Expired login or cookie: update the credentials in Prowlarr → Indexers →
   the indexer → Edit, then Test.
2. A locked account or a tracker you cannot reach: disable the indexer
   (Edit → Enable off) until access is back.
3. A site that is gone, or no definition: delete the indexer.
4. Keep the policy of [theater.md: Indexers](../../theater.md#indexers) for
   private trackers, and run `scripts/check-indexers.sh` afterwards.

## Resolved when

System → Status shows no indexer warning and the query returns nothing;
the alert clears within the hour (exportarr scrapes every 5 minutes).

## Links

- [theater.md: Indexers](../../theater.md#indexers)
