# Restart after the move — step by step

Follow this top to bottom. Every block is copy-paste. Do not skip the checks:
each one exists because the next step gives a confusing error if it fails.

**Time:** 75 minutes if nothing goes wrong; realistically about 2 hours. Steps 7
and 9 can be deferred to the afternoon — per-step estimates are on each heading
and there is an honest table at the end.
**You need:** the Mac, the router's admin page, physical access to the NAS and
the Turing Pi 2.

---

## Verified from the new house on 2026-08-07, before you start

Measured from the Mac on the new network, so Step 1 is much shorter than it
looks. Re-check anything here that you have since changed.

| | Result |
|---|---|
| LAN subnet | **already `192.168.1.0/24`**, gateway `192.168.1.1` — the single biggest risk in Step 1 is already satisfied. No node changes, no kube-vip changes, no certificate re-issue. |
| Mac address | `192.168.1.49` via DHCP |
| **New WAN IP** | **`31.164.170.92`** (was `188.155.74.203`) |
| `.228` NAS, `.238`/`.239`/`.240` nodes, `.11` VIP, `.254` ingress | **all free.** Nothing is squatting on them. |
| **`.247`** — homelab-cp-1 | **TAKEN by another device.** See the blocker below. |

### ⚠️ Blocker: something else is using `192.168.1.247`

```
192.168.1.247  ->  MAC f0:a7:31:e8:83:30   (no SSH, no kubelet — not a node)
192.168.1.251  ->  MAC f0:a7:31:e8:83:34   (same vendor, adjacent MAC)
```

`.247` is **`homelab-cp-1`**'s static address, configured in netplan on the node
itself. `homelab-cp-1` is also the node that normally holds the API VIP. If you
power the nodes on while another device holds `.247`, you get an ARP conflict:
cp-1 is unreachable, the VIP never comes up, and the whole cluster looks dead
for a reason that has nothing to do with the move.

The two devices are almost certainly a router-supplied appliance pair (set-top
box, access point) that grabbed high addresses from a wide DHCP pool. Fix it in
Step 1 by narrowing the DHCP range, then rebooting those two devices so they take
new leases.

**Do not power on the Turing Pi until the check at the end of Step 1 shows `.247`
free.** That check is the gate for the whole runbook.

Three things to know before you start:

1. **The cluster is running the old layout.** Argo CD (`all-apps`, namespace
   `argo`) is pinned to commit `c2dbd35`, path `kubernetes/applications` — the
   `main` tree. The `chore/gitops-restructure` branch is *not* live. So the
   files this guide edits are on `main`, not on the branch.
2. **Never run `git checkout main` in `~/repos/homelab`.** That checkout is on
   `chore/gitops-restructure` with ~97 modified files, and `main` does not
   contain `scripts/`, `docs/`, `apps/`, `clusters/`, `deploy/`,
   `infrastructure/`, `platform/` or `Taskfile.yml` at all. Git will refuse the
   checkout ("local changes would be overwritten"), and if you force it with
   `-f` you lose the restructure work, plus `scripts/` and `docs/` — which Steps
   8 and 9 need. Step 5 uses a throwaway clone instead. This file and
   `kubeconfig-homelab` are untracked, so they survive either way.
3. **Nothing was gracefully shut down, which is fine.** Nothing was scaled to
   zero or cordoned, so everything comes back on its own when the nodes boot.
   **Do not run `task startup` / `scripts/graceful-startup.sh`** — it is written
   for the post-migration layout and for a cluster that was quiesced. Its first
   check is `ping -c2 -W2`, and `-W` is *milliseconds* on macOS, so it declares
   the NAS unreachable and asks you to override. It then looks for a `gateway`
   namespace that does not exist, unhibernates databases that were never
   hibernated, and runs `kubectl scale deploy --all --replicas=1` across six app
   namespaces. This guide does everything useful it would have done — storage
   first, nodes, Cilium, PVCs, databases, certificates, then Argo — by hand and
   without the writes.

---

## Step 0 — Terminal setup (3 min)

Open **one** terminal and keep it for the whole procedure. This block **rewrites**
`env.sh`, so paste it once. If you do paste it again after Step 1, re-run the
`WAN=` block at the end of Step 1 too.

```sh
mkdir -p ~/homelab-move
cat > ~/homelab-move/env.sh <<'EOF'
export REPO="$HOME/repos/homelab"
export KUBECONFIG="$REPO/kubeconfig-homelab"

# Verified still correct on the new network 2026-08-07: the LAN really is
# 192.168.1.0/24 with gateway .1, so these addresses are unchanged.
export NAS=192.168.1.228
export VIP=192.168.1.11
export CP1=192.168.1.247
export CP2=192.168.1.238
export CP3=192.168.1.239
export W1=192.168.1.240
export LB_INGRESS=192.168.1.254
export PIN=c2dbd3503bea688af674aa22e9ccd4fced6e7fff
EOF
source ~/homelab-move/env.sh
echo "$REPO" && ls "$KUBECONFIG"
```

Expected: the repo path, then the kubeconfig path. If `ls` fails, your repo is
somewhere else — fix `REPO` in the file above and re-`source` it.

Preflight:

```sh
for t in kubectl curl git nc openssl ssh showmount dig; do
  printf '%-10s ' "$t"; command -v "$t" >/dev/null && echo ok || echo "MISSING"
done
kubectl version --client --output=yaml | grep gitVersion | head -1
```

- `kubectl` MISSING → `brew install kubectl`. Nothing else in this list can be
  missing except `dig`.
- **`dig` MISSING is expected** on recent macOS — Apple dropped the BIND tools.
  Either `brew install bind` (adds `dig`), or ignore it: the one place this
  guide needs DNS (Step 5) falls back to `curl` against Cloudflare's
  DNS-over-HTTPS endpoint automatically.

Nothing else is needed for this guide (no `task`, no `sops`, no `kustomize`,
no `argocd` CLI).

> If you open a new terminal at any point, run `source ~/homelab-move/env.sh`
> first.

---

## Step 1 — Router (10 min) — free `.247`, then narrow DHCP

**Good news, already measured: the LAN is `192.168.1.0/24` with gateway
`192.168.1.1`.** That is what the nodes' static netplan configuration expects, so
there is nothing to change about the subnet itself and no node console work.

The four nodes have static IPs in `/etc/netplan/` **on the nodes**. They are not
in git, so an address that another device is already holding cannot be fixed from
here — it has to be freed on the router.

**One thing must change: the DHCP pool is handing out addresses in the range the
static devices live in.** `.247` and `.251` are already occupied.

In the router admin page:

| Setting | Value | Why |
|---|---|---|
| LAN IP / gateway | `192.168.1.1` | already correct — confirm, do not change |
| Subnet mask | `255.255.255.0` | already correct |
| **DHCP range** | **`192.168.1.50` – `192.168.1.199`** | **this is the change.** Must exclude `.228` (NAS), `.238`–`.240` and `.247` (nodes), and `.254` (ingress LB) |

Then **reboot whatever is on `.247` and `.251`** so they request new leases inside
the narrowed pool. Power-cycling is enough; you do not need to identify them
first. If the router lets you delete a lease, do that too.

If you cannot find them: they are on `f0:a7:31:e8:83:30` and
`f0:a7:31:e8:83:34` — look for that MAC prefix in the router's client list, which
usually shows a name.

Then add static DHCP leases (harmless if the devices are statically configured,
and it saves you if any of them are not):

| Host | IP |
|---|---|
| truenas | `192.168.1.228` |
| homelab-cp-1 | `192.168.1.247` |
| homelab-cp-2 | `192.168.1.238` |
| homelab-cp-3 | `192.168.1.239` |
| homelab-w-1 | `192.168.1.240` |

Also add a **static route**: `192.168.2.0/24` via the LAN interface. The
LoadBalancer pool for Syncthing and qBittorrent lives in a different /24 from
the LAN and is announced by ARP from the worker node; without this route the
router cannot reach it. (This was already flaky at the old house — qBittorrent
reported `firewalled` before you left. It is not something you broke today.)

And enable **NAT loopback / hairpin NAT** if the router has the option. Every
`*.lilalala.com` record points at the *public* IP, so without it nothing
resolves usefully from inside the house and Step 8 fails for a reason that has
nothing to do with the cluster. Step 8 has a `/etc/hosts` workaround if your
router cannot do it.

You will come back to this page in Step 5 for the port forwards, which need
addresses the cluster has not announced yet.

### THE GATE — every static address must be free before you power on a node

Run this. It is the most important check in the runbook: it is the difference
between a 1-hour restart and an afternoon of debugging a "dead" cluster that is
actually an IP conflict.

```sh
IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
printf 'iface=%s  ip=%s  gateway=%s\n\n' "$IF" "$(ipconfig getifaddr "$IF")" "$GW"

# Repopulate the ARP cache, then check each address the cluster needs.
for a in 228 238 239 240 247 254 11; do
  (ping -c1 -W400 192.168.1.$a >/dev/null 2>&1 &)
done
sleep 4

BLOCKED=0
for a in 228 238 239 240 247 254 11; do
  mac=$(arp -n 192.168.1.$a 2>/dev/null | grep -o '[0-9a-f:]\{11,17\}' | head -1)
  if [ -n "$mac" ]; then
    printf '  192.168.1.%-4s OCCUPIED by %s\n' "$a" "$mac"; BLOCKED=1
  else
    printf '  192.168.1.%-4s free\n' "$a"
  fi
done
echo
[ "$BLOCKED" -eq 0 ] && echo "GATE PASSED - safe to power on the nodes" \
                     || echo "GATE FAILED - free the addresses above FIRST"
```

Expected: gateway `192.168.1.1`, an address in `192.168.1.x`, and **all seven
free**, ending in `GATE PASSED`.

`.247` was occupied when this was written. If it still is, go back and reboot that
device — do not continue. Everything downstream assumes cp-1 can take `.247`.

> Note: this check can only see devices that are *currently powered on*. A device
> that is off now and boots later can still steal an address, which is why the
> DHCP range narrowing above matters more than the check does.

Now capture the public IP. It was **`31.164.170.92`** on 2026-08-07, but it is a
dynamic address and rebooting the router in this step may well have changed it —
so measure it rather than trusting that number. **Step 5 stamps this exact value
into git, so do not type it by hand:**

```sh
WAN=$(curl -s -4 --max-time 10 https://ifconfig.me \
      || curl -s -4 --max-time 10 https://api.ipify.org)
case "$WAN" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf 'export WAN=%s\n' "$WAN" >> ~/homelab-move/env.sh
                               source ~/homelab-move/env.sh; echo "WAN=$WAN" ;;
  *) unset WAN; echo "did NOT get an IPv4 back - check the WAN link and re-run" ;;
esac
```

Expected: `WAN=` followed by your public IPv4. Write it on paper as well.

If it comes back `31.164.170.92`, nothing changed since last night and you are
fine. If it comes back different, that is also fine — Step 5 uses whatever this
prints. What matters is that you do not hand-type either value.

<details>
<summary>If the router genuinely cannot do 192.168.1.0/24</summary>

Stop and do not power on the nodes. You will need, per node, via the Turing Pi
BMC serial console (`tpi uart get -n <slot>` or the BMC web console):

1. `/etc/netplan/00-installer-config.yaml` — new address, gateway, `netplan apply`
2. `/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf` — `--node-ip` is
   the node's own new address, never the VIP
3. `/etc/kubernetes/manifests/kube-vip.yaml` on all three control planes — the
   new API VIP. Nothing in this repo manages kube-vip.
4. `kubeadm init phase certs apiserver --apiserver-cert-extra-sans <new VIP>,<node IPs>`
   on each control plane, then restart kubelet
5. The LoadBalancer pools in `kubernetes/applications/cilium/node-pool-1.yaml`
   and `node-pool-2.yaml`, and the NAS address in the six `*-deploy.yaml` files
   listed in the appendix

Budget half a day, not an hour.
</details>

---

## Step 2 — NAS alone (8 min)

Power on **only** the TrueNAS box. Nothing else.

The media share is mounted `hard` (`nfsvers=4.1,hard,timeo=600`). If the NAS is
not fully up before the nodes boot, media pods wedge in uninterruptible I/O and
cannot be killed. This ordering is not optional.

In the TrueNAS UI, confirm:

- **Storage → Pools**: pool imported, status **ONLINE** (it lost power too)
- **Services**: iSCSI **running**, NFS **running**
- **Sharing → NFS**: `/mnt/homelab/k8s/nfs` present

Then from the Mac — several checks, not just a ping:

```sh
source ~/homelab-move/env.sh
ping -c2 -t5 "$NAS" | tail -2
for p in 3260 2049 443; do
  printf 'NAS :%-5s ' "$p"
  nc -z -G 3 -w 3 "$NAS" "$p" && echo open || echo CLOSED
done
showmount -e "$NAS"
```

Expected: `2 packets received`; `open` for **3260** (iSCSI), **2049** (NFS) and
**443** (UI); and an export list containing `/mnt/homelab/k8s/nfs`.

`showmount` has no timeout flag on macOS. If it sits there for more than ~20
seconds, Ctrl-C it — that on its own means NFS is not answering, so go back to
**Services → NFS** in the UI.

**Do not continue until all of these pass.** A NAS that answers ping with an
unimported pool looks fine and then every volume fails to attach.

---

## Step 3 — Nodes (12 min)

Power the Turing Pi 2 on. Bring the nodes up **one at a time**, waiting for each
to answer before the next. Order:

1. `homelab-cp-1` (`.247`) — holds the API VIP
2. `homelab-cp-2` (`.238`)
3. `homelab-cp-3` (`.239`)
4. `homelab-w-1` (`.240`)

If the BMC supports per-slot power: `tpi power on -n <slot>`. If it powers the
board as a unit, that is fine — just wait for each node to answer before
checking the next.

```sh
source ~/homelab-move/env.sh
# -W is MILLISECONDS on macOS ping (it is seconds on Linux). 2000 = 2s. Correct
# as written -- do not "fix" it to -W2.
for h in "$CP1" "$CP2" "$CP3" "$W1"; do
  printf '%-16s ' "$h"; ping -c1 -W2000 "$h" >/dev/null 2>&1 && echo up || echo "DOWN"
done
printf 'API VIP %-8s ' "$VIP"
nc -z -G 3 -w 3 "$VIP" 6443 && echo listening || echo "NOT LISTENING"
```

All four `up` and the VIP `listening` before continuing.

```sh
kubectl get nodes -o wide
```

Expected: four nodes, all `Ready`. Give it two or three minutes — a cold boot
takes a while and `NotReady` immediately after boot is normal.

<details>
<summary>If the API VIP never comes up</summary>

kube-vip runs as a static pod on the control planes and is not managed by this
repo. Check from cp-1:

```sh
ssh nedsi@"$CP1" 'sudo crictl ps | grep -i vip; ip -4 addr show | grep 192.168.1.11'
```

If kube-vip is running but the VIP is not assigned, the usual cause is that
another device on the new LAN has taken `.11`. Check the router's DHCP client
list.

As a fallback, the kubeconfig has a second context that talks directly to cp-3:

```sh
kubectl config use-context homelab-direct
kubectl get nodes
```

Use that to get through the rest of the guide, then fix the VIP afterwards and
`kubectl config use-context homelab`.
</details>

Then etcd quorum (2 of 3 needed — nothing else checks this). The pod is found by
label rather than assumed to be `etcd-homelab-cp-1`, so this still works if cp-1
is the node that did not come back:

```sh
ETCD_POD=$(kubectl -n kube-system get pods -l component=etcd \
             -o jsonpath='{.items[0].metadata.name}')
echo "using $ETCD_POD"
kubectl -n kube-system exec "$ETCD_POD" -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster
```

Expected: three lines of the form
`https://192.168.1.2xx:2379 is healthy: successfully committed proposal: took ...`.
Two out of three is survivable; one is not — stop and fix that before anything
else. If `ETCD_POD` comes back empty, no control plane is up at all: go back to
the ping check above.

---

## Step 4 — Verify the cluster came back (12 min)

**4a. Check the Argo pin before touching anything.**

```sh
source ~/homelab-move/env.sh
kubectl -n argo get application all-apps \
  -o jsonpath='revision={.spec.source.targetRevision} prune={.spec.syncPolicy.automated.prune}{"\n"}'
```

Expected **exactly**:

```
revision=c2dbd3503bea688af674aa22e9ccd4fced6e7fff prune=false
```

> **If `revision` is `HEAD` or `main`, or `prune` is `true`: stop.** That
> configuration points at a path the restructure branch deletes, with pruning
> on. Restore the pin before doing anything else:
>
> ```sh
> kubectl -n argo patch application all-apps --type merge \
>   -p "{\"spec\":{\"source\":{\"targetRevision\":\"$PIN\"},\"syncPolicy\":{\"automated\":{\"prune\":false,\"selfHeal\":true}}}}"
> ```
>
> Then re-run the check above and confirm it now prints the expected line.
> `syncPolicy` has to be **inside** `spec` — a stray top-level `syncPolicy` is
> dropped by the API server without an error and `prune` stays `true`.

**4b. Cilium, then the ingress LoadBalancer.**

```sh
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system get ds cilium
kubectl -n ingress get svc ingress-nginx-controller -o wide
```

Expected: `daemon set "cilium" successfully rolled out`, then `4  4  4  4  4` on
the DaemonSet line, and `EXTERNAL-IP` = `192.168.1.254` on the Service.

While it is progressing `rollout status` prints
`Waiting for daemon set "cilium" rollout to finish: N of 4 updated pods are
available...` — that is normal for the first two or three minutes.

If Cilium crashloops, it is almost always `k8sServiceHost` pointing at an
unreachable API address — i.e. Step 1 did not actually give you
`192.168.1.0/24`. Confirm with:

```sh
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.k8s-service-host}{"\n"}'
```

Expected: `192.168.1.11`. Cilium was installed by hand with
`--set k8sServiceHost=...` (see `README.md` on `main`), so this value is not in
git and Argo will not fix it for you.

**4c. Volumes.** `--no-headers` matters: the header row does not contain the word
`Bound`, so without it the `||` branch can never fire.

```sh
kubectl get pvc -A --no-headers | grep -v ' Bound ' || echo "all PVCs Bound"
```

Anything unbound means the iSCSI portal or its credentials are wrong — go back
to Step 2 and confirm port 3260. Also check the CSI driver itself:

```sh
kubectl get pods -A --no-headers | grep -i democratic
```

**4d. Everything that is not happy.**

```sh
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' \
  || echo "all pods Running"
```

Keep this output. Step 6 fixes what shows up here. Expect some churn for the
first few minutes while images pull.

---

## Step 5 — New WAN IP (15 min)

The public IP is stamped into **ten** files on `main` as an
`external-dns.alpha.kubernetes.io/target` annotation. external-dns reads it and
writes the Cloudflare A records.

Editing the live objects with `kubectl annotate` does **not** work — `all-apps`
has `selfHeal: true` and will revert you within minutes. The change has to go
through git, and then the pin has to move to the new commit.

**5a. Get a clean checkout of `main`. Do not touch `$REPO`.**

`$REPO` is on `chore/gitops-restructure` with ~97 modified files. `git checkout
main` there will abort with *"Your local changes to the following files would be
overwritten by checkout"*, and forcing it deletes `scripts/`, `docs/` and the
whole restructure tree, because none of it exists on `main`. Steps 8 and 9 need
`scripts/`, so leave `$REPO` exactly as it is.

Work in a throwaway clone instead. Nothing you do in it can reach the
restructure work, and there is no branch to get wrong:

```sh
rm -rf ~/homelab-move/main-clone
git clone --branch main --single-branch \
  git@github.com:ned-si/homelab.git ~/homelab-move/main-clone
cd ~/homelab-move/main-clone && git log --oneline -1 && git status -sb
```

Expected: one commit line, and `## main...origin/main` with no modified files.

Confirm this is the repo Argo actually pulls from:

```sh
kubectl -n argo get application all-apps \
  -o jsonpath='{.spec.source.repoURL} {.spec.source.path}{"\n"}'
```

Expected: a `ned-si/homelab` URL and path `kubernetes/applications`. If the URL
is a different repo, clone *that* one instead.

**5b. Stamp the new address.** Count first, edit second — the count is the gate:

```sh
cd ~/homelab-move/main-clone
source ~/homelab-move/env.sh
OLD=188.155.74.203
grep -rl "$OLD" kubernetes/ > /tmp/wan-files.txt
wc -l < /tmp/wan-files.txt | tr -d ' '
cat /tmp/wan-files.txt
```

Expected: `10`, then the ten paths listed in the appendix. If it prints `0` you
are in the wrong directory — **stop**, do not run the next block, because a
`sed` over an empty file list either hangs on stdin or edits nothing and you
push a no-op commit.

```sh
cd ~/homelab-move/main-clone
echo "WAN=$WAN"                       # must be your new public IP, not empty
while IFS= read -r f; do
  [ -n "$f" ] && LC_ALL=C sed -i '' "s/$OLD/$WAN/g" "$f"
done < /tmp/wan-files.txt
git diff --stat | tail -1
grep -rl "$WAN" kubernetes/ | wc -l | tr -d ' '   # expect 10
grep -rl "$OLD" kubernetes/ | wc -l | tr -d ' '   # expect 0
```

Expected: `10 files changed, 10 insertions(+), 10 deletions(-)`, then `10`, then
`0`. If `WAN` printed empty, re-run the last block of Step 1 first — nothing
above this line has changed a file yet.

**5c. Push it.** Straight to `main`: there is nothing to review here and a PR is
one more thing to get wrong at 8am.

```sh
cd ~/homelab-move/main-clone
git commit -am "chore(dns): point external-dns at the new WAN address"
git show --stat --oneline HEAD | tail -1
git push origin main
NEW_SHA=$(git rev-parse HEAD); echo "NEW_SHA=$NEW_SHA"
```

Expected: `10 files changed, 10 insertions(+), 10 deletions(-)`, a successful
push, and a 40-character `NEW_SHA`. **If `git commit` complained about
`user.email`, fix that and re-run this block** — otherwise `NEW_SHA` is the
*unchanged* commit and 5d pins the stale IP without any error.

If the push is rejected because `main` is protected, do it as a PR and then take
the merged SHA from the remote — not from your local branch:

```sh
cd ~/homelab-move/main-clone
git push origin HEAD:refs/heads/chore/wan-ip     # then merge it on GitHub
git fetch origin && NEW_SHA=$(git rev-parse origin/main); echo "NEW_SHA=$NEW_SHA"
```

**5d. Move the pin.** Same terminal — `NEW_SHA` is a plain shell variable.

```sh
kubectl -n argo patch application all-apps --type merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$NEW_SHA\"}}}"
kubectl -n argo annotate application all-apps \
  argocd.argoproj.io/refresh=hard --overwrite
sleep 45
kubectl -n argo get application all-apps -o wide
```

Expected: `Synced` / `Healthy`, and the `REVISION` column showing `$NEW_SHA`.
`prune` stays `false` — do not change it. The only difference between the old pin
and the new one is those ten annotations, so this is a safe move.

If it stays `Unknown` or reports an error, read the reason — the most likely one
is a GitHub token that expired while the rack was in a van:

```sh
kubectl -n argo get application all-apps \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

**5e. Confirm DNS actually updated.** This uses `dig` if you have it and
Cloudflare DoH over `curl` if you do not, so it works on a stock Mac:

```sh
resolve() {
  if command -v dig >/dev/null 2>&1; then dig +short "$1" @1.1.1.1
  else curl -s -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" \
       | grep -o '"data":"[0-9.]*"' | cut -d'"' -f4; fi
}
sleep 90
for h in argo auth grafana theater cinema media archive cook drive syncthing; do
  printf '%-10s %s\n' "$h" "$(resolve "$h.lilalala.com" | tr '\n' ' ')"
done
echo "want: $WAN"
```

Expected: all ten showing **only** `$WAN`. If a name shows two addresses, the old
record is still there — see the note below. If a name shows nothing, that
Ingress has not synced yet; wait two minutes and re-run.

If records are stale, check external-dns:

```sh
kubectl -n external-dns logs deploy/external-dns --tail=50
```

Note external-dns on this cluster runs the default `upsert-only` policy, so it
updates records but never deletes them. Old records pointing at the previous IP
will linger until you remove them in Cloudflare by hand. Harmless, but tidy
them up when you have a moment.

**5f. Router port forwards** — back to the router page. Read the real addresses
first rather than trusting the table; Cilium hands these out from a pool and
`.0`/`.1` is an ordering, not a guarantee:

```sh
kubectl -n ingress   get svc ingress-nginx-controller -o wide
kubectl -n syncthing get svc syncthing-protocol       -o wide
kubectl -n theater   get svc qbittorrent-seed         -o wide
```

| Port | Protocol | To (expected) |
|---|---|---|
| 80 | TCP | `ingress-nginx-controller` — `192.168.1.254` |
| 443 | TCP | `ingress-nginx-controller` — `192.168.1.254` |
| 22000 | TCP + UDP | `syncthing-protocol` — `192.168.2.0` |
| 21027 | UDP | `syncthing-protocol` — `192.168.2.0` |
| 50000 | TCP | `qbittorrent-seed` — `192.168.2.1` |

`qbittorrent-seed` declares **TCP only** on `main`, so a UDP 50000 forward has
nothing to land on. Forward TCP and leave UDP for after the migration, which adds
the UDP port.

---

## Step 6 — Fix the known breakages (20 min)

An unclean power cut leaves lock files and socket files behind. Work through
these in order; skip any whose check passes.

**6a. qBittorrent — expect this one to be broken.**

A stale `/config/config/ipc-socket` from the April power event is what caused
the last outage, and this power cut is the same event. The probes that would
surface it fast exist only on the restructure branch, so the live Deployment
still reports `Running 1/1`, `0` restarts, with nothing listening.

Two commands, two seconds. The `ss` fallback chain is there because `ss` is not
guaranteed in the image (it was present on 2026-07-31; `:latest` may have moved):

```sh
kubectl -n theater exec deploy/qbittorrent -- sh -c \
  'ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || netstat -ln 2>/dev/null \
   || cat /proc/net/tcp'
kubectl -n theater exec deploy/qbittorrent -- ls -la /config/config
```

Expected if healthy: a row listening on `:8080` (or, in the `/proc/net/tcp`
fallback, a local address ending `:1F90`). **An empty table is the bug**, and
`ipc-socket` in that directory listing is the confirmation.

```sh
kubectl -n theater exec deploy/qbittorrent -- sh -c '
  cd /config/config || { echo "NO /config/config - different problem"; exit 1; }
  mkdir -p /config/quarantine
  mv -f ipc-socket lockfile /config/quarantine/ 2>/dev/null
  echo "quarantined:"; ls -la /config/quarantine'
kubectl -n theater rollout restart deploy/qbittorrent
kubectl -n theater rollout status deploy/qbittorrent --timeout=5m
kubectl -n theater exec deploy/qbittorrent -- sh -c \
  'ss -lntp 2>/dev/null || netstat -ln 2>/dev/null || cat /proc/net/tcp'
```

Both files are runtime artefacts recreated on every start — nothing is lost. The
Deployment is `strategy: Recreate` on an RWO volume, so the old pod is torn down
before the new one starts; two minutes of `rollout status` saying nothing is
normal.

Then confirm the *arr side sees it:

```sh
kubectl -n theater exec deploy/sonarr -- sh -c '
  U=http://qbittorrent:8080/api/v2/app/version
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w "sonarr->qbt %{http_code}\n" "$U"
  else
    wget -qO- "$U" && echo "  <- sonarr->qbt reachable (wget)"
  fi'
```

`200` is good. `000` means still refused. `401`/`403` is an auth problem, not
this problem. (Do not point this at sonarr's own API — the *arr apps run with
`URLBASE` set, so `/api/v3/...` returns `307`, which reads like a broken API.)

**6b. Any pod stuck in `CreateContainerError` or `ContainerCreating`.**

This is the `cilium-mgr9z` failure mode: a stale containerd container-name
reservation held by a dead sandbox. The pod UID is part of the container name,
so deleting the pod always resolves it.

```sh
kubectl get pods -A --field-selector=status.phase!=Running \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase' \
  --no-headers | grep -v Succeeded
```

For each one:

```sh
kubectl -n <namespace> delete pod <pod>
```

Read `state`, not `lastState`, when diagnosing — the last outage was chased for
119 days because a stale network error in `lastState` looked like the cause.

**6c. Databases.**

Seven single-instance CloudNativePG clusters. Single instance means no failover
and no ordering between them, but also no standby to promote.

**Check the operator first.** It is not in `cnpg-system` on this cluster — it
runs in the `immich` namespace, which is odd but is what is deployed. If it is
down, all seven clusters stay down and nothing below will help:

```sh
kubectl -n immich rollout status deploy/cnpg-cloudnative-pg --timeout=3m
```

Expected: `deployment "cnpg-cloudnative-pg" successfully rolled out`.

Then each cluster. The primary pod is read from `.status.currentPrimary` rather
than assumed to be `<cluster>-1`, because after a recreate it can be `-2` or
`-3` and a wrong name gives a silent `NotFound`:

```sh
for p in immich/immich-db keycloak/keycloak-db mealie/mealie-postgresql \
         theater/sonarr-postgresql theater/radarr-postgresql \
         theater/prowlarr-postgresql theater/lidarr-postgresql; do
  ns=${p%%/*}; cl=${p##*/}
  printf '\n== %s/%s\n' "$ns" "$cl"
  kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cl" --no-headers \
    -o custom-columns='INSTANCES:.status.instances,READY:.status.readyInstances,PRIMARY:.status.currentPrimary,PHASE:.status.phase' \
    || { echo "   NOT FOUND - the operator has not reconciled it yet"; continue; }
  pod=$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cl" \
          -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
  [ -n "$pod" ] && kubectl -n "$ns" logs "$pod" -c postgres --tail=60 2>/dev/null \
    | grep -Ei 'recovery|redo|fatal|panic|pg_control|ready to accept' | tail -5
done
```

Expected per cluster: `1  1  <cluster>-1  Cluster in healthy state`.

`"was not properly shut down; automatic recovery in progress"` followed by
`"ready to accept connections"` is **normal and fine** — that is Postgres doing
its job.

`PANIC` or any `pg_control` error is not. **If that happens on `immich-db`,
stop and do not let anything upgrade it.** It runs
`cloudnative-pgvecto.rs:16.5-v0.3.0` on PG 16 with `vectors.so` preloaded; its
dump will not restore against a stock `postgresql:17` image, and the
VectorChord migration is irreversible.

Seafile's MariaDB is the one database not under CNPG, so it has no PITR:

```sh
kubectl -n seafile logs deploy/mariadb --tail=40 | grep -Ei 'innodb|recovery|error' | tail -10
```

Look for `InnoDB: Starting crash recovery` → `InnoDB: ... started`.

**6d. Anything else that will not start** — same class of problem, same fix.
Exec in, move the artefact aside, restart:

| App | Artefact | Where |
|---|---|---|
| Seafile | `seaf-server.pid`, `ccnet-server.pid`, `seahub.pid`, `seafdav.pid` | `/shared` |
| Paperless Valkey | truncated AOF tail → `redis-check-aof --fix appendonly.aof` | its data volume |
| Paperless | Whoosh `.lock`; may need `document_index reindex` | its data volume |
| Syncthing | `database corrupted` → let it rebuild the index, **do not delete the PV** (device keys and folder IDs live there) | — |

**6e. Disk on the nodes.** `/controller` was at 83% of a 29 GB eMMC before the
move, and a cold start re-pulls a lot of images at once (qBittorrent, the four
*arr and Seafile run `:latest`; Plex and Jellyfin have no tag at all, all with
`imagePullPolicy: Always`).

```sh
source ~/homelab-move/env.sh
for h in "$CP1" "$CP2" "$CP3" "$W1"; do
  printf '%-16s ' "$h"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      nedsi@"$h" 'df -h /controller | tail -1' 2>/dev/null || echo "ssh failed"
done
kubectl get pods -A --no-headers | grep -E 'ErrImagePull|ImagePullBackOff' \
  || echo "no image pull failures"
```

`BatchMode=yes` is deliberate: without it a node with no key wedges the loop on a
password prompt. `ssh failed` here is not fatal — it only means you cannot read
the disk figure for that node.

If a node is above ~90% (this one *will* ask for the sudo password, so run it on
its own):

```sh
ssh nedsi@<node-ip> 'sudo crictl rmi --prune'
```

---

## Step 7 — Certificates (5 min) — there is a real deadline here

Ten certificates were due to renew on 2026-08-11 and expire **2026-09-10**. The
renewal window opened while the rack was in a van.

```sh
kubectl get certificate -A
kubectl get certificaterequest,order,challenge -A 2>/dev/null | grep -v '^$'
```

Expected: ten rows, all `READY=True`. If any is not:

```sh
kubectl -n cert-manager logs deploy/cert-manager --tail=100 | grep -iE 'error|fail'
```

Validation is DNS-01 via Cloudflare through ClusterIssuer **`letsencrypt`**,
using the Secret **`cloudflare-api-token-secret`** — those exact names.

```sh
kubectl -n cert-manager get secret cloudflare-api-token-secret >/dev/null 2>&1 \
  && echo "token secret present" || echo "TOKEN SECRET MISSING"
kubectl get clusterissuer letsencrypt \
  -o jsonpath='letsencrypt ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `token secret present` and `letsencrypt ready=True`. If the issuer is
not ready, that is the whole problem — the certificates cannot renew until it is,
and the deadline is 2026-09-10.

If a challenge is stuck for more than ~15 minutes, delete the Order and let
cert-manager retry:

```sh
kubectl -n <ns> delete order <order-name>
```

---

## Step 8 — End-to-end verification (10 min)

**Do not run `./scripts/tls-check.sh`.** It derives its hostname list from
`deploy/`, which is the *post-migration* layout: 15 names including
`sonarr`, `radarr`, `lidarr`, `prowlarr` and `qbittorrent`, none of which the
live cluster publishes. It will print five `UNREACHABLE over https` lines and
`tls-check FAILED`, and none of that is a real fault. Use this instead — same
checks, restricted to the ten hostnames that actually exist today, and BSD-`date`
correct:

```sh
for h in argo auth grafana theater cinema media archive cook drive syncthing; do
  fq="$h.lilalala.com"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 "https://$fq/" 2>/dev/null || echo 000)
  end=$(echo | openssl s_client -servername "$fq" -connect "$fq:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  days='?'
  if [ -n "$end" ] && exp=$(date -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null); then
    days=$(( (exp - $(date +%s)) / 86400 ))
  fi
  printf '%-10s http=%-4s cert_days_left=%s\n' "$h" "$code" "$days"
done
```

Expected: `http=` is `200`, `302` or `403` for every row (a login redirect is
fine; `000` is not), and `cert_days_left` is **above 30** for all ten. Anything
under 21 means renewal is failing — go back to Step 7.

> **If every row is `000`:** your router almost certainly does not do NAT
> loopback, so these public names do not resolve to anything reachable from
> inside the house. That is a router limitation, not a cluster fault. Prove it
> and unblock the browser checks below with a temporary hosts file:
>
> ```sh
> printf '192.168.1.254 %s\n' argo auth grafana theater cinema media \
>   archive cook drive syncthing \
>   | sed 's/$/.lilalala.com/' | sudo tee -a /etc/hosts
> ```
>
> Re-run the loop. Remove those lines from `/etc/hosts` once the router is fixed,
> or external access will look fine from this Mac when it is not.

Then by hand, in a browser. The Immich one is the important one — it is the only
check that proves the NFS and iSCSI paths rather than just the web tier.

- [ ] `https://argo.lilalala.com` — Argo CD loads, `all-apps` Synced/Healthy
- [ ] `https://media.lilalala.com` — Immich **renders an actual photo**
- [ ] `https://auth.lilalala.com` — Keycloak login works
- [ ] `https://theater.lilalala.com` — Plex plays something
- [ ] `https://cinema.lilalala.com` — Jellyfin loads
- [ ] `https://archive.lilalala.com` — Paperless loads
- [ ] `https://cook.lilalala.com` — Mealie loads
- [ ] `https://drive.lilalala.com` — Seafile loads
- [ ] `https://syncthing.lilalala.com` — shows at least one peer `Connected`
- [ ] `https://grafana.lilalala.com` — Grafana loads

And the *arr → qBittorrent link, which is what broke last time:

```sh
for a in sonarr radarr lidarr prowlarr; do
  printf '%-9s ' "$a"
  kubectl -n theater exec "deploy/$a" -- \
    curl -s -m 10 -o /dev/null -w '%{http_code}\n' \
    "http://qbittorrent:8080/api/v2/app/version" 2>/dev/null || echo "exec failed"
done
```

Expected: `200` on all four. `000` means qBittorrent is not listening — go back
to 6a. `exec failed` means that Deployment is not up, which is a 6b/6c problem.

---

## Step 9 — Take a backup (15 min) — deferrable to the afternoon

You are now in a better state than you were an hour ago. Capture it before
anything else. This is the one step you can safely postpone if you are out of
time — but postpone it by hours, not days.

`$REPO` is still on `chore/gitops-restructure`, which is where this script lives
(`main` has no `scripts/`). That is why Step 5 used a separate clone.

```sh
cd "$REPO" && ./scripts/dump-databases.sh
ls -la ~/homelab-backups/
```

Expected: nine `ok` rows (seven Postgres, one MariaDB, one SQLite) and
`verified=9  failed=0`. It takes roughly 10 minutes and ~400 MB.

If it exits immediately with `usage: mktemp ...`, that is BSD `mktemp` wanting a
template. One-line fix, then re-run:

```sh
cd "$REPO" && sed -i '' 's|STATUS="$(mktemp)"|STATUS="$(mktemp -t hlstatus)"|' \
  scripts/dump-databases.sh && grep -n 'STATUS="' scripts/dump-databases.sh | head -1
```

Copy the new directory to Proton Drive alongside the 2026-08-03 one.

Then note what is still **not** covered, so you do not mistake this for safety:
no S3 (every `destinationPath` in the repo is still
`s3://homelab-backups-REPLACE-ME/...`), no scheduled backup of any kind, and no
file-level backup at all for Seafile, Syncthing or the *arr config volumes.
Fixing that is the first item after the restart.

---

## Step 10 — Leave it alone

Do **not** re-enable anything, do not merge the restructure branch, do not
remove the pin. `all-apps` should end the day exactly as it started:

```sh
kubectl -n argo get application all-apps \
  -o jsonpath='revision={.spec.source.targetRevision} prune={.spec.syncPolicy.automated.prune}{"\n"}'
```

Expected: the new SHA from Step 5, and `prune=false`.

Also throw away the Step 5 clone, so nobody later mistakes it for a working copy:

```sh
rm -rf ~/homelab-move/main-clone
```

Write down anything that surprised you. That list is the input to the migration.

---

## Honest timings

| Step | Estimate | Notes |
|---|---|---|
| 0 Terminal | 3 min | |
| 1 Router | 10 min | Was 20. The subnet is already correct — this is now just DHCP range + freeing `.247` + forwards. |
| 2 NAS | 8 min | Pool import dominates. |
| 3 Nodes | 12 min | Cold boot of four RK1 modules. |
| 4 Verify | 12 min | Images re-pull on `:latest` + `Always`. |
| 5 WAN IP | 15 min | Includes the 90 s DNS wait and the router port forwards. |
| 6 Breakages | 20 min | Wildly variable. Could be 5, could be 45. |
| 7 Certificates | 5 min | **Deferrable** unless a cert is under 21 days. |
| 8 Verification | 10 min | |
| 9 Backup | 15 min | **Deferrable to the afternoon.** |
| 10 Leave it alone | 2 min | |

**Best case 65 minutes. Realistic under 2 hours.** The one-hour version is
Steps 0–6 plus the automated part of 8, with 7 and 9 done after lunch.

The subnet already being `192.168.1.0/24` removes what would have been the worst
overrun. What is left that can still cost you an hour: **the `.247` conflict**, if
you power the nodes on before freeing it (Step 1's gate), and **Step 6**, if
something other than qBittorrent left a lock file behind.

---

## Appendix — where the old addresses live on `main`

`main` contains **only** `.github/`, `.gitignore`, `README.md`, `iac/` and
`kubernetes/` — 85 files. No `scripts/`, no `docs/`, no `Taskfile.yml`, no
`apps/`/`clusters/`/`deploy/`/`infrastructure/`/`platform/`. That is the whole
reason Step 5 uses a separate clone.

**WAN IP `188.155.74.203`** — 10 files (verified with
`git grep -n 188.155.74.203 main`):

```
kubernetes/applications/argo-ingress.yaml:9
kubernetes/applications/immich/immich.yaml:63
kubernetes/applications/jellyfin/jellyfin-ing.yaml:7
kubernetes/applications/keycloak/keycloak-ingress.yaml:7
kubernetes/applications/kube-prom-stack.yaml:53
kubernetes/applications/mealie/mealie-ingress.yaml:7
kubernetes/applications/paperless/seafile-ingress.yaml:7
kubernetes/applications/plex/theater-ing.yaml:7
kubernetes/applications/seafile/seafile-ingress.yaml:7
kubernetes/applications/syncthing/syncthing-ing.yaml:7
```

**NAS `192.168.1.228`** — inline NFS volumes, not PVs:

```
kubernetes/applications/jellyfin/jellyfin-deploy.yaml:52
kubernetes/applications/lidarr/lidarr-deploy.yaml:76
kubernetes/applications/plex/plex-deploy.yaml:51
kubernetes/applications/qbittorrent/qbittorrent-deploy.yaml:53
kubernetes/applications/radarr/radarr-deploy.yaml:76
kubernetes/applications/sonarr/sonarr-deploy.yaml:76
iac/truenas-iscsi.yaml:30,36,101   (iSCSI API host, SSH host, target portal)
```

**LoadBalancer pools:**

```
kubernetes/applications/cilium/node-pool-1.yaml:7   192.168.1.254/32  (ingress)
kubernetes/applications/cilium/node-pool-2.yaml:7   192.168.2.0/24    (syncthing .0, qbittorrent .1)
```

**Not in git, must be done on the nodes or the router:** netplan, kubelet
`--node-ip`, kube-vip static pods, apiserver cert SANs, TrueNAS NFS exports and
iSCSI portal, router port forwards, the `192.168.2.0/24` static route,
split-horizon DNS for `lilalala.com`.

Note for later: `grep -rn SITE-SPECIFIC` on the `chore/gitops-restructure`
branch finds a much shorter list — the restructure collapses the WAN IP to a
single annotation and the NAS address to three PVs. That is the
*post-migration* layout, and it is not what the cluster reads today. Do not
follow it for this restart.
