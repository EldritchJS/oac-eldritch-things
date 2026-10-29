#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims GPU_COUNT passthrough GPUs for about 20 minutes.
# ---------------------------------------------------------------------------
# Can a VM that holds several GPUs use NVLink between them? On an HGX board
# the GPUs are wired to each other directly; passthrough hands each one to
# the guest as its own PCI device, and whether the guest's driver then
# finds and uses the links has to be shown, not assumed.
#
#   1. test-gpu-vm.sh boots a VM holding GPU_COUNT GPUs and installs the
#      driver and nvcc.
#   2. In the guest: nvidia-smi topo -m (NV# between two GPUs means NVLink,
#      PHB/SYS/NODE means PCIe) and nvidia-smi nvlink -s (per-link state).
#   3. A CUDA program copies 1 GiB between every ordered pair of GPUs, with
#      peer access on (the NVLink path, if there is one) and off (staged
#      through host memory), and prints the best of 5 for each.
#
# Only one VM, so this says nothing about NVLink between tenants (OPTIONS.md).
#
# Usage: KUBECONFIG=... ./test-gpu-nvlink.sh
#   NAMESPACE  project to create (default gpu-nvlink; must not exist)
#   GPU_COUNT  GPUs for the VM (default 4)
#   NODE       passthrough node to put the VM on (default: any)
#   MIN_GBPS   peer bandwidth every pair must reach to count as NVLink
#              (default 50; PCIe Gen5 x16 tops out near 64, measured ~15
#              host-to-device through passthrough)
# Exit: 0 every pair has peer access over NVLink, 1 a pair does not,
# 2 could not run.
set -uo pipefail
cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-gpu-nvlink}"
GPU_COUNT="${GPU_COUNT:-4}"
MIN_GBPS="${MIN_GBPS:-50}"
NODE="${NODE:-}"
VM_NAME=gpu-nvlink
GUEST_USER=ubuntu

[ "$GPU_COUNT" -ge 2 ] || { echo "GPU_COUNT must be at least 2" >&2; exit 2; }
oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
KEYDIR=""
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"
}
trap cleanup EXIT

echo "=== 1. VM with ${GPU_COUNT} GPUs, driver and nvcc (test-gpu-vm.sh) ==="
OUT=$(NAMESPACE="$NAMESPACE" VM_NAME="$VM_NAME" GPU_COUNT="$GPU_COUNT" NODE="$NODE" KEEP_VM=1 ./test-gpu-vm.sh 2>&1)
printf '%s\n' "$OUT" | grep -E '✅|❌|Results:|vbios=' | sed 's/^/  /'
KEYDIR=$(printf '%s\n' "$OUT" | sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p')
printf '%s' "$OUT" | grep -q 'VERIFICATION SUCCESS' && [ -n "$KEYDIR" ] || { echo "VM setup failed" >&2; exit 2; }

SSH_OPTS=(-i "$KEYDIR/id_ecdsa")
HELP="$(virtctl ssh --help 2>&1 || true)"
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && SSH_OPTS+=(--local-ssh=true)
TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
guest() { virtctl ssh "${SSH_OPTS[@]}" -c "$1" "$TARGET" </dev/null 2>/dev/null; }

echo "=== 2. topology and link state, from the guest ==="
TOPO=$(guest 'nvidia-smi topo -m 2>&1'); printf '%s\n' "$TOPO" | sed 's/^/  /'
guest 'nvidia-smi nvlink -s 2>&1' | awk '/^GPU/ {g=$0; up=0; n=0; next} /Link/ {n++; if ($0 !~ /inactive/) up++}
  {if (g && n) last[g]=up "/" n " links up"} END {for (k in last) print "  " k ": " last[k]}' | sort

cat > "$KEYDIR/p2p.cu" <<'CUEOF'
#include <stdio.h>
#include <cuda_runtime.h>
#define BYTES (1ull << 30)

static float best_copy(int src, int dst, void *s, void *d) {
  cudaSetDevice(src);
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  float best = 1e9f;
  for (int r = 0; r < 5; r++) {
    float ms;
    cudaEventRecord(a);
    cudaMemcpyPeerAsync(d, dst, s, src, BYTES);
    cudaEventRecord(b); cudaEventSynchronize(b);
    cudaEventElapsedTime(&ms, a, b);
    if (ms < best) best = ms;
  }
  return BYTES / (best / 1e3f) / 1e9f;
}

int main(void) {
  int n = 0;
  if (cudaGetDeviceCount(&n) != cudaSuccess || n < 2) { printf("P2P_FAIL fewer than 2 devices\n"); return 2; }
  void *buf[16];
  for (int i = 0; i < n; i++) { cudaSetDevice(i); if (cudaMalloc(&buf[i], BYTES) != cudaSuccess) { printf("P2P_FAIL alloc gpu%d\n", i); return 2; } }
  for (int i = 0; i < n; i++)
    for (int j = 0; j < n; j++) {
      if (i == j) continue;
      int can = 0; cudaDeviceCanAccessPeer(&can, i, j);
      float on = 0;
      if (can) {
        cudaSetDevice(i); cudaDeviceEnablePeerAccess(j, 0);
        cudaSetDevice(j); cudaDeviceEnablePeerAccess(i, 0);
        on = best_copy(i, j, buf[i], buf[j]);
        cudaSetDevice(i); cudaDeviceDisablePeerAccess(j);
        cudaSetDevice(j); cudaDeviceDisablePeerAccess(i);
      }
      float off = best_copy(i, j, buf[i], buf[j]);
      cudaGetLastError();
      printf("P2P gpu%d->gpu%d can_access=%d peer_GBps=%.1f staged_GBps=%.1f\n", i, j, can, on, off);
    }
  return 0;
}
CUEOF

echo "=== 3. 1 GiB copies between every pair: peer access on, then off ==="
virtctl scp "${SSH_OPTS[@]}" "$KEYDIR/p2p.cu" "$TARGET:p2p.cu" </dev/null >/dev/null 2>&1 || { echo "scp failed" >&2; exit 2; }
P2P=$(guest 'nvcc -O2 -o p2p p2p.cu 2>&1 && ./p2p 2>&1'); printf '%s\n' "$P2P" | sed 's/^/  /'

PAIRS=$(printf '%s\n' "$P2P" | grep -c '^P2P gpu')
[ "$PAIRS" -eq $((GPU_COUNT * (GPU_COUNT - 1))) ] || { echo "INCONCLUSIVE: expected $((GPU_COUNT * (GPU_COUNT - 1))) pairs, got ${PAIRS}"; exit 2; }
SLOW=$(printf '%s\n' "$P2P" | awk -v min="$MIN_GBPS" '/^P2P gpu/ {split($3,c,"="); split($4,p,"="); if (c[2] != 1 || p[2] + 0 < min) print $2}')
if [ -z "$SLOW" ]; then
  echo "PASS every GPU pair in the VM has peer access at ${MIN_GBPS}+ GB/s (NVLink)"; exit 0
else
  echo "FAIL no NVLink-speed peer access for: $(echo $SLOW)"; exit 1
fi
