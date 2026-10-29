#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims 3 passthrough GPUs for about 30 minutes.
# ---------------------------------------------------------------------------
# What does one tenant's VM see of another's NVLink traffic, when both hold
# GPUs on the same HGX board? Every GPU there is wired directly to every
# other, and the links to GPUs in other VMs stay up (README.md, "Does
# passing a subset of an NVLink clique work?"). CUDA cannot reach a GPU
# that is not on the guest's PCI bus, so this looks at what the links
# themselves show.
#
#   1. test-gpu-vm.sh boots two VMs on NODE, in two projects: tenant A
#      with 2 GPUs (driver and nvcc), tenant B with 1 (driver).
#   2. Both guests record link state, what each link's far end reports,
#      and the NVLink traffic and error counters.
#   3. A copies between its two GPUs with peer access for BURN_SECONDS;
#      partway through, both read their counters again.
#
# A's counters moving is the control: without it the counters cannot show
# traffic and the result is inconclusive. B's moving means B sees A's
# activity. What B reads of its links' far ends is reported, not judged.
# A guest with a modified driver is out of scope; that is NVIDIA's to
# answer.
#
# Usage: KUBECONFIG=... NODE=<passthrough node> ./test-gpu-nvlink-tenants.sh
#   NODE          passthrough node with 3 free GPUs (required: both VMs
#                 must share a board)
#   PREFIX        projects to create, PREFIX-a and PREFIX-b (default
#                 gpu-nvlink-tenant; must not exist)
#   BURN_SECONDS  how long A drives NVLink traffic (default 60)
# Exit: 0 B saw none of A's traffic, 1 it did, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")"

NODE="${NODE:-}"
PREFIX="${PREFIX:-gpu-nvlink-tenant}"
BURN_SECONDS="${BURN_SECONDS:-60}"
GUEST_USER=ubuntu

[ -n "$NODE" ] || { echo "NODE is required" >&2; exit 2; }
for t in a b; do
  oc get ns "$PREFIX-$t" >/dev/null 2>&1 && { echo "project $PREFIX-$t already exists" >&2; exit 2; }
done
for t in a b; do oc create ns "$PREFIX-$t" >/dev/null || exit 2; done
WORK=$(mktemp -d)
KEYDIR_a=""; KEYDIR_b=""
cleanup() {
  for t in a b; do oc delete ns "$PREFIX-$t" --wait=false >/dev/null 2>&1; done
  for t in a b; do oc wait --for=delete "ns/$PREFIX-$t" --timeout=300s >/dev/null 2>&1; done
  rm -rf "$WORK" ${KEYDIR_a:+"$KEYDIR_a"} ${KEYDIR_b:+"$KEYDIR_b"}
}
trap cleanup EXIT

echo "=== 1. tenant A (2 GPUs) and tenant B (1 GPU) on $NODE (test-gpu-vm.sh) ==="
NAMESPACE="$PREFIX-a" VM_NAME=tenant-a GPU_COUNT=2 NODE="$NODE" KEEP_VM=1 ./test-gpu-vm.sh > "$WORK/vm-a.log" 2>&1 &
NAMESPACE="$PREFIX-b" VM_NAME=tenant-b GPU_COUNT=1 NODE="$NODE" MAX_TIER=2 KEEP_VM=1 ./test-gpu-vm.sh > "$WORK/vm-b.log" 2>&1 &
wait
for t in a b; do
  echo "  tenant $t:"; grep -E '✅|❌|Results:' "$WORK/vm-$t.log" | sed 's/^/  /'
  printf -v "KEYDIR_$t" '%s' "$(sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p' "$WORK/vm-$t.log")"
done
for t in a b; do
  k="KEYDIR_$t"
  grep -q 'VERIFICATION SUCCESS' "$WORK/vm-$t.log" && [ -n "${!k}" ] || { echo "tenant $t VM setup failed" >&2; exit 2; }
done

HELP="$(virtctl ssh --help 2>&1 || true)"
EXTRA=()
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && EXTRA+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && EXTRA+=(--local-ssh=true)
guest() { # guest <a|b> <command>
  local k="KEYDIR_$1"
  virtctl ssh -i "${!k}/id_ecdsa" ${EXTRA[@]+"${EXTRA[@]}"} -c "$2" "${GUEST_USER}@vmi/tenant-$1/$PREFIX-$1" </dev/null 2>/dev/null
}
# Sum of every NVLink data counter the guest's driver reports, in KiB.
counters() { guest "$1" 'nvidia-smi nvlink -gt d 2>&1' | tee "$WORK/gt-$1-$2.txt" |
  awk '/Data (Tx|Rx)/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; n++} END {print (n ? s : "none")}'; }

echo "=== 2. what each tenant's GPUs show of their links ==="
for t in a b; do
  echo "--- tenant $t"
  guest "$t" 'nvidia-smi --query-gpu=index,uuid,pci.bus_id --format=csv,noheader; nvidia-smi topo -m' | sed 's/^/  /'
  guest "$t" 'nvidia-smi nvlink -s' | awk '/^GPU/ {g=$0; up=0; n=0; next} /Link/ {n++; if ($0 !~ /inactive/) up++}
    {if (g && n) last[g]=up "/" n " links up"} END {for (k in last) print "  " k ": " last[k]}' | sort
  echo "  far ends (nvidia-smi nvlink -R):"
  guest "$t" 'nvidia-smi nvlink -R 2>&1' | sed 's/^/    /'
done
guest b 'nvidia-smi nvlink -e 2>&1' > "$WORK/err-b-before.txt"
A0=$(counters a before); B0=$(counters b before)
echo "  NVLink data counters before (KiB): A=$A0 B=$B0"

cat > "$WORK/burn.cu" <<'CUEOF'
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <cuda_runtime.h>
#define BYTES (1ull << 30)
int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 60, can = 0;
  void *a, *b;
  cudaDeviceCanAccessPeer(&can, 0, 1);
  if (!can) { printf("BURN_FAIL no peer access between gpu0 and gpu1\n"); return 2; }
  cudaSetDevice(0); cudaDeviceEnablePeerAccess(1, 0); cudaMalloc(&a, BYTES);
  cudaSetDevice(1); cudaDeviceEnablePeerAccess(0, 0); cudaMalloc(&b, BYTES);
  time_t end = time(NULL) + secs; long n = 0;
  while (time(NULL) < end) { cudaMemcpyPeer(b, 1, a, 0, BYTES); cudaMemcpyPeer(a, 0, b, 1, BYTES); n += 2; }
  cudaDeviceSynchronize();
  printf("BURN copies=%ld GiB=%ld seconds=%d\n", n, n, secs);
  return 0;
}
CUEOF

echo "=== 3. tenant A drives NVLink between its GPUs for ${BURN_SECONDS} s ==="
virtctl scp -i "$KEYDIR_a/id_ecdsa" ${EXTRA[@]+"${EXTRA[@]}"} "$WORK/burn.cu" "${GUEST_USER}@vmi/tenant-a/$PREFIX-a:burn.cu" </dev/null >/dev/null 2>&1 ||
  { echo "scp failed" >&2; exit 2; }
guest a 'nvcc -O2 -o burn burn.cu 2>&1' | sed 's/^/  /'
guest a "nohup ./burn ${BURN_SECONDS} > burn.log 2>&1 &"
sleep $((BURN_SECONDS * 2 / 3))
A1=$(counters a during); B1=$(counters b during)
guest b 'nvidia-smi nvlink -e 2>&1' > "$WORK/err-b-during.txt"
sleep $((BURN_SECONDS / 3 + 10))
guest a 'cat burn.log' | sed 's/^/  /'
echo "  NVLink data counters during (KiB): A=$A1 B=$B1"
if ! diff -q "$WORK/err-b-before.txt" "$WORK/err-b-during.txt" >/dev/null; then
  echo "  tenant B's error counters changed:"; diff "$WORK/err-b-before.txt" "$WORK/err-b-during.txt" | sed 's/^/    /'
fi

case "$A0$A1$B0$B1" in *none*)
  echo "  raw counter output from tenant B:"; sed 's/^/    /' "$WORK/gt-b-during.txt" | head -20
  echo "INCONCLUSIVE: the guest driver reports no NVLink data counters"; exit 2 ;;
esac
guest a 'cat burn.log' | grep -q '^BURN copies' || { echo "INCONCLUSIVE: tenant A's traffic did not run"; exit 2; }
[ "$A1" -gt "$A0" ] || { echo "INCONCLUSIVE: tenant A's own counters did not move, so they cannot show traffic"; exit 2; }
echo "SUMMARY a_kib_delta=$((A1 - A0)) b_kib_delta=$((B1 - B0))"
if [ "$B1" -gt "$B0" ]; then
  echo "FAIL tenant B's NVLink counters moved while tenant A drove traffic"; exit 1
fi
echo "PASS tenant B saw none of tenant A's NVLink traffic (far-end details above)"; exit 0
