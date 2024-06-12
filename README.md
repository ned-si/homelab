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
