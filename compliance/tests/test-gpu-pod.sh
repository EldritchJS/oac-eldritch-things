#!/usr/bin/env bash
# COSTS MONEY: claims one GPU for about a minute (MOC bills claimed GPUs).
#
# Proves a container can use a GPU end to end: a pod asks for one
# nvidia.com/gpu, the scheduler places it on a node in container mode, and
# NVIDIA's CUDA vector-add sample runs on the card and checks its results.
# Creates its own project and always deletes it, pass or fail.
#
# Usage: KUBECONFIG=... ./test-gpu-pod.sh
#   NAMESPACE  project to create (default gpu-pod-test; must not exist)
#   IMAGE      CUDA sample image (nvcr.io: in the compliant registry allowlist)
#   TIMEOUT    seconds to wait for the pod to finish (default 300)
# Exit: 0 passed, 1 failed, 2 could not run.
set -uo pipefail

NAMESPACE="${NAMESPACE:-gpu-pod-test}"
IMAGE="${IMAGE:-nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0}"
TIMEOUT="${TIMEOUT:-300}"

oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }
if oc get ns "$NAMESPACE" >/dev/null 2>&1; then
  echo "project $NAMESPACE already exists; delete it or set NAMESPACE" >&2; exit 2
fi
FREE=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | awk '$1 > 0 {s += $1} END {print s + 0}')
[ "$FREE" -gt 0 ] || { echo "no node advertises nvidia.com/gpu (no node in container mode?)" >&2; exit 2; }

cleanup() { oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1; }   # waits: the GPU is released when the pod is gone
trap cleanup EXIT

oc create ns "$NAMESPACE" >/dev/null || exit 2
oc apply -n "$NAMESPACE" -f - >/dev/null <<EOF || exit 2
apiVersion: v1
kind: Pod
metadata: {name: cuda-vectoradd}
spec:
  restartPolicy: Never
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  containers:
    - name: vectoradd
      image: $IMAGE
      resources: {limits: {nvidia.com/gpu: 1}}
      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
EOF

phase=""
for _ in $(seq "$TIMEOUT"); do
  phase=$(oc get pod cuda-vectoradd -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 1
done
node=$(oc get pod cuda-vectoradd -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
logs=$(oc logs cuda-vectoradd -n "$NAMESPACE" 2>/dev/null)
printf '%s\n' "$logs" | sed 's/^/    /'
if [ "$phase" = Succeeded ] && printf '%s' "$logs" | grep -q "Test PASSED"; then
  echo "PASS a CUDA kernel ran in a pod on ${node} and checked its results"
  exit 0
fi
echo "FAIL pod phase '${phase:-none}' on '${node:-unscheduled}'"
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | tail -5 | sed 's/^/    /'
exit 1
