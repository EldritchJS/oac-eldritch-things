#!/usr/bin/env bash
set -euo pipefail

# Puts one node into GPU-passthrough mode and teaches KubeVirt about the device,
# so that VMs in this cluster can be given a whole physical GPU.
#
# Unlike the rest of vms/, this is an ADMIN script. It changes
# cluster-scoped objects (ClusterPolicy, HyperConverged) and a node label, and
# the node label change tears down the container GPU stack on that node. Run it
# read-only first — it reports everything it would do and nothing else until
# APPLY=1.
#
# The mechanism: with sandboxWorkloads enabled, the NVIDIA GPU Operator reads a
# per-node label, nvidia.com/gpu.workload.config, and deploys one of two
# mutually exclusive stacks on that node:
#
#   container      driver + container-toolkit + device-plugin + DCGM,
#                  advertising nvidia.com/gpu
#   vm-passthrough vfio-manager (binds the GPUs to vfio-pci) +
#                  sandbox-device-plugin, advertising a device-specific
#                  resource such as nvidia.com/GH100_H100_SXM5_80GB
#
# The granularity is the NODE, not the GPU. There is no supported way to leave
# two of a node's four H100s serving containers while the other two back VMs.

NODE="${NODE:-}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-nvidia-gpu-operator}"
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
HCO_NAME="${HCO_NAME:-kubevirt-hyperconverged}"

WORKLOAD_LABEL="nvidia.com/gpu.workload.config"
TARGET_WORKLOAD="${TARGET_WORKLOAD:-vm-passthrough}"

# PCI vendor:device of the GPU, e.g. 10DE:2330 for an H100 SXM5 80GB. Left
# empty it is discovered from the node with `oc debug`, which needs a debug pod
# to be schedulable; set it explicitly if that is blocked.
PCI_ID="${PCI_ID:-}"

# Resource name the sandbox device plugin advertises. Discovered after the
# label flip rather than guessed — it is derived from NVIDIA's own device name
# for the card and is not something to hardcode per cluster.
GPU_RESOURCE="${GPU_RESOURCE:-}"

APPLY="${APPLY:-0}"
RESOURCE_TIMEOUT="${RESOURCE_TIMEOUT:-300}"

# Repo convention is that mutating admin commands impersonate system:admin.
# Set AS_ADMIN="" if you are already cluster-admin and lack impersonate rights.
AS_ADMIN="${AS_ADMIN:---as=system:admin}"

PASSED=0
FAILED=0

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }
info() { echo "     $1"; }

# How to turn the IOMMU on depends on who owns the nodes' boot configuration,
# and that differs by cluster topology. On a standalone cluster it is a
# MachineConfig. On a hosted control plane (HyperShift) there is no
# MachineConfig API in the guest cluster at all — kernel arguments live on the
# NodePool object in the *management* cluster, which a guest-cluster admin
# cannot reach. Printing the wrong instructions sends people down a dead end.
iommu_remediation() {
  # Probe the API directly — BSD grep on macOS does not support \b, which made
  # an api-resources grep silently false-negative on a standalone cluster.
  if oc get machineconfigpools >/dev/null 2>&1; then
    info "Apply the kernel arguments. This reboots the node:"
    info "  oc process --local -f iommu-machineconfig.yaml | oc apply ${AS_ADMIN} -f -"
    info "  oc label node ${NODE} node-role.kubernetes.io/gpu-virt= ${AS_ADMIN}"
  else
    info "This cluster has no MachineConfig API — it is a hosted control plane"
    info "(controlPlaneTopology=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo unknown))."
    info "iommu-machineconfig.yaml does NOT apply here. Kernel arguments must be"
    info "set on the NodePool backing these workers, from the management cluster:"
    info "  oc patch nodepool <pool> -n <hosted-cluster-ns> --type=merge \\"
    info "    -p '{\"spec\":{\"config\":[{\"name\":\"gpu-virt-iommu\"}]}}'"
    info "referencing a ConfigMap that holds the MachineConfig. That is a"
    info "platform-team request, not something to do from here."
  fi
}

# Pulls the nvidia.com/* resource names a node advertises, minus the plain
# container one. In passthrough mode exactly one device-specific name should
# appear; in container mode, none.
node_vfio_resources() { # node_vfio_resources <node>
  oc get node "$1" -o jsonpath='{.status.allocatable}' 2>/dev/null \
    | python3 -c '
import json, sys
try:
    alloc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k, v in sorted(alloc.items()):
    if k.startswith("nvidia.com/") and k != "nvidia.com/gpu" and "mig-" not in k:
        print(f"{k}={v}")
' 2>/dev/null || true
}

node_container_gpus() { # node_container_gpus <node>
  oc get node "$1" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo ""
}

# Where permittedHostDevices lives depends on which HyperConverged API version
# oc resolves to. OpenShift Virtualization 4.22 introduced hco.kubevirt.io/v1,
# which restructured the spec and moved the field under .spec.virtualization;
# v1beta1 keeps it at the top level. v1 is served but NOT the storage version,
# so both are live simultaneously and oc picks v1.
#
# Getting this wrong fails silently and is worth being paranoid about: patching
# a path the served version does not define makes the apiserver prune the
# unknown field, print at most a "Warning: unknown field" line, and return
# success. The object comes back unchanged and every surrounding check passes.
hco_json() {
  oc get hyperconverged "${HCO_NAME}" -n "${CNV_NAMESPACE}" -o json 2>/dev/null
}

# Reads pciHostDevices from whichever of the two layouts is in use.
hco_pci_devices() {
  hco_json | python3 -c '
import json, sys
try:
    spec = json.load(sys.stdin).get("spec", {})
except Exception:
    print("[]"); sys.exit(0)
phd = spec.get("virtualization", {}).get("permittedHostDevices") \
      or spec.get("permittedHostDevices") or {}
print(json.dumps(phd.get("pciHostDevices", [])))
' 2>/dev/null || echo "[]"
}

echo "========================================="
echo "  GPU Passthrough Setup"
echo "  Node:          ${NODE:-<unset>}"
echo "  GPU operator:  ${GPU_OPERATOR_NS}"
echo "  Virtualization:${CNV_NAMESPACE}"
echo "  Mode:          $([ "${APPLY}" = "1" ] && echo "APPLY (will mutate)" || echo "report only (APPLY=1 to mutate)")"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ Required binary '${bin}' not found in PATH."; exit 1; }
done

if [ -z "${NODE}" ]; then
  echo "❌ NODE is required — this script changes one specific node and will not"
  echo "   pick one for you. GPU nodes on this cluster:"
  oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's/^/     /' || true
  echo ""
  echo "   NODE=<node> ./$(basename "$0")"
  exit 1
fi

oc get node "${NODE}" >/dev/null 2>&1 || { echo "❌ Node ${NODE} not found."; exit 1; }
echo "node ${NODE}: present"

case "${TARGET_WORKLOAD}" in
  container|vm-passthrough) ;;
  vm-vgpu)
    echo "❌ TARGET_WORKLOAD=vm-vgpu is out of scope for this script."
    echo "   vGPU needs the NVIDIA vGPU host driver, an AI Enterprise entitlement"
    echo "   and a DLS/CLS license server. This repo covers passthrough only."
    exit 1 ;;
  *)
    echo "❌ TARGET_WORKLOAD must be 'container' or 'vm-passthrough' (got '${TARGET_WORKLOAD}')."
    exit 1 ;;
esac

echo ""
echo "=== 1. Current node state ==="

CURRENT_WORKLOAD="$(oc get node "${NODE}" -o jsonpath="{.metadata.labels.nvidia\.com/gpu\.workload\.config}" 2>/dev/null || echo "")"
GPU_PRODUCT="$(oc get node "${NODE}" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || echo "")"
GPU_COUNT_LABEL="$(oc get node "${NODE}" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null || echo "")"
KUBEVIRT_OK="$(oc get node "${NODE}" -o jsonpath='{.metadata.labels.kubevirt\.io/schedulable}' 2>/dev/null || echo "")"

echo "  workload.config:      ${CURRENT_WORKLOAD:-<unset>}"
echo "  gpu.product:          ${GPU_PRODUCT:-<unset>}"
echo "  gpu.count:            ${GPU_COUNT_LABEL:-<unset>}"
echo "  kubevirt schedulable: ${KUBEVIRT_OK:-<unset>}"
echo "  allocatable nvidia.com/gpu:  $(node_container_gpus "${NODE}" || echo 0)"
echo "  allocatable vfio resources:  $(node_vfio_resources "${NODE}" | tr '\n' ' ')"

# A node that virt-handler will not schedule onto cannot host a VM at all, GPU
# or otherwise. Worth catching here rather than as an unschedulable VMI later.
if [ "${KUBEVIRT_OK}" = "true" ]; then
  pass "Node is virtualization-schedulable"
else
  fail "Node is virtualization-schedulable (kubevirt.io/schedulable=${KUBEVIRT_OK:-<unset>})"
  info "OpenShift Virtualization either is not installed or is not running on this node."
  info "Check with: component-checks/oc-virt-checks.sh"
fi

echo ""
echo "=== 2. IOMMU ==="

# vfio-pci cannot claim a device without an IOMMU. Ground truth is whether the
# kernel actually populated IOMMU groups — /proc/cmdline only says what was
# requested — but reading sysfs needs a debug pod, which plenty of accounts
# cannot create. So: try the direct check, and fall back to NFD's record of the
# kernel build config, which every authenticated user can read.
IOMMU_STATE=""
if IOMMU_OUT="$(oc debug "node/${NODE}" --quiet -- chroot /host sh -c \
      'ls /sys/kernel/iommu_groups 2>/dev/null | wc -l; cat /proc/cmdline' 2>/dev/null)"; then
  IOMMU_GROUPS="$(printf '%s' "${IOMMU_OUT}" | head -1 | tr -d '[:space:]')"
  CMDLINE="$(printf '%s' "${IOMMU_OUT}" | sed -n '2p')"
  IOMMU_STATE="${IOMMU_GROUPS}"
  echo "  IOMMU groups: ${IOMMU_GROUPS:-0}"
  echo "  cmdline:      ${CMDLINE}"
  if [ "${IOMMU_GROUPS:-0}" -gt 0 ] 2>/dev/null; then
    pass "IOMMU is enabled (${IOMMU_GROUPS} groups)"
  else
    fail "IOMMU is enabled (no groups under /sys/kernel/iommu_groups)"
    iommu_remediation
  fi
else
  warn "Could not run a debug pod on ${NODE} — falling back to NFD kernel config"

  # NodeFeature carries the node's kernel .config. CONFIG_AMD_IOMMU=y (or
  # INTEL_IOMMU) means the driver is built in, and on AMD it initialises from
  # the firmware IVRS table by default — amd_iommu=on is the default, not
  # something to switch on. That makes this a strong indication, not proof: an
  # explicit amd_iommu=off, or IOMMU disabled in the BIOS, would still leave
  # no groups and is invisible from here.
  NFD_NS="${NFD_NS:-openshift-nfd}"
  KCFG="$(oc get nodefeature "${NODE}" -n "${NFD_NS}" -o json 2>/dev/null \
    | python3 -c '
import json, sys
try:
    f = json.load(sys.stdin)["spec"]["features"]
    els = f["attributes"]["kernel.config"]["elements"]
except Exception:
    sys.exit(0)
for key in ("AMD_IOMMU", "INTEL_IOMMU", "IOMMU_SUPPORT", "VFIO_PCI", "VFIO_IOMMU_TYPE1"):
    if key in els:
        print(key + "=" + str(els[key]))
' 2>/dev/null || true)"

  if [ -n "${KCFG}" ]; then
    printf '%s\n' "${KCFG}" | sed 's/^/     CONFIG_/'
    if printf '%s' "${KCFG}" | grep -qE '^(AMD|INTEL)_IOMMU=y'; then
      warn "IOMMU driver is compiled in, so it is very likely active already"
      info "Confirm for certain once a debug pod is possible:"
      info "  oc debug node/${NODE} -- chroot /host ls /sys/kernel/iommu_groups | wc -l"
      info "Otherwise vfio-manager is the next check — if the IOMMU is off it"
      info "fails loudly rather than silently mis-binding."
    else
      fail "No IOMMU driver in the node's kernel config"
      iommu_remediation
    fi
  else
    warn "No NodeFeature for ${NODE} in ${NFD_NS} either — IOMMU state unknown"
    info "Check by hand: oc debug node/${NODE} -- chroot /host ls /sys/kernel/iommu_groups | wc -l"
  fi
fi

echo ""
echo "=== 3. GPU PCI device ==="

if [ -z "${PCI_ID}" ]; then
  # -d 10de: filters to NVIDIA; -nn prints the numeric vendor:device alongside
  # the human name, which is the pair permittedHostDevices wants.
  if LSPCI_OUT="$(oc debug "node/${NODE}" --quiet -- chroot /host sh -c \
        'lspci -nn -d 10de: 2>/dev/null' 2>/dev/null)"; then
    echo "${LSPCI_OUT}" | sed 's/^/     /'
    # 3D controllers (class 0302) are the GPUs; skip bridges and audio.
    PCI_ID="$(printf '%s' "${LSPCI_OUT}" \
      | grep -i '3D controller\|VGA compatible controller' \
      | grep -oiE '10de:[0-9a-f]{4}' | head -1 | tr '[:lower:]' '[:upper:]' || true)"
  fi
fi

if [ -n "${PCI_ID}" ]; then
  pass "GPU PCI id: ${PCI_ID}"
else
  fail "GPU PCI id could not be determined"
  info "Find it by hand and pass it in:"
  info "  oc debug node/${NODE} -- chroot /host lspci -nn -d 10de:"
  info "  PCI_ID=10DE:2330 NODE=${NODE} ./$(basename "$0")"
fi

echo ""
echo "=== 4. GPU Operator sandbox workloads ==="

CP_NAME="$(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
if [ -z "${CP_NAME}" ]; then
  fail "ClusterPolicy found"
  info "The NVIDIA GPU Operator does not appear to be installed."
  exit 1
fi

SANDBOX_ENABLED="$(oc get clusterpolicy "${CP_NAME}" -o jsonpath='{.spec.sandboxWorkloads.enabled}' 2>/dev/null || echo "")"
DEFAULT_WORKLOAD="$(oc get clusterpolicy "${CP_NAME}" -o jsonpath='{.spec.sandboxWorkloads.defaultWorkload}' 2>/dev/null || echo "")"
echo "  clusterpolicy:           ${CP_NAME}"
echo "  sandboxWorkloads.enabled: ${SANDBOX_ENABLED:-<unset>}"
echo "  defaultWorkload:          ${DEFAULT_WORKLOAD:-<unset>}"

if [ "${SANDBOX_ENABLED}" = "true" ]; then
  pass "sandboxWorkloads is enabled"
else
  warn "sandboxWorkloads is disabled — the operator will ignore ${WORKLOAD_LABEL}"
fi

# defaultWorkload applies to every GPU node without an explicit label, so
# changing it is a fleet-wide act. Flag loudly if it is not 'container'.
if [ -n "${DEFAULT_WORKLOAD}" ] && [ "${DEFAULT_WORKLOAD}" != "container" ]; then
  warn "defaultWorkload is '${DEFAULT_WORKLOAD}', so UNLABELLED GPU nodes are not serving containers"
fi

echo ""
echo "=== 5. KubeVirt permitted host devices ==="

if ! oc get hyperconverged "${HCO_NAME}" -n "${CNV_NAMESPACE}" >/dev/null 2>&1; then
  fail "HyperConverged ${CNV_NAMESPACE}/${HCO_NAME} found"
  exit 1
fi

HCO_APIVERSION="$(oc get hyperconverged "${HCO_NAME}" -n "${CNV_NAMESPACE}" -o jsonpath='{.apiVersion}' 2>/dev/null || echo "")"
CURRENT_PHD="$(hco_pci_devices)"
echo "  apiVersion:     ${HCO_APIVERSION:-<unknown>}"
echo "  pciHostDevices: $([ "${CURRENT_PHD}" = "[]" ] && echo "<none>" || echo "${CURRENT_PHD}")"

if [ -n "${PCI_ID}" ] && printf '%s' "${CURRENT_PHD}" | grep -qi "${PCI_ID}"; then
  pass "KubeVirt already permits ${PCI_ID}"
  PHD_NEEDED=0
else
  warn "KubeVirt does not yet permit ${PCI_ID:-this device} — VMs requesting it will be rejected"
  PHD_NEEDED=1
fi

if [ "${APPLY}" != "1" ]; then
  echo ""
  echo "========================================="
  echo "  Report only — nothing was changed"
  echo "========================================="
  echo ""
  echo "To apply, re-run with APPLY=1. That will:"
  [ "${SANDBOX_ENABLED}" = "true" ] || echo "  - enable sandboxWorkloads on clusterpolicy/${CP_NAME}"
  echo "  - set ${WORKLOAD_LABEL}=${TARGET_WORKLOAD} on ${NODE}"
  echo "  - wait for the sandbox device plugin to advertise the GPU"
  [ "${PHD_NEEDED}" = "1" ] && echo "  - add ${PCI_ID:-<pci id>} to HyperConverged permittedHostDevices"
  echo ""
  echo "Flipping the label TEARS DOWN the container GPU stack on ${NODE}."
  echo "Drain GPU pods off it first, or use test-gpu-switch.sh, which does the"
  echo "drain and times the whole transition."
  exit $([ "${FAILED}" -gt 0 ] && echo 1 || echo 0)
fi

echo ""
echo "=== 6. Applying ==="

if [ "${SANDBOX_ENABLED}" != "true" ]; then
  echo "Enabling sandboxWorkloads on clusterpolicy/${CP_NAME} ..."
  oc patch clusterpolicy "${CP_NAME}" ${AS_ADMIN} --type=merge \
    -p '{"spec":{"sandboxWorkloads":{"enabled":true,"defaultWorkload":"container"}}}'
  pass "sandboxWorkloads enabled (defaultWorkload=container, so other nodes are unaffected)"
fi

echo "Labelling ${NODE} with ${WORKLOAD_LABEL}=${TARGET_WORKLOAD} ..."
oc label node "${NODE}" ${AS_ADMIN} --overwrite "${WORKLOAD_LABEL}=${TARGET_WORKLOAD}"
pass "Node labelled ${TARGET_WORKLOAD}"

if [ "${TARGET_WORKLOAD}" = "container" ]; then
  echo ""
  echo "Node returned to container mode. nvidia.com/gpu should reappear shortly:"
  echo "  oc get node ${NODE} -o jsonpath='{.status.allocatable}' | tr ',' '\\n' | grep nvidia"
  exit 0
fi

echo ""
echo "Waiting up to ${RESOURCE_TIMEOUT}s for the sandbox device plugin to advertise the GPU..."
DEADLINE=$(( $(date +%s) + RESOURCE_TIMEOUT ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  FOUND="$(node_vfio_resources "${NODE}")"
  if [ -n "${FOUND}" ]; then
    GPU_RESOURCE="${FOUND%%=*}"
    GPU_ALLOCATABLE="${FOUND##*=}"
    break
  fi
  echo "  waiting... (container gpus still allocatable: $(node_container_gpus "${NODE}" || echo 0))"
  sleep 10
done

if [ -n "${GPU_RESOURCE}" ]; then
  pass "Sandbox device plugin advertises ${GPU_RESOURCE} (${GPU_ALLOCATABLE:-?} available)"
else
  fail "Sandbox device plugin advertises the GPU"
  echo ""
  echo "vfio-manager / sandbox-device-plugin pods on ${NODE}:"
  oc get pods -n "${GPU_OPERATOR_NS}" --field-selector "spec.nodeName=${NODE}" 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo "The usual cause is that vfio-pci could not take the device because a"
  echo "process still holds it — the nvidia driver does not release a GPU that"
  echo "a running container is using. Drain GPU pods off the node and retry."
  exit 1
fi

if [ "${PHD_NEEDED}" = "1" ]; then
  if [ -z "${PCI_ID}" ]; then
    fail "Cannot update permittedHostDevices without a PCI id"
    exit 1
  fi
  echo ""
  echo "Adding ${PCI_ID} -> ${GPU_RESOURCE} to HyperConverged permittedHostDevices ..."

  # Merge rather than replace: a merge patch overwrites the whole list, so the
  # desired list has to be computed from the current one or other permitted
  # devices would silently disappear. The nesting depends on the API version —
  # see hco_pci_devices above.
  NEW_PHD="$(hco_json | PCI_ID="${PCI_ID}" GPU_RESOURCE="${GPU_RESOURCE}" python3 -c '
import json, os, sys
hco = json.load(sys.stdin)
spec = hco.get("spec", {})
# v1 nests the field under .spec.virtualization; v1beta1 has it at the top.
nested = hco.get("apiVersion", "").endswith("/v1")
phd = (spec.get("virtualization", {}).get("permittedHostDevices")
       if nested else spec.get("permittedHostDevices")) or {}
devices = phd.get("pciHostDevices", [])
selector = os.environ["PCI_ID"]
entry = {
    "pciDeviceSelector": selector,
    "resourceName": os.environ["GPU_RESOURCE"],
    # The NVIDIA sandbox device plugin owns advertising this resource.
    # Without externalResourceProvider KubeVirt would stand up its own device
    # plugin for the same device and the two would fight over it.
    "externalResourceProvider": True,
}
devices = [d for d in devices if d.get("pciDeviceSelector", "").upper() != selector.upper()]
devices.append(entry)
body = {"permittedHostDevices": {"pciHostDevices": devices}}
print(json.dumps({"spec": {"virtualization": body} if nested else body}))
')"

  oc patch hyperconverged "${HCO_NAME}" -n "${CNV_NAMESPACE}" ${AS_ADMIN} \
    --type=merge -p "${NEW_PHD}"

  # Read it back. A patch against a field the served API version does not
  # define is pruned and still exits 0, so "the patch succeeded" proves
  # nothing — only re-reading the object does.
  if printf '%s' "$(hco_pci_devices)" | grep -qi "${PCI_ID}"; then
    pass "KubeVirt now permits ${PCI_ID} as ${GPU_RESOURCE}"
  else
    fail "Patch was accepted but ${PCI_ID} is not in permittedHostDevices"
    info "The apiserver likely pruned it as an unknown field. Current value:"
    info "  $(hco_pci_devices)"
    info "HyperConverged apiVersion: ${HCO_APIVERSION:-<unknown>}"
    exit 1
  fi
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "✅ ${NODE} is in GPU passthrough mode."
  echo ""
  echo "Boot a VM on it with:"
  echo "  GPU_RESOURCE=${GPU_RESOURCE} ./test-gpu-vm.sh"
  echo ""
  echo "Put it back to serving containers with:"
  echo "  APPLY=1 NODE=${NODE} TARGET_WORKLOAD=container ./$(basename "$0")"
else
  echo "❌ Setup incomplete — see the ❌ lines above."
  exit 1
fi
