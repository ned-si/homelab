# Theater (media stack)

Namespace `theater`: Plex and Jellyfin serve the library; Sonarr (series),
Radarr (movies) and Lidarr (music) pick releases; Prowlarr manages indexers;
qBittorrent downloads. Manifests are in `apps/theater/`.

## Quality profiles

Recyclarr (`apps/theater/recyclarr.yaml`, CronJob `recyclarr-sync`, daily 06:00)
syncs TRaSH Guides profiles, custom formats and scores into Sonarr and Radarr.
Each app has two profiles, TRaSH guide profiles used as published and renamed:

| Profile | Sonarr (TRaSH) | Radarr (TRaSH) | Use |
|---|---|---|---|
| `HD-Original` | WEB-1080p | HD Bluray + WEB | Default: original audio |
| `HD-Kids-FR` | [French MULTi.VF] HD Bluray + WEB (1080p) | [French MULTi.VF] HD Bluray + WEB | Animation and children's titles: French audio required, MULTi preferred |

Both are 1080p without remux, upgrade within 1080p, and penalise x265 (HD) and
AV1 (TRaSH "Golden Rule HD" and "Unwanted Formats" groups). Only TRaSH defaults
are synced; scores are not hand-tuned. Not covered by the guide profiles, so
left at the TRaSH default: a positive x264 score, a 5.1-audio preference, and
VFF/VFQ ranking inside French releases. The Sonarr English profile is WEB only;
TRaSH has no English Bluray + WEB 1080p profile for Sonarr.

Assign `HD-Kids-FR` per series or movie (Edit, Quality Profile). Nothing
reassigns titles automatically.

Profiles are matched by name: recyclarr's state directory is an `emptyDir`, so
every run adopts the profile whose name matches the config. To rename one,
rename it in Sonarr or Radarr first, then in the config.

Preview a config change against the live apps, without writing anything (from
a branch checkout; needs `yq`):

```sh
F=apps/theater/recyclarr.yaml
yq 'select(.kind == "ConfigMap") | .metadata.name = "recyclarr-config-preview"' "$F" \
  | kubectl -n theater apply -f -
kubectl -n theater create job recyclarr-preview --from=cronjob/recyclarr-sync \
  --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].args = ["sync", "--preview"]
        | .spec.template.spec.volumes[0].configMap.name = "recyclarr-config-preview"' \
  | kubectl -n theater apply -f -
kubectl -n theater wait --for=condition=complete --timeout=10m job/recyclarr-preview
kubectl -n theater logs job/recyclarr-preview
kubectl -n theater delete job/recyclarr-preview configmap/recyclarr-config-preview
```

Expected: one `Completed` line per app and no `[ERR]`. A wrong `trash_id` fails
the job.

## Subtitles

Not automated yet. Bazarr's manifest (`apps/theater/bazarr.yaml`) is written
but not rendered. Once it runs, its language profile is French + English, set
in its UI (Settings, Languages): Bazarr keeps profiles in its database, not in
a config file. See [subtitles](runbooks/subtitles.md).

## Indexers

Prowlarr syncs its indexers to Sonarr and Radarr (full sync). Policy: nothing
is grabbed automatically from a private or semi-private tracker, because
automatic grabs break their ratio and hit-and-run rules.

- Private and semi-private indexers use the Prowlarr app profile
  `Manual only` (RSS off, automatic search off, interactive search on). Sonarr
  and Radarr receive them with RSS and automatic search off, so they are only
  used from Interactive Search.
- Public indexers use the profile `Standard` (everything on).
- YGG stays disabled. Its definition is no longer shipped by Prowlarr, so it
  cannot be edited until it is re-added.

Prowlarr keeps this in its database, not in git. Check it after adding an
indexer (read-only):

```sh
scripts/check-indexers.sh
```

Expected: one `ok` line per indexer, exit 0. A `FAIL` line names an enabled
private or semi-private indexer on an automatic profile; fix it in Prowlarr
(Indexers, edit, Sync Profile `Manual only`).

qBittorrent has no global ratio or seeding-time limit and the categories
inherit that, so torrents seed until removed. Queueing is on with 10 active
torrents: beyond that, seeds are queued and stop uploading.

## Why it is like this

- TRaSH profiles by `trash_id`, not hand-built: the guides maintain the release
  group tiers and scores, and recyclarr re-applies them nightly. The alternative,
  custom profiles in the UI, drifts and is not in git.
- Two profiles only: one per audio need. Per-title choice stays manual because
  "animated" is not the same as "for children" and a bulk rule would get it
  wrong.
- Private trackers are manual only: their rules punish automatic grabs.
  Public indexers carry the automatic search.
