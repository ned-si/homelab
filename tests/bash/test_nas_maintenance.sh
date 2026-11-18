#!/bin/bash
# test_nas_maintenance.sh -- scripts/nas-maintenance.sh against a fake
# `kubectl` (and `curl` for --hold-guard) that serves fixture JSON and logs
# every call.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
SCRIPT="$REPO_ROOT/scripts/nas-maintenance.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
FK="$tmp/fk"
export FK

cat > "$tmp/bin/kubectl" <<'EOF'
#!/bin/bash
# Fake kubectl: fixtures in $FK, calls in $FK/calls.log.
args=()
for a in "$@"; do case "$a" in --request-timeout=*) ;; *) args+=("$a") ;; esac; done
set -- "${args[@]}"
echo "$*" >> "$FK/calls.log"
ns=""
[ "$1" = -n ] && { ns=$2; shift 2; }
fx() { # <name>: the -after variant once `down` scaled something
  if [ -f "$FK/downed" ] && [ -f "$FK/$1-after.json" ]; then cat "$FK/$1-after.json"; else cat "$FK/$1.json"; fi
}
case "$1" in
  get)
    case "$*" in
      "get deployments,statefulsets -A -o json")
        if [ -f "$FK/restarted" ]; then cat "$FK/wl-restarted.json"; else cat "$FK/wl.json"; fi ;;
      "get clusters.postgresql.cnpg.io,"*) cat "$FK/crs.json" ;;
      "get "*" -A -o json") fx "$2" ;;
      "get volumeattachments -o json") fx va ;;
      "get applications.argoproj.io -o json")
        jq -s '{items: .}' "$FK"/app-*.json ;;
      "get applications.argoproj.io "*" -o json") cat "$FK/app-$3.json" ;;
      "get pod,pvc -l "*) cat "$FK/leftovers" 2>/dev/null ;;
      "get pvc nas-canary -o jsonpath={.status.phase}") echo Bound ;;
      "get pvc nas-canary -o jsonpath={.spec.volumeName}") echo pvc-canary ;;
      "get pod "*" -o jsonpath={.status.phase}") cat "$FK/phase-$3" ;;
      "get pv pvc-canary -o jsonpath="*) echo "iqn.2005-10.org.freenas.ctl:csi-pvc-canary-cluster" ;;
      "get pv pvc-canary") [ -f "$FK/deleted" ] && exit 1; echo pv ;;
      "get secret iscsi-democratic-csi-driver-config "*)
        printf 'driver: freenas-iscsi\nhttpConnection:\n  apiKey: SECRETKEY123\n' | base64 ;;
      "get "*" -o json")
        echo '{"metadata":{"annotations":{}},"spec":{"replicas":2,"suspend":false}}' ;;
      *) echo "fake kubectl: unexpected: $*" >&2; exit 1 ;;
    esac ;;
  patch)
    if [ "$ns" = argo ]; then
      case "$*" in
        *'"op":"remove"'*) jq '.spec.syncPolicy = {}' "$FK/app-$3.json" > "$FK/x" && mv "$FK/x" "$FK/app-$3.json" ;;
      esac
    fi ;;
  scale) touch "$FK/downed" ;;
  annotate|apply) ;;
  create) if [ -f "$FK/create-fails" ]; then echo "forbidden" >&2; exit 1; fi ;;
  rollout) touch "$FK/restarted" ;;
  delete) [ "$2" = job ] || touch "$FK/deleted" ;;
  logs) cat "$FK/log-$2" 2>/dev/null ;;
  *) echo "fake kubectl: unexpected: $*" >&2; exit 1 ;;
esac
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FK/calls.log"
cat >> "$FK/curl-stdin"
cat "$FK/target.json"
EOF
chmod +x "$tmp/bin/kubectl" "$tmp/bin/curl"

today=$(date -u +%Y-%m-%d)
owner() { # <kind> <name> [apiVersion]
  printf '[{"apiVersion":"%s","kind":"%s","name":"%s","controller":true}]' "${3:-v1}" "$1" "$2"
}
pod() { # <ns> <name> <phase> <owners json> <volumes json>
  printf '{"metadata":{"namespace":"%s","name":"%s","ownerReferences":%s},"spec":{"volumes":%s},"status":{"phase":"%s"}}' \
    "$1" "$2" "$4" "$5" "$3"
}
pvcvol() { printf '[{"name":"d","persistentVolumeClaim":{"claimName":"%s"}}]' "$1"; }

# fixtures: a cluster with one workload of every owner kind on the NAS, a
# Deployment off the NAS, and a Succeeded backup pod.
fixtures() {
  rm -rf "$FK"; mkdir -p "$FK"
  : > "$FK/calls.log"
  cat > "$FK/pv.json" <<'JSON'
{"items":[
 {"metadata":{"name":"pv-a"},"spec":{"storageClassName":"iscsi"}},
 {"metadata":{"name":"pv-p"},"spec":{"storageClassName":"iscsi"}},
 {"metadata":{"name":"pv-c"},"spec":{"storageClassName":"iscsi-retain"}},
 {"metadata":{"name":"pv-g"},"spec":{"storageClassName":"iscsi"}},
 {"metadata":{"name":"pv-media"},"spec":{"storageClassName":"","nfs":{"server":"192.168.1.228","path":"/mnt/homelab/k8s/nfs"}}},
 {"metadata":{"name":"pv-other"},"spec":{"storageClassName":"local"}}]}
JSON
  cat > "$FK/pvc.json" <<'JSON'
{"items":[
 {"metadata":{"namespace":"app","name":"data"},"spec":{"volumeName":"pv-a"}},
 {"metadata":{"namespace":"app","name":"other"},"spec":{"volumeName":"pv-other"}},
 {"metadata":{"namespace":"theater","name":"media"},"spec":{"volumeName":"pv-media"}},
 {"metadata":{"namespace":"mon","name":"prom-db"},"spec":{"volumeName":"pv-p"}},
 {"metadata":{"namespace":"ch","name":"data-ch"},"spec":{"volumeName":"pv-c"}},
 {"metadata":{"namespace":"db","name":"pg-1"},"spec":{"volumeName":"pv-g"}}]}
JSON
  cat > "$FK/replicasets.json" <<JSON
{"items":[
 {"metadata":{"namespace":"app","name":"web-rs","ownerReferences":$(owner Deployment web apps/v1)}},
 {"metadata":{"namespace":"app","name":"cache-rs","ownerReferences":$(owner Deployment cache apps/v1)}}]}
JSON
  cat > "$FK/statefulsets.json" <<JSON
{"items":[
 {"metadata":{"namespace":"theater","name":"sync"}},
 {"metadata":{"namespace":"mon","name":"prometheus-p","ownerReferences":$(owner Prometheus p monitoring.coreos.com/v1)}},
 {"metadata":{"namespace":"ch","name":"chi-x","ownerReferences":$(owner ClickHouseInstallation ch-inst clickhouse.altinity.com/v1)}}]}
JSON
  cat > "$FK/jobs.json" <<JSON
{"items":[
 {"metadata":{"namespace":"app","name":"app-backup-111","ownerReferences":$(owner CronJob app-backup batch/v1)},
  "spec":{"template":{"spec":{"volumes":$(pvcvol data)}}},"status":{"succeeded":1}}]}
JSON
  cat > "$FK/cronjobs.json" <<JSON
{"items":[
 {"metadata":{"namespace":"app","name":"app-backup"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"volumes":$(pvcvol data)}}}}},
  "status":{"lastSuccessfulTime":"${today}T01:00:00Z"}},
 {"metadata":{"namespace":"app","name":"report"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{}}}}}},
 {"metadata":{"namespace":"democratic-csi","name":"nas-iscsi-guard"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{}}}}}}]}
JSON
  local succeeded
  succeeded=$(pod app app-backup-111-aaa Succeeded "$(owner Job app-backup-111 batch/v1)" "$(pvcvol data)")
  cat > "$FK/pods.json" <<JSON
{"items":[
 $(pod app web-abc Running "$(owner ReplicaSet web-rs apps/v1)" "$(pvcvol data)"),
 $(pod app cache-abc Running "$(owner ReplicaSet cache-rs apps/v1)" "$(pvcvol other)"),
 $(pod theater sync-0 Running "$(owner StatefulSet sync apps/v1)" "$(pvcvol media)"),
 $(pod mon prometheus-p-0 Running "$(owner StatefulSet prometheus-p apps/v1)" "$(pvcvol prom-db)"),
 $(pod ch chi-x-0 Pending "$(owner StatefulSet chi-x apps/v1)" "$(pvcvol data-ch)"),
 $(pod db pg-1 Running "$(owner Cluster pg postgresql.cnpg.io/v1)" "$(pvcvol pg-1)"),
 $succeeded]}
JSON
  printf '{"items":[%s]}\n' "$succeeded" > "$FK/pods-after.json"
  echo '{"items":[{"spec":{"attacher":"org.democratic-csi.iscsi"}},{"spec":{"attacher":"other"}}]}' > "$FK/va.json"
  echo '{"items":[{"spec":{"attacher":"other"}}]}' > "$FK/va-after.json"
  local a
  for a in root layer-infrastructure layer-platform layer-apps argocd immich; do
    printf '{"metadata":{"name":"%s"},"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}\n' "$a" > "$FK/app-$a.json"
  done
  echo '{"metadata":{"name":"manual"},"spec":{"syncPolicy":{}}}' > "$FK/app-manual.json"
  printf '# comment\napp/app-backup\napp/app-prune\nbackup-verify/backup-verify-files\nhome/home-backup\n' > "$FK/active-cronjobs.txt"
  cat > "$FK/wl.json" <<'JSON'
{"items":[
 {"kind":"Deployment","metadata":{"namespace":"app","name":"web"},"spec":{"replicas":2},"status":{"readyReplicas":0}},
 {"kind":"Deployment","metadata":{"namespace":"keycloak","name":"keycloak"},"spec":{"replicas":1},"status":{}},
 {"kind":"StatefulSet","metadata":{"namespace":"theater","name":"sync"},"spec":{"replicas":2},"status":{"readyReplicas":2}},
 {"kind":"StatefulSet","metadata":{"namespace":"mon","name":"prometheus-p","ownerReferences":[{"kind":"Prometheus","name":"p","controller":true}]},"spec":{"replicas":1},"status":{"readyReplicas":1}}]}
JSON
  jq '.items[0].status.readyReplicas = 2 | .items[1].status.readyReplicas = 1' "$FK/wl.json" > "$FK/wl-restarted.json"
  cat > "$FK/crs.json" <<'JSON'
{"items":[
 {"kind":"Cluster","metadata":{"namespace":"db","name":"pg"},"status":{"phase":"Cluster in healthy state"}},
 {"kind":"ClickHouseInstallation","metadata":{"namespace":"ch","name":"ch-inst"},"status":{"status":"Completed"}}]}
JSON
}

# run <args...>: "rc=<n>" and the output, stdout and stderr together.
run() {
  local rc=0 out
  out=$(PATH="$tmp/bin:$PATH" NAS_MAINT_STATE_DIR="$tmp/state" NAS_MAINT_POLL=0 NAS_MAINT_RESTART_AFTER=0 \
    NAS_MAINT_ACTIVE_CRONJOBS="$FK/active-cronjobs.txt" NAS_MAINT_GUARD_POLL=0 "$SCRIPT" "$@" 2>&1) || rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}
calls() { cat "$FK/calls.log"; }
nwrites() { grep -cE '^(-n [^ ]+ )?(patch|scale|annotate|apply|delete|rollout)' "$FK/calls.log" || true; }

echo "plan"
fixtures
out=$(run plan)
expect_contains "plan: exit 0" "rc=0" "$out"
expect_contains "plan: Deployment via its ReplicaSet" "Deployment               app/web" "$out"
expect_contains "plan: StatefulSet on an NFS PV" "StatefulSet              theater/sync" "$out"
expect_contains "plan: Prometheus CR" "Prometheus               mon/p" "$out"
expect_contains "plan: ClickHouseInstallation (Pending pod counts)" "ClickHouseInstallation   ch/ch-inst" "$out"
expect_contains "plan: CNPG cluster" "Cluster                  db/pg" "$out"
expect_contains "plan: CronJob with a NAS volume" "CronJob                  app/app-backup" "$out"
expect_contains "plan: the guard by name" "CronJob                  democratic-csi/nas-iscsi-guard" "$out"
expect_contains "plan: Succeeded backup pod ignored" "finished, ignored: app/app-backup-111-aaa (Succeeded)" "$out"
expect_contains "plan: counts" "plan: 7 workloads to stop; 5 pods on NAS volumes" "$out"
case "$out" in *cache*|*report*) bad "plan: workloads off the NAS left out" ;; *) ok "plan: workloads off the NAS left out" ;; esac
expect_contains "plan: backup today" "today app/app-backup" "$out"
expect_contains "plan: backup missing" "OLD   home/home-backup" "$out"
expect_contains "plan: backup set summary" "daily backup set: 1/2 today" "$out"
case "$out" in *backup-verify-files*|*app-prune*) bad "plan: verify and prune jobs outside the set" ;; *) ok "plan: verify and prune jobs outside the set" ;; esac
expect_eq "plan: no writes" 0 "$(nwrites)"

echo "plan: unknown owner"
fixtures
jq --argjson p "$(pod app bare Running '[]' '[{"name":"n","nfs":{"server":"192.168.1.228","path":"/x"}}]')" \
  '.items += [$p]' "$FK/pods.json" > "$FK/x" && mv "$FK/x" "$FK/pods.json"
out=$(run plan)
expect_contains "unknown: exit 3" "rc=3" "$out"
expect_contains "unknown: names the pod" "UNKNOWN OWNER: app/bare (no owner)" "$out"
out=$(run down)
expect_contains "unknown: down refuses" "rc=3" "$out"
expect_eq "unknown: down writes nothing" 0 "$(nwrites)"

echo "down: an active backup Job"
fixtures
jq --argjson p "$(pod app app-backup-222-bbb Running "$(owner Job app-backup-222 batch/v1)" "$(pvcvol data)")" \
  '.items += [$p]' "$FK/pods.json" > "$FK/x" && mv "$FK/x" "$FK/pods.json"
jq --argjson j "{\"metadata\":{\"namespace\":\"app\",\"name\":\"app-backup-222\",\"ownerReferences\":$(owner CronJob app-backup batch/v1)},\"spec\":{\"template\":{\"spec\":{\"volumes\":$(pvcvol data)}}},\"status\":{\"active\":1}}" \
  '.items += [$j]' "$FK/jobs.json" > "$FK/x" && mv "$FK/x" "$FK/jobs.json"
out=$(run plan)
expect_contains "active job: plan exits 3" "rc=3" "$out"
expect_contains "active job: plan names it" "ACTIVE NAS JOB: app/app-backup-222" "$out"
expect_eq "active job: plan writes nothing" 0 "$(nwrites)"
out=$(run down)
expect_contains "active job: exit 3" "rc=3" "$out"
expect_contains "active job: named" "ACTIVE NAS JOB: app/app-backup-222" "$out"
expect_eq "active job: nothing changed" 0 "$(nwrites)"
if [ -d "$tmp/state" ]; then bad "active job: no state file"; else ok "active job: no state file"; fi

echo "down"
fixtures
out=$(run down)
expect_contains "down: exit 0" "rc=0" "$out"
order=$(grep -E '^-n argo patch' "$FK/calls.log" | awk '{print $5}' | tr '\n' ' ')
expect_eq "down: Argo CD order (root, layers, the rest)" "root layer-infrastructure layer-platform layer-apps argocd immich " "$order"
expect_contains "down: cronjob suspended" '-n app patch cronjob app-backup --type merge -p {"spec":{"suspend":true}}' "$(calls)"
expect_contains "down: guard suspended" '-n democratic-csi patch cronjob nas-iscsi-guard' "$(calls)"
expect_contains "down: deployment scaled" '-n app scale deployment/web --replicas=0' "$(calls)"
expect_contains "down: statefulset scaled" '-n theater scale statefulset/sync --replicas=0' "$(calls)"
expect_contains "down: prometheus replicas" '-n mon patch prometheuses.monitoring.coreos.com p --type merge -p {"spec":{"replicas":0}}' "$(calls)"
expect_contains "down: clickhouse stopped" '-n ch patch clickhouseinstallations.clickhouse.altinity.com ch-inst --type merge -p {"spec":{"stop":"yes"}}' "$(calls)"
expect_contains "down: cnpg hibernated" '-n db annotate --overwrite clusters.postgresql.cnpg.io pg cnpg.io/hibernation=on' "$(calls)"
first_action=$(grep -nE '^-n [^ ]+ (patch|scale|annotate)' "$FK/calls.log" | grep -v '^[0-9]*:-n argo ' | head -n 1 | cut -d: -f1)
last_argo=$(grep -n '^-n argo patch' "$FK/calls.log" | tail -n 1 | cut -d: -f1)
if [ "$last_argo" -lt "$first_action" ]; then ok "down: Argo CD off before any action"; else bad "down: Argo CD off before any action"; fi
state=$(ls "$tmp/state"/*.json)
expect_eq "down: state file argo blocks" "root layer-infrastructure layer-platform layer-apps argocd immich" "$(jq -r '[.argo[].name] | join(" ")' "$state")"
expect_eq "down: state file actions" 7 "$(jq '.actions | length' "$state")"
expect_eq "down: previous replicas recorded" 2 "$(jq '[.actions[] | select(.kind == "Deployment")][0].previous' "$state")"
expect_eq "down: previous annotation recorded" null "$(jq -c '[.actions[] | select(.kind == "Cluster")][0].previous' "$state")"
expect_contains "down: prints the state file" "$state" "$out"

echo "status"
out=$(run status)
expect_contains "status: exit 0" "rc=0" "$out"
expect_contains "status: pods" "pods on NAS volumes: 0" "$out"
expect_contains "status: attachments" "iSCSI VolumeAttachments: 0" "$out"
expect_contains "status: state file" "state file: $state" "$out"

echo "up"
: > "$FK/calls.log"
out=$(run up "$state")
expect_contains "up: exit 0" "rc=0" "$out"
expect_contains "up: cnpg awake" '-n db annotate clusters.postgresql.cnpg.io pg cnpg.io/hibernation-' "$(calls)"
expect_contains "up: deployment back" '-n app scale deployment/web --replicas=2' "$(calls)"
expect_contains "up: clickhouse field removed" '{"spec":{"stop":null}}' "$(calls)"
expect_contains "up: cronjob back" '-n app patch cronjob app-backup --type merge -p {"spec":{"suspend":false}}' "$(calls)"
first=$(grep -nE '(annotate|scale|patch cronjob)' "$FK/calls.log" | head -n 1)
expect_contains "up: reverse order, databases first" "clusters.postgresql.cnpg.io" "$first"
expect_contains "up: restart of a non-Ready Deployment" '-n keycloak rollout restart deployment/keycloak' "$(calls)"
expect_contains "up: restart of a recorded one" '-n app rollout restart deployment/web' "$(calls)"
case "$(calls)" in *"rollout restart statefulset/prometheus-p"*) bad "up: operator-owned StatefulSet not restarted" ;; *) ok "up: operator-owned StatefulSet not restarted" ;; esac
order=$(grep -E '^-n argo patch' "$FK/calls.log" | awk '{print $5}' | tr '\n' ' ')
expect_eq "up: Argo CD order (apps, layers, root)" "argocd immich layer-infrastructure layer-platform layer-apps root " "$order"
expect_contains "up: automated block restored" '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}' "$(calls)"

echo "up: timeout still restores Argo CD"
rm -f "$FK/restarted"
: > "$FK/calls.log"
out=$(NAS_MAINT_UP_TIMEOUT=0 run up "$state")
expect_contains "up timeout: exit 1" "rc=1" "$out"
expect_contains "up timeout: lists what is left" "not ready: Deployment app/web" "$out"
expect_contains "up timeout: root restored" '-n argo patch applications.argoproj.io root --type merge' "$(calls)"
out=$(run up "$tmp/nope.json")
expect_contains "up: not a state file" "rc=3" "$out"

echo "canary"
fixtures
printf 'WRITE_OK sha256=abc size_kib=1038336\nGREW size_kib=2086912\n' > "$FK/log-nas-canary-iscsi"
printf 'ok /nas/nfs\nNFS_OK\n' > "$FK/log-nas-canary-nfs"
echo Succeeded > "$FK/phase-nas-canary-iscsi"
echo Succeeded > "$FK/phase-nas-canary-nfs"
out=$(run canary)
expect_contains "canary: PASS" "canary: PASS" "$out"
expect_contains "canary: exit 0" "rc=0" "$out"
expect_contains "canary: iSCSI manifest" "apply -f $REPO_ROOT/scripts/nas-canary/iscsi.yaml" "$(calls)"
expect_contains "canary: expansion" '-n backup-verify patch pvc nas-canary --type merge -p {"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' "$(calls)"
expect_contains "canary: NFS manifest" "apply -f $REPO_ROOT/scripts/nas-canary/nfs.yaml" "$(calls)"
expect_contains "canary: cleanup by label" "-n backup-verify delete pod,pvc -l app.kubernetes.io/name=nas-canary" "$(calls)"
case "$(calls)" in *curl*) bad "canary: no NAS API call without --hold-guard" ;; *) ok "canary: no NAS API call without --hold-guard" ;; esac

echo "canary --hold-guard"
fixtures
printf 'WRITE_OK sha256=abc size_kib=1038336\nGREW size_kib=2086912\n' > "$FK/log-nas-canary-iscsi"
printf 'NFS_OK\n' > "$FK/log-nas-canary-nfs"
echo Succeeded > "$FK/phase-nas-canary-iscsi"
echo Succeeded > "$FK/phase-nas-canary-nfs"
echo '[{"name":"csi-pvc-canary-cluster","auth_networks":["192.168.1.240/32","192.168.1.247/32","192.168.1.238/32","192.168.1.239/32"]}]' > "$FK/target.json"
out=$(run canary --hold-guard)
expect_contains "guard: PASS" "canary: PASS" "$out"
expect_contains "guard: target by name" "iscsi/target?name=csi-pvc-canary-cluster" "$(calls)"
expect_contains "guard: CA verified" "--cacert" "$(calls)"
expect_contains "guard: key on stdin" "Bearer SECRETKEY123" "$(cat "$FK/curl-stdin")"
case "$out$(calls)" in *SECRETKEY123*) bad "guard: key never in arguments or output" ;; *) ok "guard: key never in arguments or output" ;; esac
# `down` suspends the CronJob: the canary runs the guard once itself (#1472).
expect_contains "guard: Job from the suspended CronJob" \
  "-n democratic-csi create job --from=cronjob/nas-iscsi-guard nas-iscsi-guard-canary" "$(calls)"
expect_contains "guard: Job deleted" "-n democratic-csi delete job nas-iscsi-guard-canary --ignore-not-found --wait=false" "$(calls)"
case "$(grep -n 'create job\|iscsi/target' "$FK/calls.log" | head -n 1)" in
  *"create job"*) ok "guard: Job created before the first poll" ;;
  *) bad "guard: Job created before the first poll" ;;
esac
echo '[{"name":"csi-pvc-canary-cluster","auth_networks":[]}]' > "$FK/target.json"
rm -f "$FK/deleted"
out=$(NAS_MAINT_GUARD_TIMEOUT=0 run canary --hold-guard)
expect_contains "guard open: exit 1" "rc=1" "$out"
expect_contains "guard open: says why" "FAIL at guard" "$out"
: > "$FK/calls.log"
touch "$FK/create-fails"
out=$(run canary --hold-guard)
expect_contains "guard Job not created: exit 1" "rc=1" "$out"
expect_contains "guard Job not created: says why" "FAIL at guard: forbidden" "$out"
case "$(calls)" in *iscsi/target*) bad "guard Job not created: no poll" ;; *) ok "guard Job not created: no poll" ;; esac
rm -f "$FK/create-fails"

echo "canary: read-back mismatch"
fixtures
printf 'MISMATCH wrote a read b\n' > "$FK/log-nas-canary-iscsi"
echo Failed > "$FK/phase-nas-canary-iscsi"
out=$(run canary)
expect_contains "mismatch: exit 1" "rc=1" "$out"
expect_contains "mismatch: failing step" "FAIL at write" "$out"
expect_contains "mismatch: pod log shown" "MISMATCH" "$out"
expect_contains "mismatch: cleaned up" "delete pod,pvc -l app.kubernetes.io/name=nas-canary" "$(calls)"
case "$(calls)" in *nfs.yaml*) bad "mismatch: stops before NFS" ;; *) ok "mismatch: stops before NFS" ;; esac

echo "canary: empty NFS path"
fixtures
printf 'WRITE_OK x\nGREW y\n' > "$FK/log-nas-canary-iscsi"
printf 'EMPTY /nas/nfs/media\n' > "$FK/log-nas-canary-nfs"
echo Succeeded > "$FK/phase-nas-canary-iscsi"
echo Failed > "$FK/phase-nas-canary-nfs"
out=$(run canary)
expect_contains "nfs empty: exit 1" "rc=1" "$out"
expect_contains "nfs empty: failing step" "FAIL at nfs" "$out"

echo "usage"
for bad in "" "nope" "plan x" "up" "canary --force" "status x"; do
  # shellcheck disable=SC2086 # split into arguments on purpose
  out=$(run $bad)
  expect_contains "usage: '$bad'" "rc=64" "$out"
done

finish
