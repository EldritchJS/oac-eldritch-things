#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# COSTS MONEY. This creates a user-space workload that CLAIMS a GPU, and the
# MOC bill is driven by claimed GPUs -- idle or not, pod or VM. Delete the
# workload when you are done; do not leave it running overnight.
#
# Free by comparison: tests/verify.sh (T-06/T-07 only read node state) and
# gpu-switch-timing.sh / preflight.sh, which refuse to run if anything is
# already holding a GPU and never add a claim themselves.
# ---------------------------------------------------------------------------

# Automated proof that a VM on OpenShift Virtualization can be given a whole
# physical NVIDIA GPU by PCI passthrough, and that the guest can actually use it
# for CUDA compute.
#
# The verification is tiered, because the three things being claimed fail
# independently and a partial result is still worth having:
#
#   tier 1  the device is present on the guest's PCI bus
#           (passthrough plumbing works: vfio, IOMMU, permittedHostDevices)
#   tier 2  the in-guest NVIDIA driver binds it and nvidia-smi reports the card
#           (the device is functional, not just visible)
#   tier 3  a CUDA kernel runs on it and returns correct results
#           (the GPU does real work, and we get a host-to-device bandwidth
#           number across the passthrough path)
#
# Each tier is its own pass/fail line. When one fails the higher tiers are
# reported as skipped rather than failed, so the output says how far the
# platform got rather than just "no".
#
# Runs as the logged-in project user. The node must already be in passthrough
# mode — that part is admin work, see setup-passthrough.sh.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-gpu-test-vm}"
DV_NAME="${DV_NAME:-${VM_NAME}-rootdisk}"

# Resource name the NVIDIA sandbox device plugin advertises, e.g.
# nvidia.com/GH100_H100_SXM5_80GB. Discovered from the nodes when unset.
GPU_RESOURCE="${GPU_RESOURCE:-}"
GPU_COUNT="${GPU_COUNT:-1}"

# Ubuntu rather than the Fedora the other vm-testing scripts use. Ubuntu ships
# NVIDIA's datacenter drivers in its own archive, so tier 2 is one apt install
# with no third-party repo and no akmod rebuild against a moving kernel. Set
# IMAGE_URL/GUEST_USER/DRIVER_INSTALL to use something else.
IMAGE_URL="${IMAGE_URL:-docker://quay.io/containerdisks/ubuntu:24.04}"
GUEST_USER="${GUEST_USER:-ubuntu}"
DRIVER_BRANCH="${DRIVER_BRANCH:-580}"

# Bigger than the other tests': the guest holds a distro, a driver and (for
# tier 3) the CUDA toolkit.
DISK_SIZE="${DISK_SIZE:-40Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
ACCESS_MODE="${ACCESS_MODE:-}"

# How the root disk is backed:
#
#   dv             CDI imports the image into a PVC. Persistent, survives a
#                  reboot, and needs a StorageClass.
#   containerdisk  the image is pulled straight onto the node and the guest
#                  writes to an ephemeral overlay. Needs no storage at all.
#
# Nothing this test proves depends on persistence — it boots a VM, checks a
# GPU, and deletes the VM — so a cluster with no StorageClass is not a reason
# to be unable to answer the question. Left unset, this picks containerdisk
# when the cluster has no default StorageClass and dv otherwise.
BOOT_MODE="${BOOT_MODE:-}"

# Every byte of this is pinned in host RAM for the life of the VM — VFIO DMA
# needs all guest pages present, so none of it is overcommittable.
MEMORY="${MEMORY:-16Gi}"
CPU_CORES="${CPU_CORES:-8}"

MAX_TIER="${MAX_TIER:-3}"      # stop after this tier; 2 skips the CUDA toolkit
DV_TIMEOUT="${DV_TIMEOUT:-900}"
DV_STALL="${DV_STALL:-240}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600s}"
SCHED_GRACE="${SCHED_GRACE:-60}"   # seconds before an unscheduled VMI is diagnosed
POLL_ATTEMPTS="${POLL_ATTEMPTS:-40}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
SSH_TIMEOUT="${SSH_TIMEOUT:-45}"
# Driver and toolkit installs are long and talk to the network.
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-1500}"
KEEP_VM="${KEEP_VM:-0}"

WORKDIR=""
PASSED=0
FAILED=0

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }
skip() { echo "  ⏭️  $1"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_VM}" = "1" ]; then
    echo "KEEP_VM=1, leaving vm/${VM_NAME} and dv/${DV_NAME} in place. Delete with:"
    echo "  oc delete vm ${VM_NAME} dv ${DV_NAME} -n ${NAMESPACE}"
    echo ""
    echo "A VM holding a GPU keeps that GPU out of every other pool until it is"
    echo "deleted — the device is bound to this guest, not time-shared."
  else
    oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
    oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
  fi
  [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  echo "Done!"
}

run_with_timeout() {
  local secs="$1"; shift
  local rc=0 pid watcher
  "$@" & pid=$!
  ( sleep "${secs}"; kill -9 "${pid}" 2>/dev/null ) & watcher=$!
  wait "${pid}" 2>/dev/null || rc=$?
  kill "${watcher}" 2>/dev/null || true
  wait "${watcher}" 2>/dev/null || true
  return "${rc}"
}

echo "========================================="
echo "  GPU Passthrough VM Test"
echo "  Namespace:  ${NAMESPACE}"
echo "  VM:         ${VM_NAME}"
echo "  Guest:      ${IMAGE_URL}"
echo "  Max tier:   ${MAX_TIER}"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc virtctl ssh-keygen python3; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "❌ Required binary '${bin}' not found in PATH."
    if [ "${bin}" = "virtctl" ]; then
      echo "   Get the download URL with:"
      echo "   oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'"
    fi
    exit 1
  fi
done

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "❌ Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

# Find a node advertising a passthrough GPU. The resource is device-specific
# (nvidia.com/GH100_H100_SXM5_80GB and the like) rather than the nvidia.com/gpu
# that container workloads request, so looking for the latter finds nothing.
echo "Looking for nodes in GPU passthrough mode..."
PASSTHROUGH_REPORT="$(oc get nodes -o json 2>/dev/null | python3 -c '
import json, sys
try:
    nodes = json.load(sys.stdin)["items"]
except Exception:
    sys.exit(0)
for n in nodes:
    name = n["metadata"]["name"]
    alloc = n.get("status", {}).get("allocatable", {})
    for k, v in sorted(alloc.items()):
        if k.startswith("nvidia.com/") and k != "nvidia.com/gpu" and "mig-" not in k:
            print(f"{name}\t{k}\t{v}")
' 2>/dev/null || true)"

if [ -n "${PASSTHROUGH_REPORT}" ]; then
  echo "${PASSTHROUGH_REPORT}" | sed 's/^/  /'
else
  echo "  (none)"
fi

if [ -z "${GPU_RESOURCE}" ]; then
  GPU_RESOURCE="$(printf '%s' "${PASSTHROUGH_REPORT}" | awk 'NR==1{print $2}')"
fi

if [ -z "${GPU_RESOURCE}" ]; then
  echo "❌ No node is advertising a passthrough GPU resource."
  echo ""
  echo "   Container-mode GPU capacity on this cluster, for contrast:"
  oc get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NODE:.metadata.name,NVIDIA.COM/GPU:.status.allocatable.nvidia\.com/gpu,WORKLOAD:.metadata.labels.nvidia\.com/gpu\.workload\.config' \
    2>/dev/null | sed 's/^/     /' || true
  echo ""
  echo "   A node has to be put into passthrough mode before a VM can be given a"
  echo "   GPU, and that is a per-node, admin-only change that takes the node out"
  echo "   of the container GPU pool:"
  echo "     NODE=<node> ./setup-passthrough.sh            # report what it would do"
  echo "     NODE=<node> APPLY=1 ./setup-passthrough.sh    # do it"
  exit 1
fi

GPU_AVAILABLE="$(printf '%s' "${PASSTHROUGH_REPORT}" | awk -v r="${GPU_RESOURCE}" '$2==r{s+=$3} END{print s+0}')"
echo "GPU resource: ${GPU_RESOURCE} (${GPU_AVAILABLE} allocatable cluster-wide)"

if [ "${GPU_AVAILABLE}" -lt "${GPU_COUNT}" ] 2>/dev/null; then
  echo "❌ Asked for ${GPU_COUNT} x ${GPU_RESOURCE} but only ${GPU_AVAILABLE} are allocatable."
  exit 1
fi

# KubeVirt's webhook rejects a VM requesting a host device that is not in the
# permitted list, and the rejection message is terse. Catch it here instead.
# HyperConverged v1 moved permittedHostDevices under .spec.virtualization while
# v1beta1 keeps it top-level, and both are served — query both layouts.
PERMITTED="$(oc get hyperconverged -A -o jsonpath='{.items[*].spec.permittedHostDevices.pciHostDevices}{.items[*].spec.virtualization.permittedHostDevices.pciHostDevices}' 2>/dev/null || echo "")"
if printf '%s' "${PERMITTED}" | grep -q "${GPU_RESOURCE}"; then
  echo "KubeVirt permits ${GPU_RESOURCE}: yes"
else
  echo "❌ ${GPU_RESOURCE} is advertised by the device plugin but is NOT in"
  echo "   HyperConverged .spec.permittedHostDevices — KubeVirt will reject the VM."
  echo "   An admin adds it with:"
  echo "     NODE=<node> APPLY=1 ./setup-passthrough.sh"
  exit 1
fi

for kind in vm dv; do
  if oc get "${kind}" "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 \
     || oc get "${kind}" "${DV_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "❌ Leftover ${kind} from a previous run exists in ${NAMESPACE}. Remove it first:"
    echo "   oc delete vm ${VM_NAME} dv ${DV_NAME} -n ${NAMESPACE} --ignore-not-found"
    exit 1
  fi
done
echo "no leftover objects from a previous run"

trap cleanup EXIT

WORKDIR="$(mktemp -d "/tmp/${VM_NAME}-gputest.XXXXXX")"
SSH_KEY="${WORKDIR}/id_ecdsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "${SSH_KEY}" -C "gputest"
SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

echo ""
echo "=== 1. Provisioning a root disk ==="

if [ -z "${BOOT_MODE}" ]; then
  DEFAULT_SC="$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || echo "")"
  if [ -n "${STORAGE_CLASS}" ] || [ -n "${DEFAULT_SC}" ]; then
    BOOT_MODE="dv"
  else
    BOOT_MODE="containerdisk"
  fi
fi

# containerDisk takes a plain image reference; the DataVolume source wants the
# docker:// transport prefix. Derive one from the other so IMAGE_URL stays the
# single place the image is named.
CONTAINER_IMAGE="${IMAGE_URL#docker://}"

if [ "${BOOT_MODE}" = "containerdisk" ]; then
  echo "boot mode: containerdisk (${CONTAINER_IMAGE})"
  if [ -z "$(oc get sc -o name 2>/dev/null)" ]; then
    echo "  no StorageClass on this cluster — a PVC-backed root disk is not possible here."
  fi
  echo "  The guest's root filesystem is an ephemeral overlay on the node: it is"
  echo "  discarded when the VM stops, and the driver and CUDA toolkit installed"
  echo "  during this test are downloaded fresh on every run. Fine for a GPU"
  echo "  check, useless for anything that has to persist."
  # Measured on jetty (CNV 4.22.9, 2026-10-01), isolated to a single variable:
  # a containerDisk VM boots fine, and the same VM with a GPU added reproducibly
  # hangs with "containerdisk rootdisk still not ready after one minute" while
  # the container-disk sidecar exits after ~6s saying its socket "does not exist
  # anymore". Not memory (reproduced at 2Gi), not SELinux (no AVC denials), not
  # QoS (Burstable either way). Cause unknown; the combination simply does not
  # work there. A PVC-backed root disk is the supported path for GPU VMs.
  warn "containerDisk + PCI passthrough is known to fail on CNV 4.22.9"
  echo "     A VM with a GPU hangs before the guest starts. Without a GPU it boots fine."
  echo "     If this run hangs at 'Waiting for VMI to appear', that is what happened."
  echo "     The fix is a StorageClass, so the root disk can be a PVC:"
  echo "       BOOT_MODE=dv STORAGE_CLASS=<sc> ./$(basename "$0")"
  pass "root disk will be an ephemeral containerDisk (no storage required)"
else
  echo "boot mode: dv (CDI import into a PVC)"

{
  echo "apiVersion: cdi.kubevirt.io/v1beta1"
  echo "kind: DataVolume"
  echo "metadata:"
  echo "  name: ${DV_NAME}"
  echo "  namespace: ${NAMESPACE}"
  echo "spec:"
  echo "  source:"
  echo "    registry:"
  echo "      url: ${IMAGE_URL}"
  echo "      pullMethod: node"
  echo "  storage:"
  [ -n "${STORAGE_CLASS}" ] && echo "    storageClassName: ${STORAGE_CLASS}"
  [ -n "${ACCESS_MODE}" ] && { echo "    accessModes:"; echo "    - ${ACCESS_MODE}"; }
  echo "    resources:"
  echo "      requests:"
  echo "        storage: ${DISK_SIZE}"
} > "${WORKDIR}/dv.yaml"

oc apply -n "${NAMESPACE}" -f "${WORKDIR}/dv.yaml"

echo ""
echo "Waiting up to ${DV_TIMEOUT}s for the disk to provision (stall limit ${DV_STALL}s)..."
DV_PHASE=""
DV_STALLED=0
LAST_STATE=""
LAST_CHANGE=$(date +%s)
DEADLINE=$(( $(date +%s) + DV_TIMEOUT ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  DV_PHASE="$(oc get dv "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  case "${DV_PHASE}" in
    Succeeded|Failed) break ;;
  esac
  DV_PROGRESS="$(oc get dv "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")"
  echo "  phase=${DV_PHASE:-<none>} progress=${DV_PROGRESS:-n/a}"
  STATE="${DV_PHASE}/${DV_PROGRESS}"
  if [ "${STATE}" != "${LAST_STATE}" ]; then
    LAST_STATE="${STATE}"
    LAST_CHANGE=$(date +%s)
  elif [ $(( $(date +%s) - LAST_CHANGE )) -ge "${DV_STALL}" ]; then
    echo "  no progress for ${DV_STALL}s — treating as stalled"
    DV_STALLED=1
    break
  fi
  sleep 5
done

if [ "${DV_PHASE}" = "Succeeded" ]; then
  pass "CDI provisioned the root disk"
else
  fail "CDI provisioned the root disk ($([ "${DV_STALLED}" = "1" ] && echo "stalled in ${DV_PHASE:-<none>}" || echo "phase ${DV_PHASE:-<none>}"))"
  echo ""
  echo "PVC events:"
  oc describe pvc "${DV_NAME}" -n "${NAMESPACE}" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/  /' || true
  exit 1
fi
fi   # end BOOT_MODE=dv

echo ""
echo "=== 2. Booting the VM with ${GPU_COUNT} x ${GPU_RESOURCE} ==="

cat > "${WORKDIR}/user-data" <<EOF
#cloud-config
users:
  - name: ${GUEST_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
ssh_pwauth: false
EOF

# The driver install is deliberately NOT in cloud-init: inline userdata is
# capped at 2048 bytes and these namespaces cannot create secrets, so anything
# substantial has to go over ssh after boot instead.
UD_BYTES=$(wc -c < "${WORKDIR}/user-data" | tr -d ' ')
if [ "${UD_BYTES}" -gt 2048 ]; then
  echo "❌ Error: userdata is ${UD_BYTES} bytes, over the 2048-byte inline cap."
  exit 1
fi
USERDATA_BLOCK="$(sed 's/^/            /' "${WORKDIR}/user-data")"

GPU_BLOCK=""
for i in $(seq 1 "${GPU_COUNT}"); do
  GPU_BLOCK="${GPU_BLOCK}          - deviceName: ${GPU_RESOURCE}
            name: gpu$((i - 1))
"
done

# evictionStrategy: None, not LiveMigrate. A VM holding a host device cannot
# live migrate — the device's state has nowhere to go — so asking for migration
# on eviction would leave a node drain blocked on something that can never
# succeed. None says the truth out loud: draining this node kills this guest.
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
    spec:
      evictionStrategy: None
      tolerations:
      - key: nvidia.com/gpu.product
        operator: Exists
        effect: NoSchedule
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      domain:
        # q35 gives the guest a PCIe root complex. The i440fx default is
        # legacy PCI only, which a passed-through PCIe device cannot use.
        machine:
          type: q35
        cpu:
          cores: ${CPU_CORES}
        memory:
          guest: ${MEMORY}
        devices:
          gpus:
${GPU_BLOCK}          disks:
          - disk:
              bus: virtio
            name: rootdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          interfaces:
          - name: default
            masquerade: {}
          rng: {}
        resources:
          requests:
            memory: ${MEMORY}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
$(if [ "${BOOT_MODE}" = "containerdisk" ]; then
    echo "        containerDisk:"
    echo "          image: ${CONTAINER_IMAGE}"
  else
    echo "        persistentVolumeClaim:"
    echo "          claimName: ${DV_NAME}"
  fi)
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
${USERDATA_BLOCK}
EOF

echo "Waiting for VMI to appear..."
for i in $(seq 1 30); do
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && break
  sleep 2
done

# A GPU VM that cannot be placed sits Pending until BOOT_TIMEOUT with no
# explanation. Check early and surface the scheduler's own reason, which is
# almost always "Insufficient nvidia.com/<DEVICE>".
sleep "${SCHED_GRACE}"
VMI_PHASE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
if [ "${VMI_PHASE}" = "Pending" ] || [ "${VMI_PHASE}" = "Scheduling" ]; then
  echo "VMI is still ${VMI_PHASE} after ${SCHED_GRACE}s — virt-launcher pod events:"
  LAUNCHER="$(oc get pods -n "${NAMESPACE}" -l "kubevirt.io/vm=${VM_NAME}" -o name 2>/dev/null | head -1 || true)"
  [ -n "${LAUNCHER}" ] && oc describe "${LAUNCHER}" -n "${NAMESPACE}" 2>/dev/null \
    | sed -n '/Events:/,$p' | sed 's/^/  /' || true
fi

if oc wait --for=condition=Ready "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout="${BOOT_TIMEOUT}"; then
  pass "VM booted and reached Ready with the GPU attached"
else
  fail "VM booted and reached Ready"
  echo ""
  echo "VMI conditions:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null || true
  exit 1
fi

NODE_NAME="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
echo "VMI is on node: ${NODE_NAME:-unknown}"

# KubeVirt records the host devices it actually handed over, which is a
# stronger statement than "the VM has a gpus: stanza in its spec".
ATTACHED="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{range .status.deviceStatus.gpuStatuses[*]}{.name}{" "}{end}' 2>/dev/null || echo "")"
if [ -n "${ATTACHED}" ]; then
  pass "KubeVirt reports the GPU(s) attached to the VMI: ${ATTACHED}"
else
  # deviceStatus is a newer field; its absence is not itself a failure, the
  # in-guest tiers below are the real evidence.
  warn "VMI does not report deviceStatus.gpuStatuses (older KubeVirt) — relying on the in-guest checks"
fi

SSH_HELP="$(virtctl ssh --help 2>&1 || true)"
SSH_OPTS=(-i "${SSH_KEY}")
if printf '%s' "${SSH_HELP}" | grep -q -- '--local-ssh-opts'; then
  SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
fi
if printf '%s' "${SSH_HELP}" | grep -q -- '--known-hosts'; then
  : > "${WORKDIR}/known_hosts"
  SSH_OPTS+=(--known-hosts "${WORKDIR}/known_hosts")
fi
if printf '%s' "${SSH_HELP}" | grep -qE -- '--local-ssh([^-]|$)'; then
  SSH_OPTS+=(--local-ssh=true)
fi

SSH_TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
SSH_LOG="${WORKDIR}/ssh.log"
SSH_OUT=""

guest_ssh() { # guest_ssh <remote command> [timeout]
  local t="${2:-${SSH_TIMEOUT}}"
  SSH_OUT=""
  if run_with_timeout "${t}" virtctl ssh "${SSH_OPTS[@]}" -c "$1" "${SSH_TARGET}" \
       < /dev/null > "${SSH_LOG}" 2>&1; then
    SSH_OUT="$(grep -v 'different from the KubeVirt version\|^Client Version:\|^Server Version:\|Permanently added\|^Warning: ' "${SSH_LOG}" || true)"
    return 0
  fi
  return 1
}

echo ""
echo "=== 3. Reaching the guest ==="
GUEST_UP=0
for i in $(seq 1 "${POLL_ATTEMPTS}"); do
  if guest_ssh "echo GUEST_SSH_READY" && printf '%s' "${SSH_OUT}" | grep -q GUEST_SSH_READY; then
    echo "Guest SSH is up after ${i} attempt(s)."
    GUEST_UP=1
    break
  fi
  echo "Waiting for guest SSH (attempt ${i}/${POLL_ATTEMPTS})..."
  sleep "${POLL_INTERVAL}"
done

if [ "${GUEST_UP}" = "1" ]; then
  pass "Guest reachable over SSH"
else
  fail "Guest reachable over SSH"
  cat "${SSH_LOG}" 2>/dev/null || true
  exit 1
fi

guest_ssh '. /etc/os-release; echo "$PRETTY_NAME"; uname -r' || true
echo "Guest: ${SSH_OUT}"

echo ""
echo "=== 4. Tier 1 — the GPU is on the guest's PCI bus ==="

# Read sysfs rather than shelling out to lspci: pciutils is not in every cloud
# image, and /sys/bus/pci/devices is always there. 0x10de is NVIDIA; class
# 0x030000 is a VGA controller and 0x030200 a 3D controller, which is what a
# datacenter card without a display output reports.
TIER1_CMD='
found=0
for d in /sys/bus/pci/devices/*; do
  v=$(cat "$d/vendor" 2>/dev/null) || continue
  [ "$v" = "0x10de" ] || continue
  c=$(cat "$d/class" 2>/dev/null)
  case "$c" in 0x0300*|0x0302*) ;; *) continue ;; esac
  found=$((found+1))
  echo "GPU_PCI $(basename "$d") device=$(cat "$d/device" 2>/dev/null) class=$c driver=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
done
echo "GPU_PCI_COUNT=$found"
'
TIER1_OK=0
if guest_ssh "${TIER1_CMD}"; then
  echo "${SSH_OUT}" | sed 's/^/  /'
  SEEN="$(printf '%s' "${SSH_OUT}" | sed -n 's/^GPU_PCI_COUNT=//p' | tr -d '[:space:]')"
  if [ "${SEEN:-0}" -ge "${GPU_COUNT}" ] 2>/dev/null; then
    pass "Tier 1 — guest sees ${SEEN} NVIDIA GPU(s) on its PCI bus (asked for ${GPU_COUNT})"
    TIER1_OK=1
  else
    fail "Tier 1 — guest sees ${SEEN:-0} NVIDIA GPU(s), expected ${GPU_COUNT}"
  fi
else
  fail "Tier 1 — could not enumerate the guest PCI bus"
fi

echo ""
echo "=== 5. Tier 2 — the driver binds it and nvidia-smi works ==="

TIER2_OK=0
if [ "${TIER1_OK}" != "1" ]; then
  skip "Tier 2 — skipped, the device is not visible to the guest"
elif [ "${MAX_TIER}" -lt 2 ]; then
  skip "Tier 2 — skipped (MAX_TIER=${MAX_TIER})"
else
  echo "Installing the NVIDIA driver in the guest (several minutes)..."
  # Try the pinned server branch first for a reproducible result, then fall
  # back to ubuntu-drivers, which picks whatever branch the archive currently
  # recommends for this card.
  INSTALL_CMD="${DRIVER_INSTALL:-}"
  if [ -z "${INSTALL_CMD}" ]; then
    INSTALL_CMD="set -x
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \"linux-headers-\$(uname -r)\" || true
sudo apt-get install -y -qq nvidia-driver-${DRIVER_BRANCH}-server \
  || { sudo apt-get install -y -qq ubuntu-drivers-common && sudo ubuntu-drivers install --gpgpu; }
sudo modprobe nvidia || true"
  fi
  if guest_ssh "${INSTALL_CMD}" "${INSTALL_TIMEOUT}"; then
    echo "  driver install finished"
  else
    echo "  driver install command returned non-zero; checking nvidia-smi anyway"
  fi
  tail -20 "${SSH_LOG}" 2>/dev/null | sed 's/^/    /' || true

  if guest_ssh 'nvidia-smi --query-gpu=name,memory.total,driver_version,pci.bus_id --format=csv,noheader 2>&1' 120; then
    echo "${SSH_OUT}" | sed 's/^/  /'
    if printf '%s' "${SSH_OUT}" | grep -qiE 'NVIDIA|H100|A100|L40'; then
      pass "Tier 2 — nvidia-smi reports the card from inside the guest"
      TIER2_OK=1
    else
      fail "Tier 2 — nvidia-smi ran but did not report a GPU"
    fi
  else
    fail "Tier 2 — nvidia-smi did not run in the guest"
    tail -30 "${SSH_LOG}" 2>/dev/null | sed 's/^/    /' || true
  fi
fi

echo ""
echo "=== 6. Tier 3 — CUDA compute ==="

if [ "${TIER2_OK}" != "1" ]; then
  skip "Tier 3 — skipped, no working driver to run CUDA against"
elif [ "${MAX_TIER}" -lt 3 ]; then
  skip "Tier 3 — skipped (MAX_TIER=${MAX_TIER})"
else
  # SAXPY over 256 MiB buffers: big enough that the host-to-device copy is a
  # meaningful bandwidth sample across the passthrough path, small enough to
  # fit anywhere. The result check is exact — 3*1 + 2 is 5 in float with no
  # rounding — so any mismatch is a real fault, not numerical noise.
  cat > "${WORKDIR}/gpucheck.cu" <<'CUEOF'
#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>

__global__ void saxpy(size_t n, float a, const float *x, float *y) {
  size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
  if (i < n) y[i] = a * x[i] + y[i];
}

int main(void) {
  int count = 0;
  if (cudaGetDeviceCount(&count) != cudaSuccess || count < 1) {
    printf("CUDA_FAIL no devices\n");
    return 1;
  }
  cudaDeviceProp p;
  if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) {
    printf("CUDA_FAIL properties\n");
    return 1;
  }
  printf("CUDA_DEVICES %d\n", count);
  printf("CUDA_DEVICE %s sm_%d%d %.0fGiB\n", p.name, p.major, p.minor,
         p.totalGlobalMem / 1073741824.0);

  const size_t n = 1u << 26;            /* 64 Mi floats = 256 MiB per buffer */
  const size_t bytes = n * sizeof(float);
  float *hx = (float *)malloc(bytes), *hy = (float *)malloc(bytes);
  if (!hx || !hy) { printf("CUDA_FAIL host alloc\n"); return 1; }
  for (size_t i = 0; i < n; i++) { hx[i] = 1.0f; hy[i] = 2.0f; }

  float *dx = NULL, *dy = NULL;
  if (cudaMalloc(&dx, bytes) != cudaSuccess || cudaMalloc(&dy, bytes) != cudaSuccess) {
    printf("CUDA_FAIL device alloc\n");
    return 1;
  }

  cudaEvent_t s, e;
  cudaEventCreate(&s); cudaEventCreate(&e);
  cudaEventRecord(s);
  cudaMemcpy(dx, hx, bytes, cudaMemcpyHostToDevice);
  cudaMemcpy(dy, hy, bytes, cudaMemcpyHostToDevice);
  cudaEventRecord(e);
  cudaEventSynchronize(e);
  float ms = 0.0f;
  cudaEventElapsedTime(&ms, s, e);
  printf("CUDA_H2D %.2f GB/s\n", (2.0 * bytes / 1e9) / (ms / 1000.0));

  saxpy<<<(unsigned)((n + 255) / 256), 256>>>(n, 3.0f, dx, dy);
  if (cudaDeviceSynchronize() != cudaSuccess) {
    printf("CUDA_FAIL kernel %s\n", cudaGetErrorString(cudaGetLastError()));
    return 1;
  }
  cudaMemcpy(hy, dy, bytes, cudaMemcpyDeviceToHost);

  size_t bad = 0;
  for (size_t i = 0; i < n; i++) if (hy[i] != 5.0f) bad++;
  if (bad == 0) printf("CUDA_COMPUTE_OK %zu elements\n", n);
  else          printf("CUDA_FAIL %zu wrong elements\n", bad);
  return bad == 0 ? 0 : 1;
}
CUEOF

  SCP_OPTS=("${SSH_OPTS[@]}")
  echo "Copying the CUDA test program into the guest..."
  if run_with_timeout "${SSH_TIMEOUT}" virtctl scp "${SCP_OPTS[@]}" \
       "${WORKDIR}/gpucheck.cu" "${SSH_TARGET}:/tmp/gpucheck.cu" \
       < /dev/null > "${WORKDIR}/scp.log" 2>&1; then
    echo "  copied"
  else
    echo "  scp failed:"
    cat "${WORKDIR}/scp.log" 2>/dev/null | sed 's/^/    /' || true
  fi

  echo "Installing nvcc and building (this is the slow part)..."
  # Ubuntu's own nvidia-cuda-toolkit package rather than NVIDIA's network repo:
  # one well-known package name that tracks the distro, instead of a repo URL
  # and version-suffixed package names that change every CUDA release.
  guest_ssh "${CUDA_TOOLKIT_INSTALL:-export DEBIAN_FRONTEND=noninteractive; sudo apt-get install -y -qq nvidia-cuda-toolkit}" "${INSTALL_TIMEOUT}" \
    || echo "  toolkit install returned non-zero; trying to build anyway"

  if guest_ssh 'cd /tmp && nvcc -O2 -o gpucheck gpucheck.cu 2>&1 && ./gpucheck' 300; then
    echo "${SSH_OUT}" | sed 's/^/  /'
    if printf '%s' "${SSH_OUT}" | grep -q CUDA_COMPUTE_OK; then
      pass "Tier 3 — a CUDA kernel ran on the passed-through GPU and returned correct results"
      H2D="$(printf '%s' "${SSH_OUT}" | sed -n 's/^CUDA_H2D //p')"
      [ -n "${H2D}" ] && echo "     host-to-device bandwidth across the passthrough path: ${H2D}"
    else
      fail "Tier 3 — the CUDA program ran but did not report CUDA_COMPUTE_OK"
    fi
  else
    fail "Tier 3 — could not build or run the CUDA program"
    tail -30 "${SSH_LOG}" 2>/dev/null | sed 's/^/    /' || true
  fi
fi

echo ""
echo "=== 7. Informational ==="

# The headline operational consequence, and the one that contradicts what
# test-vm-migration.sh proves for an ordinary VM. Reported rather than asserted
# because it is a property of passthrough, not a defect.
MIGRATABLE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || echo "")"
MIG_REASON="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].reason}' 2>/dev/null || echo "")"
if [ "${MIGRATABLE}" = "False" ]; then
  echo "  ℹ️  LiveMigratable=False (${MIG_REASON:-no reason given}) — expected."
  echo "     A host device cannot be moved to another host, so this VM cannot"
  echo "     live migrate. Draining ${NODE_NAME:-its node} will kill the guest."
elif [ "${MIGRATABLE}" = "True" ]; then
  warn "LiveMigratable=True on a GPU VM — surprising; KubeVirt normally blocks this"
else
  warn "LiveMigratable=${MIGRATABLE:-<unset>}"
fi

if [ "${TIER2_OK}" = "1" ]; then
  # With fewer than the whole NVLink clique passed through, the peers are
  # missing and the links read as inactive. That is the thing to know before
  # anyone tries a multi-GPU job inside a VM.
  if guest_ssh 'nvidia-smi nvlink -s 2>&1 | head -20' 60; then
    echo "  NVLink status in guest:"
    echo "${SSH_OUT}" | sed 's/^/     /'
  fi
  if guest_ssh 'nvidia-smi topo -m 2>&1 | head -12' 60; then
    echo "  Topology in guest:"
    echo "${SSH_OUT}" | sed 's/^/     /'
  fi
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "✅ VERIFICATION SUCCESS: a VM was given a physical NVIDIA GPU by PCI"
  echo "   passthrough and ran CUDA on it."
else
  echo "❌ VERIFICATION FAILED: see the ❌ lines above."
  echo ""
  echo "VMI status:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo ""
  echo "Re-run with KEEP_VM=1 to keep the VM for console access:"
  echo "  KEEP_VM=1 ./$(basename "$0")"
  echo "  virtctl console ${VM_NAME} -n ${NAMESPACE}"
  exit 1
fi
