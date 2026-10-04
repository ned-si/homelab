# homelab

## Hardware

- BMC: Turing Pi 2
- Modules: 4x RK1 32G

## Infra

- Talos on nodes, have to get the conf back here
  - ATM, installed with the tpi GUI. Would be nice to install that using
  Tinkerbell instead.
- Storage with Truenas, installed by hand. Currently set up for ISCSi uniquely.

## Kubernetes

Deploy certmanager + argocd with helm, then the rest using those.

## Public WAN IP

- The public IP lives in one place only: `--default-targets` in
  `kubernetes/applications/external-dns/external-dns.yaml`. Change it there
  only, never in Ingresses (they carry no target annotation).
- After pushing, move the `all-apps` `targetRevision` pin to the new commit.
- Follow-up: replace the static IP with a DDNS-updated record.


## NOTES:

DISABLE SWAP permanently!!
```sh
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo systemctl mask swapfile.swap
```
On nodes, to avoid ARP issue, add `--node-ip=<ip>` flag to kubelet to the node
IP, not the apiserver VIP:
```sh
sudo -e /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
```

add how to deploy cilium:
```sh
# first install CRDs (experimental necessary for cilium atm, it's a known bug).
#[doc here](https://gateway-api.sigs.k8s.io/guides/#install-experimental-channel)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
API_SERVER_IP=192.168.1.11
API_SERVER_PORT=6443
helm install cilium cilium/cilium --version 1.16.3 \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=${API_SERVER_IP} \
    --set k8sServicePort=${API_SERVER_PORT} \
    --set gatewayAPI.enabled=true TODO:UPDATE
```

actually, move installation to tofu for this...

then [this
doc](https://github.com/democratic-csi/democratic-csi?tab=readme-ov-file#ubuntu--debian)
for the democratic-csi.

- Write about current set up on Truenas's side. Try to make it better/leaner.

## ingress issue

- set NAT
- set ippool to existing internal range
- set external-dns annotation to ing
- set cilium L2 announcement policy
- upgrade helm with proper values for L2: `--set l2announcements.enabled=true
--set externalIPs.enabled=true`
- remove `extneralTrafficPolicy: Local`

## immich

- wth oidc not workin?
- tidy up argo hierarchy
- test queue
- test db
- what about scaling?

## syncthing

- LB is fine, but then NAT needs to be set.
- Global Discovery needs to be enabled on all clients.

## plex

- nfs: harden (!)
- move to official helm chart

