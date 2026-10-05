#!/usr/bin/env bash
set -euo pipefail

# Automated proof that a running VM can live migrate between nodes on OpenShift
# Virtualization without rebooting the guest.
#
# Live migration is what makes node maintenance survivable for VM users: drains,
# cluster upgrades and MachineConfig rollouts all evict VMs, and without working
# migration each of those hard-kills the guest and loses whatever was in RAM.
#
# The decisive assertion is the guest's boot_id. A VM that reboots onto another
# node also ends up "running elsewhere" and would pass a naive node-name check;
# an unchanged boot_id proves the same kernel kept running the whole time.
#
# Shares its VM setup with test-vm-storage.sh — migration needs the RWX PVC root
# disk that test provisions, so run that one first if this is unfamiliar.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-migrate-test-vm}"
DV_NAME="${DV_NAME:-${VM_NAME}-rootdisk}"

# See test-vm-storage.sh: cloning is broken on pure-fb-nfsv4, so import instead.
SOURCE_MODE="${SOURCE_MODE:-registry}"
IMAGE_URL="${IMAGE_URL:-docker://quay.io/containerdisks/fedora:41}"
DATA_SOURCE="${DATA_SOURCE:-fedora}"
DATA_SOURCE_NS="${DATA_SOURCE_NS:-openshift-virtualization-os-images}"
GUEST_USER="${GUEST_USER:-fedora}"

DISK_SIZE="${DISK_SIZE:-10Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
ACCESS_MODE="${ACCESS_MODE:-}"

MEMORY="${MEMORY:-2Gi}"
CPU_CORES="${CPU_CORES:-1}"

DV_TIMEOUT="${DV_TIMEOUT:-900}"
DV_STALL="${DV_STALL:-240}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300s}"
MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-600}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-40}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
SSH_TIMEOUT="${SSH_TIMEOUT:-45}"

# How long the guest may stop executing and still count as a *live* migration.
# The switchover on a healthy cluster is well under a second; 5s is a loose
# ceiling that still catches a migration that suspended the guest for ages.
DOWNTIME_BUDGET="${DOWNTIME_BUDGET:-5}"
# Heartbeat cadence in the guest. The measurement cannot resolve a pause
# shorter than roughly this, plus normal scheduler jitter.
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-0.05}"

KEEP_VM="${KEEP_VM:-0}"

# Everything below runs as the logged-in user, with no system:admin
# impersonation. Migration is not granted to project users by default — apply
# migrate-rbac.yaml once per namespace first (see README).

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
    oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
    # Migration objects are not owned by the VM, so they outlive it.
    [ -n "${MIG_NAME:-}" ] && oc delete vmim "${MIG_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
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
echo "  VM Live Migration Test"
echo "  Namespace:   ${NAMESPACE}"
echo "  VM:          ${VM_NAME}"
echo "  Root disk:   ${DV_NAME} (${DISK_SIZE})"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc virtctl ssh-keygen awk; do
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

# Migration needs somewhere to migrate *to*. On a single-node cluster this test
# is not applicable, and saying so beats a confusing timeout later.
VIRT_NODES="$(oc get nodes -l kubevirt.io/schedulable=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")"
NODE_COUNT=$(wc -w <<< "${VIRT_NODES}")
if [ "${NODE_COUNT}" -lt 2 ]; then
  echo "❌ Live migration needs at least 2 virtualization-schedulable nodes, found ${NODE_COUNT}."
  echo "   Nodes: ${VIRT_NODES:-none}"
  exit 1
fi
echo "virtualization-schedulable nodes: ${NODE_COUNT}"

# Checked up front because the VM takes a couple of minutes to build, and
# finding out afterwards that the migration itself is forbidden wastes all of it.
if ! oc auth can-i create virtualmachineinstancemigrations -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ Not allowed to create VirtualMachineInstanceMigration in ${NAMESPACE}."
  echo "   KubeVirt does not grant migration to project users by default. Have a"
  echo "   cluster admin apply the Role and RoleBinding once:"
  echo "     oc process --local -f migrate-rbac.yaml -p NAMESPACE=${NAMESPACE} -p USER_NAME=\$(oc whoami) \\"
  echo "       | oc apply --as system:admin -f -"
  exit 1
fi
echo "permitted to create migrations: yes"

if [ "${SOURCE_MODE}" = "datasource" ]; then
  DS_READY="$(oc get datasource "${DATA_SOURCE}" -n "${DATA_SOURCE_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
  if [ "${DS_READY}" != "True" ]; then
    echo "❌ DataSource ${DATA_SOURCE_NS}/${DATA_SOURCE} is not Ready (got '${DS_READY:-not found}')."
    exit 1
  fi
  echo "datasource ${DATA_SOURCE}: Ready"
elif [ "${SOURCE_MODE}" != "registry" ]; then
  echo "❌ SOURCE_MODE must be 'registry' or 'datasource' (got '${SOURCE_MODE}')."
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

WORKDIR="$(mktemp -d "/tmp/${VM_NAME}-migrationtest.XXXXXX")"
SSH_KEY="${WORKDIR}/id_ecdsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "${SSH_KEY}" -C "migrationtest"
SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

MARKER_TOKEN="migrate-$(date +%s)-${RANDOM}"

echo ""
echo "=== 1. Provisioning an RWX PVC root disk ==="

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

if [ "${DV_PHASE}" != "Succeeded" ]; then
  if [ "${DV_STALLED}" = "1" ]; then
    fail "CDI provisioned the root disk (stalled in ${DV_PHASE:-<none>})"
  else
    fail "CDI provisioned the root disk (DataVolume phase: ${DV_PHASE:-<none>})"
  fi
  echo ""
  echo "PVC events:"
  oc describe pvc "${DV_NAME}" -n "${NAMESPACE}" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/  /' || true
  exit 1
fi
pass "CDI provisioned the root disk (DataVolume Succeeded)"

PVC_MODES="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || echo "")"
if printf '%s' "${PVC_MODES}" | grep -qw ReadWriteMany; then
  pass "Root disk is ReadWriteMany (a shared disk is what lets it move between nodes)"
else
  fail "Root disk is ReadWriteMany (got '${PVC_MODES}') — the VM will be pinned to one node"
fi

echo ""
echo "=== 2. Booting the VM ==="

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

USERDATA_BLOCK="$(sed 's/^/            /' "${WORKDIR}/user-data")"

# evictionStrategy: LiveMigrate is what makes a node drain migrate this VM
# instead of killing it, and it is the setting whose behaviour this test checks.
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

echo "Waiting for VMI to appear..."
for i in $(seq 1 30); do
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && break
  sleep 2
done
oc wait --for=condition=Ready "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout="${BOOT_TIMEOUT}"
pass "VM booted and reached Ready"

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

guest_ssh() {
  SSH_OUT=""
  if run_with_timeout "${SSH_TIMEOUT}" virtctl ssh "${SSH_OPTS[@]}" -c "$1" "${SSH_TARGET}" \
       < /dev/null > "${SSH_LOG}" 2>&1; then
    SSH_OUT="$(grep -v 'different from the KubeVirt version\|^Client Version:\|^Server Version:\|Permanently added\|^Warning: ' "${SSH_LOG}" || true)"
    return 0
  fi
  return 1
}

wait_for_guest_ssh() {
  local i
  for i in $(seq 1 "${POLL_ATTEMPTS}"); do
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

if wait_for_guest_ssh "before migration"; then
  pass "Guest reachable over SSH before migration"
else
  fail "Guest reachable over SSH before migration"
  cat "${SSH_LOG}" 2>/dev/null || true
  exit 1
fi

echo ""
echo "=== 3. Recording pre-migration state ==="

SOURCE_NODE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
VMI_UID_BEFORE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"

# boot_id is regenerated by the kernel on every boot and is stable for the life
# of a running kernel. Carrying the same value across the migration is what
# distinguishes "the guest moved" from "the guest was restarted elsewhere".
BOOT_ID_BEFORE=""
guest_ssh "cat /proc/sys/kernel/random/boot_id" && BOOT_ID_BEFORE="$(printf '%s' "${SSH_OUT}" | tr -d '[:space:]')"

guest_ssh "printf '%s\n' '${MARKER_TOKEN}' > /home/${GUEST_USER}/migration-marker.txt && sync" || true

echo "  source node: ${SOURCE_NODE}"
echo "  VMI uid:     ${VMI_UID_BEFORE}"
echo "  guest boot_id: ${BOOT_ID_BEFORE:-<not read>}"

if [ -z "${BOOT_ID_BEFORE}" ]; then
  fail "Read the guest boot_id before migrating (cannot prove the guest did not reboot without it)"
  exit 1
fi

# Timestamps appended by the guest itself. When the VM is paused for the final
# switchover it stops executing, so the gap between consecutive samples is the
# guest-visible outage — measured from inside, with no network in the way.
echo "Starting in-guest heartbeat (${HEARTBEAT_INTERVAL}s interval)..."
guest_ssh "rm -f /tmp/heartbeat; setsid nohup sh -c 'while true; do date +%s.%N; sleep ${HEARTBEAT_INTERVAL}; done' > /tmp/heartbeat 2>/dev/null < /dev/null & sleep 1; test -s /tmp/heartbeat && echo HEARTBEAT_RUNNING"
if printf '%s' "${SSH_OUT}" | grep -q HEARTBEAT_RUNNING; then
  pass "In-guest heartbeat started"
else
  warn "Heartbeat did not start — the migration will still be checked, but downtime cannot be measured"
fi

MIGRATABLE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || echo "")"
if [ "${MIGRATABLE}" = "True" ]; then
  pass "VMI reports LiveMigratable=True"
else
  MIG_REASON="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].reason}{": "}{.status.conditions[?(@.type=="LiveMigratable")].message}' 2>/dev/null || echo "")"
  fail "VMI reports LiveMigratable=True (got '${MIGRATABLE:-<unset>}' — ${MIG_REASON})"
  echo ""
  echo "KubeVirt is telling you up front that this VM cannot migrate. The reason"
  echo "above names the blocker; common ones are an RWO disk or a host device."
  exit 1
fi

echo ""
echo "=== 4. Migrating ==="

# Deliberately not `virtctl migrate`: that calls the virtualmachines/migrate
# subresource, whereas this is a plain CRD write. Both trigger the same
# operation, but the object form is visible in `oc get vmim`, can be waited on
# by name, and is what a controller or a GitOps flow would do.
MIG_NAME="$(oc create -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: ${VM_NAME}-migration-
  namespace: ${NAMESPACE}
spec:
  vmiName: ${VM_NAME}
EOF
)"
echo "Created migration ${MIG_NAME}"

echo "Waiting up to ${MIGRATION_TIMEOUT}s for the migration to complete..."
MIG_COMPLETED=""
MIG_FAILED=""
DEADLINE=$(( $(date +%s) + MIGRATION_TIMEOUT ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  MIG_COMPLETED="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.completed}' 2>/dev/null || echo "")"
  MIG_FAILED="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.failed}' 2>/dev/null || echo "")"
  [ "${MIG_COMPLETED}" = "true" ] && break
  [ "${MIG_FAILED}" = "true" ] && break
  MIG_PHASE="$(oc get vmim "${MIG_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  echo "  migration phase: ${MIG_PHASE:-<pending>}"
  sleep 5
done

MIG_PHASE="$(oc get vmim "${MIG_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
if [ "${MIG_COMPLETED}" = "true" ] && [ "${MIG_FAILED}" != "true" ]; then
  pass "Migration completed successfully (VirtualMachineInstanceMigration: ${MIG_PHASE:-unknown})"
else
  fail "Migration completed successfully (completed=${MIG_COMPLETED:-<unset>} failed=${MIG_FAILED:-<unset>} phase=${MIG_PHASE:-<none>})"
  echo ""
  echo "migrationState:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState}' 2>/dev/null | sed 's/^/  /' || true
  echo ""
fi

echo ""
echo "=== 5. Verifying the guest moved and kept running ==="

TARGET_NODE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
if [ -n "${TARGET_NODE}" ] && [ "${TARGET_NODE}" != "${SOURCE_NODE}" ]; then
  pass "VM is running on a different node (${SOURCE_NODE} -> ${TARGET_NODE})"
else
  fail "VM is running on a different node (still on ${TARGET_NODE:-unknown})"
fi

VMI_UID_AFTER="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
if [ -n "${VMI_UID_BEFORE}" ] && [ "${VMI_UID_BEFORE}" = "${VMI_UID_AFTER}" ]; then
  pass "Same VMI object throughout (not deleted and recreated)"
else
  fail "Same VMI object throughout (uid ${VMI_UID_BEFORE:-<none>} -> ${VMI_UID_AFTER:-<none>})"
fi

if wait_for_guest_ssh "after migration"; then
  pass "Guest reachable over SSH after migration"
else
  fail "Guest reachable over SSH after migration"
fi

BOOT_ID_AFTER=""
guest_ssh "cat /proc/sys/kernel/random/boot_id" && BOOT_ID_AFTER="$(printf '%s' "${SSH_OUT}" | tr -d '[:space:]')"
if [ -n "${BOOT_ID_AFTER}" ] && [ "${BOOT_ID_BEFORE}" = "${BOOT_ID_AFTER}" ]; then
  pass "Guest did not reboot — same kernel boot_id before and after"
else
  fail "Guest did not reboot (boot_id ${BOOT_ID_BEFORE} -> ${BOOT_ID_AFTER:-<not read>})"
fi

FETCHED=""
guest_ssh "cat /home/${GUEST_USER}/migration-marker.txt 2>/dev/null" && FETCHED="${SSH_OUT}"
if printf '%s' "${FETCHED}" | grep -q "${MARKER_TOKEN}"; then
  pass "Disk followed the VM — marker still readable on the new node"
else
  fail "Disk followed the VM — ${MARKER_TOKEN} not readable after migration"
fi

echo ""
echo "=== 6. Guest-visible downtime ==="

guest_ssh "pkill -f 'date +%s.%N' >/dev/null 2>&1; wc -l < /tmp/heartbeat" || true
SAMPLES="$(printf '%s' "${SSH_OUT}" | tr -d '[:space:]')"

DOWNTIME=""
if guest_ssh "awk 'NR>1{d=\$1-p; if(d>m){m=d}} {p=\$1} END{printf \"%.3f\", m+0}' /tmp/heartbeat"; then
  DOWNTIME="$(printf '%s' "${SSH_OUT}" | tr -d '[:space:]')"
fi

if [ -n "${DOWNTIME}" ] && [ "${SAMPLES:-0}" -gt 10 ] 2>/dev/null; then
  echo "  heartbeat samples: ${SAMPLES}"
  echo "  longest gap:       ${DOWNTIME}s (budget ${DOWNTIME_BUDGET}s)"
  if awk -v d="${DOWNTIME}" -v b="${DOWNTIME_BUDGET}" 'BEGIN{exit !(d<b)}'; then
    pass "Guest paused for less than ${DOWNTIME_BUDGET}s during the switchover"
  else
    fail "Guest paused for less than ${DOWNTIME_BUDGET}s (measured ${DOWNTIME}s)"
  fi
else
  warn "Could not measure downtime (samples=${SAMPLES:-0}) — the other checks still stand"
fi

echo ""
echo "=== 7. Informational ==="

MIG_MODE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.mode}' 2>/dev/null || echo "")"
MIG_START="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.startTimestamp}' 2>/dev/null || echo "")"
MIG_END="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.endTimestamp}' 2>/dev/null || echo "")"
echo "  migration mode:  ${MIG_MODE:-unknown}"
echo "  started:         ${MIG_START:-unknown}"
echo "  ended:           ${MIG_END:-unknown}"
echo "  memory:          ${MEMORY} (transfer time scales with this)"
echo ""
echo "  Total migration time is not downtime: memory is copied while the guest"
echo "  keeps running, and only the final switchover pauses it. The longest"
echo "  heartbeat gap above is the part a user would actually notice."

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "✅ VERIFICATION SUCCESS: a running VM live migrated between nodes without"
  echo "   rebooting the guest — node drains and cluster upgrades are survivable."
else
  echo "❌ VERIFICATION FAILED: see the ❌ lines above."
  echo ""
  echo "VMI status:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo ""
  echo "Migrations for this VM:"
  oc get vmim -n "${NAMESPACE}" 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo "Re-run with KEEP_VM=1 to keep the VM for console access:"
  echo "  KEEP_VM=1 ./$(basename "$0")"
  exit 1
fi
