# Cold start: power loss or move

Bring the whole homelab back after everything lost power: an outage, or a move
to a new place. Work top to bottom; each check exists because the next step
fails confusingly when it does not pass.

- Time: 45 minutes when nothing is wrong, about 2 hours with surprises.
- You need: the Mac with this repository, `kubeconfig-homelab` and
  `talosconfig` (in the password manager, or rendered by `task talos:genconfig`
  with the SOPS age key), `talosctl`, physical access to the NAS and the
  Turing Pi 2, and the router's admin page. Talos command reference:
  [talos-cheatsheet.md](../talos-cheatsheet.md).
- Nothing needs to have been shut down cleanly. The order below handles an
  unclean stop.

For a planned power-off, see [Planned shutdown](#planned-shutdown) first.

## Facts this runbook relies on

| Thing | Fact |
| --- | --- |
| Router | Sunrise Connect Box 3 Fiber, `192.168.1.1`: gateway, DHCP (pool `.50`-`.199`, set as start `192.168.1.50`, 150 addresses), DNS forwarder. It cannot reserve addresses outside the pool and has no static routes. TP-Link Decos are access points only. |
| Static devices | Set on the device, outside the DHCP pool: nodes `.247` `.238` `.239` `.240` (their Talos machine configs, from [`talos/talconfig.yaml`](../../talos/talconfig.yaml)), NAS `.228`. |
| Cluster addresses | API VIP `.11`; LoadBalancer IPs `.254` (Gateway), `.200` (qBittorrent seeding), `.201` (Syncthing); pool `.200`-`.227`. |
| NAS | TrueNAS CORE, static `192.168.1.228` on `igb0`, a port of the Digitus PCIe network card (MAC ends `B8:28`). The card's second port (`igb1`) is unconfigured and the onboard NIC has no driver in TrueNAS CORE: plug the cable into the `B8:28` port only. |
| NAS console | None: the CPU (Ryzen 5 3600) has no integrated GPU, and a graphics card needs the only PCIe slot, which holds the network card. Diagnose over the network (web UI on `:443`, SSH). |
| NAS disks | The 2.5" SATA SSD is the boot drive. The M.2 NVMe (`nvd0`) is the L2ARC cache of pool `homelab` (RAIDZ1, 5 disks). The pool imports without its cache device; it does not boot without the SSD. |
| Nodes | 4x Turing RK1 in a Turing Pi 2. All four slots power on with the board. Each boots from a 29 GB eMMC. The board's BMC gives per-slot power and a serial console per slot, from its web UI or the `tpi` CLI (`tpi power`, `tpi uart`; `tpi --help` for the flags of the installed version). |
| Clocks | The RK1 modules have no RTC battery: the clock is wrong until NTP syncs, a minute or so after boot. Talos holds etcd until the time is synced; TLS errors in the first minute are this. |
| API VIP | Talos holds `.11` on one control plane, elected through etcd: without etcd quorum there is no VIP. `talosctl` talks to the node IPs, never the VIP. |

## Step 0: terminal

Run the whole runbook in one bash shell (the blocks split variables the bash
way; zsh, the macOS default, does not):

```sh
/bin/bash
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
export TALOSCONFIG=~/homelab-backups/talos/talosconfig   # or talos/clusterconfig/talosconfig after task talos:genconfig
NAS=192.168.1.228 VIP=192.168.1.11
NODES="192.168.1.247 192.168.1.238 192.168.1.239 192.168.1.240"
CPS=192.168.1.247,192.168.1.238,192.168.1.239
for t in kubectl talosctl jq curl nc showmount dig; do
  printf '%-10s ' "$t"; command -v "$t" >/dev/null && echo ok || echo MISSING
done
```

Expected: `ok` for every tool. `task tools` installs `talosctl`; `brew install
jq` or `brew install bind` (for `dig`) if one is missing; the smoke suite in
step 8 needs all three. Every later
block assumes these variables are set in the same shell.

## Step 1: router and addresses

1. Confirm on the router's admin page: LAN `192.168.1.1/24`, DHCP pool start
   `192.168.1.50`, 150 addresses (`.50`-`.199`). After a move, also confirm the
   port forwards: 80 and 443 TCP to `.254`, 22000 TCP and UDP to `.201`, 50000
   TCP to `.200`.
2. With the NAS and the Turing Pi still off, check that no other device holds a
   static address:

   ```sh
   for a in 11 200 201 228 238 239 240 247 254; do
     ping -c1 -W400 192.168.1.$a >/dev/null 2>&1 &
   done; wait; sleep 2
   for a in 11 200 201 228 238 239 240 247 254; do
     mac=$(arp -n 192.168.1.$a 2>/dev/null | sed -n 's/.* at \([0-9a-f:]*\) on .*/\1/p')
     printf '192.168.1.%-4s %s\n' "$a" "${mac:-free}"
   done
   ```

   Expected: `free` on every line. A MAC on any line is another device on a
   static address (a Deco that kept an old lease, for example): reboot that
   device so it takes a lease inside the pool, then re-run. Do not power on the
   nodes until every line is `free`; an address conflict on `.247` or `.11`
   looks exactly like a dead cluster.
3. On a new network, the WAN IP has probably changed. Note it for step 7:

   ```sh
   curl -s -4 -m 10 https://ifconfig.me; echo
   ```

## Step 2: NAS first, alone

The media share is mounted `hard`: if the NAS is not fully up before the nodes,
media pods hang in uninterruptible I/O and cannot be killed. Power on only the
NAS, wait about 5 minutes, then:

```sh
ping -c2 -t5 "$NAS" | tail -1
for p in 443 2049 3260; do
  printf 'NAS :%-5s ' "$p"; nc -z -G 3 -w 3 "$NAS" "$p" && echo open || echo CLOSED
done
showmount -e "$NAS"
```

Expected: `0.0% packet loss`, `open` on 443 (web UI), 2049 (NFS) and 3260
(iSCSI), and an export list containing `/mnt/homelab/k8s/nfs`. `showmount` has
no timeout on macOS: more than 20 seconds means NFS is not answering (Ctrl-C).

In the web UI (`https://192.168.1.228`) confirm: pool `homelab` ONLINE (a
DEGRADED cache device is tolerable, a DEGRADED data vdev is not), services iSCSI
and NFS running.

If the NAS does not answer at all: check the cable is in the `B8:28` port of the
Digitus card, then check the router's DHCP client list in case the NAS lost its
static configuration (it then appears with a pool address).

### The NAS does not start by itself after a power loss

The NAS stays off when power returns; the Turing Pi does not. The nodes then
boot without storage: the democratic-csi controller crash-loops, pods with
iSCSI or NFS volumes sit in `Unknown`, `ContainerCreating` or `FailedMount`,
and most public names answer `503`.

1. Power the NAS on by hand and run the checks above until they pass.
2. Wait 10 minutes. The CSI controller reconnects, and the controllers replace
   the pods that were waiting on storage; most consumers recover on their own.
3. Run step 4. Delete any pod still in `ContainerCreating`, `Unknown` or
   `CrashLoopBackOff` (`kubectl -n <ns> delete pod <pod>`). Log in to iSCSI
   again on a node only if its `iscsi-democratic-csi-node` pod logs session
   errors after that.

The permanent fix is the NAS BIOS setting "Restore on AC Power Loss" set to
"Power On". TrueNAS cannot change or report it. Changing it needs a display,
which means swapping the network card for a graphics card for the duration
(see the NAS console row above).

## Step 3: nodes

Power on the Turing Pi 2. Wait 3 minutes, then:

```sh
for h in $NODES; do
  printf '%-15s ' "$h"; ping -c1 -W2000 "$h" >/dev/null 2>&1 && echo up || echo DOWN
done
printf 'VIP %s:6443 ' "$VIP"; nc -z -G 3 -w 3 "$VIP" 6443 && echo listening || echo DOWN
```

`-W` is in milliseconds on macOS. Expected: four `up` and `listening`.

- A node `DOWN`: in the BMC (web UI or `tpi`), check the slot is powered,
  power it on if not, and read its serial console
  (`tpi --host turingpi.local uart -n <slot> get | tail -60`). A node that is
  powered but frozen needs a power-cycle
  ([node-power-cycle.md](node-power-cycle.md)). A node whose console shows
  maintenance mode on a DHCP address has lost its config: apply it again
  ([node-replacement.md step 4](node-replacement.md#step-4-apply-the-machine-config)).
  A node that no longer boots: carry on with the other three and rebuild it
  afterwards ([node-replacement.md](node-replacement.md)).
- The VIP `DOWN` while the control planes are up: the VIP follows etcd, so
  check etcd first (below). Then see which control plane holds it, and read
  the VIP and etcd lines of the controller log:

  ```sh
  talosctl -n "$CPS" get addresses | grep "$VIP"
  talosctl -n 192.168.1.247 logs controller-runtime | grep -Ei 'vip|etcd' | tail -20
  ```

  Expected: one line with `$VIP` on one control plane.
- A Talos service not `Running`: `talosctl -n <ip> services`, then
  `talosctl -n <ip> logs <service>` for the failing one.

Then etcd quorum:

```sh
talosctl -n "$CPS" etcd status
```

Expected: three rows, the same `LEADER` on each, an empty `ERRORS` column.
Two rows is survivable (quorum), one is not: see
[etcd snapshot and restore](#etcd-snapshot-and-restore). A row missing because
its node times out: `talosctl -n <ip> service etcd` on that node shows why
etcd is waiting (time sync, network, volumes).

## Step 4: cluster

```sh
kubectl get nodes
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl -n democratic-csi get pods
kubectl get pvc -A --no-headers | grep -v ' Bound ' || echo "all PVCs Bound"
kubectl get clusters.postgresql.cnpg.io -A
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || echo "all pods Running"
```

Expected, in order:

- four nodes `Ready` (give it 3 minutes after boot);
- `daemon set "cilium" successfully rolled out`;
- `192.168.1.254` on `gateway/cilium-gateway-shared`, `.200` on
  `theater/qbittorrent-seed`, `.201` on `syncthing/syncthing-protocol`;
- the democratic-csi controller and one node pod per node `Running`;
- `all PVCs Bound`;
- seven CNPG clusters `Cluster in healthy state`. "was not properly shut down;
  automatic recovery in progress" in a database log, followed by "ready to
  accept connections", is normal after a power loss;
- `all pods Running`, possibly after 5 to 10 minutes of image pulls and
  restarts. Keep the output: step 6 handles what is left.

If PVCs are not Bound or volumes fail to attach, go back to step 2: port 3260
and the iSCSI service. If pods on a node are `Evicted` with `DiskPressure`, the
eMMC is full, usually of images. The kubelet's image garbage collection frees
space on its own; to see what holds it, and to remove an unused image by hand:

```sh
talosctl -n <node-ip> usage /var --depth 2 | sort -n | tail -10
talosctl -n <node-ip> image list
talosctl -n <node-ip> image remove <image-ref>
```

The node condition clears a few minutes after the space is back.

## Step 5: Argo CD

```sh
kubectl -n argo get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Expected: 25 Applications, all `Synced` and `Healthy`. Argo CD reconciles from
`main` on its own; there is nothing to un-pin or resume. `immich` has no
automated sync: if it is `OutOfSync`, find out why before syncing it
([immich-upgrade.md](immich-upgrade.md)).

An Application `Degraded` or `Progressing` for more than 15 minutes:
`kubectl -n argo get application <name> -o yaml` and read `status.conditions`
and `status.resources` for the object that is not healthy.

## Step 6: known breakages after an unclean stop

Skip any whose symptom is absent.

**qBittorrent pod `Running` but nothing listening.** A stale
`/config/config/ipc-socket` or `lockfile` from before the power loss stops it
from starting its listener, and it has no probe to report that.

```sh
kubectl -n theater exec deploy/qbittorrent -- ls -la /config/config
kubectl -n theater exec deploy/qbittorrent -- sh -c \
  'mkdir -p /config/quarantine; mv -f /config/config/ipc-socket /config/config/lockfile /config/quarantine/ 2>/dev/null; ls /config/quarantine'
kubectl -n theater rollout restart deploy/qbittorrent
kubectl -n theater rollout status deploy/qbittorrent --timeout=5m
```

Both files are recreated on start. Details:
[arr-qbittorrent.md](arr-qbittorrent.md).

**A pod stuck in `CreateContainerError` or `ContainerCreating`.** Usually a
stale containerd name reservation from a dead sandbox. Read the current
`state` in `kubectl -n <ns> describe pod <pod>`, not `lastState`, then delete
the pod; the new UID gets a new container name:

```sh
kubectl -n <ns> delete pod <pod>
```

**Postgres `PANIC` or a `pg_control` error** in a CNPG cluster log is not
normal. Stop there for that database and restore from the last dump
([backups.md](../backups.md)). On `immich-db`, never change the image
(`cloudnative-vectorchord:16.15-1.1.1`, PostgreSQL 16) as part of a recovery.

## Step 7: public access

```sh
WAN=$(curl -s -4 -m 10 https://ifconfig.me); echo "WAN=$WAN"
grep -- '--default-targets' infrastructure/external-dns/values.yaml
for h in argo auth grafana theater cinema media archive cook syncthing; do
  printf '%-10s %s\n' "$h" "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$h.lilalala.com/")"
done
```

Expected: the WAN address equal to the one in `--default-targets`, and `200`,
`302` (login redirect) or `401` (`theater`, Plex) for every hostname. `000` is
a failure.

- WAN address changed: follow [wan-ip-change.md](wan-ip-change.md). It is one
  line, `--default-targets` in `infrastructure/external-dns/values.yaml`,
  changed in a pull request.
- Every hostname `000` with the right WAN address: check the router's 80/443
  forward to `.254` and step 4's LoadBalancer line.

## Step 8: smoke suite

`scripts/smoke.sh` is read-only and checks nodes, etcd, pods, PVCs, databases,
Argo CD, every public hostname, the Immich library, LoadBalancer bindings and
DNS. Its inputs are local files, never committed. Create them once:

```sh
mkdir -p ~/homelab-smoke && chmod 700 ~/homelab-smoke && cd ~/homelab-smoke
cat > immich-sql.txt <<'EOF'
Q1: SELECT type, count(*) FROM asset GROUP BY type ORDER BY 1
Q2: SELECT type, count(*) FROM asset WHERE "deletedAt" IS NULL GROUP BY type ORDER BY 1
Q3: SELECT count(*) FROM asset_audit WHERE "deletedAt" > '<previous run UTC>'
ORIG: SELECT "originalPath" FROM asset WHERE "deletedAt" IS NULL AND NOT "isOffline" ORDER BY random() LIMIT 20
EOF
: > node-macs.txt
for pair in homelab-cp-1=192.168.1.247 homelab-cp-2=192.168.1.238 \
            homelab-cp-3=192.168.1.239 homelab-w-1=192.168.1.240; do
  n=${pair%%=*}; ip=${pair#*=}
  ping -c1 -W1000 "$ip" >/dev/null 2>&1
  echo "$n $(arp -n "$ip" | sed -n 's/.* at \([0-9a-f:]*\) on .*/\1/p')" >> node-macs.txt
done
kubectl -n argo get applications -o name | sed 's|.*/||' | while read -r a; do
  case "$a" in root|layer-*) echo "$a health" ;; *) echo "$a sync+health" ;; esac
done > argo-gate.txt
cd ~/repos/homelab
```

Then run it:

```sh
S=~/homelab-smoke; out="$S/S-$(date -u +%Y%m%dT%H%M%SZ).json"
prev=$(ls -1t "$S"/S-*.json 2>/dev/null | head -1)
bash scripts/smoke.sh --node-macs "$S/node-macs.txt" --immich-sql "$S/immich-sql.txt" \
  --argo-gate "$S/argo-gate.txt" --entry-ip 192.168.1.254 ${prev:+--previous "$prev"} \
  > "$out"; echo "exit=$?"
jq -c '{green, failing: [.items[] | select(.pass | not) | {id, name, failures}]}' "$out"
```

Expected: `exit=0` and `{"green":true,"failing":[]}` after a few minutes
(network checks retry for about a minute before they fail).
Every failure names its item and reason; fix it and re-run. With `--previous`,
the Immich asset counts must not drop below the previous run unless Immich's
audit table explains it.

## Step 9: take a backup

Now that it runs, capture it:

```sh
task backup:dump
ls -1d ~/homelab-backups/2* | tail -1
```

Expected: eight `ok` rows (seven Postgres clusters and Paperless' SQLite),
`verified=8  failed=0`, and a new directory under
`~/homelab-backups/` (about 10 minutes). Then take an etcd snapshot (next
section). The nightly restic jobs copy files and most databases to S3, but
`immich-db`, `keycloak-db` and etcd have no off-site copy except these
([backups.md](../backups.md)): copy them off the Mac.

## etcd snapshot and restore

### Snapshot

The task reads `talos/clusterconfig/talosconfig`: run `task talos:genconfig`
once first.

```sh
task talos:etcd-snapshot -- 192.168.1.239
shasum -a 256 "$(ls -1t ~/homelab-backups/etcd/talos-*.db | head -1)"
```

Expected: an `ls -l` line for `~/homelab-backups/etcd/talos-<utc>.db` of about
50 MB, then its sha256. Any healthy control plane works in place of `.239`.

### Restore

Only when etcd has lost quorum for good or its data is corrupt. It rewinds the
whole cluster state to the snapshot. Argo CD then re-applies git on top, but
anything created after the snapshot and not in git is gone (PVs provisioned
since then stay on the NAS, `Retain`, and need re-binding by hand). This
follows the upstream Talos disaster-recovery steps; it has not been rehearsed
on this cluster.

1. If no snapshot is recent enough and one control plane still has its etcd
   data, copy the raw database off it first:

   ```sh
   talosctl -n 192.168.1.239 cp /var/lib/etcd/member/snap/db ~/homelab-backups/etcd/
   ```

   Expected: `~/homelab-backups/etcd/db`.

2. Wipe the etcd data on every control plane. Only the `EPHEMERAL` partition
   is wiped; the OS, the boot partitions and the machine config stay. The
   nodes reboot and wait for an etcd bootstrap:

   ```sh
   for h in 192.168.1.247 192.168.1.238 192.168.1.239; do
     talosctl -n "$h" reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
   done
   talosctl -n "$CPS" service etcd
   ```

   Expected, after a few minutes: `STATE Preparing` on all three.

3. Bootstrap etcd from the snapshot on one control plane:

   ```sh
   talosctl -n 192.168.1.239 bootstrap --recover-from ~/homelab-backups/etcd/<snapshot>.db
   ```

   For the raw copy of step 1, use `--recover-from ~/homelab-backups/etcd/db
   --recover-skip-hash-check`. The other two
   control planes join on their own.

4. From the Mac, re-run the etcd quorum check of step 3, then steps 4 to 8.

There is no rollback once the data is wiped: the snapshot is the state.

## Planned shutdown

Before a move or planned power work:

1. Take the backups of step 9 (dumps and an etcd snapshot).
2. Power the nodes off, worker first, cp-1 last. `--force` skips the
   per-node drain, which would only push every pod onto the nodes still up;
   the kubelet still stops the pods before the node halts:

   ```sh
   for h in 192.168.1.240 192.168.1.239 192.168.1.238 192.168.1.247; do
     talosctl -n "$h" shutdown --force
   done
   ```

   Expected: each command returns once that node is down.

3. Shut the NAS down from its web UI (System, Shutdown), last.

Nothing needs scaling down or suspending: Argo CD resumes from `main` and the
databases recover on start, as above.
