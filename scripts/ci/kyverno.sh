#!/bin/bash
# kyverno.sh -- policy-as-code over deploy/ with the Kyverno CLI.
#
#   1. scripts/vendor-upstream.sh --check  the vendored files are unchanged
#   2. kyverno test policies/kyverno/tests the policies' own unit tests
#   3. kyverno apply                       policies/kyverno/*.yaml and the
#                                          vendored upstream over deploy/
#
# BLOCKING names the policies that fail the check; the vendored files stay as
# upstream wrote them. Every other finding is reported with counts. In a
# namespace NAMESPACES_FILE labels `enforce: restricted`, the restricted set
# blocks too, since PSA would reject the Pod (and PSA has no webhook
# exclusions, so excluded namespaces count there).
#
# Test knobs (tests/bash/test_kyverno_restricted.sh): KYVERNO_DEPLOY (default
# deploy), NAMESPACES_FILE, KYVERNO_APPLY_ONLY=1 skips steps 1 and 2.
#
# An evaluation error fails, except CLI_GAPS (fields only API server
# defaulting sets). Zero resources checked fails. The decision comes from the
# report: `kyverno apply` exits 1 on Audit findings even with --audit-warn.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
rc=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The policies whose violations fail CI: the ones the cluster runs in Deny
# (infrastructure/kyverno-policies/kustomization.yaml). Keep the lists equal.
BLOCKING="disallow-capabilities disallow-container-sock-mounts disallow-default-namespace disallow-host-namespaces disallow-host-path disallow-host-ports disallow-host-process disallow-latest-tag disallow-privileged-containers disallow-proc-mount disallow-selinux require-run-as-non-root-user restrict-external-ips restrict-nodeport restrict-seccomp restrict-sysctls"
# Excluded from admission by the webhook's namespaceSelector
# (infrastructure/kyverno/values.yaml): not checked here either.
EXCLUDED_NAMESPACES="kube-system argo cilium kyverno tailscale"
# One `policy|error message` per line: errors that come from the missing API
# defaulting (a Service without spec.type is a ClusterIP once stored).
CLI_GAPS="restrict-nodeport|error: no such key: type"
DEPLOY=${KYVERNO_DEPLOY:-deploy}
NAMESPACES_FILE=${NAMESPACES_FILE:-infrastructure/namespaces/namespaces.yaml}
PSS=policies/kyverno/upstream/pod-security-vpol

# The Pod Security sets, by policy directory name.
dirnames() { for d in "$@"; do [ -d "$d" ] && basename "$d"; done | tr '\n' ' '; }
RESTRICTED_SET=" $(dirnames "$PSS"/restricted/*/) "
PSS_SET=" $(dirnames "$PSS"/baseline/*/ "$PSS"/restricted/*/) "
[ "$RESTRICTED_SET" != "  " ] || { echo "kyverno: no policies under $PSS/restricted" >&2; exit 1; }
[ -f "$NAMESPACES_FILE" ] || { echo "kyverno: $NAMESPACES_FILE not found" >&2; exit 1; }
RESTRICTED_NAMESPACES=" $(yq -N 'select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted") | .metadata.name' "$NAMESPACES_FILE" | tr '\n' ' ') "
[ "$RESTRICTED_NAMESPACES" != "  " ] || { echo "kyverno: no enforce: restricted namespace in $NAMESPACES_FILE" >&2; exit 1; }
# Excluded from the webhooks but enforced by PSA: their renders are kept.
KEPT_NAMESPACES=" "
for n in $EXCLUDED_NAMESPACES; do
  [[ "$RESTRICTED_NAMESPACES" == *" $n "* ]] && KEPT_NAMESPACES+="$n "
done
echo "restricted namespaces ($NAMESPACES_FILE):$RESTRICTED_NAMESPACES"
echo "restricted set:$RESTRICTED_SET"
echo "webhook-excluded, enforced restricted, renders kept:$KEPT_NAMESPACES"

if [ "${KYVERNO_APPLY_ONLY:-0}" != 1 ]; then
  echo "== scripts/vendor-upstream.sh --check (Kyverno and Tetragon)"
  scripts/vendor-upstream.sh policies/kyverno/upstream --check || rc=1
  scripts/vendor-upstream.sh platform/tetragon/policies --check || rc=1

  echo "== kyverno test policies/kyverno/tests"
  kyverno test policies/kyverno/tests --remove-color || rc=1
fi

# policies/kyverno/kustomization.yaml is how infrastructure/kyverno-policies
# syncs these files into the cluster; it is not a policy.
policies=()
for p in policies/kyverno/*.yaml; do
  [ "$(basename "$p")" = kustomization.yaml ] || policies+=("$p")
done
while IFS= read -r p; do policies+=("$p"); done \
  < <(find policies/kyverno/upstream -name '*.yaml' -type f ! -name controls.yaml | sort)
names=" $(for p in "${policies[@]}"; do yq '.metadata.name' "$p"; done | tr '\n' ' ') "
for b in $BLOCKING; do
  [[ "$names" == *" $b "* ]] || { echo "kyverno: BLOCKING policy $b is not in the policy set" >&2; exit 1; }
done
# Expected findings (policies/kyverno/exceptions), the same objects the
# cluster runs.
exceptions=()
for e in policies/kyverno/exceptions/*.yaml; do
  [ "$(basename "$e")" = kustomization.yaml ] || exceptions+=(--exception "$e")
done
# `--resource <dir>` does not recurse: pass every file. A Service without
# spec.type gets ClusterIP, as the API server defaults it before admission
# (restrict-nodeport reads the field and errors on its absence): its file goes
# in as a normalised copy.
resources=()
d=0
while IFS= read -r f; do
  if [ "$(yq -N 'select(.kind == "Service" and .spec.type == null) | .metadata.name' "$f" | grep -c .)" -gt 0 ]; then
    d=$((d + 1))
    yq -P '(select(.kind == "Service") | .spec.type) |= (. // "ClusterIP")' "$f" > "$out/deploy-$d.yaml"
    f="$out/deploy-$d.yaml"
  fi
  resources+=(--resource "$f")
done < <(find "$DEPLOY" -name '*.yaml' -type f | sort)
[ "${#resources[@]}" -gt 0 ] || { echo "kyverno: no files in $DEPLOY/; refusing to pass" >&2; exit 1; }
: > "$out/kept.txt"
# KYVERNO_EXTRA (CI: the render_apps.py output): the Helm-rendered apps, which
# deploy/ does not hold. Their objects in the excluded namespaces are dropped,
# as admission never sees them, and null fields too, as the API server drops
# them before admission (Helm renders `initContainers: null`, which CEL cannot
# take the size of), and Service spec.type defaulted to ClusterIP as the API
# server does. Printed as block YAML (-P): yq adds keys to the flow-style
# renders unquoted, which the CLI, reading them as JSON, rejects.
if [ -n "${KYVERNO_EXTRA:-}" ]; then
  [ -d "$KYVERNO_EXTRA" ] || { echo "kyverno: KYVERNO_EXTRA $KYVERNO_EXTRA is not a directory" >&2; exit 1; }
  dropped=""
  for n in $EXCLUDED_NAMESPACES; do
    [[ "$KEPT_NAMESPACES" == *" $n "* ]] || dropped+="$n "
  done
  # shellcheck disable=SC2086 # one printf argument per namespace
  excl=$(printf '"%s",' $dropped); excl="[${excl%,}]"
  # The render holds every Application, the hydrated ones too: pass only
  # objects deploy/ does not have (the CLI refuses a duplicate), keyed by
  # kind/namespace/name, and each object once.
  key='([.kind, (.metadata.namespace // ""), .metadata.name] | join("/"))'
  find "$DEPLOY" -name '*.yaml' -type f -exec yq -N "$key" {} + | jq -R '{(.): true}' | jq -s 'add // {}' > "$out/keys.json"
  n=0 kept=0
  while IFS= read -r f; do
    n=$((n + 1))
    # Argo puts the objects a chart leaves without a namespace into the
    # Application's destination one (render index.json), not `default`.
    ns=$(jq -r --arg app "$(basename "$(dirname "$f")")" '[.[] | select(.app == $app) | .namespace][0] // ""' "$KYVERNO_EXTRA/index.json")
    NS=$ns yq -P "(select(.metadata.namespace == null and strenv(NS) != \"\" and (.kind | test(\"^(Pod|Deployment|StatefulSet|DaemonSet|ReplicaSet|Job|CronJob|Service)$\"))) | .metadata.namespace) = strenv(NS) | $key as \$k | select((.metadata.namespace // \"\") as \$ns | $excl | any_c(. == \$ns) | not) | select(load(\"$out/keys.json\") | has(\$k) | not) | del(.. | select(tag == \"!!null\")) | (select(.kind == \"Service\") | .spec.type) |= (. // \"ClusterIP\")" \
      "$f" > "$out/extra-$n.yaml" 2>/dev/null || continue
    if [ -s "$out/extra-$n.yaml" ] && [ "$(yq -N "$key" "$out/extra-$n.yaml" | grep -c .)" -gt 0 ]; then
      resources+=(--resource "$out/extra-$n.yaml")
      kept=$((kept + 1))
      # The kept objects of the webhook-excluded namespaces, as namespace/kind/name.
      # shellcheck disable=SC2016 # $ns is a yq variable
      KEPT=$KEPT_NAMESPACES yq -N 'select((.metadata.namespace // "") as $ns | strenv(KEPT) | split(" ") | any_c(. == $ns and . != "")) | .metadata.namespace + "/" + .kind + "/" + .metadata.name' \
        "$out/extra-$n.yaml" >> "$out/kept.txt"
      yq -N "$key" "$out/extra-$n.yaml" | jq -R '{(.): true}' | jq -s --slurpfile old "$out/keys.json" '$old[0] + (add // {})' > "$out/keys.new" && mv "$out/keys.new" "$out/keys.json"
    fi
  done < <(find "$KYVERNO_EXTRA" -name manifests.yaml -type f | sort)
  echo "kyverno: plus $kept of $n rendered files from $KYVERNO_EXTRA (objects already in deploy/ and the excluded namespaces${dropped:+ $dropped}dropped; $(grep -c . "$out/kept.txt") objects of${KEPT_NAMESPACES}kept)"
fi
# The CLI has no API server to look Namespaces up in: hand it every namespace
# deploy/ and the kept renders use, so policies that read namespaceObject can
# evaluate.
{
  printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: Value\nmetadata:\n  name: values\nnamespaces:\n'
  { echo default; find "$DEPLOY" -name '*.yaml' -type f -exec yq -N '.metadata.namespace // ""' {} + ;
    [ -z "${KYVERNO_EXTRA:-}" ] || find "$out" -name 'extra-*.yaml' -type f -exec yq -N '.metadata.namespace // ""' {} + ; } \
    | grep -v '^$' | sort -u | while IFS= read -r ns; do
      printf -- '- apiVersion: v1\n  kind: Namespace\n  metadata:\n    name: %s\n' "$ns"
    done
} > "$out/values.yaml"
echo "== kyverno apply: ${#policies[@]} policies over $((${#resources[@]} / 2)) files in deploy/"
echo "blocking: $BLOCKING"
kyverno apply "${policies[@]}" "${exceptions[@]}" "${resources[@]}" --values-file "$out/values.yaml" \
  --audit-warn --policy-report --remove-color > "$out/report.yaml" 2> "$out/apply.err"
if [ "$(yq '.kind' "$out/report.yaml" 2>/dev/null)" != "ClusterReport" ]; then
  echo "kyverno apply produced no report:" >&2
  head -n 20 "$out/apply.err" "$out/report.yaml" >&2
  exit 1
fi

# A run that evaluated nothing (no files, or no policy matched any of them)
# must not pass: "skip" results do not count as checked.
checked=$(yq -N '[.results[] | select(.result != "skip")] | length' "$out/report.yaml")
if [ "${checked:-0}" -eq 0 ]; then
  echo "kyverno: 0 resources checked; refusing to pass" >&2
  exit 1
fi
echo "checked: $checked policy results"

table=$(yq -N '.results[] | .policy + " " + .result' "$out/report.yaml" | sort | uniq -c \
  | awk '{printf "| %s | %s | %s |\n", $2, $3, $1}')
printf '| policy | result | count |\n|---|---|---|\n%s\n' "$table"

findings=$(yq -N '.results[] | select(.result != "pass" and .result != "skip")
  | .policy + " " + .result + " " + (.resources[0].namespace // "-") + "/" + .resources[0].kind + "/" + .resources[0].name
  + " " + ((.message // "") | split("\n") | .[0])' \
  "$out/report.yaml" | sort -u)
blocking=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  pol=$(cut -d' ' -f1 <<<"$line")
  res=$(cut -d' ' -f2 <<<"$line")
  obj=$(cut -d' ' -f3 <<<"$line")
  msg=$(cut -d' ' -f4- <<<"$line")
  if grep -qxF "$obj" "$out/kept.txt"; then
    # A render of a webhook-excluded namespace: PSA alone admits it.
    [[ "$PSS_SET" == *" $pol "* ]] || continue
  fi
  if [ "$res" = "error" ]; then
    grep -qxF "$pol|$msg" <<<"$CLI_GAPS" || blocking+="$line"$'\n'
  elif [[ " $BLOCKING " == *" $pol "* ]]; then
    blocking+="$line"$'\n'
  elif [[ "$RESTRICTED_SET" == *" $pol "* && "$RESTRICTED_NAMESPACES" == *" ${obj%%/*} "* ]]; then
    blocking+="$line"$'\n'
  fi
done <<<"$findings"

if [ -n "$findings" ]; then
  echo "== findings (BLOCKING policies, the restricted set in enforce: restricted namespaces and evaluation errors fail the check)"
  echo "$findings"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### kyverno (deploy/)"
    printf '| policy | result | count |\n|---|---|---|\n%s\n' "$table"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "$blocking" ]; then
  echo "== BLOCKING: violations of blocking policies, or evaluation errors" >&2
  printf '%s' "$blocking" >&2
  rc=1
fi
exit "$rc"
