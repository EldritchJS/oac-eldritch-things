#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims every passthrough GPU on one node for about 30 minutes.
# ---------------------------------------------------------------------------
# Is a GPU's memory cleared when a VM lets go of it? This decides whether
# passthrough GPUs can move between tenants on a compliant spoke.
#
#   1. test-gpu-vm.sh boots a VM holding all GPU_COUNT GPUs (so a restart
#      gets the same cards back) and installs the driver and nvcc.
#   2. write: fill nearly all memory on every GPU with a known pattern.
#   3. control: scan, in the same VM with no reset. If the pattern is not
#      found here, this method cannot see leftovers and the result below
#      means nothing.
#   4. Stop the VM (the GPUs go back to vfio-pci on the host), start it.
#   5. scan again. Pattern found = memory survives a VM handing GPUs back.
#
# Usage: KUBECONFIG=... ./test-gpu-memclear.sh
#   NAMESPACE  project to create (default gpu-memclear; must not exist)
#   GPU_COUNT  GPUs per node in passthrough mode (default 4)
# Exit: 0 cleared, 1 pattern survived, 2 could not run or inconclusive.
set -uo pipefail
cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-gpu-memclear}"
GPU_COUNT="${GPU_COUNT:-4}"
VM_NAME=gpu-memclear
GUEST_USER=ubuntu

oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
KEYDIR=""
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"
}
trap cleanup EXIT

echo "=== 1. VM with ${GPU_COUNT} GPUs, driver and nvcc (test-gpu-vm.sh) ==="
OUT=$(NAMESPACE="$NAMESPACE" VM_NAME="$VM_NAME" GPU_COUNT="$GPU_COUNT" KEEP_VM=1 ./test-gpu-vm.sh 2>&1)
printf '%s\n' "$OUT" | grep -E '✅|❌|Results:' | sed 's/^/  /'
KEYDIR=$(printf '%s\n' "$OUT" | sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p')
printf '%s' "$OUT" | grep -q 'VERIFICATION SUCCESS' && [ -n "$KEYDIR" ] || { echo "VM setup failed" >&2; exit 2; }

SSH_OPTS=(-i "$KEYDIR/id_ecdsa")
HELP="$(virtctl ssh --help 2>&1 || true)"
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && SSH_OPTS+=(--local-ssh=true)
TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
guest() { virtctl ssh "${SSH_OPTS[@]}" -c "$1" "$TARGET" </dev/null 2>/dev/null; }

cat > "$KEYDIR/memclear.cu" <<'CUEOF'
#include <stdio.h>
#include <string.h>
#include <cuda_runtime.h>
#define PATTERN 0xC0DEFACEu
#define CHUNK (1ull << 30)
#define MAXCHUNKS 128

__global__ void fill(unsigned *p, size_t n) {
  for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) p[i] = PATTERN;
}
__global__ void count(const unsigned *p, size_t n, unsigned long long *hits) {
  unsigned long long c = 0;
  for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) c += (p[i] == PATTERN);
  atomicAdd(hits, c);
}

int main(int argc, char **argv) {
  int write = argc > 1 && strcmp(argv[1], "write") == 0, devs = 0;
  if (cudaGetDeviceCount(&devs) != cudaSuccess || devs < 1) { printf("MEM_FAIL no devices\n"); return 2; }
  for (int d = 0; d < devs; d++) {
    cudaSetDevice(d);
    char uuid[64] = "";
    cudaDeviceProp p; cudaGetDeviceProperties(&p, d);
    for (int i = 0; i < 16; i++) sprintf(uuid + 2 * i, "%02x", (unsigned char)p.uuid.bytes[i]);
    unsigned *chunk[MAXCHUNKS]; int n = 0;
    while (n < MAXCHUNKS && cudaMalloc((void **)&chunk[n], CHUNK) == cudaSuccess) n++;
    cudaGetLastError();
    const size_t words = CHUNK / sizeof(unsigned);
    unsigned long long *hits, total = 0;
    cudaMallocManaged(&hits, sizeof *hits);
    for (int i = 0; i < n; i++) {
      if (write) fill<<<1024, 256>>>(chunk[i], words);
      else { *hits = 0; count<<<1024, 256>>>(chunk[i], words, hits); cudaDeviceSynchronize(); total += *hits; }
    }
    cudaDeviceSynchronize();
    if (write) printf("MEM_WROTE gpu%d %s %d GiB\n", d, uuid, n);
    else printf("MEM_SCAN gpu%d %s %d GiB pattern_words=%llu of %llu\n", d, uuid, n, total, (unsigned long long)n * words);
  }
  return 0;
}
CUEOF

echo "=== 2. write the pattern ==="
virtctl scp "${SSH_OPTS[@]}" "$KEYDIR/memclear.cu" "$TARGET:memclear.cu" </dev/null >/dev/null 2>&1 || { echo "scp failed" >&2; exit 2; }
guest 'nvcc -O2 -o memclear memclear.cu 2>&1 | tail -3 && ./memclear write' | sed 's/^/  /'

echo "=== 3. control: scan in the same VM, no reset ==="
CONTROL=$(guest './memclear scan'); printf '%s\n' "$CONTROL" | sed 's/^/  /'

echo "=== 4. stop the VM (GPUs return to the host), start it again ==="
virtctl stop "$VM_NAME" -n "$NAMESPACE" >/dev/null
oc wait vmi "$VM_NAME" -n "$NAMESPACE" --for=delete --timeout=600s >/dev/null 2>&1
STOPPED=$(date +%s)
virtctl start "$VM_NAME" -n "$NAMESPACE" >/dev/null
for _ in $(seq 120); do guest true && break; sleep 5; done
echo "  back after $(( $(date +%s) - STOPPED ))s"

echo "=== 5. scan after the GPUs were handed back ==="
AFTER=$(guest 'nvidia-smi -L >/dev/null && ./memclear scan'); printf '%s\n' "$AFTER" | sed 's/^/  /'

hits() { printf '%s\n' "$1" | sed -n 's/.*pattern_words=\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}'; }
C=$(hits "$CONTROL"); A=$(hits "$AFTER")
[ -n "$AFTER" ] || { echo "INCONCLUSIVE: no scan after restart"; exit 2; }
if [ "$C" -eq 0 ]; then
  echo "INCONCLUSIVE: the pattern was not visible even without a reset (the driver clears new allocations), so this method cannot see leftovers"; exit 2
elif [ "$A" -eq 0 ]; then
  echo "PASS GPU memory was cleared when the VM handed the GPUs back (control saw ${C} pattern words, after restart 0)"; exit 0
else
  echo "FAIL ${A} pattern words survived the VM handing the GPUs back (control ${C})"; exit 1
fi
