#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: holds every GPU share on NODE for about 10 minutes, plus the
# image pull.
# ---------------------------------------------------------------------------
# What can one pod see of, or do to, another pod using the same GPU at the
# same time? Run on a node whose GPUs are shared, set up one of three ways:
#   MIG           oc label node <node> nvidia.com/mig.config=all-1g.10gb --overwrite
#                 (hardware slices: own memory, own compute, own fault domain)
#   time-slicing  device-plugin-sharing.yaml, label timeslice-4
#   MPS           device-plugin-sharing.yaml, label mps-4
#
#   1. Holders: one pod per share but the last (N-1 of the node's N
#      nvidia.com/gpu), each filling its share's memory with a pattern and
#      holding it, recounting every 10 s.
#   2. The neighbour takes the last share. With time-slicing or MPS it runs
#      on a physical GPU that holders are using; with MIG, on a slice of one.
#      It reads what nvidia-smi shows, allocates all the memory it can get,
#      unwritten, and counts the pattern, then writes through an unmapped
#      address, as a crashing or hostile tenant would.
#   3. The holders are checked again: still running, pattern intact?
#
# Exit: 0 the neighbour saw no pattern and no holder's memory changed;
# 1 otherwise; 2 could not run. A holder killed by the neighbour's fault is
# reported, not failed: it is availability, not confidentiality.
#
# Usage: KUBECONFIG=... NODE=<container-mode GPU node> ./test-gpu-sharing.sh
#   NODE       node to run on (required; container mode, GPUs shared)
#   NAMESPACE  project to create (default gpu-sharing; must not exist)
#   HOLD_MIB   memory each holder fills, with time-slicing or MPS (default:
#              76 GiB divided by the replicas; MIG slices are filled whole)
#   IMAGE      CUDA image with nvcc (default nvcr.io/nvidia/cuda:12.5.0-devel-ubi9)
set -uo pipefail
cd "$(dirname "$0")"

NODE="${NODE:-}"
NAMESPACE="${NAMESPACE:-gpu-sharing}"
IMAGE="${IMAGE:-nvcr.io/nvidia/cuda:12.5.0-devel-ubi9}"

[ -n "$NODE" ] || { echo "NODE is required" >&2; exit 2; }
label() { oc get node "$NODE" -o jsonpath="{.metadata.labels.nvidia\.com/$1}" 2>/dev/null; }
MODE=$(label 'gpu\.workload\.config'); MIG_CONFIG=$(label 'mig\.config'); SHARING=$(label 'gpu\.sharing-strategy')
REPLICAS=$(label 'gpu\.replicas'); N=$(oc get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
if [ -n "$MIG_CONFIG" ] && [ "$MIG_CONFIG" != all-disabled ]; then STRATEGY="mig ($MIG_CONFIG)"; HOLD_MIB=0
elif [ "${SHARING:-none}" != none ]; then STRATEGY="$SHARING x${REPLICAS:-?}"; HOLD_MIB="${HOLD_MIB:-$(( 76 * 1024 / ${REPLICAS:-1} ))}"
else STRATEGY=; fi
[ "${MODE:-container}" = container ] && [ -n "$STRATEGY" ] && [ "${N:-0}" -ge 2 ] 2>/dev/null ||
  { echo "$NODE does not share its GPUs (mode=${MODE:-unset}, mig.config=${MIG_CONFIG:-unset}, sharing=${SHARING:-none}, nvidia.com/gpu=${N:-0})" >&2; exit 2; }
oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
trap 'oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1' EXIT
oc create configmap memtest -n "$NAMESPACE" --from-file=memtest.cu --from-file=memtest-run.sh >/dev/null || exit 2

pod() { # pod <name> <memtest-run.sh arguments>
  cat <<EOF | oc apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $NODE
  containers:
    - name: cuda
      image: $IMAGE
      command: ["sh", "/src/memtest-run.sh"]
      args: [$(printf '"%s", ' $2 | sed 's/, $//')]
      env:
        - {name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}
        - {name: TMPDIR, value: /work}  # the image's /tmp is not writable by OpenShift's random UID
        - {name: MEMTEST_MAX_MIB, value: "$HOLD_MIB"}
      resources:
        limits: {nvidia.com/gpu: 1}
      volumeMounts:
        - {name: src, mountPath: /src}
        - {name: work, mountPath: /work}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
  volumes:
    - name: src
      configMap: {name: memtest}
    - name: work
      emptyDir: {}
EOF
}
phase() { oc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null; }
logs() { oc logs "$1" -n "$NAMESPACE" 2>&1; }
gpu_of() { printf '%s\n' "$1" | sed -n 's/^GPULIST GPU [0-9]*: .*(UUID: \(GPU-[0-9a-f-]*\)).*/\1/p' | head -1; }
words() { printf '%s\n' "$1" | sed -n "s/^$2 .*pattern_words=\([0-9]*\).*/\1/p" | tail -1; }
HOLDERS=$(seq -f 'hold-%02g' 1 $((N - 1)))
# Per-holder values, as plain variables (macOS bash 3.2 has no associative arrays).
put() { printf -v "${1}_${2//-/_}" '%s' "$3"; }
get() { local v="${1}_${2//-/_}"; printf '%s' "${!v:-}"; }

echo "=== 1. $((N - 1)) holders on $NODE, sharing: $STRATEGY ==="
for h in $HOLDERS; do pod "$h" "fill hold"; done
for _ in $(seq 180); do
  waiting=0
  for h in $HOLDERS; do
    case "$(phase "$h")" in Failed|Succeeded) ;; *) logs "$h" | grep -c '^HOLDING' >/dev/null || waiting=1 ;; esac
  done
  [ "$waiting" = 0 ] && break
  sleep 5
done
for h in $HOLDERS; do
  L=$(logs "$h"); put FILLED "$h" "$(words "$L" FILLED)"; put GPU "$h" "$(gpu_of "$L")"
  [ -n "$(get FILLED "$h")" ] || { echo "  $h did not fill:"; printf '%s\n' "$L" | tail -5 | sed 's/^/    | /'; }
done
for h in $HOLDERS; do get GPU "$h"; echo; done | sort | uniq -c | awk '{print "  " ($2 == "" ? "?" : $2) ": " $1 " holders"}'

echo "=== 2. the neighbour: what it sees, what it can read, a fault ==="
pod neighbor neighbor
for _ in $(seq 180); do case "$(phase neighbor)" in Succeeded|Failed) break ;; esac; sleep 5; done
NB=$(logs neighbor); NB_GPU=$(gpu_of "$NB")
printf '%s\n' "$NB" | grep -E '^(GPULIST|SMI_GPU|SMI_APP|SCAN|FAULT|MEMTEST_FAIL)' | sed 's/^/  /'
SEEN=$(printf '%s\n' "$NB" | sed -n 's/^SCAN .*pattern_words=\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
for h in $HOLDERS; do put BEFORE "$h" "$(logs "$h" | grep -c '^CHECK ')"; done
sleep 30

echo "=== 3. the holders, 30 s after the fault ==="
CHANGED=0; DIED=0; SHARERS=0
for h in $HOLDERS; do
  L=$(logs "$h"); last=$(words "$L" CHECK); now=$(printf '%s\n' "$L" | grep -c '^CHECK ')
  same=$([ "$(get GPU "$h")" = "$NB_GPU" ] && echo "neighbour's GPU" || echo "other GPU")
  [ "$same" = "neighbour's GPU" ] && SHARERS=$((SHARERS + 1))
  if printf '%s\n' "$L" | grep -c '^CHECK_FAIL' >/dev/null || [ "$(phase "$h")" != Running ]; then
    state="DIED ($(printf '%s\n' "$L" | grep -m1 '^CHECK_FAIL' | cut -d' ' -f4))"; DIED=$((DIED + 1))
  elif [ "$now" -le "$(get BEFORE "$h")" ]; then
    state="stalled (no new check)"; DIED=$((DIED + 1))
  elif [ "${last:-0}" != "$(get FILLED "$h")" ]; then
    state="CHANGED (${last:-0} of $(get FILLED "$h") pattern words)"; CHANGED=1
  else
    state="intact"
  fi
  [ "$same" = "neighbour's GPU" ] || [ "$state" != intact ] && echo "  $h on $same: $state"
done
echo "  holders on other GPUs not listed are intact"

[ -n "$NB_GPU" ] && printf '%s\n' "$NB" | grep -c '^SCAN' >/dev/null || { echo "INCONCLUSIVE: the neighbour did not run (see above)"; exit 2; }
[ "$SHARERS" -gt 0 ] || { echo "INCONCLUSIVE: no holder was on the neighbour's GPU"; exit 2; }
echo "SUMMARY sharing=$STRATEGY holders_on_neighbours_gpu=$SHARERS neighbour_saw_pattern=$SEEN holders_died=$DIED fault=$(printf '%s\n' "$NB" | sed -n 's/^FAULT //p')"
if [ "$SEEN" -gt 0 ] || [ "$CHANGED" = 1 ]; then
  echo "FAIL the neighbour read or changed another pod's GPU memory"; exit 1
fi
[ "$DIED" -gt 0 ] && echo "AVAILABILITY: ${DIED} holder(s) stopped after the neighbour's fault"
echo "PASS the neighbour could not read or change another pod's GPU memory"; exit 0
