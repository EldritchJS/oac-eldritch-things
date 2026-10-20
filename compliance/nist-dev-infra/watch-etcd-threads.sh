#!/usr/bin/env bash
# Record etcd's threads on every control-plane node, every 2 seconds or so, during a
# rollout or upgrade: the conditions of the stage C crashes (README.md).
# Read-only: one debug pod per node. A node that drains loses its session;
# it restarts when the node is back.
#
# Columns: UTC time, etcd threads, pids in etcd's pod (limit 4,096),
# client connections on 2379, 1-minute load. When threads pass THRESH, a
# 10-second perf profile of etcd is written into the same file (lines
# starting "# "), at most once every 2 minutes per node.
#
# Usage: KUBECONFIG=... [THRESH=1500] ./watch-etcd-threads.sh [outdir]
# Stop with Ctrl-C, then check no debug pods are left:
#   oc get pods -A | grep -- -debug-
set -uo pipefail
OUT=${1:-etcd-threads-$(date +%Y%m%dT%H%M)}
THRESH=${THRESH:-1500}
mkdir -p "$OUT"

REMOTE='
last=0
while :; do
  now=$(date +%s); ts=$(date -u +%T)
  p=$(chroot /host pgrep -x etcd | head -1)
  if [ -z "$p" ]; then printf "%s\tno-etcd\n" "$ts"; sleep 1; continue; fi
  t=$(awk "/^Threads/{print \$2}" /proc/$p/status 2>/dev/null)
  cg=$(sed -n "s/^0:://p" /proc/$p/cgroup 2>/dev/null)
  pc=$(cat /host/sys/fs/cgroup$cg/../pids.current 2>/dev/null || echo -)
  c=$(chroot /host ss -Htn state established "( sport = :2379 )" | wc -l)
  printf "%s\t%s\t%s\t%s\t%s\n" "$ts" "${t:--}" "$pc" "$c" "$(cut -d" " -f1 /proc/loadavg)"
  if [ "${t:-0}" -gt THRESH ] && [ $((now - last)) -gt 120 ]; then
    last=$now
    ( perf record -q -F 99 -p "$p" -o /tmp/p.data -- sleep 10 >/dev/null 2>&1
      echo "# perf, etcd at $ts, top symbols:"
      perf report -i /tmp/p.data --stdio --no-children --sort dso,sym 2>/dev/null \
        | grep -v "^#" | grep . | head -20 | sed "s/^/# /" ) &
  fi
  sleep 1
done'
REMOTE=${REMOTE//THRESH/$THRESH}

watch_node() {
  local n=$1 f="$OUT/$1.tsv"
  printf "time\tthreads\tpod_pids\tconns_2379\tload1\n" >> "$f"
  while :; do
    oc debug "node/$n" -q -- sh -c "$REMOTE" >> "$f" 2>> "$OUT/$n.err"
    echo "# session ended $(date -u +%T)" >> "$f"
    sleep 10
  done
}

NODES=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}')
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NS=$(oc project -q 2>/dev/null || echo default)   # where oc debug puts its pods

# Stop the loops and their oc debug sessions, then delete the debug pods
# this run created: oc debug leaves its pod behind when it is killed.
stop() {
  trap - INT TERM
  for j in $(jobs -p); do pkill -TERM -P "$j" 2>/dev/null; kill "$j" 2>/dev/null; done
  wait 2>/dev/null
  for n in $NODES; do
    oc get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{"\n"}{end}' \
      | awk -v n="$n-debug-" -v s="$START" 'index($1, n) == 1 && $2 >= s {print $1}' \
      | xargs -r oc delete pod -n "$NS" --wait=false >/dev/null
  done
  echo "stopped; output in $OUT"
  exit 0
}
trap stop INT TERM
for n in $NODES; do
  watch_node "$n" &
done
echo "recording to $OUT (Ctrl-C to stop)"
wait
