# Moving the homelab to a new house

Two scripts do the mechanical parts:

```sh
task shutdown     # scripts/graceful-shutdown.sh
task startup      # scripts/graceful-startup.sh
```

This document covers what they cannot: the physical move, and the network
reconfiguration at the other end.

## The one thing that will actually bite you

**Four files contain the old house's addresses.** If you plug everything in and
nothing works, it is almost certainly one of these, not a Kubernetes fault:

| File | Value | Symptom if wrong |
|---|---|---|
| `infrastructure/gateway/gateway.yaml` | public WAN IP | DNS resolves, nothing connects from outside |
| `infrastructure/cilium/ip-pools.yaml` | LoadBalancer ranges | Gateway never gets an address; every route 404s |
| `infrastructure/cilium/values.yaml` | `k8sServiceHost` (API VIP) | Cilium CrashLoopBackOff; whole cluster dead |
| `infrastructure/nfs-storage/nfs-volumes.yaml` | TrueNAS address | media pods stuck `ContainerCreating` |

Plus `bootstrap/terraform.tfvars` (`api_server_ip`) and the `interfaces` regex in
`infrastructure/cilium/l2-announcement-policy.yaml` if the NIC names differ.

Everything else derives from those. That was a deliberate goal of the
restructure: the old repo had the WAN IP copy-pasted into a dozen Ingress
objects.

---

## Before the move

### T-7 days: prove the backups

Do not move the hardware on the assumption that backups work. Force a
verification run and read the output:

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-postgres verify-premove
kubectl -n backup-verify logs -f job/verify-premove

kubectl -n backup-verify create job --from=cronjob/backup-verify-files verify-files-premove
kubectl -n backup-verify logs -f job/verify-files-premove
```

Both must pass. If Immich's file backup has never completed a full initial run,
**that will take days over a domestic uplink** — start it now, not the night
before.

```sh
# How much has actually been uploaded?
kubectl -n immich logs -l app.kubernetes.io/name=immich-library-backup --tail=50
```

### T-2 days: write down what you will not be able to look up

Once the cluster is off, you cannot read anything out of it. Put these somewhere
you can reach from a phone:

- [ ] the age private key (should already be in your password manager)
- [ ] the restic repository password
- [ ] S3 credentials
- [ ] TrueNAS root password and the iSCSI portal address
- [ ] the qBittorrent WebUI password
- [ ] Keycloak admin password
- [ ] this repository cloned to a laptop, not only on GitHub

### T-1 day: photograph everything

- [ ] back of the Turing Pi 2, every cable
- [ ] the switch, showing which port goes where
- [ ] the router's WAN and LAN config pages
- [ ] the router's port-forwarding table — you are about to recreate it

Label both ends of every cable. Masking tape and a pen beat memory.

---

## Shutdown day

```sh
task shutdown
```

The script will, in order: suspend Argo CD automation, take a final on-demand
backup of every database and wait for it, scale applications to zero, hibernate
the Postgres clusters properly (`cnpg.io/hibernation=on`, which is an orderly
shutdown rather than a kill), then cordon and drain.

It stops before halting the OS, because the order matters:

1. **Workers first, control plane last.** The node holding the API VIP goes last
   — otherwise you lose the ability to talk to the cluster halfway through.
2. **TrueNAS after the nodes.** It is serving the iSCSI volumes those nodes are
   using. Shutting it down first yanks storage out from under live mounts.
3. Then the Turing Pi board, the PSU, the switch.

### Packing

- The RK1 modules are on a carrier board with **heatsinks that act as levers**.
  Ship the board flat in antistatic packaging, not upright in a box of clothes.
- Drives ride flat, not on their edge, and not loose.
- Keep the SD cards / eMMC and the boot media with you, not in the removal van.

---

## Arrival day

### 1. Network first, cluster second

Get the LAN working before powering on a single node.

- [ ] router up, WAN connected, internet reachable from a laptop
- [ ] **note the new LAN subnet** (`192.168.1.0/24`? `192.168.0.0/24`? something else)
- [ ] **note the new public IP**: `curl -4 ifconfig.me`
- [ ] is the public IP static or DHCP? If dynamic, you need DDNS — see below
- [ ] find the router's DHCP range, because the LoadBalancer pool must sit
      *outside* it

That last point is the one people get wrong. If the LB pool overlaps DHCP, the
router will eventually lease the Gateway's address to a laptop and you will spend
an evening chasing "intermittent" outages.

### 2. Storage before compute

Power on TrueNAS alone. Confirm:

- [ ] pool imports, status `ONLINE`
- [ ] its IP address (set a static lease if it changed)
- [ ] iSCSI service running
- [ ] NFS share exported

### 3. Update the four files

Suppose the new LAN is `192.168.50.0/24` with DHCP on `.100–.200`, the NAS at
`192.168.50.10`, the API VIP at `192.168.50.11`, and the WAN IP is `203.0.113.42`:

```sh
git checkout -b chore/new-house-network
```

| File | Change |
|---|---|
| `infrastructure/cilium/values.yaml` | `k8sServiceHost: 192.168.50.11` |
| `infrastructure/cilium/ip-pools.yaml` | gateway pool `192.168.50.254/32`; services pool `192.168.50.240–249` |
| `infrastructure/nfs-storage/nfs-volumes.yaml` | `server: 192.168.50.10` |
| `infrastructure/gateway/gateway.yaml` | target annotation `203.0.113.42` |
| `bootstrap/terraform.tfvars` | `api_server_ip = "192.168.50.11"` |
| `infrastructure/secrets/democratic-csi-iscsi.sops.yaml` | iSCSI + API host (`task secrets:edit -- ...`) |

Both pools must be inside `192.168.50.0/24` and outside `.100–.200`.

Then:

```sh
task lint
git commit -am 'chore(network): re-address for the new house'
git push -u origin chore/new-house-network
```

Merge it before starting the cluster, so Argo converges on correct values
instead of fighting you.

### 4. Node addresses

The nodes themselves need static addresses on the new subnet. That is *not* in
this repo — it is netplan on each node:

```sh
ssh nedsi@homelab-cp-1.local
sudo -e /etc/netplan/00-installer-config.yaml
sudo netplan apply
```

Also re-check the kubelet `--node-ip` flag, which must be the node's own address
and not the API VIP. Getting this wrong produces ARP weirdness that looks like
random pod networking failures:

```sh
sudo -e /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
sudo systemctl daemon-reload && sudo systemctl restart kubelet
```

If the API VIP subnet changed, the control plane's certificates may not include
the new address. Symptom: `x509: certificate is valid for 192.168.1.11, not
192.168.50.11`. Fix:

```sh
# On each control-plane node:
sudo kubeadm init phase certs apiserver \
  --apiserver-cert-extra-sans 192.168.50.11,192.168.50.12,192.168.50.13
sudo systemctl restart kubelet
```

### 5. Power on, in order

Control plane first, one at a time, waiting for each to be Ready. Then workers.

```sh
kubectl get nodes -w
```

### 6. Bring the cluster up

```sh
task startup
```

It waits at each stage and tells you what to check. It deliberately leaves Argo
CD automation **off** at the end so you can verify before reconciliation starts.

### 7. Router: port forwarding

| Port | Protocol | To | For |
|---|---|---|---|
| 80 | TCP | Gateway LB address | HTTP → HTTPS redirect + ACME fallback |
| 443 | TCP | Gateway LB address | everything web |
| 22000 | TCP + UDP | Syncthing LB address | Syncthing peer sync |
| 50000 | TCP + UDP | qBittorrent LB address | torrent peers |

Find the addresses with:

```sh
kubectl -n gateway   get gateway shared -o jsonpath='{.status.addresses[0].value}'; echo
kubectl -n syncthing get svc syncthing-sync -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
kubectl -n theater   get svc qbittorrent-peer -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

### 8. Verify

```sh
./scripts/tls-check.sh
```

Then by hand:

- [ ] `https://argo.lilalala.com` loads and every Application is Healthy
- [ ] `https://media.lilalala.com` — Immich, and a photo actually renders
      (proves the NFS/iSCSI path, not just the web tier)
- [ ] `https://auth.lilalala.com` — Keycloak, and an OIDC login works
- [ ] `https://theater.lilalala.com` — Plex plays something
- [ ] Syncthing shows peers **Connected**, not "Disconnected (relay)"
- [ ] qBittorrent reports a **reachable** listen port
- [ ] the *arr apps show qBittorrent as available
      (if not: [arr-qbittorrent.md](arr-qbittorrent.md))

### 9. Re-tighten what the move loosened

- [ ] **NFS export allow-list** now points at the old node IPs, so it is either
      broken or wide open. Fix it: [nfs-hardening.md](nfs-hardening.md)
- [ ] certificates renewed cleanly (`kubectl get certificate -A`)
- [ ] a backup has run successfully **at the new location**:
      ```sh
      kubectl -n immich create job --from=cronjob/immich-library-backup postmove-check
      ```
- [ ] re-enable Argo CD automation once you are satisfied

---

## If the WAN address is dynamic

The Gateway annotation holds a static IP, which does not survive a changing
lease. Options, best first:

1. **Ask the ISP for a static IP.** Usually cheap, sometimes free.
2. **Cloudflare DDNS**: a small CronJob that PATCHes the DNS records from inside
   the cluster. external-dns will fight it over ownership, so you would set
   `policy: upsert-only` on the affected records — messy but workable.
3. **Router-side DDNS** to a separate hostname, then `CNAME` your records at it.
   Cleanest of the workarounds, because external-dns keeps managing a CNAME whose
   target is maintained by the router.

Option 3 is the one to reach for. Set the Gateway annotation to
`external-dns.alpha.kubernetes.io/target: home.<something>.net` — a hostname
rather than an IP — and let the router keep that hostname current.

---

## If it goes badly wrong

The data is on the NAS, and the NAS is intact. Worst case is a cluster rebuild,
not data loss:

1. Reinstall the OS on the nodes, `kubeadm init`.
2. Run the bootstrap: [../bootstrap.md](../bootstrap.md).
3. Argo CD reconstructs every workload from this repository.
4. PVs for the media library use `Retain`, so NFS data survives regardless.
5. iSCSI volumes are `Delete` — those come back from S3 via
   [../backups.md](../backups.md).

The reason this restructure was worth doing is that step 3 is now a real
sentence rather than an aspiration.
