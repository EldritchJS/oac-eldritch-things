# GPU VMs on OpenShift that match bare metal

*Draft. Part one: what a GPU VM costs on H100s, and how to bring that
cost to zero. Part two: the same VMs as worker nodes of a hosted
cluster, deployed through GitOps.*

## In short

A KubeVirt VM with passthrough H100s ran inference as fast as bare
metal, once it had host CPUs of its own. NVLink inside the VM was as
fast as on the host. The same held for a full OpenShift hosted cluster
whose worker node is such a VM, built from git: within 2-4% of bare
metal on time to first token, and the same everywhere else. GPU memory
was cleared between tenants, and the one isolation gap we found is
closed. The open question is NVLink between tenants' GPUs on the same
board, which is NVIDIA's to answer.

## Why VMs

We run GPU clusters for several tenants, some of whom need compliance
(FIPS, NIST 800-171, HIPAA). Containers share the host's kernel. A VM with
passthrough GPUs gives each tenant its own kernel and its own GPUs,
and, through KubeVirt hosted clusters, its own cluster. What we needed
to know was what that isolation costs in performance.

## The setup

- One standalone OpenShift 4.22 cluster, FIPS on, with OpenShift
  Virtualization (KubeVirt). For the hosted cluster, it was the
  hypervisor, and a separate hub ran the hosted cluster's control plane.
- Two nodes, each with four H100 SXM5 80GB GPUs joined by NVLink: six
  bonded links between each pair, no NVSwitch.
- The NVIDIA GPU Operator, which moves a node between serving
  containers and passing GPUs through to VMs when one label changes.
- Small test scripts, and Ahmed Sanaullah's [AI UAT Harness][1], which
  runs acceptance tests for AI platforms on OpenShift. Its
  `chunked-prefill` test (vLLM, tensor parallel over 4 GPUs) and
  `llm-d-local` test (prefill and decode split, with the KV cache moved
  over NVLink) each ran three times in each of the setups below.

## What we found

Every column uses the same node and the same four GPUs. The only
difference is how many layers sit between the test and the GPUs:

- **Baseline: bare metal.** A pod on the cluster's own OpenShift, with
  the GPUs attached directly. No VM. This is what the other two are
  measured against.
- **Hand-made VM.** A 4-GPU, 64-vCPU VM we created by hand, running
  k3s; the test's pod runs inside it.
- **Hosted-cluster VM.** The same size of VM, but created by a
  HyperShift NodePool as the worker node of a full OpenShift hosted
  cluster (FIPS on), from git; the test's pod runs inside it.

| | Baseline: bare metal | Hand-made VM | Hosted-cluster VM |
|---|---|---|---|
| NCCL all-reduce bandwidth | 317 GB/s | 317-322 GB/s | 321-322 GB/s |
| KV cache transfer (NIXL) | 110-113 GB/s | 105-113 GB/s | 106-121 GB/s |
| Time to first token, shared vCPUs | 203 / 400 ms | 221 / 446 ms | not run |
| Time to first token, Guaranteed QoS | 203 / 400 ms | 203 / 405 ms | 205-208 / 411-415 ms |
| 1 MiB all-reduce, Guaranteed QoS | about 48 µs | about 86 µs | 49-50 µs |
| Slow small all-reduces, guest SMT off | 3 in 24 | 1 in 24 | not run |

Higher is better for bandwidth; lower is better for time. The two
time-to-first-token figures are the averages of the harness's two
tests. Differences of 1-2% in bandwidth are within run-to-run variation.

**Passthrough needs no special setup.** The guest sees its H100s, the
stock driver binds them, and CUDA runs. Several VMs can share a node,
each with its own GPUs. Host-to-device copies from pageable memory were
7-10% slower than from a container on the same node. Pageable copies
are not the card's peak, so this compares like with like rather than
with the H100's rated bandwidth.

**NVLink costs nothing in a VM.** In a VM holding all four GPUs, every
pair had peer access over NVLink, at 133 GB/s per 1 GiB copy against
23 GB/s through host memory. NCCL all-reduce and llm-d's KV cache
transfer ran at bare-metal speed.

**Time to first token depends on CPUs, not GPUs.** Time between tokens
matched bare metal from the start. The first token was 9-11% slower
while the VM's vCPUs shared host CPUs with everything else, which is
KubeVirt's default. Once the VM had host CPUs of its own, it matched.
Pinning each vCPU (`dedicatedCpuPlacement`) gave 204 and 407 ms;
Guaranteed QoS alone, where the kubelet's static CPU manager gives the
VM's pod its own set of CPUs, gave 203 and 405 ms. Guaranteed QoS is
the simpler of the two, and it is what we use. Turning on the static
CPU manager costs one reboot per node. A Guaranteed VM over 63 vCPUs
also needs KubeVirt's CPU hotplug ratio set to 1: at the default of 4,
the VM gets a virtual IOMMU, and QEMU refuses to pass it GPUs.

**Small all-reduces need SMT off in the guest.** All-reduces from
64 KiB to 4 MiB sometimes took about 120 µs in the VM, against
43-57 µs when each rank had a core to itself, as on bare metal. The
cause was topology. KubeVirt pins each pair of vCPUs to the two threads
of one physical core, but the guest saw 64 independent cores and could
place two NCCL ranks on the same one. Telling the guest the real
topology (32 cores with 2 threads each) did not help. Booting it with
`nosmt` did: 1 slow measurement in 24, against 3 in 24 on bare metal.
Throughput was the same either way, so this matters only for
latency-bound collectives. For those, give the VM twice the vCPUs it
needs, with dedicated placement, and boot it with `nosmt`. Guaranteed
QoS alone leaves 1 MiB all-reduces at about 86 µs.

**A hosted cluster on a GPU VM costs almost nothing more.** The
hosted cluster's control plane runs as pods on the hub; its one worker
node is a Guaranteed-QoS VM on the GPU node, with all four GPUs passed
through. Time to first token was 2-4% above bare metal (205-208 and
411-415 ms against 203 and 400), a few milliseconds more than the
hand-made VM, which is about what an extra OpenShift layer should
cost. Time between tokens (4.1 and 6.0 ms), NCCL all-reduce, KV cache
transfer and GPU-to-GPU copies (130-133 GB/s) matched bare metal.
Its 1 MiB all-reduces took 49-50 µs in all three runs, as on bare
metal, without turning SMT off; three runs are too few to say the
SMT problem is gone. The KV cache figures were worked out from the
transfer times in vLLM's logs.

**Moving a node between containers and VMs takes minutes, not a
reboot.** Containers to VMs took 57 seconds. The way back took 210
seconds, most of it the GPU driver reloading. Draining real workloads
first adds their own shutdown time.

## Isolation, while we were there

- **GPU memory is cleared between VMs.** We filled every GPU with a
  known pattern, gave the GPUs to a new VM in another project, and read
  their memory through BAR0, bypassing the driver. Every sampled word
  was zero: the reset that vfio performs when a VM releases a GPU
  clears it before the next VM can open it.
- **It is also cleared between containers**, by a different mechanism.
  The host driver zeroes every allocation, on whole GPUs and on MIG
  slices, including after a GPU is repartitioned.
- **Tenants do not see each other's NVLink traffic** with the stock
  driver. While one VM moved about 8 TiB between its GPUs, another
  tenant's GPU on the same board saw its NVLink counters stay at zero.
- **One real gap, now closed.** With the GPU Operator's defaults, an
  unprivileged pod could use GPUs it never requested, including GPUs
  held by other pods. One toolkit setting and an admission policy close
  it, and both now ship in our GitOps repository.

## Limits

These results come from one board design and one GPU firmware, with
three runs per measurement. The p90 tails varied as much between
bare-metal runs as between bare metal and the VM. Whether a guest
running its own driver could reach another tenant's GPU over NVLink is
a question for NVIDIA. Until it is answered, tenants who need
compliance get whole nodes, or VMs holding all four of a node's GPUs.

## What a GPU hosted cluster needs

The hosted cluster above was built from our GitOps repository, on a
hypervisor cluster imported into a separate hub. Five things were not
obvious:

- **FIPS has to be set when the cluster is created.** A hosted
  cluster's `fips` setting defaults to off and cannot be changed
  later; turning it on means deleting and rebuilding the cluster.
- **A cluster whose only node has GPUs must not taint it.** Node
  Feature Discovery taints GPU nodes by default, which leaves the
  cluster's own platform pods with nowhere to run. Its taints have to
  be turned off on such a cluster.
- **Deleting a hosted cluster leaves its route on the hypervisor.** The
  old passthrough route keeps the cluster's hostname, so a rebuilt
  cluster's apps do not answer until the old route is deleted.
- **Shared volumes in the hosted cluster are block devices only.** Its
  storage class, which passes volumes through from the hypervisor,
  offers ReadWriteMany only in block mode, and new volumes are owned by
  root. A workload that expects a shared, writable file system, as the
  test harness did, needs ReadWriteOnce volumes and a change of owner.
- **Check where the node's disk went.** A misspelled or outdated
  storage class key in the NodePool's settings is ignored without an
  error, and the VM's disk lands on the hypervisor's default class.
  Check the disk's volume after the node is created.

## Next

Running more than one hosted cluster on a GPU node, each with its own
GPUs, and the NVLink question above.

## Thanks

To Ahmed Sanaullah, whose [AI UAT Harness][1] and experiment
recommendations produced the inference and NVLink measurements here.

[1]: https://github.com/asanaullah/ai-uat-harness
