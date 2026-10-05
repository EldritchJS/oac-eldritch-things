#!/usr/bin/env bash
set -euo pipefail

# Automated proof that a VM on OpenShift Virtualization can be given persistent
# storage: CDI provisions a root disk from a golden image, the VM boots off that
# PVC, and data written inside the guest survives a full stop/start cycle.
#
# This is the storage counterpart to test-vm.sh, which boots from an ephemeral
# containerDisk and so proves nothing about persistence.
#
# Results come back over `virtctl ssh`, the same channel test-vm.sh uses.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-pvc-test-vm}"
DV_NAME="${DV_NAME:-${VM_NAME}-rootdisk}"

# Where the root disk comes from:
#   registry   — CDI imports a container disk into a fresh PVC (default)
#   datasource — CDI clones one of the SSP golden images, which is the path the
#                console's "Create VM from template" button takes
#
# registry is the default because cloning is broken on pure-fb-nfsv4: the Pure
# CSI driver rejects csi-clone with "volume cloning is not supported for
# FlashBlade", and the host-assisted fallback dies untarring onto the target.
# Run with SOURCE_MODE=datasource to re-test cloning once that is fixed.
SOURCE_MODE="${SOURCE_MODE:-registry}"
IMAGE_URL="${IMAGE_URL:-docker://quay.io/containerdisks/fedora:41}"
DATA_SOURCE="${DATA_SOURCE:-fedora}"
DATA_SOURCE_NS="${DATA_SOURCE_NS:-openshift-virtualization-os-images}"
GUEST_USER="${GUEST_USER:-fedora}"   # cloud-user for the rhel* images

# Empty means "let CDI pick from the StorageProfile", which is what a real user
# gets. Set them to assert a specific class or mode instead.
DISK_SIZE="${DISK_SIZE:-10Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
ACCESS_MODE="${ACCESS_MODE:-}"

MEMORY="${MEMORY:-2Gi}"
CPU_CORES="${CPU_CORES:-1}"

DV_TIMEOUT="${DV_TIMEOUT:-900}"      # seconds to wait for the disk to provision
# A broken clone or import does not set phase=Failed — it retry-loops forever,
# so the only signal is that nothing is moving. Give up after this long with no
# change in phase or progress and report why.
DV_STALL="${DV_STALL:-240}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300s}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-40}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
SSH_TIMEOUT="${SSH_TIMEOUT:-45}"
KEEP_VM="${KEEP_VM:-0}"              # set to 1 to leave the VM and disk for debugging

# Everything below runs as the logged-in user, with no system:admin
# impersonation, so the test reflects what a real project user can actually do.

WORKDIR=""
PASSED=0
FAILED=0

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_VM}" = "1" ]; then
    echo "KEEP_VM=1, leaving vm/${VM_NAME} and dv/${DV_NAME} in place. Delete with:"
    echo "  oc delete vm ${VM_NAME} -n ${NAMESPACE}"
    echo "  oc delete dv ${DV_NAME} -n ${NAMESPACE}"
  else
    oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
    # Deleting the DataVolume reclaims the PVC it provisioned.
    oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
  fi
  [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  echo "Done!"
}

# Portable timeout: macOS has no coreutils `timeout` by default.
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
echo "  VM Persistent Storage Test"
echo "  Namespace:   ${NAMESPACE}"
echo "  VM:          ${VM_NAME}"
echo "  Root disk:   ${DV_NAME} (${DISK_SIZE})"
if [ "${SOURCE_MODE}" = "datasource" ]; then
  echo "  Source:      clone of DataSource ${DATA_SOURCE_NS}/${DATA_SOURCE}"
else
  echo "  Source:      registry import of ${IMAGE_URL}"
fi
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc virtctl ssh-keygen; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "❌ Required binary '${bin}' not found in PATH."
    [ "${bin}" = "virtctl" ] && echo "   Download it from the OpenShift console (Command line tools) or:" \
      && echo "   oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'"
    exit 1
  fi
done

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "❌ Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

if [ "${SOURCE_MODE}" = "datasource" ]; then
  DS_READY="$(oc get datasource "${DATA_SOURCE}" -n "${DATA_SOURCE_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
  if [ "${DS_READY}" != "True" ]; then
    echo "❌ DataSource ${DATA_SOURCE_NS}/${DATA_SOURCE} is not Ready (got '${DS_READY:-not found}')."
    echo "   Available boot sources:"
    oc get datasource -n "${DATA_SOURCE_NS}" 2>/dev/null | sed 's/^/     /' || true
    exit 1
  fi
  echo "datasource ${DATA_SOURCE}: Ready"
elif [ "${SOURCE_MODE}" != "registry" ]; then
  echo "❌ SOURCE_MODE must be 'registry' or 'datasource' (got '${SOURCE_MODE}')."
  exit 1
fi

# Fail before creating anything if a previous run left objects behind; silently
# reusing them would let a stale disk pass the persistence check.
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

# Ephemeral keypair, thrown away on exit. ECDSA rather than RSA to stay under
# KubeVirt's 2048-byte inline userdata cap, and rather than ed25519 to match the
# key type test-vm.sh settled on for these guests.
WORKDIR="$(mktemp -d "/tmp/${VM_NAME}-storagetest.XXXXXX")"
SSH_KEY="${WORKDIR}/id_ecdsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "${SSH_KEY}" -C "storagetest"
SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

# Nonce proves the file read back after the restart is the one written before
# it, not a leftover from an earlier run or a fixture baked into the image.
PERSIST_TOKEN="persist-$(date +%s)-${RANDOM}"

echo ""
echo "=== 1. Provisioning a PVC-backed root disk (CDI) ==="

{
  echo "apiVersion: cdi.kubevirt.io/v1beta1"
  echo "kind: DataVolume"
  echo "metadata:"
  echo "  name: ${DV_NAME}"
  echo "  namespace: ${NAMESPACE}"
  echo "spec:"
  if [ "${SOURCE_MODE}" = "datasource" ]; then
    echo "  sourceRef:"
    echo "    kind: DataSource"
    echo "    name: ${DATA_SOURCE}"
    echo "    namespace: ${DATA_SOURCE_NS}"
  else
    echo "  source:"
    echo "    registry:"
    echo "      url: ${IMAGE_URL}"
    # node pull reuses the kubelet's registry credentials and trust, so the
    # importer does not need its own pull secret for the container disk.
    echo "      pullMethod: node"
  fi
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
    Succeeded) break ;;
    Failed)    break ;;
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
  pass "CDI provisioned the root disk (DataVolume Succeeded)"
else
  if [ "${DV_STALLED}" = "1" ]; then
    fail "CDI provisioned the root disk (stalled in ${DV_PHASE:-<none>})"
  else
    fail "CDI provisioned the root disk (DataVolume phase: ${DV_PHASE:-<none>})"
  fi
  echo ""
  echo "DataVolume conditions:"
  oc get dv "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null || true
  echo ""
  echo "PVC events:"
  oc describe pvc "${DV_NAME}" -n "${NAMESPACE}" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/  /' || true

  # The CDI worker pod usually carries the real error; the PVC events only say
  # it is waiting. Clone workers live in the source namespace, importers here.
  for ns in "${NAMESPACE}" "${DATA_SOURCE_NS}"; do
    for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E 'importer|source-pod|cdi-upload' || true); do
      echo ""
      echo "CDI worker log (${ns}/${pod##*/}):"
      oc logs "${pod}" -n "${ns}" --tail=20 2>/dev/null | sed 's/^/  /' || true
    done
  done

  echo ""
  echo "If the PVC never bound, the StorageClass may not support the requested"
  echo "access mode. Re-run with ACCESS_MODE=ReadWriteOnce to check."
  echo "If a clone stalled, the driver may not support cloning at all — the"
  echo "default SOURCE_MODE=registry imports instead and avoids that path."
  exit 1
fi

PVC_UID_BEFORE="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
PVC_PHASE="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
PVC_CAPACITY="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "")"
PVC_SC="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")"
PVC_MODES="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || echo "")"
PVC_VOLMODE="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeMode}' 2>/dev/null || echo "")"

echo ""
echo "  PVC:          ${DV_NAME}"
echo "  phase:        ${PVC_PHASE}"
echo "  capacity:     ${PVC_CAPACITY}"
echo "  storageClass: ${PVC_SC}"
echo "  accessModes:  ${PVC_MODES}"
echo "  volumeMode:   ${PVC_VOLMODE}"

if [ "${PVC_PHASE}" = "Bound" ]; then
  pass "PVC is Bound (${PVC_CAPACITY} on ${PVC_SC})"
else
  fail "PVC is Bound (phase: ${PVC_PHASE:-<none>})"
fi

echo ""
echo "=== 2. Booting the VM from the PVC ==="

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

UD_BYTES=$(wc -c < "${WORKDIR}/user-data" | tr -d ' ')
echo "cloud-init userdata: ${UD_BYTES} bytes (KubeVirt inline cap is 2048)"
if [ "${UD_BYTES}" -gt 2048 ]; then
  echo "❌ Error: userdata exceeds the inline limit."
  exit 1
fi

USERDATA_BLOCK="$(sed 's/^/            /' "${WORKDIR}/user-data")"

# evictionStrategy: LiveMigrate is the realistic setting for a VM on persistent
# RWX storage, and it makes the LiveMigratable condition meaningful — which is
# what the migration test will assert against.
#
# NOTE: as in test-vm.sh, deliberately no `ports:` list on the masquerade
# interface. Listing ports makes KubeVirt forward only those, silently blocking
# SSH on 22 and making every virtctl ssh/scp fail with "connection refused".
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
      evictionStrategy: LiveMigrate
      domain:
        cpu:
          cores: ${CPU_CORES}
        devices:
          disks:
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
        persistentVolumeClaim:
          claimName: ${DV_NAME}
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
${USERDATA_BLOCK}
EOF

wait_for_vmi_ready() { # wait_for_vmi_ready <label>
  echo "Waiting for VMI to appear ($1)..."
  for i in $(seq 1 30); do
    oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && break
    sleep 2
  done
  oc wait --for=condition=Ready "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout="${BOOT_TIMEOUT}"
}

wait_for_vmi_ready "first boot"

# Confirm the running VM is actually backed by the PVC rather than anything
# ephemeral — this is the assertion that separates this test from test-vm.sh.
BOOT_CLAIM="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.volumeStatus[?(@.name=="rootdisk")].persistentVolumeClaimInfo.claimName}' 2>/dev/null || echo "")"
if [ "${BOOT_CLAIM}" = "${DV_NAME}" ]; then
  pass "VM booted from the PVC (rootdisk -> ${BOOT_CLAIM})"
else
  fail "VM booted from the PVC (rootdisk claim: ${BOOT_CLAIM:-<none>}, expected ${DV_NAME})"
fi

NODE_BEFORE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
echo "VMI running on node: ${NODE_BEFORE:-unknown}"

# virtctl's SSH flags moved around between releases, so probe --help rather than
# assuming. The exact-match guard on --local-ssh matters: a plain substring test
# also matches --local-ssh-opts, and virtctl 1.9 has the latter but not the
# former, so a loose test passes an unknown flag and every call fails.
SSH_HELP="$(virtctl ssh --help 2>&1 || true)"
SSH_OPTS=(-i "${SSH_KEY}")
if printf '%s' "${SSH_HELP}" | grep -q -- '--local-ssh-opts'; then
  # Without these the local ssh binary aborts on the unknown host key. The VM is
  # new every run, so its key is never in known_hosts.
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

guest_ssh() { # guest_ssh <remote command>
  SSH_OUT=""
  if run_with_timeout "${SSH_TIMEOUT}" virtctl ssh "${SSH_OPTS[@]}" -c "$1" "${SSH_TARGET}" \
       < /dev/null > "${SSH_LOG}" 2>&1; then
    SSH_OUT="$(grep -v 'different from the KubeVirt version\|^Client Version:\|^Server Version:\|Permanently added\|^Warning: ' "${SSH_LOG}" || true)"
    return 0
  fi
  return 1
}

wait_for_guest_ssh() { # wait_for_guest_ssh <label>
  local i
  for i in $(seq 1 "${POLL_ATTEMPTS}"); do
    # cloud-init installs the key after boot, so the first attempts legitimately
    # fail with "Permission denied" rather than a connection error.
    if guest_ssh "echo GUEST_SSH_READY"; then
      if printf '%s' "${SSH_OUT}" | grep -q GUEST_SSH_READY; then
        echo "Guest SSH is up after ${i} attempt(s) ($1)."
        return 0
      fi
    fi
    echo "Waiting for guest SSH ($1, attempt ${i}/${POLL_ATTEMPTS})..."
    sleep "${POLL_INTERVAL}"
  done
  return 1
}

echo ""
echo "=== 3. Reaching the guest ==="
if wait_for_guest_ssh "first boot"; then
  pass "Guest reachable over SSH (cloud-init applied the key)"
else
  fail "Guest reachable over SSH"
  echo "Last ssh output:"
  cat "${SSH_LOG}" 2>/dev/null || true
  exit 1
fi

echo ""
echo "--- Guest disk layout ---"
guest_ssh 'echo "os: $(. /etc/os-release; echo $PRETTY_NAME)"; echo; df -h /; echo; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null' || true
echo "${SSH_OUT}"
echo "-------------------------"

echo ""
echo "=== 4. Writing data to the persistent disk ==="
MARKER_PATH="/home/${GUEST_USER}/persistence-check.txt"
echo "Writing ${PERSIST_TOKEN} to ${MARKER_PATH} ..."
if guest_ssh "printf '%s\n' '${PERSIST_TOKEN}' > ${MARKER_PATH} && sync && cat ${MARKER_PATH}" \
   && printf '%s' "${SSH_OUT}" | grep -q "${PERSIST_TOKEN}"; then
  pass "Wrote the marker to the guest filesystem and flushed it to disk"
else
  fail "Wrote the marker to the guest filesystem"
  cat "${SSH_LOG}" 2>/dev/null || true
fi

echo ""
echo "=== 5. Full stop/start cycle ==="
echo "Stopping vm/${VM_NAME} ..."
virtctl stop "${VM_NAME}" -n "${NAMESPACE}"

# Waiting for the VMI object to go away (not just the VM to report stopped)
# proves the guest and its virt-launcher pod were genuinely torn down, so the
# restart cannot be served from anything still in memory.
if oc wait --for=delete "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout=180s >/dev/null 2>&1; then
  pass "VM stopped cleanly (VMI and virt-launcher pod removed)"
else
  fail "VM stopped cleanly (VMI still present after 180s)"
fi

echo ""
echo "Starting vm/${VM_NAME} ..."
virtctl start "${VM_NAME}" -n "${NAMESPACE}"

if wait_for_vmi_ready "after restart"; then
  pass "VM restarted and reached Ready"
else
  fail "VM restarted and reached Ready"
fi

NODE_AFTER="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
echo "VMI now running on node: ${NODE_AFTER:-unknown} (was ${NODE_BEFORE:-unknown})"

PVC_UID_AFTER="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
if [ -n "${PVC_UID_BEFORE}" ] && [ "${PVC_UID_BEFORE}" = "${PVC_UID_AFTER}" ]; then
  pass "Same PVC reused across the restart (not reprovisioned)"
else
  fail "Same PVC reused across the restart (uid ${PVC_UID_BEFORE:-<none>} -> ${PVC_UID_AFTER:-<none>})"
fi

echo ""
echo "=== 6. Verifying the data survived ==="
if wait_for_guest_ssh "after restart"; then
  echo "Reading ${MARKER_PATH} back out of the guest..."
  FETCHED=""
  guest_ssh "cat ${MARKER_PATH} 2>/dev/null" && FETCHED="${SSH_OUT}"
  if printf '%s' "${FETCHED}" | grep -q "${PERSIST_TOKEN}"; then
    pass "Data survived the restart — read ${PERSIST_TOKEN} back from the disk"
  else
    fail "Data survived the restart — ${PERSIST_TOKEN} not found in ${MARKER_PATH}"
    echo "Got: ${FETCHED:-<nothing>}"
  fi
else
  fail "Guest reachable over SSH after restart"
fi

echo ""
echo "=== 7. Informational ==="

# Not pass/fail: the guest agent is a property of the image, and a missing agent
# does not mean persistent storage is broken. It is reported because the
# migration and console tests depend on it.
AGENT="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null || echo "")"
if [ "${AGENT}" = "True" ]; then
  GUEST_OS="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.guestOSInfo.prettyName}' 2>/dev/null || echo "")"
  echo "  ✅ qemu-guest-agent connected${GUEST_OS:+ (${GUEST_OS})}"
else
  warn "qemu-guest-agent not connected — virtctl guestosinfo and graceful shutdown hooks will not work"
fi

# The prerequisite the live-migration test will build on. RWX is what makes the
# disk movable between nodes; RWO would pin this VM to one host.
if printf '%s' "${PVC_MODES}" | grep -qw ReadWriteMany; then
  echo "  ✅ Root disk is ReadWriteMany — live migration is possible on this storage"
else
  warn "Root disk access mode is '${PVC_MODES}', not ReadWriteMany — this VM cannot live migrate"
fi

MIGRATABLE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || echo "")"
if [ "${MIGRATABLE}" = "True" ]; then
  echo "  ✅ VMI reports LiveMigratable=True"
else
  MIG_REASON="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].reason}{" "}{.status.conditions[?(@.type=="LiveMigratable")].message}' 2>/dev/null || echo "")"
  warn "VMI reports LiveMigratable=${MIGRATABLE:-<unset>}${MIG_REASON:+ — ${MIG_REASON}}"
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "✅ VERIFICATION SUCCESS: VMs get real persistent storage — a CDI-provisioned"
  echo "   PVC root disk survives a full VM stop/start with its data intact."
else
  echo "❌ VERIFICATION FAILED: see the ❌ lines above."
  echo ""
  echo "VMI status:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo ""
  echo "Re-run with KEEP_VM=1 to keep the VM and disk for console access:"
  echo "  KEEP_VM=1 ./$(basename "$0")"
  echo "  virtctl console ${VM_NAME} -n ${NAMESPACE}"
  exit 1
fi
