# GPUs for VMs on OAC: the options

Three questions came up:

1. How do we give a VM access to a host's GPUs?
2. Can several VMs on one host each have GPUs?
3. Can one GPU be shared between several VMs?

This page answers them for OAC spokes, compliant and non-compliant, and
says what each answer would take. The hands-on runbook, scripts and
measurements from jetty are in [README.md](README.md). Status is as of
2026-10-20. "To verify" marks what has not been tested.

## Short answers

| Question | Answer | Licence | Status |
|---|---|---|---|
| 1. A VM with a GPU | **PCI passthrough**: a whole GPU is bound to `vfio-pci` and handed to one VM | None | **Proven on jetty (2026-10-20):** an Ubuntu VM got an H100, loaded the driver and ran a CUDA kernel correctly |
| 2. Several VMs per host | **Yes**, one or more whole GPUs each. A 4-GPU node serves up to four 1-GPU VMs, two 2-GPU VMs, or one 4-GPU VM | None | **Proven on jetty (2026-10-20):** four 1-GPU VMs ran at once on one node, each on a different H100, and all passed |
| 3. One GPU shared by several VMs | Only with **NVIDIA vGPU**: MIG-backed slices or time-sliced shares | NVIDIA AI Enterprise, plus a licence server | MOC has no licence today; set aside (Settled, below) |

Containers can share a GPU without a licence (MIG, time-slicing). VMs
cannot: the GPU Operator's sharing features for VMs all go through vGPU.

## The options

| | Passthrough | MIG-backed vGPU | Time-sliced vGPU |
|---|---|---|---|
| GPUs per VM | 1 to all on the node | A slice of one | A share of one |
| VMs per H100 | 1 | Up to 7 | Several, by profile |
| Isolation between VMs | Separate hardware, IOMMU | Partitioned memory and compute | Separate memory; compute and cache shared in turn |
| Host driver | None (`vfio-pci`) | NVIDIA vGPU manager | NVIDIA vGPU manager |
| Licence | None | NVIDIA AI Enterprise | NVIDIA AI Enterprise |
| GPU Operator node label | `vm-passthrough` | `vm-vgpu` | `vm-vgpu` |
| Status at MOC | Proven on jetty | Set aside | Set aside |

## What OAC already has

- **`nvidia-gpu-operator` chart:** `clusterPolicy.sandboxWorkloads.enabled`
  (off by default), with the VFIO manager, sandbox device plugin and vGPU
  device manager enabled. `vgpuManager` is off; it needs the licensed image.
- **`openshift-virtualization` chart**, through the `virtualization-clusters`
  ApplicationSet. Its HyperConverged sets tolerations only.
- **The per-node label** `nvidia.com/gpu.workload.config` (`container`,
  `vm-passthrough`, `vm-vgpu`), which the operator acts on once
  `sandboxWorkloads` is on. Nodes without the label keep serving containers.

## What passthrough would take on a spoke

1. **GPU Operator values:** `sandboxWorkloads.enabled: true`, with
   `defaultWorkload: container`, so unlabelled nodes do not change.
2. **The HyperConverged's `permittedHostDevices`:** the GPU's PCI id (for the
   H100 SXM5, `10DE:2330`) mapped to the sandbox plugin's resource name
   (`nvidia.com/GH100_H100_SXM5_80GB`), with `externalResourceProvider: true`.
   The `openshift-virtualization` chart needs a value for this.
3. **Which nodes serve VMs:** label them `vm-passthrough`. On a hosted
   cluster, that fits a NodePool of its own, with the label in the
   NodePool's `nodeLabels`, so GPU-VM nodes come and go as a pool.
4. **IOMMU:** on by default on these AMD nodes. jetty's H100 nodes have 103
   IOMMU groups with no kernel argument. So hosted clusters, which have no
   MachineConfig API, should not need kernel arguments either. To verify on
   a hosted cluster.
5. **The `vfio_iommu_type1` kernel module, loaded at boot.** The GPU
   Operator's VFIO manager loads `vfio-pci` but not this backend, and
   without it every GPU VM fails to start ("No available IOMMU models").
   On jetty it was loaded by hand; it needs a MachineConfig (or, on a
   hosted cluster, NodePool config) listing it in `/etc/modules-load.d/`.
   `setup-passthrough.sh` checks for it.
6. **A StorageClass for VM disks.** A `containerDisk` VM did not boot with
   a GPU attached (jetty, CNV 4.22.9), so the root disk has been a PVC. The
   cause may have been the missing `vfio_iommu_type1`; not retested.
7. **Quotas and billing:** VM GPUs appear under the model's resource name,
   not `nvidia.com/gpu`. A quota or a billing count keyed on
   `nvidia.com/gpu` misses them. Our T-17 check already counts GPU VMs.
   Whether MOC's billing does is to verify.

## Constraints, measured on jetty

Details and evidence: [README.md](README.md).

- **A node serves containers or VMs, not both.** Switching is a label
  change with no reboot (measured: about 70 s to VMs, 210 to 250 s back to
  containers), but every GPU-holding pod has to leave the node first.
- **GPU VMs cannot live migrate.** Drains, upgrades and MachineConfig
  rollouts stop them. The runbook's VMs set `evictionStrategy: None`, so a
  drain does not wait for a migration that cannot happen.
- **Guest memory is pinned.** A 16 GiB GPU VM takes 16 GiB of host RAM
  outright, plus overhead for the card's memory windows.
- **GPU VMs and RDMA do not share a node.** Passthrough needs the IOMMU on;
  RDMA needed it off on an earlier cluster. Moving a node between the two
  roles takes a reboot.
- **NVLink.** jetty's H100 nodes have 4 SXM5 GPUs wired to each other
  directly (no NVSwitch). A 4-GPU VM gets the whole NVLink mesh. Whether a
  1- or 2-GPU VM works normally with its NVLink peers absent is to verify.
  A 2-GPU VM should take GPUs 0 and 1, or 2 and 3, to stay on one CPU
  socket.
- **GPUDirect RDMA inside a VM** would also need each GPU's neighbouring
  NIC, or a virtual function of it, passed through. Out of scope for now.

## Compliant and non-compliant spokes

| | Non-compliant spoke | Compliant spoke |
|---|---|---|
| Passthrough | Yes | Yes. Each VM has its own GPU behind the IOMMU |
| Between tenants | Reuse the GPU | GPU memory is cleared before the next VM can read it: shown on one jetty node (2026-10-26), from a new VM in another project, with a positive control. The acceptance suite flags any passthrough node whose kernel, device, reset method or VBIOS differs from what was tested ([memclear-record.md](memclear-record.md)) |
| MIG-backed vGPU | Yes, with a licence | Within one tenant. Across tenants, it is an argument to make in the SSP |
| Time-sliced vGPU | Yes, with a licence | Not across tenants: compute and cache are shared |
| FIPS | — | Passthrough needs no NVIDIA driver on the host. The vGPU manager is a kernel module on a FIPS host: **to verify** |
| VM disks | Any class | The hub's TLS class (NFS over TLS), as for every volume |
| Guest OS | Tenant's choice | The image and its hardening are part of the tenant's boundary; to decide who owns them |

## What vGPU would take

Not a no, but a purchase and some setup:

1. **An NVIDIA AI Enterprise licence**, priced per GPU. A decision for MOC.
2. **A licence server** the guests can reach: NVIDIA's cloud service, or a
   delegated licence server run on site.
3. **The vGPU manager image**, built from NVIDIA's licensed files and kept
   in a **private** registry. It cannot be public, unlike `tlshd`.
4. **Chart values:** `vgpuManager.enabled` with that image, the vGPU device
   manager's profile config, and the HyperConverged's mediated device
   settings. On Hopper, which profiles and mechanism apply with our
   versions is to verify against NVIDIA's OpenShift Virtualization docs.
5. **Nodes labelled `vm-vgpu`:** again a whole node, so a vGPU NodePool
   alongside the passthrough and container ones.

## Next steps

In order of what each one unblocks:

1. **Ask NVIDIA** about H100: whether a function-level reset always
   clears HBM (jetty shows it does, on VBIOS `96.00.DA.00.17`; is it
   guaranteed, and what if a reset fails?), whether NVLink between
   GPUs passed to different VMs is isolated, and whether the links can be
   turned off from the host. On jetty's boards each GPU is wired to the
   other three by NVLink, and with 1-GPU VMs the links between different
   tenants' GPUs stay physically up. A guest with the stock driver sees no
   peers, so has no path to them: tenant B saw none of tenant A's 8 TiB
   of NVLink traffic in its counters, and no far ends
   (`test-gpu-nvlink-tenants.sh`, 2026-10-29). Whether a guest running its own driver
   can send NVLink traffic to a peer without the peer's cooperation is
   unknown, and cannot be tested without writing such a driver. Until
   NVIDIA answers, compliant spokes give one tenant whole nodes (or 4-GPU
   VMs), so linked GPUs never belong to different tenants. A project
   node selector enforces that for pinned projects
   (`test-gpu-tenant-pinning.sh`, 2026-10-29); unpinned projects, which
   any user can create, need a cluster default as well.
2. **On a spoke:** passthrough on a hosted cluster, with a GPU-VM NodePool.
   A hosted cluster of the next compliant hub, or `oac-dev-workload0`.
   (`nist-dev-workload0` went with its hub on 2026-10-28.)
3. **Billing:** whether MOC's billing counts GPUs held by VMs.

## Settled

- **GPU memory is cleared between tenants (2026-10-20, 2026-10-26,
  2026-10-28 after jetty's reinstall).**
  Memory written by one VM read as zero, past the driver, after the GPUs
  were handed back: to the same VM, then to a new VM in another project,
  with a positive control (`test-gpu-memclear.sh`; sampled, one node,
  [memclear-record.md](memclear-record.md)). Read from the host, memory
  is already clear once the VM lets go, with no suspend in between: the
  reset vfio does on release clears it. NVIDIA's confirmation (next
  steps, 1) would back it for compliance. Between containers nothing
  resets the GPU; the host's NVIDIA driver zeroes memory on every
  allocation instead, shown for pods that exit, are killed or are deleted
  (`test-gpu-container-memclear.sh`).
- **Sharing a GPU between containers (2026-10-29).** Between tenants,
  give containers MIG slices or whole GPUs. On jetty, a pod on a MIG slice
  could neither read its neighbours' memory, nor see their use, nor crash
  them. Time-slicing and MPS kept memory private too, but showed each pod
  its neighbours' memory use and activity; time-slicing sets no limit, so
  one pod can take the whole GPU; and under MPS one pod's fault killed
  every other pod on its GPU. Use those within one tenant only (README.md,
  "What can pods sharing a GPU at once see of, or do to, each other?").
- **The GPU Operator's toolkit needs
  `ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED=false` on any
  cluster with more than one tenant,** plus an admission policy keeping the
  `nvidia*` RuntimeClasses to the GPU Operator. Without the setting, a pod
  can use GPUs it never requested; shown on jetty and on oac-dev-workload0,
  which runs oac-apps' chart. Set on jetty 2026-10-29; both are in oac-apps
  PR #208.
- **vGPU is set aside (2026-10-28).** It only pays for VMs smaller than
  one GPU, and costs a per-GPU licence each year, a licence server, a
  private image, an unverified FIPS question and billing by fraction of
  a GPU. On a compliant spoke, one tenant per GPU node rules out the
  cross-tenant packing where the gain would be. If small GPUs are wanted,
  offer MIG to containers instead: no licence, shown on jetty (README.md,
  "Can containers share a GPU without a licence?"). With the GPU
  Operator's default `mig.strategy: single`, though, a slice is advertised
  as `nvidia.com/gpu`, the same name as a whole GPU, so billing would
  charge it as one. Per-slice billing needs `mixed`, where each profile is
  its own resource (`nvidia.com/mig-1g.10gb`), or a collector that reads
  the node's product label. VMs stay on passthrough, charged per GPU. Reopen only for real demand
  for sub-GPU VMs. First check whether any GPU purchase came with NVIDIA
  AI Enterprise (some data-center GPUs include a subscription).
- **A VM gets NVLink between its own GPUs (2026-10-28).** A 4-GPU VM saw
  six bonded links between every pair and copied between any two GPUs at
  133.1 GB/s, against about 23 GB/s through host memory
  (`test-gpu-nvlink.sh`). So a whole-node VM is a full NVLink machine.
  Between GPUs of different VMs, a stock guest sees none of a
  neighbour's NVLink traffic (`test-gpu-nvlink-tenants.sh`); next steps 1
  still stands for a guest with its own driver.
