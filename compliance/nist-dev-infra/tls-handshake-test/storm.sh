#!/usr/bin/env bash
# Reconnection storm against the test etcd, optionally on a CPU-loaded node:
# the conditions of the stage C crashes. Reports peak threads and whether
# the server died.
# Usage: [GOMAXPROCS=n] [LOAD=cores] [CONNS=n] [CYCLES=n] [HOLD=15s] [TIMEOUT=20s]
#        storm.sh <label> <server-node> <client-node>
# Same prerequisites as measure.sh. Creates namespace hs-test; delete it
# afterwards.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
LABEL=$1 SN=$2 CN=$3
CONNS=${CONNS:-2250} CYCLES=${CYCLES:-4} HOLD=${HOLD:-15s} TIMEOUT=${TIMEOUT:-20s} LOAD=${LOAD:-0}
oc get ns hs-test >/dev/null 2>&1 || oc create ns hs-test >/dev/null
oc get secret -n hs-test hs-certs >/dev/null 2>&1 || oc create secret generic hs-certs -n hs-test --from-file="$D/certs" >/dev/null
oc delete pod -n hs-test etcd-test stress --ignore-not-found --wait >/dev/null
"$D/render.sh" "$SN" "$CN" | oc apply -f - >/dev/null 2>&1
oc wait -n hs-test --for=condition=Ready pod/etcd-test pod/client --timeout=180s >/dev/null
oc cp "$D/hsburst" hs-test/client:/work/hsburst && oc exec -n hs-test client -- chmod +x /work/hsburst
IP=$(oc get pod -n hs-test etcd-test -o jsonpath='{.status.podIP}')

if [ "$LOAD" -gt 0 ]; then
  # Busy loops standing in for the workloads a drain moves onto the node.
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: stress, namespace: hs-test}
spec:
  nodeName: $SN
  tolerations: [{operator: Exists}]
  restartPolicy: Never
  activeDeadlineSeconds: 900
  containers:
    - name: stress
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: [sh, -c, 'for i in \$(seq $LOAD); do (while :; do :; done) & done; wait']
      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
EOF
  oc wait -n hs-test --for=condition=Ready pod/stress --timeout=120s >/dev/null
  sleep 5
fi

SECS=$(( CYCLES * ${HOLD%s} + 15 ))
oc exec -n hs-test etcd-test -- sh -c 'max=0; end=$(( $(date +%s) + '"$SECS"' )); while [ $(date +%s) -lt $end ]; do t=$(awk "/Threads/{print \$2}" /proc/1/status 2>/dev/null) || break; [ "${t:-0}" -gt $max ] && max=$t; sleep 0.1; done; echo $max' > "$D/.peak" 2>/dev/null &
sleep 1
echo "== $LABEL: $CONNS connections, timeout $TIMEOUT, load $LOAD cores, GOMAXPROCS=${GOMAXPROCS:-default}, server on $SN"
oc exec -n hs-test client -- /work/hsburst -addr "$IP:2379" -storm "$CONNS" -cycles "$CYCLES" -hold "$HOLD" -timeout "$TIMEOUT" || true
wait || true
echo "server peak threads: $(cat "$D/.peak" 2>/dev/null || echo '?')"
oc get pod -n hs-test etcd-test -o jsonpath='server: {.status.phase}, restarts {.status.containerStatuses[0].restartCount}, terminated {.status.containerStatuses[0].state.terminated.reason} exit {.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
oc logs -n hs-test etcd-test 2>/dev/null | grep -m3 -E "pthread_create|SIGABRT|fatal error" || true
oc delete pod -n hs-test stress --ignore-not-found --wait=false >/dev/null
