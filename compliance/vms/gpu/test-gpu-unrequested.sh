#!/usr/bin/env bash
# Can a tenant's pod use GPUs it did not request? With the GPU Operator's
# defaults it can: a pod that names one of the operator's RuntimeClasses
# and sets NVIDIA_VISIBLE_DEVICES=all gets every GPU on its node, outside
# the device plugin, quotas and billing. Two settings close it (oac-apps
# #208): the toolkit's ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED
# =false, and an admission policy keeping the nvidia* RuntimeClasses to the
# GPU Operator's namespace. This checks that a cluster has not lost them.
#
#   1. A project with a service account that has edit in it, as a tenant.
#   2. As that tenant, on NODE: a control pod with no RuntimeClass, then one
#      pod per nvidia* RuntimeClass, each requesting no GPU, setting
#      NVIDIA_VISIBLE_DEVICES=all and running nvidia-smi -L.
#   3. Each pod must be rejected when created, or run and find no GPU.
#
# Requests no GPU, so costs nothing. Needs a cluster admin for step 1.
#
# Exit: 0 no pod saw a GPU, 1 one did, 2 could not run.
#
# Usage: KUBECONFIG=... ./test-gpu-unrequested.sh
#   NODE       GPU node to run on (default: the first with nvidia.com/gpu)
#   NAMESPACE  project to create (default gpu-unrequested; must not exist)
#   IMAGE      image without nvidia-smi of its own (default
#              registry.access.redhat.com/ubi9/ubi-minimal)
set -uo pipefail

NAMESPACE="${NAMESPACE:-gpu-unrequested}"
IMAGE="${IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal}"
NODE="${NODE:-$(oc get nodes -o json | python3 -I -c '
import json,sys
print(next((n["metadata"]["name"] for n in json.load(sys.stdin)["items"]
            if int(n["status"]["allocatable"].get("nvidia.com/gpu", "0")) > 0), ""))')}"
AS="system:serviceaccount:$NAMESPACE:tenant"

[ -n "$NODE" ] || { echo "no node advertises nvidia.com/gpu; set NODE" >&2; exit 2; }
CLASSES=$(oc get runtimeclass -o name 2>/dev/null | sed 's#.*/##' | grep '^nvidia')
[ -n "$CLASSES" ] || { echo "no nvidia* RuntimeClass on this cluster: nothing to test" >&2; exit 2; }
oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
trap 'oc delete ns "$NAMESPACE" --wait=false >/dev/null 2>&1' EXIT
oc create sa tenant -n "$NAMESPACE" >/dev/null
oc create rolebinding tenant-edit -n "$NAMESPACE" --clusterrole=edit --serviceaccount="$NAMESPACE:tenant" >/dev/null
[ "$(oc auth can-i '*' '*' --all-namespaces --as="$AS")" = no ] || { echo "the tenant service account is cluster-admin" >&2; exit 2; }

pod() { # pod <name> <runtimeClassName or empty>; prints the apply error, if any
  cat <<EOF | oc apply -n "$NAMESPACE" --as="$AS" -f - 2>&1 >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  restartPolicy: Never
  ${2:+runtimeClassName: $2}
  nodeSelector: {kubernetes.io/hostname: $NODE}
  tolerations: [{key: nvidia.com/gpu.product, operator: Exists}]
  containers:
    - name: c
      image: $IMAGE
      command: ["sh", "-c", "nvidia-smi -L 2>&1 || echo 'no nvidia-smi'"]
      env:
        - {name: NVIDIA_VISIBLE_DEVICES, value: all}
        - {name: NVIDIA_DRIVER_CAPABILITIES, value: utility}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
EOF
}
result() { # result <name>: waits, then prints the number of GPUs the pod listed
  local _
  for _ in $(seq 60); do
    case "$(oc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) break ;; esac
    sleep 5
  done
  oc logs "$1" -n "$NAMESPACE" 2>/dev/null | grep -c '^GPU [0-9]*:'
}

echo "=== a tenant on $NODE, requesting no GPU ==="
SAW=0 ADMITTED=
for c in "" $CLASSES; do
  name=${c:-control}
  err=$(pod "$name" "$c")
  if [ -n "$err" ]; then
    echo "  ${c:-no RuntimeClass}: rejected ($(printf '%s' "$err" | sed 's/.*denied request: //' | cut -c1-90))"
    continue
  fi
  [ -n "$c" ] && ADMITTED="$ADMITTED $c"
  n=$(result "$name")
  if [ "$n" -gt 0 ]; then
    echo "  ${c:-no RuntimeClass}: ❌ saw $n GPU(s)"; SAW=1
  else
    echo "  ${c:-no RuntimeClass}: ran, no GPU ($(oc logs "$name" -n "$NAMESPACE" 2>/dev/null | tail -1 | cut -c1-60))"
  fi
done

[ -n "$ADMITTED" ] && echo "WARN a tenant could use RuntimeClass(es)$ADMITTED: no admission policy, so only the toolkit setting stands"
[ "$SAW" = 0 ] && { echo "PASS no pod got a GPU it did not request"; exit 0; }
echo "FAIL a tenant's pod got GPUs without requesting any; see oac-apps #208"; exit 1
