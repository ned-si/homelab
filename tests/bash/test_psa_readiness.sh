#!/bin/bash
# Tests for scripts/psa-readiness.sh with a fake `kubectl`.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/psa-readiness.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake kubectl: answers the reads and server dry runs the script makes from
# the fixtures in $FAKE_DIR, logs every call, and refuses anything else.
# A dry-run Pod whose first image contains `bad` gets a PodSecurity warning,
# `broken` a non-PodSecurity error.
cat > "$tmp/kubectl" <<'FAKE'
#!/bin/bash
d=${FAKE_DIR:?}
args=" $* "
echo "$*" >> "$d/calls.log"
case "$args" in
  *" get namespace "*) cat "$d/ns.json" ;;
  *" label --dry-run=server "*)
    cat "$d/label.out" >&2 2>/dev/null
    echo "namespace/x labeled (server dry run)" ;;
  *" get replicasets "*) cat "$d/rs.json" ;;
  *" get policyreports.wgpolicyk8s.io "*) cat "$d/polr.json" ;;
  *" get --raw "*) cat "$d/alerts.json" ;;
  *" get deployments,statefulsets,daemonsets,replicasets,jobs,cronjobs "*) cat "$d/ctrl.json" ;;
  *" create --dry-run=server -f - "*)
    n=$(($(cat "$d/dryrun.count" 2>/dev/null || echo 0) + 1))
    echo "$n" > "$d/dryrun.count"
    cat > "$d/dryrun-$n.json"
    case "$(jq -r '.spec.containers[0].image' "$d/dryrun-$n.json")" in
      *bad*)
        echo 'Warning: would violate PodSecurity "restricted:latest": runAsNonRoot != true (pod or container "main" must set securityContext.runAsNonRoot=true)' >&2
        echo pod/psa-readiness-abcde ;;
      *broken*)
        echo 'Error from server (Forbidden): pods "psa-readiness-" is forbidden: error looking up service account home/missing' >&2
        exit 1 ;;
      *) echo pod/psa-readiness-abcde ;;
    esac ;;
  *) echo "$*" >> "$d/refused.log"; echo "fake kubectl: refused: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$tmp/kubectl"
export KUBECTL="$tmp/kubectl"

# setup <warn label>: a clean namespace `home`.
#   - RS ha-old at 0 replicas fails a restricted policy (ignored);
#   - Deployment ha fails a best-practice policy (ignored);
#   - controllers: Deployment ha, StatefulSet syncthing (claim template data),
#     CronJob prune, Job hook (no owner), plus RS ha-old (owned by the
#     Deployment) and Job prune-1 (owned by the CronJob), both skipped.
setup() {
  rm -rf "$tmp/d"; mkdir -p "$tmp/d"; export FAKE_DIR="$tmp/d"
  cat > "$FAKE_DIR/ns.json" <<EOF
{"metadata":{"name":"home","labels":{"pod-security.kubernetes.io/warn":"$1","pod-security.kubernetes.io/audit":"$1"}}}
EOF
  : > "$FAKE_DIR/label.out"
  cat > "$FAKE_DIR/rs.json" <<'EOF'
{"items":[{"metadata":{"name":"ha-new"},"spec":{"replicas":1}},{"metadata":{"name":"ha-old"},"spec":{"replicas":0}}]}
EOF
  cat > "$FAKE_DIR/polr.json" <<'EOF'
{"items":[
{"scope":{"kind":"Pod","name":"ha-new-x1"},"results":[{"policy":"require-run-as-nonroot","result":"pass"}]},
{"scope":{"kind":"ReplicaSet","name":"ha-old"},"results":[{"policy":"require-run-as-nonroot","result":"fail"}]},
{"scope":{"kind":"Deployment","name":"ha"},"results":[{"policy":"require-probes","result":"fail"},{"policy":"disallow-privilege-escalation","result":"pass"}]},
{"scope":{"kind":"Service","name":"ha"},"results":[]}
]}
EOF
  echo '[{"labels":{"alertname":"Watchdog"}}]' > "$FAKE_DIR/alerts.json"
  ctrl ok ok
}

# ctrl <deployment image> <cronjob image>
ctrl() {
  cat > "$FAKE_DIR/ctrl.json" <<EOF
{"items":[
{"kind":"Deployment","metadata":{"name":"ha"},"spec":{"replicas":1,"template":{"metadata":{"labels":{"app":"ha"}},"spec":{"containers":[{"name":"main","image":"$1"}],"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"ha"}}]}}}},
{"kind":"ReplicaSet","metadata":{"name":"ha-old","ownerReferences":[{"kind":"Deployment","name":"ha"}]},"spec":{"replicas":0,"template":{"spec":{"containers":[{"name":"main","image":"bad"}]}}}},
{"kind":"StatefulSet","metadata":{"name":"syncthing"},"spec":{"replicas":0,"template":{"spec":{"containers":[{"name":"main","image":"ok"}]}},"volumeClaimTemplates":[{"metadata":{"name":"data"}}]}},
{"kind":"CronJob","metadata":{"name":"prune"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"main","image":"$2"}]}}}}}},
{"kind":"Job","metadata":{"name":"prune-1","ownerReferences":[{"kind":"CronJob","name":"prune"}]},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"bad"}]}}}},
{"kind":"Job","metadata":{"name":"hook"},"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"main","image":"ok"}]}}}}
]}
EOF
}

run() { out=$(bash "$SCRIPT" home 2>&1); rc=$?; }

echo "clean namespace"
setup restricted
run
expect_eq "exit 0" 0 "$rc"
expect_eq "last line READY" READY "$(printf '%s\n' "$out" | tail -1)"
expect_contains "G1 passes" "G1 ok   label dry run: no warning" "$out"
expect_contains "G2 counts the vendored PSS policies" "G2 ok   reports: no fail of the 16 Pod Security Standards policies" "$out"
expect_contains "G3 sends 4 templates" "G3 ok   4 pod templates" "$out"
case "$out" in
  *ha-old*|*require-probes*) bad "RS at 0 and best-practice policies are ignored" ;;
  *) ok "RS at 0 and best-practice policies are ignored" ;;
esac
sts=$(jq -c '.spec.volumes' "$FAKE_DIR/dryrun-2.json")
expect_eq "StatefulSet Pod gets its claim volume" '[{"name":"data","persistentVolumeClaim":{"claimName":"data-syncthing-0"}}]' "$sts"
expect_eq "Deployment Pod keeps its volumes" '[{"name":"config","persistentVolumeClaim":{"claimName":"ha"}}]' "$(jq -c '.spec.volumes' "$FAKE_DIR/dryrun-1.json")"
expect_eq "dry-run Pods are generated in the namespace" "Pod psa-readiness- home" \
  "$(jq -r '"\(.kind) \(.metadata.generateName) \(.metadata.namespace)"' "$FAKE_DIR/dryrun-3.json")"
expect_eq "CronJob Pod spec from the job template" Never "$(jq -r '.spec.restartPolicy' "$FAKE_DIR/dryrun-3.json")"

echo "one failing Pod"
setup restricted
cat > "$FAKE_DIR/label.out" <<'EOF'
Warning: existing pods in namespace "home" violate the new PodSecurity enforce level "restricted:latest"
Warning: bad-pod: allowPrivilegeEscalation != false
EOF
jq '.items += [{"scope":{"kind":"Pod","name":"bad-pod"},"results":[{"policy":"disallow-privilege-escalation","result":"fail"},{"policy":"restrict-seccomp-strict","result":"fail"}]},
               {"scope":{"kind":"ReplicaSet","name":"ha-new"},"results":[{"policy":"require-run-as-nonroot","result":"fail"}]}]' \
  "$FAKE_DIR/polr.json" > "$FAKE_DIR/p" && mv "$FAKE_DIR/p" "$FAKE_DIR/polr.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "G1 names the Pod" "G1 FAIL bad-pod: allowPrivilegeEscalation != false" "$out"
expect_contains "G2 names the Pod and its policies" "G2 FAIL Pod/bad-pod: disallow-privilege-escalation, restrict-seccomp-strict" "$out"
expect_contains "G2 names a ReplicaSet above 0" "G2 FAIL ReplicaSet/ha-new: require-run-as-nonroot" "$out"
expect_contains "NOT READY with the count" "NOT READY (4)" "$out"

echo "one failing CronJob template"
setup restricted
ctrl ok bad
run
expect_eq "exit 1" 1 "$rc"
expect_contains "G3 names the CronJob" 'G3 FAIL CronJob/prune: would violate PodSecurity "restricted:latest": runAsNonRoot != true' "$out"
expect_contains "G1 still passes" "G1 ok" "$out"

echo "non-PodSecurity dry-run error"
setup restricted
ctrl broken ok
run
expect_eq "exit 1" 1 "$rc"
expect_contains "G3 reads the error as a failure" "G3 FAIL Deployment/ha: dry run failed: Error from server (Forbidden)" "$out"

echo "stale reports"
setup restricted
echo '[{"labels":{"alertname":"Watchdog"}},{"labels":{"alertname":"KyvernoReportsStale"}}]' > "$FAKE_DIR/alerts.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "G2 fails on KyvernoReportsStale" "G2 FAIL KyvernoReportsStale is firing" "$out"

echo "warn label below restricted"
setup baseline
run
expect_eq "exit 1" 1 "$rc"
expect_contains "G3 needs warn at restricted" "G3 FAIL warn label is baseline" "$out"
if [ -f "$FAKE_DIR/dryrun.count" ]; then bad "no dry-run Pods without warn restricted"; else ok "no dry-run Pods without warn restricted"; fi

echo "usage"
bash "$SCRIPT" 'Bad_NS' > /dev/null 2>&1; expect_eq "rejects an invalid namespace" 64 "$?"
bash "$SCRIPT" > /dev/null 2>&1; expect_eq "rejects no argument" 64 "$?"

echo "read-only"
setup restricted
"$KUBECTL" --request-timeout=20s -n home delete pod x > /dev/null 2>&1
expect_eq "the fake refuses a write verb" 99 "$?"
expect_eq "the refused write is logged" "--request-timeout=20s -n home delete pod x" "$(cat "$FAKE_DIR/refused.log")"
setup restricted
run
ctrl ok bad; run
ctrl broken ok; run
if [ -s "$FAKE_DIR/refused.log" ]; then bad "the script made a refused call: $(cat "$FAKE_DIR/refused.log")"; else ok "the script made no refused call"; fi
others=$(grep -v -E -e '(^| )get ' -e ' --dry-run=server( |$)' "$FAKE_DIR/calls.log" || true)
expect_eq "every call is a get or a server dry run" "" "$others"

finish
