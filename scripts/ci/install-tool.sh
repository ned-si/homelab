#!/bin/bash
# install-tool.sh <tool>... -- install pinned CI binaries (linux amd64).
#
# Version and sha256 come from the workflow `env:` (<TOOL>_VERSION, <TOOL>_SHA256);
# the download is verified with sha256sum before anything is extracted or run.
# Installs into $RUNNER_TEMP/bin and appends that directory to $GITHUB_PATH.
# Tools: kubeconform actionlint shellcheck gitleaks trivy kyverno kube-linter helm
#        kubectl kind tofu promtool alertmanager talhelper talosctl hugo htmltest
#        exiftool
#
# TOOL_CACHE=<dir> (restored in CI by actions/cache): downloads are kept there
# as <sha256>. A cached file goes through the same sha256 check as a download;
# on a mismatch it is deleted and downloaded again. Files of tools not named
# in this call are removed, so a saved cache holds this call's pins only.
# curl retries timeouts and HTTP 408/429/5xx with exponential backoff.
set -euo pipefail

bin="${RUNNER_TEMP:?RUNNER_TEMP not set}/bin"
mkdir -p "$bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache=${TOOL_CACHE:-}
if [ -n "$cache" ]; then mkdir -p "$cache"; fi
used=" "

need() { # NAME -> value of env var NAME, or fail
  local v=${!1:-}
  [ -n "$v" ] || { echo "install-tool: $1 is not set" >&2; exit 1; }
  printf '%s' "$v"
}

fetch() { # url sha256 -> $work/dl
  used="$used$2 "
  if [ -n "$cache" ] && [ -f "$cache/$2" ]; then
    cp "$cache/$2" "$work/dl"
    if echo "$2  $work/dl" | sha256sum -c --quiet - 2>/dev/null; then
      echo "cached $1"
      return
    fi
    echo "install-tool: cached copy of $1 fails its sha256; downloading it again" >&2
    rm -f "$cache/$2"
  fi
  curl -fsSL --retry 6 --retry-connrefused --retry-max-time 240 -m 300 -o "$work/dl" "$1"
  echo "$2  $work/dl" | sha256sum -c --quiet - || { echo "install-tool: sha256 mismatch for $1" >&2; exit 1; }
  echo "downloaded $1"
  if [ -n "$cache" ]; then cp "$work/dl" "$cache/$2"; fi
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
    hugo) # the extended edition
      v=$(need HUGO_VERSION); fetch "https://github.com/gohugoio/hugo/releases/download/v$v/hugo_extended_${v}_linux-amd64.tar.gz" "$(need HUGO_SHA256)"
      tar -xzf "$work/dl" -C "$bin" hugo ;;
    htmltest)
      v=$(need HTMLTEST_VERSION); fetch "https://github.com/wjdp/htmltest/releases/download/v$v/htmltest_${v}_linux_amd64.tar.gz" "$(need HTMLTEST_SHA256)"
      tar -xzf "$work/dl" -C "$bin" htmltest ;;
    exiftool) # a Perl script that loads lib/ from its own directory
      v=$(need EXIFTOOL_VERSION); fetch "https://github.com/exiftool/exiftool/archive/refs/tags/$v.tar.gz" "$(need EXIFTOOL_SHA256)"
      rm -rf "$bin/exiftool-dist" && mkdir -p "$bin/exiftool-dist"
      tar -xzf "$work/dl" -C "$bin/exiftool-dist" --strip-components=1 "exiftool-$v/exiftool" "exiftool-$v/lib"
      cat > "$bin/exiftool" <<EOF
#!/bin/sh
exec perl "$bin/exiftool-dist/exiftool" "\$@"
EOF
      chmod 0755 "$bin/exiftool" ;;
    *) echo "install-tool: unknown tool $tool" >&2; exit 64 ;;
  esac
  rm -f "$work/dl"
  echo "installed $tool"
done

if [ -n "$cache" ]; then
  for f in "$cache"/*; do
    [ -f "$f" ] || continue
    case "$used" in *" ${f##*/} "*) ;; *) rm -f "$f" ;; esac
  done
fi

if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >> "$GITHUB_PATH"; fi
