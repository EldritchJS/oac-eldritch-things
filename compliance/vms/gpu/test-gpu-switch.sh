#!/usr/bin/env bash
set -euo pipefail

# Measures what it actually costs to re-purpose a GPU node between container
# workloads and VM workloads, in both directions.
#
# The question this answers: a node's GPUs serve either containers or VMs, not
# both. How long does switching take, what has to be evicted to do it, and does
# the node come back clean? Those three numbers decide whether "borrow an H100
# node for VMs for an afternoon" is a reasonable thing to offer users or a
# half-day outage.
#
# The round trip:
#
#   container  ──drain──> flip label ──> vfio-pci binds ──> VM resource
#       ^                                                        │
#       └────── flip label <── nvidia driver rebinds <───────────┘
#
# THIS IS DESTRUCTIVE. It cordons the node and deletes every pod on it that
# holds a GPU, in every namespace. It restores the original label and uncordons
# on exit, including on failure, but the evicted pods are not recreated — only
# controller-managed ones come back by themselves. Pick the node deliberately.
#
# Admin-only: node labels, cordon and cross-namespace pod deletion.

NODE="${NODE:-}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-nvidia-gpu-operator}"
WORKLOAD_LABEL="nvidia.com/gpu.workload.config"

# Namespace for the throwaway container-side probe pod.
NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
PROBE_NAME="${PROBE_NAME:-gpu-switch-probe}"
# Any small image will do: when a pod requests nvidia.com/gpu the NVIDIA
# container toolkit injects the driver libraries and nvidia-smi into it, so the
# image itself needs nothing NVIDIA-specific. This one is public and needs no
# pull secret.
GPU_PROBE_IMAGE="${GPU_PROBE_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

SWITCH_TIMEOUT="${SWITCH_TIMEOUT:-600}"   # per direction
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-300}"
POLL="${POLL:-5}"

AS_ADMIN="${AS_ADMIN:---as=system:admin}"

# Deliberate speed bump. Everything else in this repo is safe to run on a whim;
# this is not.
CONFIRM="${CONFIRM:-}"

PASSED=0
FAILED=0
ORIGINAL_LABEL=""
LABEL_WAS_SET=0
CORDONED=0
PROBE_LOG=""

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }

# Timing ledger: "label<TAB>seconds" lines, printed as a table at the end.
TIMINGS=""
record() { TIMINGS="${TIMINGS}$1	$2
"; }

now() { date +%s; }

cleanup() {
  echo ""
  echo "=== Restoring ${NODE} ==="
  oc delete pod "${PROBE_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if [ "${LABEL_WAS_SET}" = "1" ]; then
    echo "Restoring ${WORKLOAD_LABEL}=${ORIGINAL_LABEL}"
    oc label node "${NODE}" ${AS_ADMIN} --overwrite "${WORKLOAD_LABEL}=${ORIGINAL_LABEL}" >/dev/null 2>&1 || true
  elif [ -n "${NODE}" ]; then
    echo "Removing ${WORKLOAD_LABEL} (it was not set before this run)"
    oc label node "${NODE}" ${AS_ADMIN} "${WORKLOAD_LABEL}-" >/dev/null 2>&1 || true
  fi

  if [ "${CORDONED}" = "1" ]; then
    echo "Uncordoning ${NODE}"
    oc adm uncordon "${NODE}" ${AS_ADMIN} >/dev/null 2>&1 || true
  fi
  echo "Done!"
  echo ""
  echo "Pods evicted during the run are NOT recreated by this script. Anything"
  echo "managed by a Deployment, DaemonSet or Job controller will reschedule on"
  echo "its own; bare pods and Notebooks will not."
}

# --- State readers -----------------------------------------------------------
#
# Each of these is a plain function rather than a string passed to eval. The
# waits below need predicates, and embedding python one-liners inside quoted
# eval strings is a reliable way to produce a script that fails for quoting
# reasons rather than cluster reasons.

# Container-mode GPU capacity on the node, 0 when the resource is absent.
alloc_container_gpu() {
  local v
  v="$(oc get node "${NODE}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")"
  echo "${v:-0}"
}

# Passthrough-mode capacity as "name=count", empty if none. The resource name
# is device-specific (nvidia.com/GH100_H100_SXM5_80GB and so on), so it is
# discovered rather than assumed.
alloc_vfio_gpu() {
  oc get node "${NODE}" -o jsonpath='{.status.allocatable}' 2>/dev/null \
    | python3 -c '
import json, sys
try:
    alloc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in sorted(alloc):
    if key.startswith("nvidia.com/") and key != "nvidia.com/gpu" and "mig-" not in key:
        print(key + "=" + str(alloc[key]))
        break
' 2>/dev/null || true
}

# "namespace/name" of every pod on the node holding an nvidia.com/* resource.
# The GPU operator's own daemonsets hold devices too, but tearing those down is
# the operator's job — deleting them here just makes it recreate them.
gpu_pods_on_node() {
  oc get pods -A --field-selector "spec.nodeName=${NODE}" -o json 2>/dev/null \
    | SKIP_NS="${GPU_OPERATOR_NS}" python3 -c '
import json, os, sys
skip = os.environ["SKIP_NS"]
try:
    pods = json.load(sys.stdin)["items"]
except Exception:
    sys.exit(0)
for pod in pods:
    ns = pod["metadata"]["namespace"]
    name = pod["metadata"]["name"]
    if ns == skip:
        continue
    for container in pod["spec"].get("containers", []):
        res = container.get("resources", {})
        claims = list(res.get("limits", {})) + list(res.get("requests", {}))
        if any(c.startswith("nvidia.com/") for c in claims):
            print(ns + "/" + name)
            break
' 2>/dev/null || true
}

vmis_on_node() {
  oc get vmi -A -o json 2>/dev/null | NODE_NAME="${NODE}" python3 -c '
import json, os, sys
node = os.environ["NODE_NAME"]
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    sys.exit(0)
for vmi in items:
    if vmi.get("status", {}).get("nodeName") == node:
        print(vmi["metadata"]["namespace"] + "/" + vmi["metadata"]["name"])
' 2>/dev/null || true
}

# --- Predicates for wait_until ----------------------------------------------

no_container_gpu()      { [ "$(alloc_container_gpu)" = "0" ]; }
container_gpu_restored() { [ "$(alloc_container_gpu)" = "${BASELINE_GPUS}" ]; }
has_vfio_resource()     { [ -n "$(alloc_vfio_gpu)" ]; }
no_vfio_resource()      { [ -z "$(alloc_vfio_gpu)" ]; }
gpu_pods_cleared()      { [ -z "$(gpu_pods_on_node)" ]; }
vfio_manager_running() {
  oc get pods -n "${GPU_OPERATOR_NS}" --field-selector "spec.nodeName=${NODE}" 2>/dev/null \
    | grep -q 'vfio-manager.*Running'
}

# Waits for a predicate function to succeed. Prints elapsed seconds on stdout
# so the caller can record them; progress goes to stderr so it does not end up
# in the captured value.
wait_until() { # wait_until <timeout> <description> <predicate function>
  local timeout="$1" desc="$2" predicate="$3"
  local start deadline
  start="$(now)"
  deadline=$(( start + timeout ))
  while [ "$(now)" -lt "${deadline}" ]; do
    if "${predicate}"; then
      echo $(( $(now) - start ))
      return 0
    fi
    echo "    waiting for ${desc}... ($(( $(now) - start ))s)" >&2
    sleep "${POLL}"
  done
  echo ""
  return 1
}

# Runs nvidia-smi in a throwaway pod that requests a container GPU. This is the
# check that matters for the container side: not "is the driver loaded on the
# host" but "can an ordinary workload still get a GPU here".
run_container_probe() {
  PROBE_LOG=""
  oc delete pod "${PROBE_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  cat <<EOF | oc apply -n "${NAMESPACE}" -f - >/dev/null 2>&1 || return 1
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  tolerations:
  - key: nvidia.com/gpu.product
    operator: Exists
    effect: NoSchedule
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: probe
    image: ${GPU_PROBE_IMAGE}
    command: ["/bin/sh","-c","nvidia-smi -L && echo PROBE_OK"]
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF

  local deadline phase
  deadline=$(( $(now) + PROBE_TIMEOUT ))
  while [ "$(now)" -lt "${deadline}" ]; do
    phase="$(oc get pod "${PROBE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    case "${phase}" in
      Succeeded|Failed) break ;;
    esac
    sleep "${POLL}"
  done

  PROBE_LOG="$(oc logs "${PROBE_NAME}" -n "${NAMESPACE}" 2>&1 || echo "")"
  oc delete pod "${PROBE_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  printf '%s' "${PROBE_LOG}" | grep -q PROBE_OK
}

echo "========================================="
echo "  GPU Node Context-Switch Test"
echo "  Node:      ${NODE:-<unset>}"
echo "  Probe ns:  ${NAMESPACE}"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ Required binary '${bin}' not found in PATH."; exit 1; }
done

if [ -z "${NODE}" ]; then
  echo "❌ NODE is required. GPU nodes on this cluster:"
  oc get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,WORKLOAD:.metadata.labels.nvidia\.com/gpu\.workload\.config' \
    2>/dev/null | sed 's/^/     /' || true
  exit 1
fi

oc get node "${NODE}" >/dev/null 2>&1 || { echo "❌ Node ${NODE} not found."; exit 1; }

if [ "${CONFIRM}" != "yes-drain-this-node" ]; then
  echo ""
  echo "❌ This test cordons ${NODE} and deletes every GPU-holding pod on it,"
  echo "   across all namespaces, twice. Pods currently at risk:"
  echo ""
  AT_RISK="$(gpu_pods_on_node)"
  if [ -n "${AT_RISK}" ]; then
    echo "${AT_RISK}" | sed 's/^/     /'
  else
    echo "     (none)"
  fi
  echo ""
  echo "   Re-run with CONFIRM=yes-drain-this-node to proceed."
  exit 1
fi

SANDBOX_ENABLED="$(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].spec.sandboxWorkloads.enabled}' 2>/dev/null || echo "")"
if [ "${SANDBOX_ENABLED}" != "true" ]; then
  echo "❌ sandboxWorkloads is not enabled on the ClusterPolicy, so the operator"
  echo "   will ignore ${WORKLOAD_LABEL} and nothing will switch."
  echo "   Enable it first: NODE=${NODE} APPLY=1 ./setup-passthrough.sh"
  exit 1
fi
echo "sandboxWorkloads: enabled"

ORIGINAL_LABEL="$(oc get node "${NODE}" -o jsonpath="{.metadata.labels.nvidia\.com/gpu\.workload\.config}" 2>/dev/null || echo "")"
[ -n "${ORIGINAL_LABEL}" ] && LABEL_WAS_SET=1
echo "current ${WORKLOAD_LABEL}: ${ORIGINAL_LABEL:-<unset>}"

trap cleanup EXIT

echo ""
echo "=== 1. Baseline: the node serves containers ==="

BASELINE_GPUS="$(alloc_container_gpu)"
echo "  allocatable nvidia.com/gpu: ${BASELINE_GPUS}"
if [ "${BASELINE_GPUS}" -gt 0 ] 2>/dev/null; then
  pass "Node starts out advertising ${BASELINE_GPUS} container GPU(s)"
else
  fail "Node starts out advertising container GPUs (got ${BASELINE_GPUS})"
  echo "   It may already be in passthrough mode. This test measures a round"
  echo "   trip starting from container mode; put it back first:"
  echo "     NODE=${NODE} APPLY=1 TARGET_WORKLOAD=container ./setup-passthrough.sh"
  exit 1
fi

echo "  Running a container GPU probe pod..."
if run_container_probe; then
  pass "A container workload can get a GPU on this node"
  printf '%s\n' "${PROBE_LOG}" | sed 's/^/     /'
else
  fail "A container workload can get a GPU on this node"
  printf '%s\n' "${PROBE_LOG:-<no logs>}" | sed 's/^/     /'
fi

echo ""
echo "=== 2. Draining GPU workloads off ${NODE} ==="

# The drain is not optional and not something the operator does for you. The
# nvidia kernel driver will not release a GPU that a running container has
# open, so vfio-pci cannot claim it and the switch silently stalls. Measuring
# the drain separately is the point: on a busy node it dominates the cost.
DRAIN_START="$(now)"

oc adm cordon "${NODE}" ${AS_ADMIN}
CORDONED=1
echo "  cordoned"

GPU_PODS="$(gpu_pods_on_node)"
GPU_POD_COUNT="$(printf '%s' "${GPU_PODS}" | grep -c . || true)"

if [ -n "${GPU_PODS}" ]; then
  echo "  evicting ${GPU_POD_COUNT} pod(s):"
  echo "${GPU_PODS}" | sed 's/^/     /'
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    oc delete pod "${entry#*/}" -n "${entry%%/*}" ${AS_ADMIN} \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done <<< "${GPU_PODS}"
else
  echo "  no GPU-holding pods to evict"
fi

if DRAIN_SECS="$(wait_until "${DRAIN_TIMEOUT}" "GPU pods to clear" gpu_pods_cleared)"; then
  record "drain ${GPU_POD_COUNT} GPU pod(s)" "${DRAIN_SECS}"
  pass "Drained ${GPU_POD_COUNT} GPU pod(s) in ${DRAIN_SECS}s"
else
  record "drain ${GPU_POD_COUNT} GPU pod(s)" "TIMEOUT"
  fail "GPU pods cleared within ${DRAIN_TIMEOUT}s"
  echo "   still holding GPUs:"
  gpu_pods_on_node | sed 's/^/     /'
fi

echo ""
echo "=== 3. container -> vm-passthrough ==="

FLIP1_START="$(now)"
oc label node "${NODE}" ${AS_ADMIN} --overwrite "${WORKLOAD_LABEL}=vm-passthrough"
echo "  labelled vm-passthrough at t=0"

if SECS="$(wait_until "${SWITCH_TIMEOUT}" "nvidia.com/gpu to disappear" no_container_gpu)"; then
  record "  container GPUs withdrawn" "${SECS}"
  pass "Container GPU capacity withdrawn after ${SECS}s"
else
  record "  container GPUs withdrawn" "TIMEOUT"
  fail "Container GPU capacity withdrawn within ${SWITCH_TIMEOUT}s"
fi

if SECS="$(wait_until "${SWITCH_TIMEOUT}" "vfio-manager to run" vfio_manager_running)"; then
  record "  vfio-manager running" "${SECS}"
  pass "vfio-manager is Running on the node after ${SECS}s"
else
  record "  vfio-manager running" "TIMEOUT"
  warn "vfio-manager did not report Running — the resource check below is the real test"
fi

if SECS="$(wait_until "${SWITCH_TIMEOUT}" "the passthrough resource to appear" has_vfio_resource)"; then
  record "  passthrough resource advertised" "${SECS}"
  pass "Passthrough resource advertised after ${SECS}s: $(alloc_vfio_gpu)"
else
  record "  passthrough resource advertised" "TIMEOUT"
  fail "Passthrough resource advertised within ${SWITCH_TIMEOUT}s"
  echo ""
  echo "  GPU operator pods on ${NODE}:"
  oc get pods -n "${GPU_OPERATOR_NS}" --field-selector "spec.nodeName=${NODE}" 2>/dev/null | sed 's/^/     /' || true
  echo ""
  echo "  The usual cause is a GPU still held open by a process, which stops"
  echo "  vfio-pci from taking the device. Check vfio-manager's log."
fi

record "container -> vm-passthrough TOTAL" "$(( $(now) - FLIP1_START ))"
record "  including drain" "$(( $(now) - DRAIN_START ))"

if oc adm uncordon "${NODE}" ${AS_ADMIN} >/dev/null 2>&1; then
  CORDONED=0
  echo "  uncordoned — the node can take VMs now"
fi

# Scheduling a VM is the end-to-end proof, but it needs a root disk and several
# minutes, so it lives in test-gpu-vm.sh. Here we assert the two conditions
# that make it possible.
VFIO_RES="$(alloc_vfio_gpu)"
if [ -n "${VFIO_RES}" ]; then
  VFIO_NAME="${VFIO_RES%%=*}"
  # HyperConverged v1 moved permittedHostDevices under .spec.virtualization
  # while v1beta1 keeps it top-level, and both are served — query both.
  PERMITTED="$(oc get hyperconverged -A -o jsonpath='{.items[*].spec.permittedHostDevices.pciHostDevices}{.items[*].spec.virtualization.permittedHostDevices.pciHostDevices}' 2>/dev/null || echo "")"
  if printf '%s' "${PERMITTED}" | grep -q "${VFIO_NAME}"; then
    pass "KubeVirt permits ${VFIO_NAME} — a VM can now request it"
  else
    warn "${VFIO_NAME} is allocatable but not in HyperConverged permittedHostDevices"
    warn "  VMs will be rejected until an admin adds it: APPLY=1 NODE=${NODE} ./setup-passthrough.sh"
  fi
fi

echo ""
echo "=== 4. vm-passthrough -> container ==="

# Nothing to drain going back in the pod sense: it is VMs that hold the devices
# now, and a GPU a running guest owns cannot be rebound either.
LIVE_VMIS="$(vmis_on_node)"
if [ -n "${LIVE_VMIS}" ]; then
  warn "VMIs still running on ${NODE} — a GPU they hold cannot be rebound:"
  echo "${LIVE_VMIS}" | sed 's/^/     /'
fi

FLIP2_START="$(now)"
oc label node "${NODE}" ${AS_ADMIN} --overwrite "${WORKLOAD_LABEL}=container"
echo "  labelled container at t=0"

if SECS="$(wait_until "${SWITCH_TIMEOUT}" "the passthrough resource to disappear" no_vfio_resource)"; then
  record "  passthrough resource withdrawn" "${SECS}"
  pass "Passthrough resource withdrawn after ${SECS}s"
else
  record "  passthrough resource withdrawn" "TIMEOUT"
  fail "Passthrough resource withdrawn within ${SWITCH_TIMEOUT}s"
fi

# The driver daemonset has to come back and load or rebuild the kernel module
# before any GPU is advertised again. This is the slow half of the round trip
# and the number people will care about.
if SECS="$(wait_until "${SWITCH_TIMEOUT}" "nvidia.com/gpu to come back" container_gpu_restored)"; then
  record "  container GPUs restored" "${SECS}"
  pass "All ${BASELINE_GPUS} container GPU(s) back after ${SECS}s"
else
  record "  container GPUs restored" "TIMEOUT"
  fail "Container GPU capacity returned to ${BASELINE_GPUS} within ${SWITCH_TIMEOUT}s (now: $(alloc_container_gpu))"
fi

record "vm-passthrough -> container TOTAL" "$(( $(now) - FLIP2_START ))"

echo ""
echo "  Re-running the container GPU probe..."
if run_container_probe; then
  pass "A container workload can get a GPU on this node again"
  printf '%s\n' "${PROBE_LOG}" | sed 's/^/     /'
else
  fail "A container workload can get a GPU on this node again"
  printf '%s\n' "${PROBE_LOG:-<no logs>}" | sed 's/^/     /'
fi

record "ROUND TRIP TOTAL" "$(( $(now) - DRAIN_START ))"

echo ""
echo "=== 5. Cost of a switch ==="
echo ""
printf '%s' "${TIMINGS}" | awk -F'\t' '{printf "  %-42s %s\n", $1, ($2=="TIMEOUT" ? "TIMEOUT" : $2 "s")}'
echo ""
echo "  Granularity is the whole node: all ${BASELINE_GPUS} GPUs move together."
echo "  There is no supported way to split one node's GPUs between containers"
echo "  and VMs, so the unit of scheduling for mixed use is a node-afternoon,"
echo "  not a GPU."

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "✅ VERIFICATION SUCCESS: ${NODE} switched from container GPUs to VM"
  echo "   passthrough and back, and serves container workloads again."
else
  echo "❌ VERIFICATION FAILED: see the ❌ lines above."
  echo ""
  echo "Node state now:"
  oc get node "${NODE}" \
    -o custom-columns='NODE:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,GPUS:.status.allocatable.nvidia\.com/gpu,WORKLOAD:.metadata.labels.nvidia\.com/gpu\.workload\.config' \
    2>/dev/null || true
  echo ""
  echo "GPU operator pods on the node:"
  oc get pods -n "${GPU_OPERATOR_NS}" --field-selector "spec.nodeName=${NODE}" 2>/dev/null | sed 's/^/  /' || true
  exit 1
fi
