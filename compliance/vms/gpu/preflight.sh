#!/usr/bin/env bash
set -euo pipefail

# Answers one question about whatever cluster you are currently logged into:
# can it run a GPU passthrough VM, and if not, what is missing and who has to
# fix it?
#
# Strictly READ-ONLY. It creates nothing, patches nothing, and needs no admin
# and no debug pod — every check works for an ordinary authenticated user.
# Run it before anything else in this directory, on any cluster, including ones
# you have only just been given access to.
#
# It also reports what *you personally* are allowed to do, because the usual
# reason this work stalls is not a missing feature but a missing permission,
# and that is cheaper to discover now than three steps in.

NAMESPACE="${NAMESPACE:-${PROJECT:-$(oc project -q 2>/dev/null || echo default)}}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-nvidia-gpu-operator}"
WORKLOAD_LABEL="nvidia.com/gpu.workload.config"

PASSED=0
FAILED=0
BLOCKERS=""

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }
info() { echo "     $1"; }
blocker() { BLOCKERS="${BLOCKERS}  - $1
"; }

# oc auth can-i, reduced to yes/no without the stderr noise and without
# tripping set -e on a "no".
can_i() { # can_i <verb> <resource> [-n ns]
  oc auth can-i "$@" 2>/dev/null || true
}

report_can() { # report_can <label> <verb> <resource> [-n ns]
  local label="$1"; shift
  printf '     %-46s %s\n' "${label}" "$(can_i "$@")"
}

echo "========================================="
echo "  GPU Passthrough Preflight (read-only)"
echo "========================================="

for bin in oc python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ Required binary '${bin}' not found in PATH."; exit 1; }
done
oc whoami >/dev/null 2>&1 || { echo "❌ Not logged in to a cluster."; exit 1; }

echo ""
echo "=== 1. Cluster ==="
echo "  user:      $(oc whoami 2>/dev/null)"
echo "  server:    $(oc whoami --show-server 2>/dev/null)"
echo "  version:   $(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo unknown)"
echo "  namespace: ${NAMESPACE}"

TOPOLOGY="$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo unknown)"
echo "  control plane topology: ${TOPOLOGY}"

# Decides which IOMMU remediation path is even available. On a hosted control
# plane the guest cluster has no MachineConfig API and kernel arguments belong
# to a NodePool in the management cluster.
# Probe the API directly rather than grepping `oc api-resources`: BSD grep on
# macOS does not understand \b, which silently turned this into a false
# negative on a standalone cluster.
HAS_MC=0
oc get machineconfigpools >/dev/null 2>&1 && HAS_MC=1

if [ "${HAS_MC}" = "1" ]; then
  info "MachineConfig API present — iommu-machineconfig.yaml is applicable here"
elif [ "${TOPOLOGY}" = "External" ]; then
  info "Hosted control plane and no MachineConfig API — kernel arguments live"
  info "on the NodePool in the management cluster, not here"
else
  info "No MachineConfig API, but topology is ${TOPOLOGY} rather than External."
  info "Unexpected combination; check 'oc get machineconfigpools' by hand."
fi

echo ""
echo "=== 2. OpenShift Virtualization ==="

if oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
  pass "KubeVirt CRDs are served"
  HCO_STATE="$(oc get hyperconverged -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
  if [ -n "${HCO_STATE}" ]; then
    pass "HyperConverged exists: ${HCO_STATE}"
  else
    warn "No HyperConverged object readable — CNV may be partially installed, or you cannot read it"
  fi
else
  fail "KubeVirt CRDs are not served — OpenShift Virtualization is not installed"
  blocker "Install OpenShift Virtualization. Nothing else in this directory applies without it."
fi

echo ""
echo "=== 3. GPU nodes ==="

GPU_NODES="$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -z "${GPU_NODES}" ]; then
  # Not every cluster labels with gpu.present; fall back to allocatable.
  GPU_NODES="$(oc get nodes -o json 2>/dev/null | python3 -c '
import json, sys
try: items = json.load(sys.stdin)["items"]
except Exception: sys.exit(0)
for n in items:
    alloc = n.get("status", {}).get("allocatable", {})
    if any(k.startswith("nvidia.com/") for k in alloc):
        print(n["metadata"]["name"])
' 2>/dev/null || true)"
fi

if [ -z "${GPU_NODES}" ]; then
  # Both detection paths depend on software: the gpu.present label comes from
  # NFD, and an allocatable nvidia.com/* resource comes from the GPU operator's
  # device plugin. On a cluster with neither installed, a box full of H100s
  # looks exactly like a box with no GPUs. Do not report "no GPUs" when the
  # honest answer is "the API cannot see them from here".
  if ! oc get ns openshift-nfd >/dev/null 2>&1 && ! oc get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
    warn "No GPU nodes visible, but neither NFD nor the GPU operator is installed"
    info "That means the API cannot report GPUs even if the hardware is there."
    info "Check the hardware directly (needs debug-pod rights):"
    info "  oc debug node/<worker> -- chroot /host lspci -nn -d 10de:"
    blocker "Install NFD and the NVIDIA GPU Operator, then re-run this preflight."
  else
    fail "No GPU nodes found (or you cannot list nodes)"
    blocker "No visible GPU nodes. Check 'oc auth can-i list nodes'."
  fi
else
  pass "$(printf '%s' "${GPU_NODES}" | grep -c .) GPU node(s) visible"
  # GPU_NODES has to be exported, not just set: without it python raises
  # KeyError and the whole table vanishes into the 2>/dev/null below.
  oc get nodes -o json 2>/dev/null | GPU_NODES="${GPU_NODES}" python3 -c '
import json, os, sys
want = set(os.environ["GPU_NODES"].split())
try: items = json.load(sys.stdin)["items"]
except Exception: sys.exit(0)
print("     %-22s %-26s %-5s %-11s %-6s %s" % ("NODE","PRODUCT","GPUS","KUBEVIRT","Q35","WORKLOAD"))
for n in items:
    name = n["metadata"]["name"]
    if name not in want: continue
    l = n["metadata"]["labels"]
    a = n.get("status", {}).get("allocatable", {})
    print("     %-22s %-26s %-5s %-11s %-6s %s" % (
        name,
        l.get("nvidia.com/gpu.product", "?"),
        a.get("nvidia.com/gpu", "0"),
        l.get("kubevirt.io/schedulable", "<unset>"),
        l.get("machine-type.node.kubevirt.io/q35", "<unset>"),
        l.get("nvidia.com/gpu.workload.config", "<unset>")))
' 2>/dev/null || true

  # A GPU node that virt-handler will not schedule onto cannot host a GPU VM,
  # which is the single most common reason this whole idea is a non-starter on
  # a given cluster.
  VM_CAPABLE="$(for n in ${GPU_NODES}; do
    s="$(oc get node "$n" -o jsonpath='{.metadata.labels.kubevirt\.io/schedulable}' 2>/dev/null || echo "")"
    [ "$s" = "true" ] && echo "$n"
  done)"
  if [ -n "${VM_CAPABLE}" ]; then
    pass "GPU nodes that can host VMs: $(printf '%s' "${VM_CAPABLE}" | tr '\n' ' ')"
  else
    fail "No GPU node has kubevirt.io/schedulable=true"
    blocker "CNV is not running on the GPU nodes. Often a nodeSelector/taint on the HyperConverged workloads placement, or GPU nodes excluded from the virt-handler DaemonSet."
  fi
fi

echo ""
echo "=== 4. IOMMU ==="

# Ground truth is /sys/kernel/iommu_groups, which needs a debug pod. NFD's copy
# of the kernel build config is readable by anyone and is a strong indication:
# CONFIG_AMD_IOMMU=y means the driver is built in, and on AMD it initialises
# from the firmware IVRS table by default. It cannot see an explicit
# amd_iommu=off or an IOMMU disabled in the BIOS, so it is evidence, not proof.
NFD_NS="${NFD_NS:-$(oc get nodefeature -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")}"
FIRST_GPU_NODE="$(printf '%s' "${GPU_NODES}" | head -1)"

if [ -n "${NFD_NS}" ] && [ -n "${FIRST_GPU_NODE}" ]; then
  KCFG="$(oc get nodefeature "${FIRST_GPU_NODE}" -n "${NFD_NS}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    els = json.load(sys.stdin)["spec"]["features"]["attributes"]["kernel.config"]["elements"]
except Exception:
    sys.exit(0)
for k in ("AMD_IOMMU", "INTEL_IOMMU", "IOMMU_SUPPORT", "VFIO_PCI", "VFIO_IOMMU_TYPE1"):
    if k in els: print("CONFIG_" + k + "=" + str(els[k]))
' 2>/dev/null || true)"

  if [ -n "${KCFG}" ]; then
    printf '%s\n' "${KCFG}" | sed 's/^/     /'
    if printf '%s' "${KCFG}" | grep -qE '^CONFIG_(AMD|INTEL)_IOMMU=y'; then
      pass "IOMMU driver is compiled into the node kernel — very likely already active"
      info "Confirm if you can create a debug pod:"
      info "  oc debug node/${FIRST_GPU_NODE} -- chroot /host ls /sys/kernel/iommu_groups | wc -l"
    else
      fail "No IOMMU driver in the node kernel config"
      if [ "${HAS_MC}" = "1" ]; then
        blocker "Enable IOMMU: oc process --local -f iommu-machineconfig.yaml | oc apply -f - (reboots nodes)"
      else
        blocker "Enable IOMMU via the NodePool in the management cluster — platform-team request."
      fi
    fi
  else
    warn "NodeFeature for ${FIRST_GPU_NODE} unreadable — IOMMU state unknown"
  fi
else
  warn "No NodeFeature objects found (NFD not installed, or not readable) — IOMMU state unknown"
  info "vfio-manager is the backstop: with the IOMMU off it fails loudly rather than mis-binding"
fi

echo ""
echo "=== 5. GPU Operator sandbox workloads ==="

SW="$(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].spec.sandboxWorkloads}' 2>/dev/null || echo "")"
if [ -z "${SW}" ]; then
  warn "No ClusterPolicy readable in this cluster"
  info "Without the NVIDIA GPU Operator there is no vfio-manager and no sandbox device plugin."
  info "Passthrough is still possible by binding vfio-pci by hand, but nothing here automates that."
else
  echo "     ${SW}"
  SW_ENABLED="$(printf '%s' "${SW}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("enabled"))' 2>/dev/null || echo "?")"
  SW_MODE="$(printf '%s' "${SW}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mode"))' 2>/dev/null || echo "?")"
  if [ "${SW_ENABLED}" = "True" ] || [ "${SW_ENABLED}" = "true" ]; then
    pass "sandboxWorkloads enabled (mode=${SW_MODE})"
  else
    fail "sandboxWorkloads is disabled — the operator will ignore ${WORKLOAD_LABEL}"
    blocker "Enable it: NODE=<node> APPLY=1 ./setup-passthrough.sh (needs patch on clusterpolicies.nvidia.com)"
  fi
  [ "${SW_MODE}" = "kubevirt" ] || warn "mode=${SW_MODE}, expected 'kubevirt' for VM passthrough"
fi

echo ""
echo "=== 6. KubeVirt host devices ==="

# Both layouts are queried at once. HyperConverged v1 (OpenShift Virtualization
# 4.22+) moved permittedHostDevices under .spec.virtualization; v1beta1 keeps it
# at the top level, and both versions are served, so which one you get back
# depends on what oc picks. A jsonpath that misses just yields nothing.
PHD="$(oc get hyperconverged -A -o jsonpath='{.items[*].spec.permittedHostDevices.pciHostDevices}{.items[*].spec.virtualization.permittedHostDevices.pciHostDevices}' 2>/dev/null || echo "")"
if [ -n "${PHD}" ]; then
  pass "permittedHostDevices has entries"
  echo "     ${PHD}"
else
  warn "permittedHostDevices is empty — no PCI device is allow-listed for VMs yet"
  info "setup-passthrough.sh adds the entry once the resource name is discoverable."
  info "Not a blocker yet: the device has to be advertised before it can be allow-listed."
fi

echo ""
echo "=== 7. Storage ==="

# Easy to forget until a DataVolume sits Pending forever. It matters more than
# it looks for GPU VMs specifically: containerDisk, the obvious way to boot a
# VM without any storage at all, does not work alongside PCI passthrough on
# CNV 4.22.9 — see the note in test-gpu-vm.sh. So a GPU VM needs a real PVC,
# which means a real StorageClass.
SC_DEFAULT="$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || echo "")"
SC_ANY="$(oc get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "${SC_DEFAULT}" ]; then
  pass "default StorageClass: ${SC_DEFAULT}"
elif [ "${SC_ANY}" != "0" ]; then
  warn "${SC_ANY} StorageClass(es) but none marked default — pass STORAGE_CLASS= explicitly"
  oc get sc --no-headers 2>/dev/null | awk '{print "     "$1}'
else
  fail "No StorageClass on this cluster"
  blocker "No StorageClass: test-gpu-vm.sh cannot provision a root disk, and containerDisk is not a workaround for a GPU VM. Install a storage provider (on bare metal with spare disks, the LVM Storage operator is the usual answer)."
fi

echo ""
echo "=== 8. What a switch would cost ==="

if [ -n "${GPU_NODES}" ]; then
  oc get pods -A -o json 2>/dev/null | GPU_NODES="${GPU_NODES}" python3 -c '
import json, os, sys
nodes = os.environ["GPU_NODES"].split()
try: pods = json.load(sys.stdin)["items"]
except Exception: sys.exit(0)
counts = {n: 0 for n in nodes}
for p in pods:
    node = p["spec"].get("nodeName", "")
    if node not in counts: continue
    if p["metadata"]["namespace"] == "nvidia-gpu-operator": continue
    for c in p["spec"].get("containers", []):
        r = c.get("resources", {})
        if any(k.startswith("nvidia.com/") for k in list(r.get("limits", {})) + list(r.get("requests", {}))):
            counts[node] += 1
            break
for n in nodes:
    note = "  <- idle, free to borrow" if counts[n] == 0 else ""
    print("     %-22s %d GPU pod(s) to evict%s" % (n, counts[n], note))
' 2>/dev/null || warn "Could not list pods cluster-wide"
  info "Switching a node is a label flip, but every GPU-holding pod must leave first."
fi

echo ""
echo "=== 9. Your permissions ==="
echo "   setup (admin):"
report_can "patch clusterpolicies.nvidia.com"  patch clusterpolicies.nvidia.com
report_can "patch hyperconverged"              patch hyperconverged -n openshift-cnv
report_can "patch nodes (label a node)"        patch nodes
report_can "list pods cluster-wide"            list pods --all-namespaces
report_can "create pods (switch-test probe)"   create pods -n "${NAMESPACE}"
report_can "delete pods cluster-wide (drain)"  delete pods --all-namespaces
echo "   running the VM test in ${NAMESPACE}:"
report_can "create virtualmachines"            create virtualmachines.kubevirt.io -n "${NAMESPACE}"
report_can "create datavolumes"                create datavolumes.cdi.kubevirt.io -n "${NAMESPACE}"
report_can "create persistentvolumeclaims"     create persistentvolumeclaims -n "${NAMESPACE}"
report_can "virtctl ssh/console subresource"   get virtualmachineinstances/console -n "${NAMESPACE}"

CAN_VM="$(can_i create virtualmachines.kubevirt.io -n "${NAMESPACE}")"
CAN_ADMIN="$(can_i patch clusterpolicies.nvidia.com)"

# The repo convention is to run mutating commands with --as=system:admin. That
# is not a backdoor — it needs an explicit impersonate grant — but plenty of
# accounts that look read-only do hold one, so it is worth reporting as its own
# row rather than concluding "blocked" from the direct rights alone.
#
# Note that `oc auth can-i impersonate users` is misleading here: oc resolves
# "users" to the user.openshift.io group, while Kubernetes impersonation is
# checked against "users" in the core group. The reliable test is to make an
# impersonated request and see whether it is refused.
IMPERSONATE="${AS_ADMIN:-}"
if [ -n "${IMPERSONATE}" ]; then
  echo "   as ${IMPERSONATE}:"
  if IMP_OUT="$(oc get nodes ${IMPERSONATE} 2>&1 >/dev/null)"; then
    pass "impersonation works — you can act as ${IMPERSONATE#--as=}"
    report_can "patch clusterpolicies.nvidia.com" patch clusterpolicies.nvidia.com ${IMPERSONATE}
    report_can "patch hyperconverged"             patch hyperconverged -n openshift-cnv ${IMPERSONATE}
    report_can "patch nodes"                      patch nodes ${IMPERSONATE}
    report_can "create virtualmachines"           create virtualmachines.kubevirt.io -n "${NAMESPACE}" ${IMPERSONATE}
    CAN_ADMIN=yes
    CAN_VM=yes
  else
    warn "impersonation refused: ${IMP_OUT}"
  fi
else
  info "(set AS_ADMIN=--as=system:admin to also report what impersonation buys you)"
fi

[ "${CAN_VM}" = "yes" ] || blocker "Cannot create VirtualMachines in ${NAMESPACE} — test-gpu-vm.sh has nowhere to run. Try AS_ADMIN=--as=system:admin, or get edit rights on a namespace."
[ "${CAN_ADMIN}" = "yes" ] || blocker "Cannot patch ClusterPolicy — setup-passthrough.sh APPLY=1 and test-gpu-switch.sh need an account that can, or a working impersonate grant."

echo ""
echo "========================================="
echo "  ${PASSED} checks passed, ${FAILED} failed"
echo "========================================="

if [ -z "${BLOCKERS}" ]; then
  echo "✅ This cluster looks ready. Next:"
  echo "     NODE=<idle gpu node> ./setup-passthrough.sh            # report only"
  echo "     NODE=<idle gpu node> APPLY=1 ./setup-passthrough.sh"
  echo "     ./test-gpu-vm.sh"
else
  echo "Blockers, in the order they have to be cleared:"
  printf '%s' "${BLOCKERS}"
  echo ""
  echo "Nothing above was changed — this script only reads."
fi
