#!/usr/bin/env bash
set -euo pipefail

# Removes what the GPU tests create. The test scripts clean up after themselves
# on exit, so this is for the KEEP_VM=1 case and for interrupted runs.
#
# By default it only touches namespaced objects, which a project user can do.
# REVERT_NODE=1 additionally puts the node back into container mode, which is
# admin work and takes the node's GPUs away from any VM still holding one.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-gpu-test-vm}"
DV_NAME="${DV_NAME:-${VM_NAME}-rootdisk}"
PROBE_NAME="${PROBE_NAME:-gpu-switch-probe}"

NODE="${NODE:-}"
REVERT_NODE="${REVERT_NODE:-0}"
WORKLOAD_LABEL="nvidia.com/gpu.workload.config"
AS_ADMIN="${AS_ADMIN:---as=system:admin}"

echo "=== Removing GPU test objects from ${NAMESPACE} ==="
oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
# Deleting the DataVolume reclaims the PVC it provisioned.
oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
oc delete pod "${PROBE_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false

if [ "${REVERT_NODE}" = "1" ]; then
  if [ -z "${NODE}" ]; then
    echo "❌ REVERT_NODE=1 needs NODE=<node>."
    exit 1
  fi
  echo ""
  echo "=== Returning ${NODE} to container mode ==="
  oc label node "${NODE}" ${AS_ADMIN} --overwrite "${WORKLOAD_LABEL}=container"
  oc adm uncordon "${NODE}" ${AS_ADMIN} >/dev/null 2>&1 || true
  echo "Labelled container and uncordoned. The driver stack takes a few minutes"
  echo "to come back; watch for nvidia.com/gpu to reappear:"
  echo "  oc get node ${NODE} -o jsonpath='{.status.allocatable}' | tr ',' '\\n' | grep nvidia"
  echo ""
  echo "The HyperConverged permittedHostDevices entry is left in place — it is"
  echo "harmless with no node in passthrough mode, and removing it would break"
  echo "any other node still serving GPU VMs."
fi

echo "Done!"
