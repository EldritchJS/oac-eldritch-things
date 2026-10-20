#!/usr/bin/env bash
# One configuration: fresh test server, then sequential and burst runs.
# Usage: [GOMAXPROCS=n] [GLIBC_TUNABLES=...] [IMAGE=etcd-image] [NATIVE=1] [PERF=1]
#        measure.sh <label> <server-node> <client-node>
#
# The server is the cluster's own etcd image with etcd's TLS settings; the
# client (main.go) starts N handshakes at once. Needs, next to this script:
#   hsburst  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o hsburst .
#   hsserve  (NATIVE=1 only) the same, with ./server
#   certs/   ca.crt, server.{crt,key}, client.{crt,key}: throwaway RSA-2048,
#            server SAN DNS:etcd-test, both serverAuth and clientAuth
# PERF=1 profiles the server process during the bursts (perf, from a node
# debug pod) and prints the top symbols.
# Creates namespace hs-test; delete it afterwards.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
LABEL=$1 SN=$2 CN=$3
oc get ns hs-test >/dev/null 2>&1 || oc create ns hs-test >/dev/null
oc get secret -n hs-test hs-certs >/dev/null 2>&1 || oc create secret generic hs-certs -n hs-test --from-file="$D/certs" >/dev/null
oc delete pod -n hs-test etcd-test --ignore-not-found --wait >/dev/null
"$D/render.sh" "$SN" "$CN" | oc apply -f - >/dev/null 2>&1
oc wait -n hs-test --for=condition=Ready pod/etcd-test pod/client --timeout=180s >/dev/null
oc cp "$D/hsburst" hs-test/client:/work/hsburst && oc exec -n hs-test client -- chmod +x /work/hsburst
if [ "${NATIVE:-}" = 1 ]; then
  oc cp "$D/hsserve" hs-test/etcd-test:/data/hsserve.tmp
  oc exec -n hs-test etcd-test -- sh -c 'chmod +x /data/hsserve.tmp && mv /data/hsserve.tmp /data/hsserve'
  until oc exec -n hs-test etcd-test -- sh -c 'grep -q hsserve /proc/1/cmdline' 2>/dev/null; do sleep 1; done
  MATCH=/data/hsserve
else
  MATCH=--name=etcd-test
fi
IP=$(oc get pod -n hs-test etcd-test -o jsonpath='{.status.podIP}')
cpu() { oc exec -n hs-test etcd-test -- sh -c 'tk=$(getconf CLK_TCK); awk -v tk=$tk "{printf \"%.2f %.2f\", \$14/tk, \$15/tk}" /proc/1/stat'; }
sample() { oc exec -n hs-test etcd-test -- sh -c 'max=0; end=$(( $(date +%s) + '"$1"' )); while [ $(date +%s) -lt $end ]; do t=$(awk "/Threads/{print \$2}" /proc/1/status); [ $t -gt $max ] && max=$t; sleep 0.05; done; echo $max'; }
phase() { # name levels rounds pause secs
  read -r u0 s0 <<<"$(cpu)"
  sample "$5" > "$D/.peak" &
  if [ "${PERF:-}" = 1 ] && [ "$1" = burst ]; then
    oc debug "node/$SN" -q -- sh -c 'p=$(chroot /host pgrep -f -- "'"$MATCH"'" | head -1)
      perf record -q -F 499 -p "$p" -o /tmp/p.data -- sleep '"$(( $5 - 2 ))"' 2>/dev/null
      echo "-- by object"; perf report -i /tmp/p.data --stdio --no-children --sort dso 2>/dev/null | grep -v "^#" | grep . | head -8
      echo "-- by symbol"; perf report -i /tmp/p.data --stdio --no-children --sort dso,sym 2>/dev/null | grep -v "^#" | grep . | head -25' > "$D/.perf" 2>&1 &
    sleep 15  # the debug pod takes a while to start
  fi
  sleep 1
  oc exec -n hs-test client -- /work/hsburst -addr "$IP:2379" -levels "$2" -rounds "$3" -pause "$4" > "$D/.out"
  wait
  read -r u1 s1 <<<"$(cpu)"
  n=$(awk 'NR>1 && $1 ~ /^[0-9]+$/ {s+=$3} END {print s}' "$D/.out")
  echo "== $LABEL $1 (GOMAXPROCS=${GOMAXPROCS:-default}${GLIBC_TUNABLES:+ $GLIBC_TUNABLES}) on $SN"
  cat "$D/.out"
  awk -v u0="$u0" -v u1="$u1" -v s0="$s0" -v s1="$s1" -v n="$n" -v pk="$(cat "$D/.peak")" \
    'BEGIN {printf "server: %d handshakes, user %.1fs sys %.1fs, %.2f ms CPU per handshake, peak threads %s\n", n, u1-u0, s1-s0, (u1-u0+s1-s0)*1000/n, pk}'
  if [ "${PERF:-}" = 1 ] && [ "$1" = burst ]; then cat "$D/.perf"; fi
}
phase sequential 1 200 0s 20
phase burst 3000 3 3s "$([ "${PERF:-}" = 1 ] && echo 45 || echo 25)"
