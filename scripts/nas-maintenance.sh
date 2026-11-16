#!/bin/bash
# nas-maintenance.sh plan
# nas-maintenance.sh down
# nas-maintenance.sh up <state-file>
# nas-maintenance.sh canary [--hold-guard]
# nas-maintenance.sh status
#
# Stops and starts every workload that uses the NAS, and proves the storage
# path end to end, for a NAS maintenance window
# (.kiro/specs/nas-on-truenas-scale/design.md, scripts/nas-maintenance.sh).
#
#   plan    read-only: the workloads with a NAS volume (iSCSI class, or NFS
#           on the NAS) and the action `down` takes on each, plus the daily
#           backup set with each job's last success.
#   down    Argo CD automated sync off (root, the layers, then the rest),
#           then the actions; records every previous value in
#           $NAS_MAINT_STATE_DIR/<utc>.json after each change; waits until
#           no pod mounts a NAS volume and no iSCSI VolumeAttachment is left.
#   up      reverses a state file, waits for the workloads, restarts once
#           what is still not Ready after the databases are healthy, then
#           restores Argo CD (apps, layers, root), in every case.
#   canary  in namespace backup-verify: a new iSCSI volume written, read back
#           and expanded, then the four NFS paths non-empty
#           (scripts/nas-canary/). --hold-guard (SCALE) also waits until
#           nas-iscsi-guard limits the new target to the four nodes.
#   status  the counts `down` waits on and the newest state file.
#
# Needs kubectl (operator kubeconfig), jq; curl for --hold-guard.
# Exit 0 done, 1 timeout or failed step, 2 kubectl error, 3 precondition,
# 64 usage. Logs go to stderr with UTC timestamps.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NAS_IP=${NAS_IP:-192.168.1.228}
STATE_DIR=${NAS_MAINT_STATE_DIR:-$HOME/homelab-backups/nas-maintenance}
POLL=${NAS_MAINT_POLL:-10}
ARGO_TIMEOUT=${NAS_MAINT_ARGO_TIMEOUT:-120}
DOWN_TIMEOUT=${NAS_MAINT_DOWN_TIMEOUT:-900}
UP_TIMEOUT=${NAS_MAINT_UP_TIMEOUT:-1200}
RESTART_AFTER=${NAS_MAINT_RESTART_AFTER:-300}
STEP_TIMEOUT=${NAS_MAINT_STEP_TIMEOUT:-300}
GUARD_TIMEOUT=${NAS_MAINT_GUARD_TIMEOUT:-900}
GUARD_POLL=${NAS_MAINT_GUARD_POLL:-30}
ISCSI_AUTH_NETWORKS=${ISCSI_AUTH_NETWORKS:-192.168.1.247/32 192.168.1.238/32 192.168.1.239/32 192.168.1.240/32}
ACTIVE_CRONJOBS=${NAS_MAINT_ACTIVE_CRONJOBS:-$ROOT/ci/active-cronjobs.txt}
CANARY_DIR="$HERE/nas-canary"
CANARY_NS=backup-verify
CANARY_LABEL=app.kubernetes.io/name=nas-canary
ATTACHER=org.democratic-csi.iscsi
LAYERS="layer-infrastructure layer-platform layer-apps"
# Added by name: no NAS volume, but it must not write while the NAS changes.
EXTRA_CRONJOBS="democratic-csi/nas-iscsi-guard"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { local rc=$1; shift; log "$*"; exit "$rc"; }
usage() { sed -n '2,6p' "$0" | sed 's/^# //' >&2; exit 64; }
k() { kubectl --request-timeout="${KUBECTL_TIMEOUT:-20s}" "$@"; }
now() { date -u +%s; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# collect: the objects plan needs, as one JSON document in $tmp/objects.json.
collect() {
  local r
  for r in pods pvc pv replicasets statefulsets jobs cronjobs; do
    k get "$r" -A -o json > "$tmp/$r.json" 2> "$tmp/err" || die 2 "kubectl get $r: $(head -n 1 "$tmp/err")"
  done
  jq -n --arg nas "$NAS_IP" \
    --slurpfile pods "$tmp/pods.json" --slurpfile pvcs "$tmp/pvc.json" --slurpfile pvs "$tmp/pv.json" \
    --slurpfile rs "$tmp/replicasets.json" --slurpfile sts "$tmp/statefulsets.json" \
    --slurpfile jobs "$tmp/jobs.json" --slurpfile cronjobs "$tmp/cronjobs.json" \
    '{nas: $nas, pods: $pods[0].items, pvcs: $pvcs[0].items, pvs: $pvs[0].items, rs: $rs[0].items,
      sts: $sts[0].items, jobs: $jobs[0].items, cronjobs: $cronjobs[0].items}' > "$tmp/objects.json" \
    || die 2 "kubectl returned invalid JSON"
}

# The plan from $tmp/objects.json: targets in `down` order, the counted,
# finished and unknown pods, and the active NAS Jobs.
# shellcheck disable=SC2016 # jq variables
PLAN_JQ='
def key: .metadata.namespace + "/" + .metadata.name;
def ctl: [(.metadata.ownerReferences // [])[] | select(.controller == true)][0];
. as $o
| ([$o.pvs[] | select((.spec.storageClassName // "") as $c
    | $c == "iscsi" or $c == "iscsi-retain"
      or (.spec.csi.driver // "") == "org.democratic-csi.iscsi"
      or (.spec.nfs.server // "") == $o.nas) | {key: .metadata.name, value: true}] | from_entries) as $nasPV
| ([$o.pvcs[] | select($nasPV[.spec.volumeName // ""]) | {key: key, value: true}] | from_entries) as $nasPVC
| def nas_vols($ns): any(.volumes[]?;
    (.persistentVolumeClaim.claimName // null) as $c
    | ($c != null and ($nasPVC[$ns + "/" + $c] // false)) or ((.nfs.server // "") == $o.nas));
  ([$o.rs[] | {key: key, value: .}] | from_entries) as $rs
| ([$o.sts[] | {key: key, value: .}] | from_entries) as $sts
| ([$o.jobs[] | {key: key, value: .}] | from_entries) as $jobs
| def owner_of($p):
    ($p.metadata.namespace) as $ns | ($p | ctl) as $c
    | if $c == null then {unknown: "no owner"}
      elif $c.kind == "ReplicaSet" then
        (($rs[$ns + "/" + $c.name] // {}) | ctl) as $d
        | if $d != null and $d.kind == "Deployment" then {kind: "Deployment", namespace: $ns, name: $d.name}
          else {unknown: ("ReplicaSet/" + $c.name)} end
      elif $c.kind == "StatefulSet" then
        (($sts[$ns + "/" + $c.name] // {}) | ctl) as $d
        | if $d == null then {kind: "StatefulSet", namespace: $ns, name: $c.name}
          elif $d.kind == "Prometheus" then {kind: "Prometheus", namespace: $ns, name: $d.name}
          elif $d.kind == "ClickHouseInstallation" then {kind: "ClickHouseInstallation", namespace: $ns, name: $d.name}
          else {unknown: ("StatefulSet/" + $c.name + " -> " + $d.kind)} end
      elif $c.kind == "Cluster" and ($c.apiVersion | startswith("postgresql.cnpg.io/")) then
        {kind: "Cluster", namespace: $ns, name: $c.name}
      elif $c.kind == "Job" then
        (($jobs[$ns + "/" + $c.name] // {}) | ctl) as $d
        | if $d != null and $d.kind == "CronJob" then {kind: "CronJob", namespace: $ns, name: $d.name}
          else {unknown: ("Job/" + $c.name + " without CronJob")} end
      else {unknown: ($c.kind + "/" + $c.name)} end;
  def counted: .status.phase as $ph
    | $ph == "Pending" or $ph == "Running" or ($ph == "Unknown" and .metadata.deletionTimestamp != null);
  [$o.pods[] | select(.metadata.namespace as $ns | .spec | nas_vols($ns))] as $nasPods
| [$nasPods[] | select(counted)] as $counted
| [$counted[] | {pod: key, owner: owner_of(.)}] as $owned
| [$o.cronjobs[] | select(.metadata.namespace as $ns | .spec.jobTemplate.spec.template.spec | nas_vols($ns))
    | {kind: "CronJob", namespace: .metadata.namespace, name: .metadata.name}] as $cronjobs
| [$o.cronjobs[] | select(key as $k | $extra | index($k))
    | {kind: "CronJob", namespace: .metadata.namespace, name: .metadata.name}] as $extraCron
| ["CronJob", "Deployment", "StatefulSet", "Prometheus", "ClickHouseInstallation", "Cluster"] as $order
| {
    targets: ([$owned[].owner | select(.unknown == null)] + $cronjobs + $extraCron | unique
      | sort_by(.kind as $k | ($order | index($k)), .namespace, .name)),
    unknown: [$owned[] | select(.owner.unknown != null) | .pod + " (" + .owner.unknown + ")"],
    counted: [$counted[] | key],
    finished: [$nasPods[] | select(counted | not) | key + " (" + .status.phase + ")"],
    active_jobs: [$o.jobs[] | select((.status.active // 0) > 0)
      | select(.metadata.namespace as $ns | .spec.template.spec | nas_vols($ns)) | key]
  }
'

compute_plan() {
  collect
  jq --argjson extra "$(printf '%s\n' $EXTRA_CRONJOBS | jq -R . | jq -s .)" "$PLAN_JQ" \
    "$tmp/objects.json" > "$tmp/plan.json" || die 2 "plan: cannot evaluate the objects"
}

action_of() {
  case "$1" in
    Deployment|StatefulSet) echo "scale to 0" ;;
    Prometheus) echo "spec.replicas: 0" ;;
    ClickHouseInstallation) echo 'spec.stop: "yes"' ;;
    Cluster) echo "cnpg.io/hibernation=on" ;;
    CronJob) echo "suspend" ;;
  esac
}

# The daily backup set: ci/active-cronjobs.txt names with -backup, minus
# backup-verify-*; `today` when the last success is after 00:00Z.
print_backups() {
  local today total=0 fresh=0 ns name t mark
  today=$(date -u +%Y-%m-%dT00:00:00Z)
  echo "daily backup set (last success, today = since $today):"
  while IFS=/ read -r ns name; do
    total=$((total + 1))
    t=$(jq -r --arg ns "$ns" --arg n "$name" \
      '[.cronjobs[] | select(.metadata.namespace == $ns and .metadata.name == $n)][0].status.lastSuccessfulTime // "never"' \
      "$tmp/objects.json")
    if [ "$t" != never ] && [[ ! "$t" < "$today" ]]; then mark=today; fresh=$((fresh + 1)); else mark=OLD; fi
    printf '  %-5s %-50s %s\n' "$mark" "$ns/$name" "$t"
  done < <(grep -v '^#' "$ACTIVE_CRONJOBS" | grep -E '^[^/]+/[^/]*-backup' | grep -vE '/backup-verify-')
  echo "daily backup set: $fresh/$total today"
}

print_plan() {
  local n
  n=$(jq '.targets | length' "$tmp/plan.json")
  echo "plan: $n workloads to stop; $(jq '.counted | length' "$tmp/plan.json") pods on NAS volumes"
  jq -r '.targets[] | [.kind, .namespace + "/" + .name] | @tsv' "$tmp/plan.json" | while IFS=$'\t' read -r kind obj; do
    printf '  %-24s %-50s %s\n' "$kind" "$obj" "$(action_of "$kind")"
  done
  jq -r '.finished[] | "  finished, ignored: " + .' "$tmp/plan.json"
  jq -r '.active_jobs[] | "  ACTIVE NAS JOB: " + .' "$tmp/plan.json"
  jq -r '.unknown[] | "  UNKNOWN OWNER: " + .' "$tmp/plan.json"
  print_backups
}

cmd_plan() {
  compute_plan
  print_plan
  if [ "$(jq '.unknown | length' "$tmp/plan.json")" -gt 0 ]; then
    die 3 "plan: unknown owner; extend the table in design.md before a window"
  fi
  if [ "$(jq '.active_jobs | length' "$tmp/plan.json")" -gt 0 ]; then
    die 3 "plan: a Job on a NAS volume is active; wait for it"
  fi
}

# --- state file -------------------------------------------------------------

state_init() {
  mkdir -p "$STATE_DIR" || die 3 "cannot create $STATE_DIR"
  STATE="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ).json"
  jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{version: 1, started: $t, argo: [], actions: []}' > "$STATE"
  log "state file: $STATE"
}

# state_add <argo|actions> <json>: append and rewrite, so an interrupted run
# leaves a usable record.
state_add() {
  if ! { jq --argjson e "$2" ".$1 += [\$e]" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }; then
    die 1 "cannot write $STATE"
  fi
}

# --- Argo CD ----------------------------------------------------------------

argo_automated() { # <app>: the automated block as JSON, `null` when off
  k -n argo get applications.argoproj.io "$1" -o json | jq -c '.spec.syncPolicy.automated // null'
}

argo_off() { # <app> <wait 0|1>
  local app=$1 block deadline
  block=$(argo_automated "$app") || die 2 "kubectl get application $app failed"
  if [ "$block" = null ]; then log "argo: $app has no automated sync"; return 0; fi
  k -n argo patch applications.argoproj.io "$app" --type json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' > /dev/null || die 2 "argo: patch $app failed"
  state_add argo "$(jq -nc --arg n "$app" --argjson b "$block" '{name: $n, automated: $b}')"
  log "argo: $app automated sync off"
  [ "$2" = 1 ] || return 0
  deadline=$(( $(now) + ARGO_TIMEOUT ))
  while :; do
    block=$(argo_automated "$app") || die 2 "kubectl get application $app failed"
    [ "$block" = null ] && return 0
    [ "$(now)" -lt "$deadline" ] || die 1 "argo: $app got its automated block back"
    k -n argo patch applications.argoproj.io "$app" --type json \
      -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' > /dev/null || true
    sleep "$POLL"
  done
}

argo_all_off() {
  local app rest
  argo_off root 1
  for app in $LAYERS; do argo_off "$app" 1; done
  rest=$(k -n argo get applications.argoproj.io -o json | jq -r '.items[].metadata.name' | sort) \
    || die 2 "kubectl get applications failed"
  for app in $rest; do
    case " root $LAYERS " in *" $app "*) continue ;; esac
    argo_off "$app" 0
  done
}

# argo_restore <state>: apps first, layers next, root last.
argo_restore() {
  local st=$1 app block order
  order=$(jq -r --arg layers "$LAYERS" '($layers | split(" ")) as $l
    | [.argo[] | .name] as $n
    | ([$n[] | select(. as $x | $x != "root" and ($l | index($x) | not))] + [$l[] | select(. as $x | $n | index($x))]
       + [$n[] | select(. == "root")])[]' "$st")
  for app in $order; do
    block=$(jq -c --arg n "$app" '[.argo[] | select(.name == $n)][0].automated' "$st")
    if k -n argo patch applications.argoproj.io "$app" --type merge \
      -p "{\"spec\":{\"syncPolicy\":{\"automated\":$block}}}" > /dev/null; then
      log "argo: $app automated sync restored"
    else
      log "argo: restoring $app FAILED; restore it by hand"
    fi
  done
}

# --- actions ----------------------------------------------------------------

resource_of() {
  case "$1" in
    Deployment) echo deployment ;;
    StatefulSet) echo statefulset ;;
    Prometheus) echo prometheuses.monitoring.coreos.com ;;
    ClickHouseInstallation) echo clickhouseinstallations.clickhouse.altinity.com ;;
    Cluster) echo clusters.postgresql.cnpg.io ;;
    CronJob) echo cronjob ;;
  esac
}

field_of() {
  case "$1" in
    Deployment|StatefulSet|Prometheus) echo '.spec.replicas' ;;
    ClickHouseInstallation) echo '.spec.stop' ;;
    Cluster) echo '.metadata.annotations["cnpg.io/hibernation"]' ;;
    CronJob) echo '.spec.suspend' ;;
  esac
}

# set_value <kind> <ns> <name> <json value>: the one write per object.
set_value() {
  local kind=$1 ns=$2 name=$3 v=$4 r
  r=$(resource_of "$kind")
  case "$kind" in
    Deployment|StatefulSet)
      [ "$v" = null ] && v=1
      k -n "$ns" scale "$r/$name" --replicas="$v" > /dev/null ;;
    Prometheus) k -n "$ns" patch "$r" "$name" --type merge -p "{\"spec\":{\"replicas\":$v}}" > /dev/null ;;
    ClickHouseInstallation) k -n "$ns" patch "$r" "$name" --type merge -p "{\"spec\":{\"stop\":$v}}" > /dev/null ;;
    CronJob)
      [ "$v" = null ] && v=false
      k -n "$ns" patch "$r" "$name" --type merge -p "{\"spec\":{\"suspend\":$v}}" > /dev/null ;;
    Cluster)
      if [ "$v" = null ]; then k -n "$ns" annotate "$r" "$name" cnpg.io/hibernation- > /dev/null
      else k -n "$ns" annotate --overwrite "$r" "$name" "cnpg.io/hibernation=$(jq -r . <<<"$v")" > /dev/null; fi ;;
  esac
}

down_value() {
  case "$1" in
    Deployment|StatefulSet|Prometheus) echo 0 ;;
    ClickHouseInstallation) echo '"yes"' ;;
    Cluster) echo '"on"' ;;
    CronJob) echo true ;;
  esac
}

# nas_counts: "<pods> <attachments>" still holding the NAS.
nas_counts() {
  local pods va
  compute_plan
  pods=$(jq '.counted | length' "$tmp/plan.json")
  va=$(k get volumeattachments -o json | jq --arg a "$ATTACHER" '[.items[] | select(.spec.attacher == $a)] | length') \
    || die 2 "kubectl get volumeattachments failed"
  echo "$pods $va"
}

cmd_down() {
  local kind ns name prev deadline counts
  compute_plan
  print_plan
  [ "$(jq '.unknown | length' "$tmp/plan.json")" -eq 0 ] || die 3 "down: unknown owner, nothing changed"
  [ "$(jq '.active_jobs | length' "$tmp/plan.json")" -eq 0 ] || die 3 "down: a Job on a NAS volume is active, nothing changed"
  jq -c '.targets[]' "$tmp/plan.json" > "$tmp/targets"
  state_init
  echo "$STATE"
  argo_all_off
  while IFS= read -r t; do
    kind=$(jq -r .kind <<<"$t"); ns=$(jq -r .namespace <<<"$t"); name=$(jq -r .name <<<"$t")
    prev=$(k -n "$ns" get "$(resource_of "$kind")" "$name" -o json | jq -c "$(field_of "$kind") // null") \
      || die 2 "down: kubectl get $kind $ns/$name failed"
    set_value "$kind" "$ns" "$name" "$(down_value "$kind")" || die 2 "down: $kind $ns/$name failed"
    state_add actions "$(jq -c --argjson p "$prev" '. + {previous: $p}' <<<"$t")"
    log "down: $kind $ns/$name $(action_of "$kind") (was $prev)"
  done < "$tmp/targets"
  deadline=$(( $(now) + DOWN_TIMEOUT ))
  while :; do
    counts=$(nas_counts) || die 2 "down: kubectl error while waiting; state file $STATE"
    log "down: waiting, pods on NAS volumes and iSCSI attachments: $counts"
    [ "$counts" = "0 0" ] && { log "down: done; up with: $0 up $STATE"; return 0; }
    if [ "$(now)" -ge "$deadline" ]; then
      jq -r '.counted[] | "  still mounted: " + .' "$tmp/plan.json" >&2
      die 1 "down: timeout; state file $STATE"
    fi
    sleep "$POLL"
  done
}

# not_ready <state>: the recorded workloads not back yet, one per line.
not_ready() {
  local st=$1
  k get deployments,statefulsets -A -o json > "$tmp/wl.json" || return 2
  k get clusters.postgresql.cnpg.io,clickhouseinstallations.clickhouse.altinity.com -A -o json > "$tmp/crs.json" || return 2
  jq -r --slurpfile wl "$tmp/wl.json" --slurpfile crs "$tmp/crs.json" '
    def ready: (.status.readyReplicas // 0) >= (.spec.replicas // 1);
    .actions[] | . as $a
    | if $a.kind == "Deployment" or $a.kind == "StatefulSet" then
        [$wl[0].items[] | select(.kind == $a.kind and .metadata.namespace == $a.namespace and .metadata.name == $a.name)][0]
        | select(. == null or (ready | not)) | $a.kind + " " + $a.namespace + "/" + $a.name
      elif $a.kind == "Prometheus" then
        [$wl[0].items[] | select(.kind == "StatefulSet" and .metadata.namespace == $a.namespace
          and any((.metadata.ownerReferences // [])[]; .kind == "Prometheus" and .name == $a.name))][0]
        | select(. == null or (ready | not)) | "Prometheus " + $a.namespace + "/" + $a.name
      elif $a.kind == "ClickHouseInstallation" then
        [$crs[0].items[] | select(.kind == $a.kind and .metadata.namespace == $a.namespace and .metadata.name == $a.name)][0]
        | select(. == null or .status.status != "Completed") | $a.kind + " " + $a.namespace + "/" + $a.name
      elif $a.kind == "Cluster" then
        [$crs[0].items[] | select(.kind == "Cluster" and .metadata.namespace == $a.namespace and .metadata.name == $a.name)][0]
        | select(. == null or .status.phase != "Cluster in healthy state") | "Cluster " + $a.namespace + "/" + $a.name
      else empty end' "$st"
}

# restart_not_ready: `rollout restart` once on every Deployment and
# StatefulSet (without a controller) in the cluster that is not Ready.
restart_not_ready() {
  k get deployments,statefulsets -A -o json | jq -r '.items[]
    | select((.spec.replicas // 1) > 0 and (.status.readyReplicas // 0) < (.spec.replicas // 1))
    | select([(.metadata.ownerReferences // [])[] | select(.controller == true)] | length == 0)
    | (.kind | ascii_downcase) + " " + .metadata.namespace + " " + .metadata.name' \
    | while read -r kind ns name; do
      if k -n "$ns" rollout restart "$kind/$name" > /dev/null; then log "up: restarted $kind $ns/$name"
      else log "up: restart of $kind $ns/$name failed"; fi
    done
}

cmd_up() {
  local st=$1 t kind ns name prev deadline healthy_at="" restarted=0 left rc=0
  [ -r "$st" ] && [ "$(jq -r '.version // empty' "$st" 2>/dev/null)" = 1 ] || die 3 "up: $st is not a state file"
  # Argo CD comes back in every case, so `up` can be re-run.
  trap 'argo_restore "$st"; rm -rf "$tmp"' EXIT
  jq -c '.actions | reverse | .[]' "$st" > "$tmp/actions"
  while IFS= read -r t; do
    kind=$(jq -r .kind <<<"$t"); ns=$(jq -r .namespace <<<"$t"); name=$(jq -r .name <<<"$t")
    prev=$(jq -c .previous <<<"$t")
    if set_value "$kind" "$ns" "$name" "$prev"; then log "up: $kind $ns/$name back to $prev"
    else log "up: $kind $ns/$name FAILED"; rc=2; fi
  done < "$tmp/actions"
  deadline=$(( $(now) + UP_TIMEOUT ))
  while :; do
    left=$(not_ready "$st") || { log "up: kubectl error while waiting"; left="?"; }
    [ -z "$left" ] && break
    if [ -z "$healthy_at" ] && [ "$left" != "?" ] && ! grep -q '^Cluster ' <<<"$left"; then
      healthy_at=$(now); log "up: every CNPG cluster healthy"
    fi
    if [ -n "$healthy_at" ] && [ "$restarted" = 0 ] && [ "$(now)" -ge $((healthy_at + RESTART_AFTER)) ]; then
      restarted=1; restart_not_ready
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      while IFS= read -r l; do log "up: not ready: $l"; done <<<"$left"
      log "up: timeout"
      exit 1
    fi
    sleep "$POLL"
  done
  log "up: every workload Ready"
  exit "$rc"
}

# --- canary -----------------------------------------------------------------

canary_pv=""
canary_cleanup() {
  local deadline
  k -n "$CANARY_NS" delete pod,pvc -l "$CANARY_LABEL" --ignore-not-found --wait=false > /dev/null 2>&1
  [ -n "$canary_pv" ] || return 0
  deadline=$(( $(now) + STEP_TIMEOUT ))
  while k get pv "$canary_pv" > /dev/null 2>&1; do
    [ "$(now)" -lt "$deadline" ] || { log "canary: PV $canary_pv still there"; return 1; }
    sleep "$POLL"
  done
}

canary_fail() { # <step> <detail>
  local p
  for p in nas-canary-iscsi nas-canary-nfs; do
    k -n "$CANARY_NS" logs "$p" --tail=20 2>/dev/null | sed "s/^/  $p: /" >&2
  done
  canary_cleanup
  die 1 "canary: FAIL at $1: $2"
}

# wait_log <pod> <word>: until the pod logs a line starting with <word>.
wait_log() {
  local pod=$1 word=$2 step=$3 deadline phase
  deadline=$(( $(now) + STEP_TIMEOUT ))
  while :; do
    if k -n "$CANARY_NS" logs "$pod" 2>/dev/null | grep -q "^$word"; then return 0; fi
    phase=$(k -n "$CANARY_NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = Failed ] && canary_fail "$step" "pod $pod failed"
    [ "$(now)" -lt "$deadline" ] || canary_fail "$step" "no $word from $pod within ${STEP_TIMEOUT}s (phase ${phase:-none})"
    sleep "$POLL"
  done
}

wait_phase() { # <pod> <step>: until Succeeded
  local pod=$1 step=$2 deadline phase
  deadline=$(( $(now) + STEP_TIMEOUT ))
  while :; do
    phase=$(k -n "$CANARY_NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = Succeeded ] && return 0
    [ "$phase" = Failed ] && canary_fail "$step" "pod $pod failed"
    [ "$(now)" -lt "$deadline" ] || canary_fail "$step" "pod $pod not done within ${STEP_TIMEOUT}s (phase ${phase:-none})"
    sleep "$POLL"
  done
}

# nas_api <path>: GET on the TrueNAS REST API, with the key from the driver
# Secret held in memory and the CA from the democratic-csi values.
nas_api() {
  local key
  key=$(k -n democratic-csi get secret iscsi-democratic-csi-driver-config \
    -o jsonpath='{.data.driver-config-file\.yaml}' | base64 -d \
    | sed -n 's/^[[:space:]]*apiKey:[[:space:]]*//p' | head -n 1 | tr -d "\"'")
  [ -n "$key" ] || { log "canary: cannot read the driver config"; return 2; }
  [ -s "$tmp/ca.pem" ] || awk '/^extraCaCerts:/ {on = 1; next} on && /^[^ ]/ {exit} on {sub(/^  /, ""); print}' \
    "$ROOT/infrastructure/democratic-csi/values-iscsi.yaml" > "$tmp/ca.pem"
  printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -sS -m 10 --fail --cacert "$tmp/ca.pem" --config - "https://$NAS_IP/api/v2.0/$1"
}

hold_guard() {
  local iqn target want got deadline
  iqn=$(k get pv "$canary_pv" -o jsonpath='{.spec.csi.volumeAttributes.iqn}')
  target=${iqn##*:}
  [ -n "$target" ] || canary_fail guard "no iqn on PV $canary_pv"
  # shellcheck disable=SC2086 # one address per word
  want=$(printf '%s\n' $ISCSI_AUTH_NETWORKS | jq -R . | jq -sc 'sort')
  deadline=$(( $(now) + GUARD_TIMEOUT ))
  log "canary: waiting for nas-iscsi-guard to limit target $target to $want"
  while :; do
    got=$(nas_api "iscsi/target?name=$target" | jq -c '[.[0].auth_networks[]?] | sort' 2>/dev/null)
    log "canary: target $target auth_networks ${got:-unreadable}"
    [ "$got" = "$want" ] && return 0
    [ "$(now)" -lt "$deadline" ] || canary_fail guard "target $target not limited within ${GUARD_TIMEOUT}s"
    sleep "$GUARD_POLL"
  done
}

cmd_canary() {
  local hold=$1 deadline
  if [ -n "$(k -n "$CANARY_NS" get pod,pvc -l "$CANARY_LABEL" -o name 2>/dev/null)" ]; then
    log "canary: removing leftovers of an earlier run"
    canary_cleanup
  fi
  log "canary: iSCSI volume"
  k apply -f "$CANARY_DIR/iscsi.yaml" > /dev/null 2> "$tmp/err" || canary_fail create "$(head -n 1 "$tmp/err")"
  deadline=$(( $(now) + STEP_TIMEOUT ))
  until [ "$(k -n "$CANARY_NS" get pvc nas-canary -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ]; do
    [ "$(now)" -lt "$deadline" ] || canary_fail bind "PVC nas-canary not Bound within ${STEP_TIMEOUT}s"
    sleep "$POLL"
  done
  canary_pv=$(k -n "$CANARY_NS" get pvc nas-canary -o jsonpath='{.spec.volumeName}')
  log "canary: bound to $canary_pv"
  wait_log nas-canary-iscsi WRITE_OK write
  log "canary: $(k -n "$CANARY_NS" logs nas-canary-iscsi | grep '^WRITE_OK')"
  k -n "$CANARY_NS" patch pvc nas-canary --type merge \
    -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' > /dev/null || canary_fail expand "patch failed"
  wait_phase nas-canary-iscsi expand
  k -n "$CANARY_NS" logs nas-canary-iscsi | grep -q '^GREW' || canary_fail expand "no GREW line"
  log "canary: $(k -n "$CANARY_NS" logs nas-canary-iscsi | grep '^GREW')"
  [ "$hold" = 1 ] && hold_guard
  canary_cleanup || canary_fail delete "volume not deleted"
  log "canary: iSCSI volume deleted"
  log "canary: NFS paths"
  k apply -f "$CANARY_DIR/nfs.yaml" > /dev/null 2> "$tmp/err" || canary_fail nfs "$(head -n 1 "$tmp/err")"
  wait_phase nas-canary-nfs nfs
  k -n "$CANARY_NS" logs nas-canary-nfs | grep -q '^NFS_OK' || canary_fail nfs "no NFS_OK line"
  k -n "$CANARY_NS" logs nas-canary-nfs | sed 's/^/  /' >&2
  canary_pv=""
  canary_cleanup
  echo "canary: PASS"
}

cmd_status() {
  local counts newest
  counts=$(nas_counts) || exit 2
  echo "pods on NAS volumes: ${counts% *}"
  echo "iSCSI VolumeAttachments: ${counts#* }"
  # The names are UTC timestamps: the last in order is the newest.
  newest=$(find "$STATE_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort | tail -n 1)
  echo "state file: ${newest:-none}"
}

case "${1:-}" in
  plan) [ "$#" -eq 1 ] || usage; cmd_plan ;;
  down) [ "$#" -eq 1 ] || usage; cmd_down ;;
  up) [ "$#" -eq 2 ] || usage; cmd_up "$2" ;;
  canary)
    case "$#:${2:-}" in
      1:) cmd_canary 0 ;;
      2:--hold-guard) cmd_canary 1 ;;
      *) usage ;;
    esac ;;
  status) [ "$#" -eq 1 ] || usage; cmd_status ;;
  *) usage ;;
esac
