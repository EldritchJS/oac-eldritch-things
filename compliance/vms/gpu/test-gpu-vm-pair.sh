#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims GPUS_PER_VM x 2 passthrough GPUs for about 20 minutes.
# ---------------------------------------------------------------------------
# Can one node serve two multi-GPU VMs at once? Runs test-gpu-vm.sh twice in
# parallel, each VM asking for GPUS_PER_VM GPUs, then checks that both VMs
# were running at the same time on the same node with no GPU in common.
#
# Both VMs go in one project: one tenant per GPU node until NVLink between
# tenants is answered (OPTIONS.md).
#
# Usage: KUBECONFIG=... ./test-gpu-vm-pair.sh
#   NAMESPACE    project to create (default gpu-vm-pair; must not exist)
#   GPUS_PER_VM  GPUs for each VM (default 2)
# Exit: 0 both VMs passed all tiers side by side, 1 a check failed, 2 could
# not run.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

NAMESPACE="${NAMESPACE:-gpu-vm-pair}"
GPUS_PER_VM="${GPUS_PER_VM:-2}"
VMS=(gpu-pair-a gpu-pair-b)

oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
LOGDIR=$(mktemp -d)
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  for vm in "${VMS[@]}"; do
    k=$(sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p' "$LOGDIR/$vm.log" 2>/dev/null)
    [ -n "$k" ] && rm -rf "$k"
  done
  rm -rf "$LOGDIR"
}
trap cleanup EXIT

echo "=== 1. two VMs with ${GPUS_PER_VM} GPUs each, all tiers, in parallel ==="
for vm in "${VMS[@]}"; do
  NAMESPACE="$NAMESPACE" VM_NAME="$vm" GPU_COUNT="$GPUS_PER_VM" KEEP_VM=1 \
    ./test-gpu-vm.sh > "$LOGDIR/$vm.log" 2>&1 &
done
wait

FAILED=0
for vm in "${VMS[@]}"; do
  echo "  $vm:"
  grep -E '✅|❌|Results:|vbios=' "$LOGDIR/$vm.log" | sed 's/^/    /'
  grep -q 'VERIFICATION SUCCESS' "$LOGDIR/$vm.log" || FAILED=1
done

echo "=== 2. both running together, on one node, on different GPUs ==="
# KEEP_VM=1 left both VMs up, so this sees them side by side, each still
# holding its GPUs.
HELP="$(virtctl ssh --help 2>&1 || true)"
EXTRA=()
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && EXTRA+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && EXTRA+=(--local-ssh=true)
nodes="" uuids=""
for vm in "${VMS[@]}"; do
  phase=$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
  node=$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null)
  echo "  $vm: ${phase:-absent} on ${node:--}"
  [ "$phase" = Running ] || FAILED=1
  nodes="$nodes $node"
  k=$(sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p' "$LOGDIR/$vm.log")
  u=$(virtctl ssh -i "$k/id_ecdsa" "${EXTRA[@]}" -c 'nvidia-smi --query-gpu=uuid --format=csv,noheader' \
        "ubuntu@vmi/$vm/$NAMESPACE" </dev/null 2>/dev/null)
  echo "$u" | sed "s/^/    $vm GPU /"
  uuids="$uuids
$u"
done
[ "$(echo $nodes | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" = 1 ] \
  && echo "  same node" || { echo "  not on one node"; FAILED=1; }
total=$(printf '%s\n' "$uuids" | grep -c GPU-)
distinct=$(printf '%s\n' "$uuids" | grep GPU- | sort -u | wc -l | tr -d ' ')
if [ "$total" -eq $((GPUS_PER_VM * 2)) ] && [ "$distinct" -eq "$total" ]; then
  echo "  $distinct distinct GPUs, none shared"
else
  echo "  GPUs seen: $total, distinct: $distinct (want $((GPUS_PER_VM * 2)) distinct)"; FAILED=1
fi

[ "$FAILED" = 0 ] && { echo "PASS two ${GPUS_PER_VM}-GPU VMs ran side by side on one node"; exit 0; }
echo "FAIL see above"; exit 1
