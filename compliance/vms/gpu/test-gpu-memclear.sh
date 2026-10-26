#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims every passthrough GPU on one node for about 30 minutes
# (HANDOFF=new-vm: about 40).
# ---------------------------------------------------------------------------
# Is a GPU's memory cleared when a VM lets go of it? This decides whether
# passthrough GPUs can move between tenants on a compliant spoke.
#
#   1. test-gpu-vm.sh boots a VM holding all GPU_COUNT GPUs (so a restart
#      gets the same cards back) and installs the driver and nvcc.
#   2. A CUDA program fills nearly all memory on every GPU with a pattern
#      and holds it.
#   3. pramin.py samples every GiB through BAR0's PRAMIN window, bypassing
#      the NVIDIA driver (which clears memory before handing it out, so CUDA
#      alone cannot see leftovers): the control. If the pattern is not found
#      here, the result below means nothing. The driver is then blocked from
#      loading at the next boot.
#   4. Hand the GPUs back with the pattern still held (they return to
#      vfio-pci on the host), and get them into a guest again:
#        HANDOFF=restart  stop the VM, as a tenant's VM is stopped, and
#                         start it (the default)
#        HANDOFF=new-vm   delete the VM and its disk, and boot a new VM in
#                         a second project (a second tenant) with no GPU
#                         driver at all. It asks for all GPU_COUNT GPUs, so
#                         on a node with that many it gets the same cards.
#   5. Sample again; no driver has touched the GPUs since. Pattern found =
#      memory survives a VM handing its GPUs back.
#
# Usage: KUBECONFIG=... ./test-gpu-memclear.sh
#   NAMESPACE  project to create (default gpu-memclear; must not exist).
#              HANDOFF=new-vm also creates ${NAMESPACE}-b
#   GPU_COUNT  GPUs per node in passthrough mode (default 4)
#   HANDOFF    restart or new-vm (default restart)
# Exit: 0 cleared, 1 pattern survived, 2 could not run or inconclusive.
set -uo pipefail
cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-gpu-memclear}"
GPU_COUNT="${GPU_COUNT:-4}"
HANDOFF="${HANDOFF:-restart}"
VM_NAME=gpu-memclear
GUEST_USER=ubuntu
NAMESPACE_B="${NAMESPACE}-b"
VM_NAME_B=gpu-memclear-b

case "$HANDOFF" in restart|new-vm) ;; *) echo "HANDOFF must be restart or new-vm" >&2; exit 2 ;; esac
for ns in "$NAMESPACE" $([ "$HANDOFF" = new-vm ] && echo "$NAMESPACE_B"); do
  oc get ns "$ns" >/dev/null 2>&1 && { echo "project $ns already exists" >&2; exit 2; }
done
oc create ns "$NAMESPACE" >/dev/null || exit 2
KEYDIR="" KEYDIR_B=""
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  [ "$HANDOFF" = new-vm ] && oc delete ns "$NAMESPACE_B" --timeout=300s >/dev/null 2>&1
  [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"
  [ -n "$KEYDIR_B" ] && rm -rf "$KEYDIR_B"
}
trap cleanup EXIT

echo "=== 1. VM with ${GPU_COUNT} GPUs, driver and nvcc (test-gpu-vm.sh) ==="
OUT=$(NAMESPACE="$NAMESPACE" VM_NAME="$VM_NAME" GPU_COUNT="$GPU_COUNT" KEEP_VM=1 ./test-gpu-vm.sh 2>&1)
printf '%s\n' "$OUT" | grep -E '✅|❌|Results:|vbios=' | sed 's/^/  /'
KEYDIR=$(printf '%s\n' "$OUT" | sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p')
printf '%s' "$OUT" | grep -q 'VERIFICATION SUCCESS' && [ -n "$KEYDIR" ] || { echo "VM setup failed" >&2; exit 2; }

SSH_OPTS=(-i "$KEYDIR/id_ecdsa")
HELP="$(virtctl ssh --help 2>&1 || true)"
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && SSH_OPTS+=(--local-ssh=true)
TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
guest() { virtctl ssh "${SSH_OPTS[@]}" -c "$1" "$TARGET" </dev/null 2>/dev/null; }
# Before a scan after the handback: no GPU driver may have touched the cards.
UNTOUCHED='lsmod | grep -cE "^(nvidia|nouveau)" | sed "s/^/gpu driver modules loaded: /"
  sudo dmesg | grep -iE "nouveau|nvidia|NVRM" | head -5 | sed "s/^/kernel log: /"
  for d in /sys/bus/pci/devices/*; do [ "$(cat $d/vendor)" = 0x10de ] || continue
    [ -e $d/driver ] && echo "bound: $(basename $d) $(basename $(readlink $d/driver))"; done
  echo untouched-check-done' 

cat > "$KEYDIR/memclear.cu" <<'CUEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
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
  int write = argc > 1 && strcmp(argv[1], "scan") != 0, devs = 0;
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
    fflush(stdout);
  }
  if (argc > 1 && strcmp(argv[1], "hold") == 0) for (;;) sleep(60);  /* keep the memory allocated */
  return 0;
}
CUEOF

echo "=== 2. write the pattern and hold it ==="
virtctl scp "${SSH_OPTS[@]}" "$KEYDIR/memclear.cu" "$TARGET:memclear.cu" </dev/null >/dev/null 2>&1 &&
  virtctl scp "${SSH_OPTS[@]}" pramin.py "$TARGET:pramin.py" </dev/null >/dev/null 2>&1 || { echo "scp failed" >&2; exit 2; }
guest 'nvcc -O2 -o memclear memclear.cu 2>&1 | tail -3; (nohup ./memclear hold > hold.log 2>&1 </dev/null &) ; for i in $(seq 120); do [ "$(grep -c MEM_WROTE hold.log)" -ge '"$GPU_COUNT"' ] && break; sleep 5; done; cat hold.log' | sed 's/^/  /'

echo "=== 3. control: sample every GiB past the driver while the pattern is held ==="
CONTROL=$(guest 'sudo python3 pramin.py scan 2>&1'); printf '%s\n' "$CONTROL" | sed 's/^/  /'
# Nothing in the guest may touch the GPUs after the restart.
guest 'printf "blacklist %s\ninstall %s /bin/false\n" nvidia nvidia nvidia_uvm nvidia_uvm nvidia_drm nvidia_drm nvidia_modeset nvidia_modeset nouveau nouveau | sudo tee /etc/modprobe.d/memclear-no-driver.conf >/dev/null; sudo systemctl disable nvidia-persistenced 2>/dev/null; echo blocked' | sed 's/^/  driver at boot: /'

if [ "$HANDOFF" = restart ]; then
  echo "=== 4. stop the VM with the pattern still held (as a tenant VM is stopped), start it ==="
  virtctl stop "$VM_NAME" -n "$NAMESPACE" >/dev/null
  oc wait vmi "$VM_NAME" -n "$NAMESPACE" --for=delete --timeout=600s >/dev/null 2>&1
  STOPPED=$(date +%s)
  virtctl start "$VM_NAME" -n "$NAMESPACE" >/dev/null
  for _ in $(seq 120); do guest true && break; sleep 5; done
  echo "  back after $(( $(date +%s) - STOPPED ))s"
else
  echo "=== 4. delete the VM and its disk with the pattern still held; boot a new VM in $NAMESPACE_B ==="
  NODE_A=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')
  oc delete vm "$VM_NAME" -n "$NAMESPACE" --wait=false >/dev/null
  oc wait vmi "$VM_NAME" -n "$NAMESPACE" --for=delete --timeout=600s >/dev/null 2>&1
  oc delete dv "${VM_NAME}-rootdisk" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  echo "  VM A deleted (it ran on $NODE_A)"
  oc create ns "$NAMESPACE_B" >/dev/null || { echo "could not create $NAMESPACE_B" >&2; exit 2; }
  OUT_B=$(NAMESPACE="$NAMESPACE_B" VM_NAME="$VM_NAME_B" GPU_COUNT="$GPU_COUNT" MAX_TIER=1 NO_GPU_DRIVER=1 KEEP_VM=1 ./test-gpu-vm.sh 2>&1)
  printf '%s\n' "$OUT_B" | grep -E '✅|❌|Results:' | sed 's/^/  /'
  KEYDIR_B=$(printf '%s\n' "$OUT_B" | sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p')
  printf '%s' "$OUT_B" | grep -q 'VERIFICATION SUCCESS' && [ -n "$KEYDIR_B" ] || { echo "VM B setup failed" >&2; exit 2; }
  NODE_B=$(oc get vmi "$VM_NAME_B" -n "$NAMESPACE_B" -o jsonpath='{.status.nodeName}')
  [ "$NODE_B" = "$NODE_A" ] || { echo "INCONCLUSIVE: VM B is on $NODE_B, not $NODE_A, so it has other GPUs"; exit 2; }
  echo "  VM B is on $NODE_B, holding all $GPU_COUNT of its GPUs"
  SSH_OPTS=(-i "$KEYDIR_B/id_ecdsa")
  printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
  printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && SSH_OPTS+=(--local-ssh=true)
  TARGET="${GUEST_USER}@vmi/${VM_NAME_B}/${NAMESPACE_B}"
  virtctl scp "${SSH_OPTS[@]}" pramin.py "$TARGET:pramin.py" </dev/null >/dev/null 2>&1 || { echo "scp to VM B failed" >&2; exit 2; }
fi

echo "=== 5. sample again; no driver has touched the GPUs since the handback ==="
CHECK=$(guest "$UNTOUCHED"); printf '%s\n' "$CHECK" | sed 's/^/  /'
printf '%s' "$CHECK" | grep -q untouched-check-done || { echo "INCONCLUSIVE: could not check the guest's drivers"; exit 2; }
if printf '%s\n' "$CHECK" | grep -qE 'loaded: [1-9]|^kernel log: |^bound: '; then
  echo "INCONCLUSIVE: a GPU driver ran in the guest before the scan, and may have cleared the memory itself"; exit 2
fi
AFTER=$(guest 'sudo python3 pramin.py scan 2>&1'); printf '%s\n' "$AFTER" | sed 's/^/  /'

hits() { printf '%s\n' "$1" | sed -n 's/.*pattern_words=\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}'; }
C=$(hits "$CONTROL"); A=$(hits "$AFTER")
[ -n "$AFTER" ] || { echo "INCONCLUSIVE: no scan after the handback"; exit 2; }
WHO=$([ "$HANDOFF" = new-vm ] && echo "in a new VM in another project" || echo "after restart")
if [ "$C" -eq 0 ]; then
  echo "INCONCLUSIVE: the pattern was not visible through PRAMIN while it was held, so this method cannot see leftovers"; exit 2
elif [ "$A" -eq 0 ]; then
  echo "PASS GPU memory was cleared when the VM handed the GPUs back (control saw ${C} pattern words, ${WHO} 0)"; exit 0
else
  echo "FAIL ${A} pattern words survived the VM handing the GPUs back (control ${C})"; exit 1
fi
