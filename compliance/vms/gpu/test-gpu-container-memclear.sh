#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims GPU_COUNT GPUs on a container-mode node for about
# 5 minutes per handoff (15 for the default three), plus the image pull.
# ---------------------------------------------------------------------------
# Can a pod read GPU memory a previous pod left behind? Between containers
# nothing resets the GPU: the host's NVIDIA driver keeps it, and clearing
# memory before handing it out again is the driver's job. A container tenant
# only has CUDA, so the test is whether CUDA in pod B sees pod A's data.
# (test-gpu-memclear.sh is the VM version, where vfio resets the GPU.)
#
# For each handoff in HANDOFFS:
#   1. Pod A takes all GPU_COUNT GPUs on NODE, fills nearly all their memory
#      with a pattern and reads it back. Control: it frees one chunk and
#      allocates it again in the same process; pattern found there shows
#      the scan can see leftovers when nothing clears them.
#   2. Pod A lets go:
#        exit    the process ends normally (memory never freed by hand)
#        kill    the process kills itself with SIGKILL while holding it
#        delete  the pod is deleted while the process holds it
#   3. Pod B takes the same GPUs (same UUIDs checked), allocates as much
#      memory as it can, does not write it, and counts the pattern.
#
# Not covered: MIG slices, GPUs shared at once (time-slicing, MPS), and
# anything CUDA cannot see (caches, registers).
#
# Usage: KUBECONFIG=... NODE=<container-mode GPU node> ./test-gpu-container-memclear.sh
#   NODE       node to run on (required; must be in container mode)
#   NAMESPACE  project to create (default gpu-memclear-ctr; must not exist)
#   GPU_COUNT  GPUs on the node (default 4); every pod takes all of them
#   HANDOFFS   which handoffs, in order (default "exit kill delete")
#   IMAGE      CUDA image with nvcc (default nvcr.io/nvidia/cuda:12.5.0-devel-ubi9)
# Exit: 0 no pattern in any pod B, 1 pattern found, 2 could not run or
# inconclusive.
set -uo pipefail
cd "$(dirname "$0")"

NODE="${NODE:-}"
NAMESPACE="${NAMESPACE:-gpu-memclear-ctr}"
GPU_COUNT="${GPU_COUNT:-4}"
HANDOFFS="${HANDOFFS:-exit kill delete}"
IMAGE="${IMAGE:-nvcr.io/nvidia/cuda:12.5.0-devel-ubi9}"

[ -n "$NODE" ] || { echo "NODE is required" >&2; exit 2; }
for h in $HANDOFFS; do
  case "$h" in exit|kill|delete) ;; *) echo "unknown handoff $h (exit, kill, delete)" >&2; exit 2 ;; esac
done
MODE=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}' 2>/dev/null)
FREE=$(oc get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
[ "${MODE:-container}" = container ] && [ "${FREE:-0}" -ge "$GPU_COUNT" ] ||
  { echo "$NODE is not serving $GPU_COUNT GPUs to containers (mode=${MODE:-unset}, nvidia.com/gpu=${FREE:-0})" >&2; exit 2; }
oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
WORK=$(mktemp -d)
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/memtest.cu" <<'CUEOF'
// memtest fill exit|kill|hold   fill every GPU's memory with PATTERN, then let go
// memtest scan                  allocate every GPU's memory, unwritten, and count PATTERN
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <cuda_runtime.h>
#define PATTERN 0xC0DEFACEu
#define CHUNK (1ull << 30)
#define SMALL (64ull << 20)
#define MAXB 256

__global__ void fill(unsigned *p, size_t n) {
  for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) p[i] = PATTERN;
}
__global__ void count(const unsigned *p, size_t n, unsigned long long *c) {
  unsigned long long hit = 0, zero = 0;
  for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) {
    unsigned v = p[i]; hit += v == PATTERN; zero += v == 0;
  }
  atomicAdd(&c[0], hit); atomicAdd(&c[1], zero);
}

static void *buf[MAXB]; static size_t len[MAXB]; static int nbuf;

static void grab(void) {  // as much memory as the driver will give, 1 GiB then 64 MiB at a time
  size_t s = CHUNK;
  for (nbuf = 0; nbuf < MAXB;) {
    if (cudaMalloc(&buf[nbuf], s) == cudaSuccess) { len[nbuf++] = s; continue; }
    cudaGetLastError();
    if (s == SMALL) break;
    s = SMALL;
  }
}
static void tally(int from, int to, unsigned long long *c, unsigned long long *words) {
  cudaMemset(c, 0, 16); *words = 0;
  for (int i = from; i < to; i++) { count<<<1024, 256>>>((unsigned *)buf[i], len[i] / 4, c); *words += len[i] / 4; }
  cudaDeviceSynchronize();
}
static void uuid(int d, char *out) {
  cudaDeviceProp p; cudaGetDeviceProperties(&p, d);
  for (int i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", (unsigned char)p.uuid.bytes[i]);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);  // a crash must not lose what was printed
  if (argc < 2 || (strcmp(argv[1], "fill") && strcmp(argv[1], "scan"))) { fprintf(stderr, "usage: memtest fill exit|kill|hold | scan\n"); return 2; }
  int n = 0;
  if (cudaGetDeviceCount(&n) != cudaSuccess || n == 0) { printf("MEMTEST_FAIL no CUDA devices\n"); return 2; }
  for (int d = 0; d < n; d++) {
    char id[33]; uuid(d, id);
    cudaSetDevice(d);
    unsigned long long *c, words;
    if (cudaMallocManaged(&c, 16) != cudaSuccess) { printf("MEMTEST_FAIL gpu%d counter\n", d); return 2; }
    grab();
    if (nbuf == 0) { printf("MEMTEST_FAIL gpu%d no memory\n", d); return 2; }
    if (!strcmp(argv[1], "scan")) {
      tally(0, nbuf, c, &words);
      printf("SCAN gpu%d %s pattern_words=%llu zero_words=%llu of %llu\n", d, id, c[0], c[1], words);
      continue;  // memory freed at exit
    }
    for (int i = 0; i < nbuf; i++) fill<<<1024, 256>>>((unsigned *)buf[i], len[i] / 4);
    tally(0, nbuf, c, &words);
    printf("FILLED gpu%d %s pattern_words=%llu of %llu\n", d, id, c[0], words);
    // Control: free a chunk and take it back in the same process.
    cudaFree(buf[0]); cudaMalloc(&buf[0], len[0]);
    tally(0, 1, c, &words);
    printf("REALLOC gpu%d pattern_words=%llu of %llu\n", d, c[0], words);
    fill<<<1024, 256>>>((unsigned *)buf[0], len[0] / 4);
    cudaDeviceSynchronize();
  }
  fflush(stdout);
  if (!strcmp(argv[1], "fill") && argc > 2 && !strcmp(argv[2], "kill")) { printf("KILLING\n"); fflush(stdout); raise(SIGKILL); }
  if (!strcmp(argv[1], "fill") && argc > 2 && !strcmp(argv[2], "hold")) { printf("HOLDING\n"); fflush(stdout); for (;;) pause(); }
  return 0;
}
CUEOF
oc create configmap memtest -n "$NAMESPACE" --from-file=memtest.cu="$WORK/memtest.cu" >/dev/null || exit 2

pod() { # pod <name> <memtest args>
  cat <<EOF | oc apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $NODE
  containers:
    - name: cuda
      image: $IMAGE
      command: ["sh", "-c", "nvcc -O2 -o /work/memtest /src/memtest.cu && exec /work/memtest $2"]
      env:
        - {name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}
        - {name: TMPDIR, value: /work}  # the image's /tmp is not writable by OpenShift's random UID
      resources:
        limits: {nvidia.com/gpu: $GPU_COUNT}
      volumeMounts:
        - {name: src, mountPath: /src}
        - {name: work, mountPath: /work}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
  volumes:
    - name: src
      configMap: {name: memtest}
    - name: work
      emptyDir: {}
EOF
}
phase() { oc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null; }
# Why a pod gave no result lines: its phase, exit code and the end of its log.
why() { # why <name> <log>
  echo "    pod $1: $(oc get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}' 2>/dev/null)"
  printf '%s\n' "$2" | tail -15 | sed 's/^/    | /'
}
# Wait until the pod has finished, or (with a pattern) printed a line matching it.
await() { # await <name> [pattern]
  for _ in $(seq 180); do
    case "$(phase "$1")" in Succeeded|Failed) return 0 ;; esac
    [ -n "${2:-}" ] && oc logs "$1" -n "$NAMESPACE" 2>/dev/null | grep -q "$2" && return 0
    sleep 5
  done
  return 1
}
sum() { printf '%s\n' "$1" | sed -n "s/^$2 .*pattern_words=\([0-9]*\).*/\1/p" | awk '{s += $1} END {print s + 0}'; }
uuids() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k {print $3}' | sort | tr '\n' ' '; }

FOUND=0; BAD=0
for h in $HANDOFFS; do
  echo "=== handoff: $h ==="
  ARG=$([ "$h" = delete ] && echo "fill hold" || echo "fill $h")
  pod "fill-$h" "$ARG"
  if [ "$h" = delete ]; then
    await "fill-$h" HOLDING || { echo "  pod A did not start holding" >&2; BAD=1; continue; }
    A=$(oc logs "fill-$h" -n "$NAMESPACE" 2>&1)  # gone with the pod
    printf '%s\n' "$A" | grep -q '^FILLED' || why "fill-$h" "$A"
    oc delete pod "fill-$h" -n "$NAMESPACE" --grace-period=1 --wait=true >/dev/null 2>&1
  else
    await "fill-$h" || { echo "  pod A did not finish" >&2; BAD=1; continue; }
    A=$(oc logs "fill-$h" -n "$NAMESPACE" 2>&1)
    printf '%s\n' "$A" | grep -q '^FILLED' || why "fill-$h" "$A"
    oc delete pod "fill-$h" -n "$NAMESPACE" --wait=true >/dev/null 2>&1
  fi
  printf '%s\n' "$A" | grep -E '^(FILLED|REALLOC|KILLING|HOLDING|MEMTEST_FAIL)' | sed 's/^/  A: /'

  pod "scan-$h" scan
  await "scan-$h" || { echo "  pod B did not finish" >&2; BAD=1; continue; }
  B=$(oc logs "scan-$h" -n "$NAMESPACE" 2>&1)
  printf '%s\n' "$B" | grep -q '^SCAN' || why "scan-$h" "$B"
  oc delete pod "scan-$h" -n "$NAMESPACE" --wait=true >/dev/null 2>&1
  printf '%s\n' "$B" | grep -E '^(SCAN|MEMTEST_FAIL)' | sed 's/^/  B: /'

  FILLED=$(sum "$A" FILLED); LEFT=$(sum "$B" SCAN)
  if [ "$(printf '%s\n' "$A" | grep -c '^FILLED')" -ne "$GPU_COUNT" ] || [ "$(printf '%s\n' "$B" | grep -c '^SCAN')" -ne "$GPU_COUNT" ]; then
    echo "  INCONCLUSIVE: not every GPU was filled and scanned"; BAD=1
  elif [ "$(uuids "$A" FILLED)" != "$(uuids "$B" SCAN)" ]; then
    echo "  INCONCLUSIVE: pod B got different GPUs from pod A"; BAD=1
  elif [ "$FILLED" -eq 0 ]; then
    echo "  INCONCLUSIVE: pod A could not read its own pattern back"; BAD=1
  elif [ "$LEFT" -gt 0 ]; then
    echo "  FOUND: pod B read ${LEFT} pattern words of pod A's ${FILLED}"; FOUND=1
  else
    echo "  cleared: pod A wrote ${FILLED} pattern words, pod B read none (same-process realloc saw $(sum "$A" REALLOC))"
  fi
done

if [ "$FOUND" = 1 ]; then
  echo "FAIL a pod read GPU memory a previous pod left behind"; exit 1
elif [ "$BAD" = 1 ]; then
  echo "INCONCLUSIVE: see above"; exit 2
else
  echo "PASS no pod read a previous pod's GPU memory (handoffs: $HANDOFFS)"; exit 0
fi
