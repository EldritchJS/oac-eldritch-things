#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims every GPU (or MIG slice) on a container-mode node for
# about 5 minutes per handoff (15 for the default three), plus the image pull.
# ---------------------------------------------------------------------------
# Can a pod read GPU memory a previous pod left behind? Between containers
# nothing resets the GPU: the host's NVIDIA driver keeps it, and clearing
# memory before handing it out again is the driver's job. A container tenant
# only has CUDA, so the test is whether CUDA in pod B sees pod A's data.
# (test-gpu-memclear.sh is the VM version, where vfio resets the GPU.)
#
# For each handoff in HANDOFFS:
#   1. Pod A takes all GPU_COUNT GPUs on NODE, or all its MIG slices, fills
#      nearly all their memory with a pattern and reads it back. Control: it
#      frees one chunk and allocates it again in the same process.
#   2. Pod A lets go:
#        exit    the process ends normally (memory never freed by hand)
#        kill    the process kills itself with SIGKILL while holding it
#        delete  the pod is deleted while the process holds it
#   3. With RELABEL, the node's GPUs are repartitioned (MIG manager), as an
#      operator changing the slice layout between tenants would.
#   4. Pod B takes the same GPUs or slices (same UUIDs checked, unless
#      repartitioned), allocates as much memory as it can, does not write it,
#      and counts the pattern.
#
# MIG: label the node first (nvidia.com/mig.config=all-1g.10gb gives 28
# slices on 4 H100s); GPU_COUNT follows. GPUs shared at once (time-slicing,
# MPS) are test-gpu-sharing.sh. Not covered: anything CUDA cannot see
# (caches, registers).
#
# Usage: KUBECONFIG=... NODE=<container-mode GPU node> ./test-gpu-container-memclear.sh
#   NODE       node to run on (required; must be in container mode, unshared)
#   NAMESPACE  project to create (default gpu-memclear-ctr; must not exist)
#   GPU_COUNT  GPUs or slices every pod takes (default: all the node has)
#   HANDOFFS   which handoffs, in order (default "exit kill delete")
#   RELABEL    a mig.config to switch to after pod A (e.g. all-3g.40gb or
#              all-disabled); put back afterwards. One handoff only
#   IMAGE      CUDA image with nvcc (default nvcr.io/nvidia/cuda:12.5.0-devel-ubi9)
# Exit: 0 no pattern in any pod B, 1 pattern found, 2 could not run or
# inconclusive.
set -uo pipefail
cd "$(dirname "$0")"

NODE="${NODE:-}"
NAMESPACE="${NAMESPACE:-gpu-memclear-ctr}"
HANDOFFS="${HANDOFFS:-exit kill delete}"
RELABEL="${RELABEL:-}"
IMAGE="${IMAGE:-nvcr.io/nvidia/cuda:12.5.0-devel-ubi9}"

[ -n "$NODE" ] || { echo "NODE is required" >&2; exit 2; }
for h in $HANDOFFS; do
  case "$h" in exit|kill|delete) ;; *) echo "unknown handoff $h (exit, kill, delete)" >&2; exit 2 ;; esac
done
[ -z "$RELABEL" ] || [ "$(echo $HANDOFFS | wc -w)" -eq 1 ] || { echo "RELABEL takes one handoff" >&2; exit 2; }
label() { oc get node "$NODE" -o jsonpath="{.metadata.labels.nvidia\.com/$1}" 2>/dev/null; }
free() { oc get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null; }
MODE=$(label 'gpu\.workload\.config'); SHARING=$(label 'gpu\.sharing-strategy'); MIG_CONFIG=$(label 'mig\.config')
GPU_COUNT="${GPU_COUNT:-$(free)}"
[ "${MODE:-container}" = container ] && [ "${SHARING:-none}" = none ] && [ "${GPU_COUNT:-0}" -gt 0 ] && [ "$(free)" -ge "$GPU_COUNT" ] 2>/dev/null ||
  { echo "$NODE is not serving ${GPU_COUNT:-?} unshared GPUs to containers (mode=${MODE:-unset}, sharing=${SHARING:-none}, nvidia.com/gpu=$(free))" >&2; exit 2; }
oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
RELABELLED=
# Wait for the MIG manager to finish a layout and the device plugin to show it.
mig_settle() {
  for _ in $(seq 120); do
    # The device plugin restarts after the MIG manager, so the count must be
    # non-zero and the same twice, 20 s apart.
    if [ "$(label 'mig\.config\.state')" = success ] && [ "$(label 'mig\.config')" = "$1" ]; then
      n1=$(free); sleep 20; n2=$(free)
      [ "${n1:-0}" -gt 0 ] && [ "$n1" = "$n2" ] 2>/dev/null && return 0
    fi
    [ "$(label 'mig\.config\.state')" = failed ] && return 1
    sleep 5
  done
  return 1
}
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  if [ -n "$RELABELLED" ]; then
    oc label node "$NODE" "nvidia.com/mig.config=$MIG_CONFIG" --overwrite >/dev/null
    mig_settle "$MIG_CONFIG" && echo "put back mig.config=$MIG_CONFIG" || echo "WARNING: mig.config=$MIG_CONFIG not back to success; check $NODE" >&2
  fi
}
trap cleanup EXIT
oc create configmap memtest -n "$NAMESPACE" --from-file=memtest.cu --from-file=memtest-run.sh >/dev/null || exit 2

pod() { # pod <name> <gpus> <memtest-run.sh arguments>
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
      args: [$(printf '"%s", ' $3 | sed 's/, $//')]
      env:
        - {name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}
        - {name: TMPDIR, value: /work}  # the image's /tmp is not writable by OpenShift's random UID
      resources:
        limits: {nvidia.com/gpu: $2}
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
# Why a pod gave no result lines: its phase, exit code and the end of its log.
why() { # why <name> <log>
  echo "    pod $1: $(oc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}' 2>/dev/null)"
  printf '%s\n' "$2" | tail -15 | sed 's/^/    | /'
}
# Wait until the pod has finished, or has printed a line matching a pattern
# at least <count> times.
await() { # await <name> [pattern count]
  for _ in $(seq 180); do
    case "$(phase "$1")" in Succeeded|Failed) return 0 ;; esac
    [ -n "${2:-}" ] && [ "$(logs "$1" | grep -c "$2")" -ge "$3" ] && return 0
    sleep 5
  done
  return 1
}
sum() { printf '%s\n' "$1" | sed -n "s/^$2 .*pattern_words=\([0-9]*\).*/\1/p" | awk '{s += $1} END {print s + 0}'; }
lines() { printf '%s\n' "$1" | grep -c "^$2 "; }
has() { printf '%s\n' "$1" | grep -c "^$2" >/dev/null; }  # not grep -q: with pipefail, its early exit fails printf
# Result lines, or a one-line summary when there is one per MIG slice.
show() { # show <prefix> <log> <keys>
  if [ "$(printf '%s\n' "$2" | grep -cE "^($3) ")" -le 8 ]; then
    printf '%s\n' "$2" | grep -E "^($3|MEMTEST_FAIL) " | sed "s/^/  $1: /"
  else
    for k in ${3//|/ }; do
      echo "  $1: $(lines "$2" "$k") $k lines, $(sum "$2" "$k") pattern words in all"
    done
    printf '%s\n' "$2" | grep '^MEMTEST_FAIL' | sed "s/^/  $1: /"
  fi
}
uuids() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k {print $3}' | sort | tr '\n' ' '; }

FOUND=0; BAD=0
for h in $HANDOFFS; do
  echo "=== handoff: $h$([ -n "$RELABEL" ] && echo ", then mig.config ${MIG_CONFIG:-unset} -> $RELABEL") ==="
  # One memtest process per MIG slice, one for all GPUs otherwise.
  PROCS=$([ -n "$MIG_CONFIG" ] && [ "$MIG_CONFIG" != all-disabled ] && echo "$GPU_COUNT" || echo 1)
  if [ "$h" = delete ]; then
    pod "fill-$h" "$GPU_COUNT" "fill hold"
    await "fill-$h" '^HOLDING' "$PROCS" || { echo "  pod A did not start holding" >&2; BAD=1; continue; }
    A=$(logs "fill-$h")  # gone with the pod
    oc delete pod "fill-$h" -n "$NAMESPACE" --grace-period=1 --wait=true >/dev/null 2>&1
  else
    pod "fill-$h" "$GPU_COUNT" "fill $h"
    await "fill-$h" || { echo "  pod A did not finish" >&2; BAD=1; continue; }
    A=$(logs "fill-$h")
    oc delete pod "fill-$h" -n "$NAMESPACE" --wait=true >/dev/null 2>&1
  fi
  has "$A" FILLED || why "fill-$h" "$A"
  show A "$A" 'FILLED|REALLOC'

  B_COUNT=$GPU_COUNT
  if [ -n "$RELABEL" ]; then
    oc label node "$NODE" "nvidia.com/mig.config=$RELABEL" --overwrite >/dev/null && RELABELLED=1
    mig_settle "$RELABEL" || { echo "  mig.config=$RELABEL did not reach success" >&2; BAD=1; continue; }
    B_COUNT=$(free)
    [ "${B_COUNT:-0}" -gt 0 ] 2>/dev/null || { echo "  no GPUs advertised after repartitioning" >&2; BAD=1; continue; }
    echo "  repartitioned: mig.config=$RELABEL, nvidia.com/gpu=$B_COUNT"
  fi
  pod "scan-$h" "$B_COUNT" scan
  await "scan-$h" || { echo "  pod B did not finish" >&2; BAD=1; continue; }
  B=$(logs "scan-$h")
  oc delete pod "scan-$h" -n "$NAMESPACE" --wait=true >/dev/null 2>&1
  has "$B" SCAN || why "scan-$h" "$B"
  show B "$B" SCAN

  FILLED=$(sum "$A" FILLED); LEFT=$(sum "$B" SCAN)
  if [ "$(lines "$A" FILLED)" -ne "$GPU_COUNT" ] || [ "$(lines "$B" SCAN)" -ne "$B_COUNT" ] || [ "$B_COUNT" -eq 0 ]; then
    echo "  INCONCLUSIVE: not every GPU was filled and scanned"; BAD=1
  elif [ -z "$RELABEL" ] && [ "$(uuids "$A" FILLED)" != "$(uuids "$B" SCAN)" ]; then
    echo "  INCONCLUSIVE: pod B got different GPUs from pod A"; BAD=1
  elif [ "$FILLED" -eq 0 ]; then
    echo "  INCONCLUSIVE: pod A could not read its own pattern back"; BAD=1
  elif [ "$LEFT" -gt 0 ]; then
    echo "  FOUND: pod B read ${LEFT} pattern words of pod A's ${FILLED}"; FOUND=1
  else
    echo "  cleared: pod A wrote ${FILLED} pattern words, pod B read none (same-process realloc saw $(sum "$A" REALLOC))"
  fi
done

if [ "$FOUND" = 1 ]; then
  echo "FAIL a pod read GPU memory a previous pod left behind"; exit 1
elif [ "$BAD" = 1 ]; then
  echo "INCONCLUSIVE: see above"; exit 2
else
  echo "PASS no pod read a previous pod's GPU memory (handoffs: $HANDOFFS${RELABEL:+, repartitioned to $RELABEL})"; exit 0
fi
