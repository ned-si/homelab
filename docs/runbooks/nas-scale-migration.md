# Migrate the NAS from TrueNAS CORE to SCALE

Move the NAS (`192.168.1.228`) from TrueNAS CORE 13.0-U6.7 to TrueNAS
Community Edition 25.10.8 in place, on the same hardware, boot SSD and pool
`homelab`, through four manual updates in the web UI: 24.04.2.5, 24.10.2.4,
25.04.2.6, 25.10.8. The same stop flashes the Turing Pi 2 BMC from 2.0.5 to
v2.1.0. The way back to CORE is an image of the CORE boot SSD, taken in the
window. Why it is done this way, and every rule below with its reason:
[the spec](../../.kiro/specs/nas-on-truenas-scale/design.md).

- Time: about 3.5 hours, a weekday from 09:00 Zurich (08:00Z in winter);
  the scale-up (window step 14) must start by 14:00 Zurich.
- Household impact: every app with a NAS volume or a Keycloak login is down
  for the whole window, the SMB share too; every app, the website included,
  is down for about 30 minutes during the BMC step.
- Who: steps marked **operator** are physical or in the TrueNAS UI. The
  others are commands on the Mac, run by the operator or by an agent whose
  brief allows live writes for the window.
- You need: the USB-SATA adapter, a screwdriver, a microSD card, the BMC
  login and the TrueNAS root login (both kept by the owner, not in this
  repository), and `tpi` from the
  [tpi releases](https://github.com/turing-machines/tpi/releases).
- Never: `zpool upgrade`, the UI's "Upgrade Pool" button, or any action on a
  "new pool features" alert, until the rollback window closes 48 hours after
  the window. CORE cannot import the pool after a feature is enabled, and the
  rollback refuses to start.

## Files

The update files go in `~/homelab-backups/nas/updates/`. Each SHA-256 below
was computed on download on 2026-11-16 and matches the `.sha256` file
TrueNAS publishes next to the update file.

| Step | File | Size (bytes) | SHA-256 |
| --- | --- | --- | --- |
| U1 | [`TrueNAS-SCALE-24.04.2.5.update`](https://download.sys.truenas.net/TrueNAS-SCALE-Dragonfish/24.04.2.5/TrueNAS-SCALE-24.04.2.5.update) | 1320603648 | `dfee3b50dd183619ee08714b4abff9158588e3a9c07847bac579cdfa1092f3be` |
| U2 | [`TrueNAS-SCALE-24.10.2.4.update`](https://download.sys.truenas.net/TrueNAS-SCALE-ElectricEel/24.10.2.4/TrueNAS-SCALE-24.10.2.4.update) | 1575714816 | `ac246169f98423475b2eda678013d58bb5c2250c8e3e4ef8b207cf1c88807d6c` |
| U3 | [`TrueNAS-SCALE-25.04.2.6.update`](https://download.sys.truenas.net/TrueNAS-SCALE-Fangtooth/25.04.2.6/TrueNAS-SCALE-25.04.2.6.update) | 1677979648 | `21c8d658b0ac96e4ea88af3fcaca03bcbeb0f41ec05a728536679fcc64f0c902` |
| U4 | [`TrueNAS-SCALE-25.10.8.update`](https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update) | 2003349504 | `c518e5407759686d1ba46512900b887ad4d8f5f7f80e40bc3317bf38b035190d` |

The BMC files go in `~/homelab-backups/bmc-firmware/`, from the
[BMC-Firmware v2.1.0 release](https://github.com/turing-machines/BMC-Firmware/releases/tag/v2.1.0).
The release publishes no checksum: these were computed on download and are
the values to compare with.

| Use | File | Size (bytes) | SHA-256 |
| --- | --- | --- | --- |
| Flash (OTA) | [`tp2-ota-v2.1.0.tpu`](https://github.com/turing-machines/BMC-Firmware/releases/download/v2.1.0/tp2-ota-v2.1.0.tpu) | 39993344 | `2c726062ba535c0a1d6b655bc1e668a712e0e8eb252474089c07ff2c5da1fe3e` |
| Recovery (microSD) | [`tp2-firmware-sdcard-v2.1.0.img`](https://github.com/turing-machines/BMC-Firmware/releases/download/v2.1.0/tp2-firmware-sdcard-v2.1.0.img) | 57819136 | `28247398f3a8415a4759f9c3ecf4956328009968bf5e5782df75728e24ab9549` |

Download again (resumes a partial file) and check:

```sh
mkdir -p ~/homelab-backups/nas/updates && cd ~/homelab-backups/nas/updates
for p in TrueNAS-SCALE-Dragonfish/24.04.2.5/TrueNAS-SCALE-24.04.2.5.update \
         TrueNAS-SCALE-ElectricEel/24.10.2.4/TrueNAS-SCALE-24.10.2.4.update \
         TrueNAS-SCALE-Fangtooth/25.04.2.6/TrueNAS-SCALE-25.04.2.6.update \
         TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update; do
  curl -sSL -C - -m 3600 -O "https://download.sys.truenas.net/$p"
done
shasum -a 256 -c <<'EOF'
dfee3b50dd183619ee08714b4abff9158588e3a9c07847bac579cdfa1092f3be  TrueNAS-SCALE-24.04.2.5.update
ac246169f98423475b2eda678013d58bb5c2250c8e3e4ef8b207cf1c88807d6c  TrueNAS-SCALE-24.10.2.4.update
21c8d658b0ac96e4ea88af3fcaca03bcbeb0f41ec05a728536679fcc64f0c902  TrueNAS-SCALE-25.04.2.6.update
c518e5407759686d1ba46512900b887ad4d8f5f7f80e40bc3317bf38b035190d  TrueNAS-SCALE-25.10.8.update
EOF
cd ~/homelab-backups/bmc-firmware
shasum -a 256 -c <<'EOF'
2c726062ba535c0a1d6b655bc1e668a712e0e8eb252474089c07ff2c5da1fe3e  tp2-ota-v2.1.0.tpu
28247398f3a8415a4759f9c3ecf4956328009968bf5e5782df75728e24ab9549  tp2-firmware-sdcard-v2.1.0.img
EOF
```

Expected: six lines ending in `: OK`. A `FAILED` line: delete that file,
download it again, check again. Never upload or flash a file that does not
match.

## Step 0: terminal

Run every block in one bash shell (the blocks set variables the bash way):

```sh
/bin/bash
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
export TALOSCONFIG=~/homelab-backups/talos/talosconfig
NAS=192.168.1.228
CPS=192.168.1.247,192.168.1.238,192.168.1.239
DAY=$(date -u +%Y%m%d)                       # the window day
PRE=~/homelab-backups/nas/<yyyymmdd>-pre     # recorded the day before
OUT=~/homelab-backups/nas/$DAY
QUIESCED=$OUT-quiesced
LOG=$OUT/window.log
mkdir -p "$OUT" && chmod 700 "$OUT"
wait_gone() {   # up to 10 minutes until none of the addresses answers ping
  for i in $(seq 120); do
    up=; for h in "$@"; do ping -c1 -W1000 "$h" >/dev/null 2>&1 && up="$up $h"; done
    [ -z "$up" ] && { echo "down: $*"; return 0; }
    sleep 5
  done
  echo "still up:$up"; return 1
}
for t in kubectl talosctl task jq curl nc gh tpi nmap smbutil shasum python3; do
  printf '%-9s ' "$t"; command -v "$t" >/dev/null && echo ok || echo MISSING
done
```

Expected: `ok` for every tool (`brew install nmap` if it is missing).
`task talos:etcd-snapshot` reads `talos/clusterconfig/talosconfig`: run
`task talos:genconfig` once if it is not there. Every step's outcome (PASS
lines, IDs, hashes, addresses) goes into `$LOG`, through `tee -a "$LOG"` or
by hand; rollback step 0 reads it.

## The day before

1. Spec tasks 1 to 6 are merged and `scripts/nas-maintenance.sh canary`
   passed on CORE.
2. Record the baseline and check it:

   ```sh
   PRE=~/homelab-backups/nas/$(date -u +%Y%m%d)-pre
   scripts/nas-check.py --record "$PRE"
   scripts/nas-check.py --expect core --baseline "$PRE"
   ```

   Expected: exit 0 and a `PASS` line for every check (version, pools,
   features, services, nfs, smb, iscsi, tls, ui). Set `PRE` in step 0 to this
   directory on the window day. A `FAIL` line: fix it on CORE, or stop the
   window until it is understood.
3. The four update files and both BMC files are downloaded and check `OK`
   ([Files](#files)).
4. The BMC's 2.1 network change does not apply. Open a BMC shell (`ssh
   root@turingpi.local`, the BMC login) and run the test from the
   [v2.1 network migration page](https://docs.turingpi.com/docs/v20-to-v21-migration):

   ```sh
   f=/mnt/overlay/upper/etc/network/interfaces
   if [ -f "$f" ] && { grep -qE '^[^#]*eth0' "$f" || ! grep -qE 'node[1-4]|ge[01]' "$f"; }; then
     echo 'migration required!'; else echo 'Not affected'; fi
   exit
   ```

   Expected: `Not affected`. Anything else: stop and read that page before
   the window; the flash would rewrite the BMC's network configuration.
5. **Operator**: tells the household: from 09:00 to about 12:30 (14:00 at
   the latest), no app that uses storage or a login, and no SMB share; every
   app is down for about 30 minutes early in the window. Has the USB-SATA
   adapter, a screwdriver and a microSD card at hand.

## The window

### 1. Preconditions

```sh
kubectl get nodes
kubectl -n argo get applications -o json \
  | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name'
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s -m 10 'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false&filter=severity%3D%22critical%22' \
  | jq -r '.[].labels.alertname'
kill "$PF"
scripts/nas-maintenance.sh plan 2>&1 | tee -a "$LOG"
```

Expected: four nodes `Ready`; no Application name printed; no alert name
printed; `plan` exits 0, lists the stateful workloads and marks every job of
the daily backup set `today`. A job not `today`, or `plan` exiting 3 (a
backup still running, an unknown owner): wait for the job, or handle the
owner by hand, and run `plan` again. Do not start the window on a red
cluster.

### 2. Freeze

```sh
gh workflow disable renovate-next.yaml
gh workflow disable auto-rollback.yaml
scripts/maintenance-silence.sh cluster 6h "NAS CORE to SCALE, #1305" | tee -a "$LOG"
SILENCE=<silence id>
```

Expected: the silence line with its ID. **Operator**: pauses the
healthchecks.io check (its Pause button), or it pages "cluster dead" about
20 minutes after `down` stops the main Prometheus. From here until the
rollback window closes, no pull request that adds a PVC merges.

### 3. Backups

```sh
task backup:dump 2>&1 | tail -3 | tee -a "$LOG"
CLUSTERS="immich/immich-db keycloak/keycloak-db mealie/mealie-postgresql
  home/home-assistant-postgresql theater/sonarr-postgresql
  theater/radarr-postgresql theater/lidarr-postgresql theater/prowlarr-postgresql"
for c in $CLUSTERS; do
  kubectl -n "${c%/*}" create -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${c#*/}-pre-scale-$DAY
spec:
  cluster:
    name: ${c#*/}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
done
task talos:etcd-snapshot -- 192.168.1.239 | tee -a "$LOG"
```

Expected: `verified=9  failed=0` (eight Postgres clusters and Paperless'
SQLite) and the dump directory; eight `backup.postgresql.cnpg.io/... created`
lines; the `ls -l` line of the etcd snapshot. Then, every minute until all
eight read `completed` (about 15 minutes):

```sh
for c in $CLUSTERS; do
  printf '%-40s %s\n' "$c" "$(kubectl -n "${c%/*}" get backup "${c#*/}-pre-scale-$DAY" -o jsonpath='{.status.phase}')"
done | tee -a "$LOG"
```

A `failed` phase: [CNPGBackupFailed](alerts/CNPGBackupFailed.md); the window
does not continue without all eight.

### 4. Stop the stateful workloads

```sh
scripts/nas-maintenance.sh down 2>&1 | tee -a "$LOG"
STATE=~/homelab-backups/nas-maintenance/<utc>.json   # the path down printed
scripts/nas-maintenance.sh status
scripts/nas-check.py --expect core --baseline "$PRE" --quiesced 2>&1 | tee -a "$LOG"
```

Expected: `down` prints its plan, then exits 0 within 15 minutes; `status`
shows zero pods on NAS volumes and zero democratic-csi VolumeAttachments;
`nas-check.py` exits 0 with `PASS quiesced` (no iSCSI session). `down` exit
1: it lists what still mounts a NAS volume; inspect it, re-run `status`.
Keep `$STATE`: `up` and the rollback need it.

### 5. BMC firmware

The nodes lose power when the BMC reboots, so they shut down first. The NAS
is still untouched: a failure in this step stops the window with nothing on
the NAS changed ([Stop rules](#stop-rules)).

1. Snapshot and file check:

   ```sh
   task talos:etcd-snapshot -- 192.168.1.239 | tee -a "$LOG"
   shasum -a 256 ~/homelab-backups/bmc-firmware/tp2-ota-v2.1.0.tpu | tee -a "$LOG"
   ```

   Expected: the snapshot's `ls -l` line, then
   `2c726062ba535c0a1d6b655bc1e668a712e0e8eb252474089c07ff2c5da1fe3e`.
2. Shut the nodes down, worker first, then the three control planes in one
   call so etcd stops on all three together:

   ```sh
   talosctl -n 192.168.1.240 shutdown && wait_gone 192.168.1.240
   talosctl -n "$CPS" shutdown && wait_gone 192.168.1.247 192.168.1.238 192.168.1.239
   ```

   Expected: `down: 192.168.1.240`, then
   `down: 192.168.1.247 192.168.1.238 192.168.1.239`. A drain that hangs for
   more than 5 minutes: Ctrl-C and repeat that line with `shutdown --force`.
3. Flash. The BMC login goes through the environment, never on the command
   line or in the log:

   ```sh
   read -r -p 'BMC user: ' TPI_USERNAME; read -r -s -p 'BMC password: ' TPI_PASSWORD; echo
   export TPI_USERNAME TPI_PASSWORD
   tpi info | tee -a "$LOG"
   tpi firmware --file ~/homelab-backups/bmc-firmware/tp2-ota-v2.1.0.tpu \
     --sha256 2c726062ba535c0a1d6b655bc1e668a712e0e8eb252474089c07ff2c5da1fe3e
   ```

   Expected: `tpi info` shows daemon 2.0.5; the transfer runs to the end and
   `tpi firmware` exits 0. The BMC verifies the file against the SHA-256 and
   reverts on a mismatch; a non-zero exit leaves 2.0.5 in place: check the
   file again and retry once.
4. Reboot the BMC and wait for it:

   ```sh
   tpi reboot
   for i in $(seq 60); do sleep 10; tpi info >/dev/null 2>&1 && break; done
   tpi info | tee -a "$LOG"
   ping -c1 turingpi.local | head -1 | tee -a "$LOG"
   arp -n "$(ping -c1 turingpi.local | sed -n '1s/.*(\([0-9.]*\)).*/\1/p')" | tee -a "$LOG"
   ```

   Expected within 10 minutes: `tpi info` shows daemon 2.1.0; the ping line
   shows the BMC's address and the `arp` line its new MAC (v2.1.0 uses
   OUI-assigned MACs, so the DHCP lease is likely new). `turingpi.local`
   not resolving: find the BMC in the router's DHCP client list and run the
   same commands with `--host <bmc-ip>`.
5. Power the slots:

   ```sh
   tpi power status
   ```

   For each slot that shows `off`, control planes first:
   `tpi power on -n 1`, `-n 2`, `-n 3`, then `-n 4`. Expected:
   `node1: on` to `node4: on` in `tpi power status`.
6. Checks, within 15 minutes of power-on:

   ```sh
   kubectl get nodes
   talosctl -n 192.168.1.239 etcd status
   talosctl -n 192.168.1.239 health
   scripts/nas-check.py --expect core --baseline "$PRE" --quiesced 2>&1 | tee -a "$LOG"
   nmap -sV -p 22 <bmc-ip> | grep '^22/' | tee -a "$LOG"
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 &
   PF=$!; sleep 3
   curl -s -m 10 http://localhost:9093/api/v2/silences | jq -r '.[] | select(.status.state == "active") | .id'
   kill "$PF"
   ```

   Expected: four nodes `Ready`; three members and one leader, no errors;
   `health` ends with every check OK; `nas-check.py` exits 0; OpenSSH 9.8 or
   later on port 22; the silence ID from step 2. No active silence
   (Alertmanager has no persistent storage and restarted): run step 2's
   `maintenance-silence.sh` line again and note the new `SILENCE`.
7. If the BMC address changed: open a PR with the new address in
   `platform/blackbox-exporter/probes/lan.yaml` (the target and the
   `bmc` relabel regex) and `docs/networking.md`, body `Closes #1307`, and
   merge it with `scripts/pr-merge.sh <n>` before step 14 (Argo CD sync is
   paused; `up` deploys it). If it did not change, close #1307 with the
   `tpi info` and `nmap` lines.

### 6. Pool snapshot

**Operator**, CORE UI: Storage > Snapshots > Add: dataset `homelab`, name
`pre-scale-<yyyymmdd>` (the window day), Recursive on. Then:

```sh
scripts/nas-check.py --expect core --baseline "$PRE" --snapshot "pre-scale-$DAY" --only snapshot 2>&1 | tee -a "$LOG"
```

Expected: `PASS snapshot`, exit 0. A `FAIL` names the datasets without the
snapshot: take the snapshot again with Recursive on.

### 7. Record the quiesced state

```sh
scripts/nas-check.py --record "$QUIESCED" 2>&1 | tee -a "$LOG"
ls "$QUIESCED"
```

Expected: exit 0; one JSON file per endpoint, `features.txt`,
`fingerprint.txt`, `meta.json`. From here on, `$QUIESCED` is the baseline.

### 8. Save the CORE configuration

**Operator**, CORE UI, every file into `~/homelab-backups/nas/<yyyymmdd>/`
(`$OUT`):

- System > General > Save Config, with "Export Password Secret Seed" on.
- System > Advanced > Save Debug.
- System > Certificates: download `homelab-nas-ca`, and the `nas`
  certificate with its key.

```sh
ls -l "$OUT"
```

Expected: the configuration `.tar`, the debug `.tgz`, the CA and the `nas`
certificate and key, and `window.log`. These files hold secrets: they never
go into git, a chat or a log.

### 9. Image the CORE boot SSD

1. **Operator**: CORE UI, power menu (top right) > Shut Down. Takes the boot
   SSD (Kingston A400 120 GB) out and connects it to the Mac with the
   adapter. macOS says the disk is not readable: click **Ignore**, never
   **Initialize**.
2. Find it and image it:

   ```sh
   diskutil list external physical
   sudo scripts/nas-boot-image.sh read disk<N> "$OUT/" 2>&1 | tee -a "$LOG"
   sudo scripts/nas-boot-image.sh verify disk<N> "$OUT/" 2>&1 | tee -a "$LOG"
   diskutil eject disk<N>
   ```

   `disk<N>` is the external disk of about 120 GB, never the Mac's own disk.
   Expected: `read` writes `core-boot.device.plist`, `core-boot.img.gz` and
   `core-boot.img.sha256`; `verify` exits 0 (same SHA-256). Exit 3: the
   script refused the disk (internal, or not 100 to 130 GB); check
   `diskutil list` and use the right identifier. `verify` exit 1: run
   `read` again; the SSD does not go back until `verify` passes.
3. **Operator**: SSD back in its port, NAS on.

### 10. CORE is back

```sh
ping -c2 -t5 "$NAS" | tail -1
for p in 443 2049 3260; do
  printf 'NAS :%-5s ' "$p"; nc -z -G 3 -w 3 "$NAS" "$p" && echo open || echo CLOSED
done
scripts/nas-check.py --expect core --baseline "$QUIESCED" --quiesced 2>&1 | tee -a "$LOG"
```

Expected about 5 minutes after power-on: `0.0% packet loss`, `open` three
times, `nas-check.py` exit 0. The NAS silent with the SSD back: check the
SSD sits in the boot port, then [Rollback](#rollback) step 3 (restore the
image).

### 11. The update chain

For each step U1 to U4, **operator**, in the web UI: System > Update >
Install Manual Update File, the file from `~/homelab-backups/nas/updates/`
([Files](#files)), save the configuration when offered, temporary location
"Memory Device", Apply, and confirm the reboot. Each takes about 15
minutes.

Ignore every "Upgrade Pool" prompt and the new-features alert.

| Step | From | File |
| --- | --- | --- |
| U1 | 13.0-U6.7 | `TrueNAS-SCALE-24.04.2.5.update` |
| U2 | 24.04.2.5 | `TrueNAS-SCALE-24.10.2.4.update` |
| U3 | 24.10.2.4 | `TrueNAS-SCALE-25.04.2.6.update` |
| U4 | 25.04.2.6 | `TrueNAS-SCALE-25.10.8.update` |

After each reboot:

```sh
ping -c2 -t5 "$NAS" | tail -1
nc -z -G 3 -w 3 "$NAS" 443 && echo "443 open"
scripts/nas-check.py --expect scale --baseline "$QUIESCED" --only version,pools,features 2>&1 | tee -a "$LOG"
```

Expected: `0.0% packet loss`, `443 open`, `PASS pools`, `PASS features`.
After U1 to U3 the version line reads `FAIL version` with the version just
installed (the rule is 25.10.8 exactly): that is the record of the step,
not a failure. After U4: `PASS version`. **Operator** also checks in the UI:
login works, pool `homelab` ONLINE, and under Network > Interfaces the
`en*` interface (description `igb0`) holds `192.168.1.228`.

`FAIL features` after any step: stop the chain, [Rollback](#rollback) step
0 decides. Other differences: [Stop rules](#stop-rules).

If CORE refuses the U1 file because of its version: **operator**, CORE UI,
System > Update, train `TrueNAS-13.0-STABLE`, update to 13.0-U6.8 and
reboot (about 15 minutes); `nas-check.py --expect core --baseline
"$QUIESCED" --only version,pools,features` exits 0; then U1 again.

### 12. Fixes

Apply only those whose check fails; write each one applied into `$LOG`.

- iSCSI targets open (always run, before the full check): the guard, by
  hand, while no session is open:

  ```sh
  kubectl -n democratic-csi create job --from=cronjob/nas-iscsi-guard nas-iscsi-guard-manual
  kubectl -n democratic-csi wait --for=condition=complete job/nas-iscsi-guard-manual --timeout=10m
  kubectl -n democratic-csi logs job/nas-iscsi-guard-manual | tee -a "$LOG"
  kubectl -n democratic-csi delete job nas-iscsi-guard-manual
  ```

  Expected: `condition met`; one JSON line per target it limited (name and
  old value). A 401 (`api key rejected`): the API key fix below first.
- `FAIL nfs` on `maproot_group` (`wheel` does not resolve on SCALE):
  **operator**, Shares > Unix (NFS) Shares, the `/mnt/homelab/k8s/backups`
  export, Advanced, Maproot Group `root`, Save.
- A child dataset that does not mount from a node, or shows empty through
  its parent (the canary's non-empty checks in step 13): **operator**, add
  an NFS export for that dataset's path with the same Hosts (the four nodes)
  and the same Maproot User and Group as its parent export.
- `FAIL tls` (TrueNAS replaced a certificate it found malformed with a
  self-signed one): **operator**, Credentials > Certificates > Import, the
  `nas` certificate and key saved in step 8; System > General, select it as
  the GUI SSL certificate, Save, restart the UI. Then `nas-check.py` again.
- `nas-check.py` exits 2 on SSH (key login broken after the migration):
  **operator**, Credentials > Users, the democratic-csi SSH user, paste the
  public key from the baseline's `user` record in `$QUIESCED` (field
  `sshpubkey`) into its SSH public key field, Save; System >
  Services > SSH still allows key login for that user. Until it works, read
  the feature flags in the UI's System > Shell:
  `zpool get -H -o property,value all homelab | grep feature@`, paste the
  output into `$OUT/features-scale.txt` and add
  `--features-file "$OUT/features-scale.txt"` to `nas-check.py`.
- API key rejected (exporter and guard 401, democratic-csi controller log
  401), on its own 45-minute budget, CI included: **operator**, Credentials >
  API Keys, a new key for the user the old one belonged to (the baseline's
  `user` record; otherwise the democratic-csi SSH user). Put it into
  `infrastructure/secrets/democratic-csi-iscsi.sops.yaml` with
  `task secrets:seal`, set the `api-token` date in `ci/secret-rotation.tsv`
  in the same PR, merge with `scripts/pr-merge.sh <n>`. Sync is paused, so
  sync that one Application by hand and restart:

  ```sh
  kubectl -n argo patch application secrets-infrastructure --type merge \
    -p '{"operation":{"initiatedBy":{"username":"nas-maintenance"},"sync":{"revision":"main"}}}'
  kubectl -n argo get application secrets-infrastructure -o jsonpath='{.status.operationState.phase}{"\n"}'
  kubectl -n democratic-csi rollout restart deploy/iscsi-democratic-csi-controller \
    ds/iscsi-democratic-csi-node deploy/truenas-exporter
  ```

  Expected: the phase reads `Succeeded` (repeat the `get` until it does),
  then three `restarted` lines.

Then the full check:

```sh
scripts/nas-check.py --expect scale --baseline "$QUIESCED" 2>&1 | tee -a "$LOG"
```

Expected: exit 0, a `PASS` line for every check.

### 13. Canary on SCALE

```sh
scripts/nas-maintenance.sh canary --hold-guard 2>&1 | tee -a "$LOG"
```

Expected: exit 0: the 1 GiB `iscsi` volume is written, read back, expanded
to 2 GiB and deleted; the guard limited its new target to the four nodes
within 15 minutes; the four NFS paths are non-empty, and `media/` and
`torrents/` are non-empty through the parent mount. Exit 1 names the
failing step: fix it from step 12's list, or the guard Job's log for the
guard poll.

### 14. Start the workloads

```sh
scripts/nas-maintenance.sh up "$STATE" 2>&1 | tee -a "$LOG"
```

Expected: exit 0 within about 25 minutes; Argo CD automated sync restored
(apps, then layers, then `root`). Exit 1 lists what is not Ready; Argo CD is
restored anyway and `up` can run again. Then the acceptance checks:

```sh
kubectl -n argo get applications -o json \
  | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name'
kubectl get clusters.postgresql.cnpg.io -A
scripts/smoke.sh
kubectl -n monitoring port-forward pod/prometheus-nas-watch-0 9091:9090 >/dev/null 2>&1 &
PF1=$!
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF2=$!; sleep 3
curl -s -m 10 -G http://localhost:9091/api/v1/query --data-urlencode 'query=probe_success{job="nas-watch"}' \
  | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
for q in truenas_up 'probe_success{device="bmc"}'; do
  curl -s -m 10 -G http://localhost:9090/api/v1/query --data-urlencode "query=$q" | jq -r --arg q "$q" '.data.result[] | "\($q) \(.value[1])"'
done
kill "$PF1" "$PF2"
```

Expected: no Application name printed; eight clusters `Cluster in healthy
state`; `smoke.sh` green; `1` for `192.168.1.228:443`, `:2049` and `:3260`;
`truenas_up 1`; `probe_success{device="bmc"} 1` (after the step 5.7 PR, if
the address changed).

### 15. SMB

```sh
smbutil view -g //192.168.1.228
mkdir -p /tmp/nas-smb && mount_smbfs //guest:@192.168.1.228/bits_and_pieces /tmp/nas-smb
echo test > /tmp/nas-smb/.nas-scale-test && rm /tmp/nas-smb/.nas-scale-test && echo "write ok"
umount /tmp/nas-smb && rmdir /tmp/nas-smb
```

Expected: `bits_and_pieces` in the share list, then `write ok`.
**Operator**: opens the share on both Windows machines. A Windows machine
that refuses guest access while the Mac works: a client setting ("insecure
guest logons"); open an issue, it does not stop the window.

### 16. Unfreeze

```sh
scripts/maintenance-silence.sh --expire "$SILENCE"
gh workflow enable auto-rollback.yaml
gh workflow view auto-rollback.yaml | head -3
```

Expected: `expired <id>`; the workflow shown as active. **Operator**:
resumes the healthchecks.io check. `renovate-next.yaml` stays disabled, and
PRs that add a PVC stay frozen, until the rollback window closes (spec task
10).

## Stop rules

- BMC step: the BMC does not answer 10 minutes after `tpi reboot`, or the
  nodes or etcd are not healthy 30 minutes after power-on: stop the window
  before step 6; nothing on the NAS has changed. Recover with
  [A node won't come back](../talos-cheatsheet.md#a-node-wont-come-back)
  (UART through `tpi uart`, a slot power-cycle) or, if the BMC does not
  boot, the SD-card image: **operator**, written to the microSD card and
  booted per the Turing Pi firmware-upgrade guide. Then
  `scripts/nas-maintenance.sh up "$STATE"` on CORE, step 16, and the
  migration on another weekday.
- A check that fails and that step 12's list does not fix within 30 minutes
  (45 for the API key replacement): [Rollback](#rollback).
- 14:00 Zurich and step 14 has not started: [Rollback](#rollback), so the
  household has its services in the evening.
- No ping on `.228` after U1's reboot: look at the router's DHCP client
  list. A new lease whose MAC ends `B8:28` (or the onboard port's MAC):
  **operator**, open `https://<lease-ip>`, Network > Interfaces, put
  `192.168.1.228/24` static on that interface with the gateway and DNS from
  the baseline's `network/configuration` record in `$QUIESCED`, Test Changes, Save
  Changes, Persist, then the U1 check. Nothing new on the router within 15
  minutes, or the UI on the lease address unreachable: rollback. Without a
  console there is no other fix.
- A failure after U2, U3 or U4 that the previous boot environment fixes:
  **operator**, System > Boot, activate the previous one, reboot. Try the
  update once more; if it fails again, rollback.

## The day after

- Every backup CronJob's night run succeeded, including
  `immich-library-backup-local` on the backups export and
  `books-config-backup-calibre-web` at 05:20Z on the NFS export:

  ```sh
  kubectl get cronjobs -A -o json | jq -r '.items[] | select(.metadata.name | test("-backup")) | "\(.metadata.namespace)/\(.metadata.name) \(.status.lastSuccessfulTime)"'
  ```

  Expected: every time after 00:00Z today.
- `truenas_up` 1, no `NASExporterFailing`, `NASiSCSITargetOpen` silent.

## Rollback

Valid while the feature flags of `homelab` equal the baseline, and until the
rollback window closes 48 hours after the window. After that, PVCs may again
be created and their targets would be missing on CORE.

0. Refusal check:

   ```sh
   scripts/nas-check.py --expect scale --baseline "$QUIESCED" --only features,iscsi 2>&1 | tee -a "$LOG"
   ```

   Add `--features-file` (window step 12) if SSH is broken. `FAIL
   features`: stop, CORE could not import the pool; open an issue. SCALE
   unreachable: `grep features "$LOG"` must show `PASS features` after every
   update step that ran; if one is missing, stop and open an issue. Every
   target the `iscsi` check lists as extra (a PVC created after the window)
   gets a one-off restic backup of its PVC now and is recreated on CORE
   after step 5.
1. If the apps run: `scripts/nas-maintenance.sh down`, and keep the new
   state file as `$STATE`.
2. If the SCALE UI is reachable: **operator**, Storage, pool `homelab`,
   Export/Disconnect with "Destroy data" off and "Delete saved
   configurations" off, so CORE imports it without a force flag.
3. **Operator**: shut the NAS down (UI, or the power button held 4
   seconds), boot SSD to the Mac (**Ignore** on the "not readable" dialog),
   then:

   ```sh
   diskutil list external physical
   sudo scripts/nas-boot-image.sh restore disk<N> ~/homelab-backups/nas/<yyyymmdd>/
   diskutil eject disk<N>
   ```

   Expected: the script prints the device, asks for the disk identifier
   again, writes the image and ends with `verify` exit 0. Exit 3: the disk
   does not match `core-boot.device.plist` (size, media name, serial); it
   is the wrong disk. **Operator**: SSD back, NAS on.
4. Check CORE:

   ```sh
   scripts/nas-check.py --expect core --baseline "$QUIESCED" 2>&1 | tee -a "$LOG"
   ```

   Expected: exit 0. Pool `homelab` not imported (step 2 did not run):
   **operator**, CORE UI, Storage > Pools > Add > Import an existing pool;
   if CORE refuses a pool last used by another system, `sudo zpool import
   -f -R /mnt homelab` over SSH, then System > Reboot, and check again.
5. `scripts/nas-maintenance.sh canary`, then
   `scripts/nas-maintenance.sh up "$STATE"` (the state file of the `down`
   still in effect), then window steps 14 to 16.
6. democratic-csi needs nothing: its config works on both systems, the API
   key in the image is the CORE key, and the guard does nothing on CORE.
7. Open an issue with what failed. The snapshot and the image stay.

Last resort, only with a console (a graphics card in place of the network
card; the onboard NIC has no CORE driver, so there is no network either):
clean-install CORE 13.0-U6.7 from the ISO and upload the configuration saved
in window step 8.
