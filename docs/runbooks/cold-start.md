# Cold start: power loss or move

Bring the whole homelab back after everything lost power: an outage, or a move
to a new place. Work top to bottom; each check exists because the next step
fails confusingly when it does not pass.

- Time: 45 minutes when nothing is wrong, about 2 hours with surprises.
- You need: the Mac with this repository and `kubeconfig-homelab`, the SSH key
  for `nedsi@` on the nodes, physical access to the NAS and the Turing Pi 2, and
  the router's admin page.
- Nothing needs to have been shut down cleanly. The order below handles an
  unclean stop.

For a planned power-off, see [Planned shutdown](#planned-shutdown) first.

## Facts this runbook relies on

| Thing | Fact |
| --- | --- |
| Router | Sunrise Connect Box 3 Fiber, `192.168.1.1`: gateway, DHCP (pool `.50`-`.199`, set as start `192.168.1.50`, 150 addresses), DNS forwarder. It cannot reserve addresses outside the pool and has no static routes. TP-Link Decos are access points only. |
| Static devices | Set on the device, outside the DHCP pool: nodes `.247` `.238` `.239` `.240` (`/etc/netplan/01-homelab-static.yaml`, cloud-init networking disabled), NAS `.228`. |
| Cluster addresses | API VIP `.11`; LoadBalancer IPs `.254` (Gateway), `.200` (qBittorrent seeding), `.201` (Syncthing); pool `.200`-`.227`. |
| NAS | TrueNAS CORE, static `192.168.1.228` on `igb0`, a port of the Digitus PCIe network card (MAC ends `B8:28`). The card's second port (`igb1`) is unconfigured and the onboard NIC has no driver in TrueNAS CORE: plug the cable into the `B8:28` port only. |
| NAS console | None: the CPU (Ryzen 5 3600) has no integrated GPU, and a graphics card needs the only PCIe slot, which holds the network card. Diagnose over the network (web UI on `:443`, SSH). |
| NAS disks | The 2.5" SATA SSD is the boot drive. The M.2 NVMe (`nvd0`) is the L2ARC cache of pool `homelab` (RAIDZ1, 5 disks). The pool imports without its cache device; it does not boot without the SSD. |
| Nodes | 4x Turing RK1 in a Turing Pi 2. All four slots power on with the board. Each boots from a 29 GB eMMC. The board's BMC gives per-slot power and a serial console per slot, from its web UI or the `tpi` CLI (`tpi power`, `tpi uart`; `tpi --help` for the flags of the installed version). |
| Clocks | The RK1 modules have no RTC battery: the clock is wrong until NTP syncs, a minute or so after boot. TLS errors in the first minute are this. |

Node network configuration, `/etc/netplan/01-homelab-static.yaml` (mode 600;
`homelab-cp-1` shown, only the address differs per node):

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.1.247/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1]
```

## Step 0: terminal

Run the whole runbook in one bash shell (the blocks split variables the bash
way; zsh, the macOS default, does not):

```sh
/bin/bash
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
NAS=192.168.1.228 VIP=192.168.1.11
NODES="192.168.1.247 192.168.1.238 192.168.1.239 192.168.1.240"
SSHO="-o ConnectTimeout=5 -o BatchMode=yes"
for t in kubectl jq curl nc ssh showmount dig; do
  printf '%-10s ' "$t"; command -v "$t" >/dev/null && echo ok || echo MISSING
done
```

Expected: `ok` for every tool. `brew install jq` or `brew install bind` (for
`dig`) if one is missing; the smoke suite in step 8 needs both. Every later
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
  power it on if not, and read its serial console. A node that boots but is
  unreachable usually has a broken `/etc/netplan/01-homelab-static.yaml`; fix it
  from the serial console and run `sudo netplan apply`.
- The VIP `DOWN` while the control planes are up: read kube-vip's log on a
  control plane:

  ```sh
  ssh $SSHO nedsi@192.168.1.247 'sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a --name kube-vip'
  ssh $SSHO nedsi@192.168.1.247 'sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock logs --tail 20 $(sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a -q --name kube-vip | head -1)'
  ```

  - `lookup kubernetes on ...:53: no such host`: the `/etc/nsswitch.conf`
    mount is missing from `/etc/kubernetes/manifests/kube-vip.yaml`. Restore it
    as in [networking.md](../networking.md#kubernetes-api-vip).
  - `listen tcp :2112: bind: address already in use`: a sandbox from before the
    power loss is still running. List them with `crictl pods --name kube-vip`,
    then `crictl stopp <old-id>` and `crictl rmp <old-id>` (same
    `--runtime-endpoint`).
- etcd or kube-apiserver in a crash loop after the network is fixed:
  `sudo systemctl restart kubelet` on that control plane resets the 5-minute
  back-off.

Then etcd quorum:

```sh
for h in 192.168.1.247 192.168.1.238 192.168.1.239; do
  ssh $SSHO nedsi@"$h" 'E=unix:///run/containerd/containerd.sock;
    c=$(sudo -n crictl --runtime-endpoint $E ps -q --name etcd | head -1);
    sudo -n crictl --runtime-endpoint $E exec "$c" etcdctl \
      --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
      endpoint health'
done
```

Expected: three `127.0.0.1:2379 is healthy` lines. Two is survivable (quorum),
one is not: see [etcd snapshot and restore](#etcd-snapshot-and-restore).

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
eMMC is full of images:

```sh
ssh $SSHO nedsi@<node-ip> 'sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune; df -h / | tail -1'
```

The node condition clears a few minutes later.

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

**Seafile does not start.** Stale pid files in `/shared`
(`seaf-server.pid`, `ccnet-server.pid`, `seahub.pid`, `seafdav.pid`): move them
aside in the pod and restart the Deployment. MariaDB logs
`InnoDB: Starting crash recovery` and then starts; that is normal:

```sh
kubectl -n seafile logs deploy/mariadb --tail=40 | grep -Ei 'innodb|error'
```

**Postgres `PANIC` or a `pg_control` error** in a CNPG cluster log is not
normal. Stop there for that database and restore from the last dump
([backups.md](../backups.md)). On `immich-db`, never change the image
(`cloudnative-pgvecto.rs:16.5-v0.3.0`, PostgreSQL 16) as part of a recovery.

## Step 7: public access

```sh
WAN=$(curl -s -4 -m 10 https://ifconfig.me); echo "WAN=$WAN"
grep -- '--default-targets' infrastructure/external-dns/values.yaml
for h in argo auth grafana theater cinema media archive cook drive syncthing; do
  printf '%-10s %s\n' "$h" "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$h.lilalala.com/")"
done
```

Expected: the WAN address equal to the one in `--default-targets`, and `200`,
`302` (login redirect) or `401` (`theater`, Plex) for every hostname. `000` is
a failure.

- WAN address changed: change `--default-targets` in
  `infrastructure/external-dns/values.yaml` in a pull request and merge it
  ([README](../../README.md#how-changes-reach-the-cluster)). external-dns updates
  every record once Argo CD syncs; `dig +short media.lilalala.com @1.1.1.1`
  shows the new address after a minute or two. Old records are never deleted
  (`upsert-only`), which is harmless.
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

Expected: nine `ok` rows (seven Postgres clusters, the Seafile MariaDB,
Paperless' SQLite), `verified=9  failed=0`, and a new directory under
`~/homelab-backups/` (about 10 minutes). Then take an etcd snapshot (next section). Copy both off
the Mac: there is no off-site backup yet ([backups.md](../backups.md)).

## etcd snapshot and restore

### Snapshot

```sh
snap=snap-$(date -u +%Y%m%dT%H%M%SZ).db
ssh $SSHO nedsi@192.168.1.247 "E=unix:///run/containerd/containerd.sock;
  c=\$(sudo -n crictl --runtime-endpoint \$E ps -q --name etcd | head -1);
  sudo -n crictl --runtime-endpoint \$E exec \$c etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd/$snap >/dev/null &&
  sudo -n mkdir -p /root/etcd-snapshots && sudo -n mv /var/lib/etcd/$snap /root/etcd-snapshots/ &&
  sudo -n chmod 600 /root/etcd-snapshots/$snap && sudo -n sha256sum /root/etcd-snapshots/$snap"
mkdir -p ~/homelab-backups/etcd
ssh $SSHO nedsi@192.168.1.247 "sudo -n cat /root/etcd-snapshots/$snap" > ~/homelab-backups/etcd/$snap
chmod 600 ~/homelab-backups/etcd/$snap
shasum -a 256 ~/homelab-backups/etcd/$snap
```

Expected: the same sha256 twice, and a file of about 55 MB. The snapshot is
written inside the etcd container's data directory (`/var/lib/etcd`, a host
mount) because the hosts have no `etcdctl`.

### Restore

Only when etcd has lost quorum for good or its data is corrupt. It rewinds the
whole cluster state to the snapshot. Argo CD then re-applies git on top, but
anything created after the snapshot and not in git is gone (PVs provisioned
since then stay on the NAS, `Retain`, and need re-binding by hand). This
procedure follows the upstream kubeadm and etcd restore steps; it has not been
rehearsed on this cluster.

1. Copy the snapshot to the three control planes:

   ```sh
   snap=~/homelab-backups/etcd/<snapshot>.db
   for h in 192.168.1.247 192.168.1.238 192.168.1.239; do
     scp -o ConnectTimeout=5 "$snap" nedsi@"$h":/tmp/restore.db
   done
   ```

2. On each control plane, stop etcd and the API server and keep the old data:

   ```sh
   sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/
   sleep 30
   sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name 'etcd|kube-apiserver'
   sudo mv /var/lib/etcd /var/lib/etcd.before-restore
   ```

   Expected: the `crictl ps` table is empty.

3. On each control plane, restore with `etcdutl` from the etcd image already on
   the node. Set `NAME` and `IP` to that node: `homelab-cp-1` / `192.168.1.247`,
   `homelab-cp-2` / `192.168.1.238`, `homelab-cp-3` / `192.168.1.239`:

   ```sh
   NAME=homelab-cp-1 IP=192.168.1.247
   sudo ctr -n k8s.io run --rm --net-host \
     --mount type=bind,src=/tmp,dst=/tmp,options=rbind:rw \
     --mount type=bind,src=/var/lib,dst=/var/lib,options=rbind:rw \
     registry.k8s.io/etcd:3.5.24-0 etcd-restore \
     etcdutl snapshot restore /tmp/restore.db --name "$NAME" \
       --initial-cluster homelab-cp-1=https://192.168.1.247:2380,homelab-cp-2=https://192.168.1.238:2380,homelab-cp-3=https://192.168.1.239:2380 \
       --initial-advertise-peer-urls "https://$IP:2380" --data-dir /var/lib/etcd
   ```

   Expected: a `restored snapshot` log line and a new `/var/lib/etcd/member`.

4. On each control plane, start them again:

   ```sh
   sudo mv /etc/kubernetes/etcd.yaml /etc/kubernetes/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```

5. From the Mac, re-run the etcd quorum check of step 3, then steps 4 to 8.

Rollback: stop the static pods again, move `/var/lib/etcd.before-restore` back
to `/var/lib/etcd` on each node, and start them.

## Planned shutdown

Before a move or planned power work:

1. Take the backups of step 9 (dumps and an etcd snapshot).
2. Power the nodes off, worker first, cp-1 last:

   ```sh
   for h in 192.168.1.240 192.168.1.239 192.168.1.238 192.168.1.247; do
     ssh $SSHO nedsi@"$h" 'sudo -n shutdown -h now'; sleep 60
   done
   ```

3. Shut the NAS down from its web UI (System, Shutdown), last.

Nothing needs scaling down or suspending: Argo CD resumes from `main` and the
databases recover on start, as above. `scripts/graceful-shutdown.sh` and
`scripts/graceful-startup.sh` predate the current layout; do not use them.
