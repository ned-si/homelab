# Replace a node

Rebuild one node from a blank eMMC and join it back: a failed module, a
corrupted root filesystem, or a planned reinstall. The other three nodes keep
running throughout. This procedure follows the upstream kubeadm steps for
removing and joining nodes; it has not been rehearsed on this cluster.

- Time: about 1 hour, most of it flashing.
- You need: the Mac with this repository and `kubeconfig-homelab`, the SSH
  agent with the key for `nedsi@`, the Turing Pi 2 BMC (web UI or the `tpi`
  CLI), and the router's admin page.
- Replace one node at a time. With one control plane gone, etcd keeps quorum
  on the other two; with two gone, it has none
  ([cold-start.md](cold-start.md#restore)).

## Facts this runbook relies on

| Thing | Fact |
| --- | --- |
| Nodes | `homelab-cp-1` `192.168.1.247`, `homelab-cp-2` `.238`, `homelab-cp-3` `.239` (control planes, untainted, so they run workloads too), `homelab-w-1` `.240` (worker). The hostname is the node name and, on a control plane, the etcd member name. |
| Hardware | Turing RK1 in a Turing Pi 2 slot. The 29 GB eMMC is on the module: a failed eMMC means a new module. |
| OS image | Ubuntu 22.04 Server for the RK1 (vendor kernel 5.10), from `https://firmware.turingpi.com/turing-rk1/`. First login `ubuntu` / `ubuntu`, which forces a new password. The running nodes get the kernel and u-boot from `ppa:jjriek/rockchip`, pinned in `/etc/apt/preferences.d/rockchip-ppa`. |
| Kernel arguments | `bootargs` in `/boot/firmware/ubuntuEnv.txt` carry `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0`: the nodes run cgroup v1. |
| Packages | `containerd.io` from Docker's apt repository, `kubeadm` `kubelet` `kubectl` from `pkgs.k8s.io` (`core:/stable:/v1.32`), all four held with `apt-mark hold`; `open-iscsi`, `multipath-tools`, `nfs-common`, `lsscsi` for democratic-csi and the NFS mounts. No swap. |
| containerd | `/etc/containerd/config.toml` is `containerd config default` with one change: `SystemdCgroup = true`. |
| Cluster | `kubeadm-config`: `controlPlaneEndpoint: 192.168.1.11:6443`, `proxy.disabled: true` (Cilium replaces kube-proxy). The kubelet takes its node IP from `eth0`; there is no `--node-ip` flag. |
| kube-vip | `/etc/kubernetes/manifests/kube-vip.yaml`, mode 600, byte-identical on the three control planes ([manifest](#kube-vip-manifest)). |

## Step 0: terminal

One bash shell for the whole runbook. Set the node being replaced:

```sh
/bin/bash
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
SSHO="-o ConnectTimeout=5 -o BatchMode=yes"
N=homelab-cp-3 IP=192.168.1.239 ROLE=control-plane   # or: N=homelab-w-1 IP=192.168.1.240 ROLE=worker
OK=192.168.1.238                                     # a healthy control plane, not $IP
E=unix:///run/containerd/containerd.sock
etcdctl() { ssh $SSHO nedsi@"$OK" "c=\$(sudo -n crictl --runtime-endpoint $E ps -q --name etcd | head -1);
  sudo -n crictl --runtime-endpoint $E exec \$c etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key $*"; }
etcdctl member list -w table
```

Expected: a table with three `started` members named `homelab-cp-1`..`3`
(the one being replaced may be missing if it already failed).

## Step 1: back up

Take the dumps and an etcd snapshot from a healthy control plane, as in
[cold-start.md step 9](cold-start.md#step-9-take-a-backup) and
[Snapshot](cold-start.md#snapshot). If `$N` is `homelab-cp-1`, run the snapshot
commands against `$OK` instead of `192.168.1.247`.

## Step 2: remove the old node

If the node still runs, drain it first (bounded; single-instance databases
move to another node with their volume):

```sh
kubectl drain "$N" --ignore-daemonsets --delete-emptydir-data --timeout=15m
```

Expected: `node/<name> drained`. A dead node cannot be drained; skip to the
next block.

```sh
kubectl delete node "$N"
```

Expected: `node "<name>" deleted`. Pods that ran there are recreated on the
other nodes within a few minutes. A pod stuck in `ContainerCreating` with
`Multi-Attach error` holds an iSCSI volume still attached to the dead node:
`kubectl get volumeattachment | grep "$N"`, then
`kubectl delete volumeattachment <name>` for each.

Control plane only: remove its etcd member, by the ID in the first column of
step 0's table:

```sh
etcdctl member remove <member-id>
etcdctl member list -w table
```

Expected: `Member <id> removed`, then two `started` members. Do not remove a
second member.

Then forget the old host key on the Mac (the reinstall generates a new one):

```sh
ssh-keygen -R "$IP"
```

## Step 3: flash

Download the Ubuntu 22.04 Server image for the RK1 from
`https://firmware.turingpi.com/turing-rk1/` and flash it to the module's slot
from the BMC: web UI, Flash Node, pick the slot and the image, Install OS. The
`tpi` CLI does the same (`tpi flash --help` for the flags of the installed
version). The BMC verifies the image and reboots the module when done.

Expected: the BMC reports the verification passed. After a minute the module
appears in the router's DHCP client list with an address from the pool
(`.50`-`.199`). Call it `<dhcp-ip>`.

## Step 4: first login, user and network

```sh
ssh ubuntu@<dhcp-ip>
```

Log in with `ubuntu`, set the new password when asked, log in again, then on the
node (replace `<public-key>` with the line `ssh-add -L` prints on the Mac, and
`<name>` / `<ip>` with `$N` / `$IP`):

```sh
sudo hostnamectl set-hostname <name>
sudo adduser --disabled-password --gecos '' nedsi
sudo usermod -aG sudo nedsi
echo 'nedsi ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-nedsi
sudo chmod 440 /etc/sudoers.d/90-nedsi
sudo install -d -m 700 -o nedsi -g nedsi /home/nedsi/.ssh
echo '<public-key>' | sudo tee /home/nedsi/.ssh/authorized_keys
sudo chown nedsi:nedsi /home/nedsi/.ssh/authorized_keys
sudo chmod 600 /home/nedsi/.ssh/authorized_keys
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo tee /etc/netplan/01-homelab-static.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      addresses: [<ip>/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1]
EOF
sudo chmod 600 /etc/netplan/01-homelab-static.yaml
ls /etc/netplan/
```

Expected: `ls` shows `01-homelab-static.yaml` and the image's own file (for
example `50-cloud-init.yaml`). Remove every file except
`01-homelab-static.yaml` with `sudo rm /etc/netplan/<file>`, then
`sudo netplan apply`. The SSH session hangs: the node moved to `$IP`. From
the Mac:

```sh
ssh $SSHO -o StrictHostKeyChecking=accept-new nedsi@"$IP" 'hostname; ip -br -4 addr show eth0; sudo -n true && echo sudo-ok'
```

Expected: the node name, `eth0 UP <ip>/24`, `sudo-ok`. If the node does not
answer, fix the netplan file from the BMC serial console (`tpi uart --help`).

## Step 5: OS prerequisites

Copy the kernel arguments from a healthy node. Compare the two `bootargs`
lines; they must be identical except `root=UUID=`:

```sh
ssh $SSHO nedsi@"$OK" 'grep ^bootargs /boot/firmware/ubuntuEnv.txt'
ssh $SSHO nedsi@"$IP" 'grep ^bootargs /boot/firmware/ubuntuEnv.txt'
```

If the cgroup arguments are missing on `$IP`, add them to the end of its
`bootargs=` line with `sudo -e /boot/firmware/ubuntuEnv.txt`.

Install the same package versions as the healthy node:

```sh
V=$(ssh $SSHO nedsi@"$OK" "dpkg-query -W -f='\${Package}=\${Version} ' containerd.io kubeadm kubelet kubectl")
echo "$V"
ssh $SSHO nedsi@"$IP" "set -e
  sudo -n install -m 0755 -d /etc/apt/keyrings
  curl -fsSL -m 30 https://download.docker.com/linux/ubuntu/gpg | sudo -n tee /etc/apt/keyrings/docker.asc >/dev/null
  echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable' | sudo -n tee /etc/apt/sources.list.d/docker.list >/dev/null
  curl -fsSL -m 30 https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo -n gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-v1.32-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-v1.32-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo -n tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo -n apt-get update -q
  sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -q $V open-iscsi multipath-tools nfs-common lsscsi
  sudo -n apt-mark hold containerd.io kubeadm kubelet kubectl
  containerd config default | sudo -n tee /etc/containerd/config.toml >/dev/null
  sudo -n sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  echo 'net.ipv4.ip_forward = 1' | sudo -n tee /etc/sysctl.d/k8s.conf >/dev/null
  sudo -n systemctl enable open-iscsi multipathd
  sudo -n reboot"
```

`$V` reads like `containerd.io=1.7.24-1 kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1`.
The session closes on the reboot. Two minutes later:

```sh
ssh $SSHO nedsi@"$IP" 'cat /proc/cmdline; stat -fc %T /sys/fs/cgroup; swapon --show; grep -c "SystemdCgroup = true" /etc/containerd/config.toml; apt-mark showhold; ls /etc/apt/preferences.d/; uname -r; timedatectl show -p NTPSynchronized'
```

Expected: the cgroup arguments in the command line, `tmpfs` (cgroup v1), no
swap lines, `1`, the four held packages, `rockchip-ppa` among the preference
files, the same kernel as `$OK` (`uname -r` there), and
`NTPSynchronized=yes`. A missing pin or a different kernel: compare
`/etc/apt/sources.list.d/` and `/etc/apt/preferences.d/` with `$OK` and copy
what is missing. The RK1 has no RTC battery: do not join before the clock is
synchronised, or certificate checks fail.

TrueNAS: if iSCSI initiator group 1 (Shares, Block (iSCSI), Initiators Groups)
lists initiator names instead of allowing all initiators, add the new node's
name from `sudo cat /etc/iscsi/initiatorname.iscsi`. Otherwise volumes cannot
attach on this node.

## Step 6: join

The join token is valid 24 hours and the certificate key 2 hours. Both are
credentials: they stay in shell variables, never in a file.

```sh
JOIN=$(ssh $SSHO nedsi@"$OK" 'sudo -n kubeadm token create --print-join-command')
if [ "$ROLE" = control-plane ]; then
  KEY=$(ssh $SSHO nedsi@"$OK" 'sudo -n kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')
  JOIN="$JOIN --control-plane --certificate-key $KEY"
fi
ssh $SSHO nedsi@"$IP" "sudo -n $JOIN" > /tmp/join.log 2>&1; echo "exit=$?"; tail -5 /tmp/join.log; rm -f /tmp/join.log
unset JOIN KEY
```

Expected: `exit=0` and `This node has joined the cluster` (on a control plane,
followed by `a new control plane instance was created`). kubeadm adds the etcd
member on a control plane by itself.

If the join fails half-way, `ssh $SSHO nedsi@"$IP" 'sudo -n kubeadm reset -f'`,
remove a half-added etcd member as in step 2, and repeat step 6.

## Step 7: kube-vip (control plane only)

Copy the manifest from the healthy control plane:

```sh
ssh $SSHO nedsi@"$OK" 'sudo -n cat /etc/kubernetes/manifests/kube-vip.yaml' \
  | ssh $SSHO nedsi@"$IP" 'sudo -n tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null; sudo -n chmod 600 /etc/kubernetes/manifests/kube-vip.yaml'
for h in 192.168.1.247 192.168.1.238 192.168.1.239; do
  ssh $SSHO nedsi@"$h" 'sudo -n sha256sum /etc/kubernetes/manifests/kube-vip.yaml'
done
```

Expected: the same hash three times. The kubelet starts the pod within a
minute. If no control plane is healthy, write the manifest below instead.

### kube-vip manifest

`/etc/kubernetes/manifests/kube-vip.yaml`, identical on every control plane
(`vip_nodename` comes from the pod's node name):

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  name: kube-vip
  namespace: kube-system
spec:
  containers:
    - args:
        - manager
      env:
        - name: vip_arp
          value: 'true'
        - name: port
          value: '6443'
        - name: vip_nodename
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: vip_interface
          value: eth0
        - name: vip_subnet
          value: '32'
        - name: dns_mode
          value: first
        - name: cp_enable
          value: 'true'
        - name: cp_namespace
          value: kube-system
        - name: svc_enable
          value: 'true'
        - name: svc_leasename
          value: plndr-svcs-lock
        - name: vip_leaderelection
          value: 'true'
        - name: vip_leasename
          value: plndr-cp-lock
        - name: vip_leaseduration
          value: '5'
        - name: vip_renewdeadline
          value: '3'
        - name: vip_retryperiod
          value: '1'
        - name: address
          value: 192.168.1.11
        - name: prometheus_server
          value: :2112
      image: ghcr.io/kube-vip/kube-vip:v1.2.4@sha256:dde4c0669d9058c74c69c0bc2f0122e26900e1e4b913c03577cb6e4e28083079
      imagePullPolicy: IfNotPresent
      name: kube-vip
      resources: {}
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
      volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
        - mountPath: /etc/nsswitch.conf
          name: nsswitch
          readOnly: true
  hostAliases:
    - hostnames:
        - kubernetes
      ip: 127.0.0.1
  hostNetwork: true
  volumes:
    - hostPath:
        path: /etc/kubernetes/admin.conf
      name: kubeconfig
    - name: nsswitch
      hostPath:
        path: /etc/nsswitch.conf
        type: File
status: {}
```

- `vip_subnet`, not `vip_cidr`: kube-vip v1.x reads `vip_subnet`.
- `svc_enable` also announces LoadBalancer IPs
  ([networking.md](../networking.md#loadbalancer-ips)).
- The `nsswitch` mount makes the `kubernetes` host alias win over DNS
  ([networking.md](../networking.md#kubernetes-api-vip)).
- On the first control plane of a new cluster only, `admin.conf` has no rights
  until `kubeadm init` has finished. Point the `kubeconfig` volume at
  `/etc/kubernetes/super-admin.conf` for the `init`, then back to `admin.conf`.

## Step 8: check

```sh
kubectl get node "$N" -o wide
kubectl get pods -A -o wide --field-selector spec.nodeName="$N"
etcdctl member list -w table
etcdctl endpoint health --cluster
ssh $SSHO nedsi@"$IP" 'sudo -n grep -c nsswitch /etc/kubernetes/manifests/kube-vip.yaml'
kubectl -n kube-system get lease plndr-cp-lock plndr-svcs-lock
```

Expected:

- the node `Ready`, version as on the others, `INTERNAL-IP` equal to `$IP`;
- `cilium`, `cilium-envoy`, `iscsi-democratic-csi-node` and the node exporter
  `Running` on it (plus `etcd`, `kube-apiserver`, `kube-controller-manager`,
  `kube-scheduler` and `kube-vip` on a control plane);
- three `started` members and three `is healthy` lines (control plane);
- `4` from the nsswitch check (control plane);
- both leases with a holder.

If `INTERNAL-IP` is wrong, set `KUBELET_EXTRA_ARGS=--node-ip=<ip>` in the
node's `/etc/default/kubelet` and `sudo systemctl restart kubelet`.

Then recreate the smoke suite's `node-macs.txt` (a new module has a new MAC)
and run the suite, both as in
[cold-start.md step 8](cold-start.md#step-8-smoke-suite). Expected:
`{"green":true,"failing":[]}`.

## Rollback

There is no previous state to return to: the old node is gone after step 2.
If the new node cannot join, leave it out (`kubeadm reset -f` on it, no etcd
member for it) and run on three nodes, two control planes with quorum.
Replacing a second control plane before the first is back leaves etcd without
quorum.
