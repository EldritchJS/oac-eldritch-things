#!/bin/sh
# Runs inside the test pods of test-gpu-container-memclear.sh and
# test-gpu-sharing.sh: compiles memtest.cu, lists the pod's GPUs, then runs
# memtest with the given arguments on each. CUDA sees one MIG device per
# process, so on MIG each slice gets a process of its own.
#
#   memtest-run.sh <memtest arguments>
#   memtest-run.sh neighbor   what nvidia-smi shows, then scan, then fault
nvcc -O2 -o /work/memtest /src/memtest.cu || exit 1
nvidia-smi -L | sed 's/^/GPULIST /'
NEXT=
if [ "$1" = neighbor ]; then
  nvidia-smi --query-gpu=uuid,memory.used,memory.total,utilization.gpu --format=csv,noheader | sed 's/^/SMI_GPU /'
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader | sed 's/^/SMI_APP /'
  set -- scan
  NEXT=fault
fi
MIGS=$(nvidia-smi -L | grep -o 'MIG-[0-9a-f-]*')
if [ -n "$MIGS" ]; then
  for m in $MIGS; do CUDA_VISIBLE_DEVICES=$m MEMTEST_ID=$m /work/memtest "$@" & done
  wait
else
  /work/memtest "$@"
fi
[ -z "$NEXT" ] || /work/memtest "$NEXT"
