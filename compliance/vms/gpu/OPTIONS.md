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
| 3. One GPU shared by several VMs | Only with **NVIDIA vGPU**: MIG-backed slices or time-sliced shares | NVIDIA AI Enterprise, plus a licence server | MOC has no licence today |

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
| Status at MOC | Proven on jetty | Not started | Not started |

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
| Between tenants | Reuse the GPU | Check that the GPU is reset and its memory cleared before the next VM gets it. **To verify** |
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

1. **Reset between tenants:** whether the GPU's memory is cleared when a VM
   releases it (`test-gpu-memclear.sh`). This decides passthrough on
   compliant spokes.
2. **NVLink between tenants:** a 1-GPU VM works with its NVLink peers in
   other VMs, and most links stay physically up. Whether one guest can use
   them to reach a peer's memory must be settled before compliant use.
3. **On a spoke:** passthrough on a hosted cluster, with a GPU-VM NodePool.
   `nist-dev-workload0` (being built, with H100s) or `oac-dev-workload0`.
4. **Billing:** whether MOC's billing counts GPUs held by VMs.
5. **vGPU:** price the licence, then decide.
