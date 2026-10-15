#!/bin/bash
# install-tool.sh <tool>... -- install pinned CI binaries (linux amd64).
#
# Version and sha256 come from the workflow `env:` (<TOOL>_VERSION, <TOOL>_SHA256);
# the download is verified with sha256sum before anything is extracted or run.
# Installs into $RUNNER_TEMP/bin and appends that directory to $GITHUB_PATH.
# Tools: kubeconform actionlint shellcheck gitleaks trivy kyverno kube-linter helm
#        kubectl kind tofu promtool alertmanager talhelper talosctl
set -euo pipefail

bin="${RUNNER_TEMP:?RUNNER_TEMP not set}/bin"
mkdir -p "$bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

need() { # NAME -> value of env var NAME, or fail
  local v=${!1:-}
  [ -n "$v" ] || { echo "install-tool: $1 is not set" >&2; exit 1; }
  printf '%s' "$v"
}

fetch() { # url sha256 -> $work/dl
  curl -fsSL --retry 3 --retry-delay 5 -m 300 -o "$work/dl" "$1"
  echo "$2  $work/dl" | sha256sum -c --quiet - || { echo "install-tool: sha256 mismatch for $1" >&2; exit 1; }
}

for tool in "$@"; do
  case "$tool" in
    kubeconform)
      v=$(need KUBECONFORM_VERSION); fetch "https://github.com/yannh/kubeconform/releases/download/$v/kubeconform-linux-amd64.tar.gz" "$(need KUBECONFORM_SHA256)"
      tar -xzf "$work/dl" -C "$bin" kubeconform ;;
    actionlint)
      v=$(need ACTIONLINT_VERSION); fetch "https://github.com/rhysd/actionlint/releases/download/v$v/actionlint_${v}_linux_amd64.tar.gz" "$(need ACTIONLINT_SHA256)"
      tar -xzf "$work/dl" -C "$bin" actionlint ;;
    shellcheck)
      v=$(need SHELLCHECK_VERSION); fetch "https://github.com/koalaman/shellcheck/releases/download/$v/shellcheck-$v.linux.x86_64.tar.xz" "$(need SHELLCHECK_SHA256)"
      tar -xJf "$work/dl" -C "$work" && install -m 0755 "$work/shellcheck-$v/shellcheck" "$bin/shellcheck" ;;
    gitleaks)
      v=$(need GITLEAKS_VERSION); fetch "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_linux_x64.tar.gz" "$(need GITLEAKS_SHA256)"
      tar -xzf "$work/dl" -C "$bin" gitleaks ;;
    trivy)
      v=$(need TRIVY_VERSION); fetch "https://github.com/aquasecurity/trivy/releases/download/v$v/trivy_${v}_Linux-64bit.tar.gz" "$(need TRIVY_SHA256)"
      tar -xzf "$work/dl" -C "$bin" trivy ;;
    kyverno)
      v=$(need KYVERNO_VERSION); fetch "https://github.com/kyverno/kyverno/releases/download/$v/kyverno-cli_${v}_linux_x86_64.tar.gz" "$(need KYVERNO_SHA256)"
      tar -xzf "$work/dl" -C "$bin" kyverno ;;
    kube-linter)
      v=$(need KUBE_LINTER_VERSION); fetch "https://github.com/stackrox/kube-linter/releases/download/$v/kube-linter-linux.tar.gz" "$(need KUBE_LINTER_SHA256)"
      tar -xzf "$work/dl" -C "$bin" kube-linter ;;
    helm)
      v=$(need HELM_VERSION); fetch "https://get.helm.sh/helm-$v-linux-amd64.tar.gz" "$(need HELM_SHA256)"
      tar -xzf "$work/dl" -C "$work" && install -m 0755 "$work/linux-amd64/helm" "$bin/helm" ;;
    kubectl)
      v=$(need KUBECTL_VERSION); fetch "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl" "$(need KUBECTL_SHA256)"
      install -m 0755 "$work/dl" "$bin/kubectl" ;;
    kind)
      v=$(need KIND_VERSION); fetch "https://github.com/kubernetes-sigs/kind/releases/download/$v/kind-linux-amd64" "$(need KIND_SHA256)"
      install -m 0755 "$work/dl" "$bin/kind" ;;
    tofu)
      v=$(need TOFU_VERSION); fetch "https://github.com/opentofu/opentofu/releases/download/v$v/tofu_${v}_linux_amd64.tar.gz" "$(need TOFU_SHA256)"
      tar -xzf "$work/dl" -C "$bin" tofu ;;
    promtool)
      v=$(need PROMTOOL_VERSION); fetch "https://github.com/prometheus/prometheus/releases/download/v$v/prometheus-$v.linux-amd64.tar.gz" "$(need PROMTOOL_SHA256)"
      tar -xzf "$work/dl" -C "$work" && install -m 0755 "$work/prometheus-$v.linux-amd64/promtool" "$bin/promtool" ;;
    alertmanager) # alertmanager and amtool
      v=$(need ALERTMANAGER_VERSION); fetch "https://github.com/prometheus/alertmanager/releases/download/v$v/alertmanager-$v.linux-amd64.tar.gz" "$(need ALERTMANAGER_SHA256)"
      tar -xzf "$work/dl" -C "$work"
      install -m 0755 "$work/alertmanager-$v.linux-amd64/alertmanager" "$bin/alertmanager"
      install -m 0755 "$work/alertmanager-$v.linux-amd64/amtool" "$bin/amtool" ;;
    talhelper)
      v=$(need TALHELPER_VERSION); fetch "https://github.com/budimanjojo/talhelper/releases/download/$v/talhelper_linux_amd64.tar.gz" "$(need TALHELPER_SHA256)"
      tar -xzf "$work/dl" -C "$bin" talhelper ;;
    talosctl)
      v=$(need TALOSCTL_VERSION); fetch "https://github.com/siderolabs/talos/releases/download/$v/talosctl-linux-amd64" "$(need TALOSCTL_SHA256)"
      install -m 0755 "$work/dl" "$bin/talosctl" ;;
    *) echo "install-tool: unknown tool $tool" >&2; exit 64 ;;
  esac
  rm -f "$work/dl"
  echo "installed $tool"
done

if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >> "$GITHUB_PATH"; fi
