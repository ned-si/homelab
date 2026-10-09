# WAN IP change

The ISP gives the house a dynamic public address. When it changes, every
`*.lilalala.com` record still points at the old one and the public names stop
answering. The fix is one line in git:
`--default-targets` in
[`infrastructure/external-dns/values.yaml`](../../infrastructure/external-dns/values.yaml),
the only copy of the address (CI rule `wan-ip-single-source` fails a second one).

- Time: 15 minutes, most of it CI.
- You need: the Mac on the house network (not a phone hotspot: it reports the
  carrier's address), this repository, `kubeconfig-homelab`, `gh`, and the
  router's admin page.
- When: after a router reboot, a power loss, a move, or when
  [`scripts/smoke.sh`](../../scripts/smoke.sh) item 10 logs
  `WAN rule: api.ipify.org and ifconfig.me agree on <ip>`.

## 1. Detect

```sh
cd ~/repos/homelab
export KUBECONFIG="$PWD/kubeconfig-homelab"
ping -c1 -t3 192.168.1.1 >/dev/null && echo "on the house network" || echo "NOT on the house network"
curl -s -4 -m 10 https://api.ipify.org; echo
dig +short myip.opendns.com @resolver1.opendns.com
grep -- '--default-targets' infrastructure/external-dns/values.yaml
dig +short media.lilalala.com @1.1.1.1
```

Expected: `on the house network`, the same address from `api.ipify.org` and
OpenDNS, and that address in `--default-targets` and in the public answer.
Nothing to do then.

If the Mac's answer is in doubt, ask from inside the cluster, which always
leaves through the house router:

```sh
kubectl -n default run wan-ip-check --image=curlimages/curl:8.11.1 --restart=Never \
  --command -- curl -s -m 15 https://api.ipify.org
sleep 30; kubectl -n default logs wan-ip-check; echo
kubectl -n default delete pod wan-ip-check
```

Expected: one IPv4 address. It is the authoritative one.

## 2. Change the address

Replace the address on the `--default-targets=` line, then open and merge a
pull request:

```sh
NEW=<new-wan-ip>
git switch main && git pull --ff-only
git switch -c fix/wan-ip
sed -i '' "s/--default-targets=[0-9.]*/--default-targets=$NEW/" infrastructure/external-dns/values.yaml
git diff --stat
git commit -am "fix(external-dns): point records at the new WAN IP"
git push -u origin fix/wan-ip
gh pr create --fill
gh pr checks --watch
scripts/pr-merge.sh <pr-number>
git switch main && git pull --ff-only && git branch -d fix/wan-ip
```

Expected: `git diff --stat` shows one file and one line changed, every check
passes, and `pr-merge.sh` squash-merges the PR. If `wan-ip-single-source`
fails, the address was also written somewhere else: remove that copy.

## 3. Verify DNS and HTTPS

Argo CD syncs `external-dns` from `main` within three minutes, and external-dns
updates the Cloudflare records on its next loop (one minute):

```sh
kubectl -n external-dns get deploy external-dns \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep default-targets
kubectl -n external-dns logs deploy/external-dns --since=10m | grep -i 'UPDATE' | head
for h in argo auth grafana theater cinema media archive cook drive syncthing; do
  printf '%-10s %-16s %s\n' "$h" "$(dig +short "$h.lilalala.com" @1.1.1.1 | tr '\n' ' ')" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$h.lilalala.com/")"
done
```

Expected: the new address in the Deployment's arguments, `UPDATE` lines for
the A records, the new address for every hostname, and `200`, `302` (login
redirect) or `401` (`theater`, Plex) for every hostname. `000` is a failure.
Records are never deleted (`--policy=upsert-only`), so stale ones from removed
hostnames keep the old address; that is harmless.

- Old address still answered after 10 minutes: the cache in `1.1.1.1` holds it
  for the record's TTL; check the record in the Cloudflare dashboard.
- External-dns logs an authentication error: the token in
  `cloudflare-api-token-secret` is no longer valid ([secrets.md](../secrets.md)).

## 4. Check the router

On the router's admin page (`192.168.1.1`), the port forwards must still be:

| Port | Target | Service |
| --- | --- | --- |
| 80, 443 TCP | `192.168.1.254` | Gateway `gateway/shared` |
| 22000 TCP and UDP | `192.168.1.201` | Syncthing |
| 50000 TCP | `192.168.1.200` | qBittorrent seeding |

From a phone on mobile data, open `https://media.lilalala.com`. Expected: the
Immich login page. NAT loopback makes step 3 pass from the house even when a
forward is missing, so only an outside client proves the forward.

## Rollback

Revert the merged PR (`git revert <sha>` on a branch, then the same PR and
`pr-merge.sh` steps). external-dns writes the previous address back.

## Why it is like this

The address is set by hand in git because a second, automatic writer would
fight external-dns over the same records. A DDNS updater that opens this pull
request itself is the planned automation.
