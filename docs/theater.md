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
AV1 (TRaSH "Golden Rule HD" and "Unwanted Formats" groups). TRaSH defaults are
synced, plus the deviations below. VFF/VFQ ranking inside French releases stays
at the TRaSH default. The Sonarr English profile is WEB only; TRaSH has no
English Bluray + WEB 1080p profile for Sonarr.

### Deviations from TRaSH

Deliberate operator preferences, set in the `custom_formats` blocks of
`apps/theater/recyclarr.yaml`. They use TRaSH custom formats by `trash_id` and
override only the score, in both profiles of both apps:

| Custom format | TRaSH default in these profiles | Score here |
|---|---|---|
| `x264` | 0 | +50 |
| `x265 (HD)` | -10000 | -10000 (pinned) |
| `5.1 Surround`, `6.1 Surround`, `7.1 Surround` | 0 | +100 |

The bonuses are preferences, not blocks: a release without them still
qualifies, and they stay below a release group tier step plus the streaming
service bonus. They also act as upgrades: a 5.1 release of the same tier
replaces a stereo file, from public indexers only (see Indexers).

Check the scores after a sync (read-only; prints one line per profile and
custom format):

```sh
kubectl -n theater exec deploy/radarr -c radarr -- sh -c '
  K=$(grep -o "<ApiKey>[^<]*" /config/config.xml | cut -d">" -f2)
  curl -s -H "X-Api-Key: $K" http://127.0.0.1:7878/arr/radarr/api/v3/qualityprofile' \
  | jq -r '.[] | .name as $p | .formatItems[]
      | select(.name | test("x26[45]|Surround")) | "\($p) \(.name) \(.score)"'
```

Expected: `HD-Original` and `HD-Kids-FR` show the scores in the table. For
Sonarr use `deploy/sonarr`, container `sonarr`, port `8989`, path
`/arr/sonarr`.

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
- Public indexers use the profile `Standard` (everything on). They also carry
  the tag `books`, which is what Prowlarr's `LazyLibrarian` application syncs;
  a non-public indexer must never get it.
- YGG stays disabled. Its definition is no longer shipped by Prowlarr, so it
  cannot be edited until it is re-added.

Prowlarr keeps this in its database, not in git. Check it after adding an
indexer (read-only):

```sh
scripts/check-indexers.sh
```

Expected: one `ok` line per indexer, exit 0. A `FAIL` line names an enabled
private or semi-private indexer on an automatic profile or with the `books` tag; fix it in Prowlarr
(Indexers, edit, Sync Profile `Manual only`).

qBittorrent has no global ratio or seeding-time limit and the categories
inherit that, so torrents seed until removed. Queueing is on with 10 active
torrents: beyond that, seeds are queued and stop uploading.

## Why it is like this

- TRaSH profiles by `trash_id`, not hand-built: the guides maintain the release
  group tiers and scores, and recyclarr re-applies them nightly. The alternative,
  custom profiles in the UI, drifts and is not in git.
- The x264 and multichannel-audio preferences are score overrides on TRaSH
  custom formats, not custom formats of our own: TRaSH keeps maintaining the
  matching rules, and the deviation is a few lines in git.
- Two profiles only: one per audio need. Per-title choice stays manual because
  "animated" is not the same as "for children" and a bulk rule would get it
  wrong.
- Private trackers are manual only: their rules punish automatic grabs.
  Public indexers carry the automatic search.
