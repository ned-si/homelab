# Subtitles keep switching themselves off

Symptom: subtitles work, then stop mid-playback. Switching track or seeking
backwards brings them back. Reported on Plex; not seen on Jellyfin with the same
files.

## Diagnose before changing anything

The instinct is that the subtitle files are misnamed. Rule that in or out first,
because it changes the fix completely.

**A naming problem is static.** If `Movie.en.srt` is not matched, the track never
appears in the list — on every play, forever. It cannot work and then stop, and
seeking cannot repair it.

**Seeking restarts the transcode.** It makes the server tear down the session and
build a new one. When "restart the transcode" is the cure, the transcode is the
fault, not the file.

Which points at **image-based subtitles forcing a burn-in**. PGS (Blu-ray rips)
and VOBSUB (DVD rips) are bitmaps, not text. No client can render them, so the
server composites them into the video, which forces a full decode → overlay →
encode cycle. Text subtitles (SRT/ASS) are handed to the client as text and cost
nothing.

### Four checks that separate the two theories

Run during a failure. Ten minutes.

| # | Check | Burn-in | Naming |
|---|---|---|---|
| 1 | Does it happen on **SRT/ASS** files, or only **PGS/VOBSUB**? | only bitmap | either |
| 2 | Does Plex's Activity dashboard say **Transcode**, and mention burning subtitles? | yes | no, Direct Play |
| 3 | Is it worse on **4K/HEVC** than 1080p H.264? | yes | no difference |
| 4 | Is the Plex container at its CPU limit while it happens? | yes | no |

```sh
# 4 — watch the container during playback
kubectl -n theater top pod -l app.kubernetes.io/name=plex

# 1 — what subtitle tracks does a given file actually carry?
kubectl -n theater exec deploy/jellyfin -- \
  /usr/lib/jellyfin-ffmpeg/ffprobe -v error \
    -select_streams s -show_entries stream=index,codec_name:stream_tags=language \
    -of csv=p=0 "/media/<path to file>"
```

`codec_name` of `hdmv_pgs_subtitle` or `dvd_subtitle` is bitmap. `subrip`, `ass`
or `mov_text` is text.

## Why this cluster is unusually bad at burn-in

Four Turing RK1 modules, i.e. RK3588. The SoC has a capable video engine —
hardware decode and encode plus HDR tone mapping — and **Plex cannot use it.**
Plex supports Quick Sync and NVENC; Rockchip support is a long-standing open
feature request. So every Plex transcode here is software, on Cortex-A76 cores.

Jellyfin *can* use it, via `jellyfin-ffmpeg`'s Rockchip MPP/RGA support. That is
not wired up in this repo yet (it needs the Rockchip devices passed into the
container and a kernel that exposes them) and is tracked separately.

This is why the same file behaves differently in the two servers.

## Fix, cheapest first

### 1. Bazarr — the actual fix

Bazarr fetches **text** subtitles for everything Sonarr and Radarr manage, and
names them the way both servers expect. No bitmap, no burn-in, no transcode,
and the naming concern disappears as a side effect. Its manifest is written
(`apps/theater/bazarr.yaml`) but not deployed: adding it to
`apps/theater/kustomization.yaml` is its own pull request.

After it is running:

1. Settings → Providers: add at least one. OpenSubtitles.com needs a free
   account; Podnapisi and Addic7ed do not.
2. Settings → Languages: create a profile, mark it default. Enable
   **"Use Embedded Subtitles"** so it does not re-download what a file already
   carries as text.
3. Settings → Sonarr / Radarr: the URLs are in-cluster, so
   `http://sonarr.theater.svc.cluster.local:8989` and
   `http://radarr.theater.svc.cluster.local:7878`. API keys come from each app's
   Settings → General.
4. Trigger a sync and check one known-bad file gained an `.srt`.

**No path mapping should be needed** as long as Bazarr mounts the media share at
the same path as Sonarr and Radarr, so the paths they report resolve. If the UI
shows path-mapping errors, the mount is wrong — fix the mount, not the mapping.

### 2. Force text where a file only has bitmap

Some releases only ship PGS. Options, in order of preference: let Bazarr fetch an
external SRT (usually possible); re-acquire in a release that has text subs; OCR
the PGS to SRT with Subtitle Edit (lossy, manual, last resort).

### 3. Hardware transcoding, only if 1 and 2 leave real cases

Plex Pass is present, so hardware transcoding is unlocked — but not on this
cluster, because Plex cannot reach the RK3588 engine. That means separate x86
hardware with Quick Sync or NVENC, and it is worth being precise about what is on
hand:

- **A GTX 970 (Maxwell GM204)** has NVENC H.264 encode but no HEVC encode, and no
  HEVC *decode* either. For HEVC sources it would software-decode on the CPU and
  encode to H.264. Fine for 1080p, struggles with 4K HEVC burn-in.
- **An Intel N100/N150 mini PC** has Quick Sync, handles HEVC 10-bit and AV1
  decode, costs less and draws about a tenth of the power.

Either way this is the expensive fix for a problem Bazarr solves for free, which
is why it is third.

## Client notes

**Samsung Tizen TV.** Plex is a first-class store app; Jellyfin's Tizen client is
a community build that needs sideloading. That asymmetry is a real reason to keep
Plex as the TV client even where Jellyfin handles media better, and it is why
"just use Jellyfin" is not the answer here.

**Do not put Plex or Jellyfin behind the SSO proxy.** TV clients cannot complete
an OIDC redirect. They keep their own authentication — see the header of
`apps/theater/sso.yaml`.
