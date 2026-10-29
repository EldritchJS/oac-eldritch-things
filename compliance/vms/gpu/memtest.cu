// GPU memory tests, run in pods by test-gpu-container-memclear.sh and
// test-gpu-sharing.sh (through memtest-run.sh, which compiles this).
//
//   memtest fill exit|kill|hold  fill each visible GPU's memory with PATTERN and
//                                read it back, then let go: exit normally, die by
//                                SIGKILL, or hold it and recount every 10 s (CHECK)
//   memtest scan                 allocate each visible GPU's memory, unwritten,
//                                and count PATTERN in it
//   memtest fault                write through an unmapped address, as a crashing
//                                or hostile tenant would
//
// MEMTEST_ID names the device in the output when one is visible (default: its
// UUID). MEMTEST_MAX_MIB caps what fill takes per GPU, for GPUs that several
// pods share at once.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <cuda_runtime.h>
#define PATTERN 0xC0DEFACEu
#define CHUNK (1ull << 30)
#define SMALL (64ull << 20)
#define MAXB 256
#define MAXD 16

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
__global__ void poke(unsigned *p) { *p = PATTERN; }

static void *buf[MAXD][MAXB]; static size_t len[MAXD][MAXB]; static int nbuf[MAXD];
static unsigned long long *cnt[MAXD];  // [0] pattern words, [1] zero words
static char id[MAXD][64];

static void grab(int d, size_t cap) {  // as much as allowed, 1 GiB then 64 MiB at a time
  size_t s = CHUNK, got = 0;
  for (nbuf[d] = 0; nbuf[d] < MAXB;) {
    if (cap && got + s > cap) { if (s == SMALL) break; s = SMALL; continue; }
    if (cudaMalloc(&buf[d][nbuf[d]], s) == cudaSuccess) { len[d][nbuf[d]++] = s; got += s; continue; }
    cudaGetLastError();
    if (s == SMALL) break;
    s = SMALL;
  }
}
static int tally(int d, int from, int to, unsigned long long *words) {  // 0, or the CUDA error
  cudaSetDevice(d);
  cudaMemset(cnt[d], 0, 16); *words = 0;
  for (int i = from; i < to; i++) { count<<<1024, 256>>>((unsigned *)buf[d][i], len[d][i] / 4, cnt[d]); *words += len[d][i] / 4; }
  return cudaDeviceSynchronize();
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);  // a crash must not lose what was printed
  if (argc < 2 || (strcmp(argv[1], "fill") && strcmp(argv[1], "scan") && strcmp(argv[1], "fault"))) {
    fprintf(stderr, "usage: memtest fill exit|kill|hold | scan | fault\n"); return 2;
  }
  const char *let_go = argc > 2 ? argv[2] : "exit";
  size_t cap = getenv("MEMTEST_MAX_MIB") ? (size_t)atoll(getenv("MEMTEST_MAX_MIB")) << 20 : 0;
  int n = 0;
  if (cudaGetDeviceCount(&n) != cudaSuccess || n == 0) { printf("MEMTEST_FAIL no CUDA devices\n"); return 2; }
  if (n > MAXD) n = MAXD;

  if (!strcmp(argv[1], "fault")) {
    poke<<<1, 1>>>((unsigned *)16);
    printf("FAULT %s\n", cudaGetErrorName(cudaDeviceSynchronize()));
    return 0;
  }
  for (int d = 0; d < n; d++) {
    cudaDeviceProp p; cudaGetDeviceProperties(&p, d);
    if (getenv("MEMTEST_ID") && n == 1) snprintf(id[d], sizeof id[d], "%s", getenv("MEMTEST_ID"));
    else for (int i = 0; i < 16; i++) sprintf(id[d] + 2 * i, "%02x", (unsigned char)p.uuid.bytes[i]);
    cudaSetDevice(d);
    unsigned long long words;
    if (cudaMallocManaged(&cnt[d], 16) != cudaSuccess) { printf("MEMTEST_FAIL gpu%d %s counter\n", d, id[d]); return 2; }
    grab(d, strcmp(argv[1], "fill") ? 0 : cap);
    if (nbuf[d] == 0) { printf("MEMTEST_FAIL gpu%d %s no memory\n", d, id[d]); return 2; }
    if (!strcmp(argv[1], "scan")) {
      tally(d, 0, nbuf[d], &words);
      printf("SCAN gpu%d %s pattern_words=%llu zero_words=%llu of %llu\n", d, id[d], cnt[d][0], cnt[d][1], words);
      continue;  // memory freed at exit
    }
    for (int i = 0; i < nbuf[d]; i++) fill<<<1024, 256>>>((unsigned *)buf[d][i], len[d][i] / 4);
    tally(d, 0, nbuf[d], &words);
    printf("FILLED gpu%d %s pattern_words=%llu of %llu\n", d, id[d], cnt[d][0], words);
    // Control: free a chunk and take it back in the same process.
    cudaFree(buf[d][0]); cudaMalloc(&buf[d][0], len[d][0]);
    tally(d, 0, 1, &words);
    printf("REALLOC gpu%d pattern_words=%llu of %llu\n", d, cnt[d][0], words);
    fill<<<1024, 256>>>((unsigned *)buf[d][0], len[d][0] / 4);
    cudaDeviceSynchronize();
  }
  if (!strcmp(argv[1], "scan")) return 0;
  if (!strcmp(let_go, "kill")) { printf("KILLING\n"); raise(SIGKILL); }
  if (!strcmp(let_go, "hold")) {
    printf("HOLDING\n");
    for (;;) {
      sleep(10);
      for (int d = 0; d < n; d++) {
        unsigned long long words;
        int e = tally(d, 0, nbuf[d], &words);
        if (e) { printf("CHECK_FAIL gpu%d %s %s\n", d, id[d], cudaGetErrorName((cudaError_t)e)); return 3; }
        printf("CHECK gpu%d %s pattern_words=%llu of %llu\n", d, id[d], cnt[d][0], words);
      }
    }
  }
  return 0;
}
