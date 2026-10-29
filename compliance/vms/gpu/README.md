# GPU Passthrough for VMs

> The options for GPUs in VMs on OAC (passthrough, vGPU, compliant and non-compliant spokes) are summarised in [OPTIONS.md](OPTIONS.md). This page is the runbook behind it.

Giving a VM a physical NVIDIA GPU, and measuring what it costs to move a node between serving containers and serving VMs.

> **Status: passthrough is proven on `jetty` (2026-10-20).** An Ubuntu 24.04 VM on `moc-r4pcc02u16` was given one H100; the guest saw it on its PCI bus (tier 1), the 580-server driver bound it and `nvidia-smi` reported *NVIDIA H100 80GB HBM3* (tier 2), and a CUDA kernel returned correct results with 15.4 GB/s host-to-device (tier 3). Two fixes were needed:
>
> - **`vfio_iommu_type1` was not loaded on the node.** The GPU Operator's VFIO manager loads `vfio-pci` but not this backend, and every GPU VM failed with `vfio 0000:06:00.0: failed to setup container for group 42: No available IOMMU models`. It was loaded by hand (`modprobe vfio_iommu_type1`), which a reboot undoes; `vfio-iommu-type1-machineconfig.yaml` now loads it at boot on jetty's GPU workers (applied 2026-10-20). `setup-passthrough.sh` checks for it.
> - **The in-guest driver install hung** until its 25-minute timeout on the first full run. The script exported `DEBIAN_FRONTEND`, which `sudo` drops, so a package could stop to ask a question with no terminal; the cause is likely, not proven. The script now passes the settings after `sudo` and closes stdin. Tiers 2 and 3 were then run by hand, with those settings, in a VM kept by `KEEP_VM=1`. The fixed script then passed all three tiers on its own the same day, run by `../../tests/cluster-acceptance.sh --gpu`.
>
> **Several VMs per node (2026-10-20):** four 1-GPU VMs ran at once on `moc-r4pcc02u16`, each on a different H100 (four distinct UUIDs, overlapping runs), and all passed tiers 1–3 at 15.4–15.7 GB/s host-to-device.
>
> **The second GPU node (2026-10-26):** `moc-r4pcc02u15` was switched to `vm-passthrough` for one run and back. A 1-GPU VM pinned to it (`NODE=`) passed tiers 1–3, firmware `96.00.DA.00.17` as on u16. Its NVLink links were all inactive, where on 2026-10-20 a 1-GPU VM on u16 saw them up; u15's other three GPUs were unused that time, u16's were held by other VMs with their drivers loaded.
>
> **Two 2-GPU VMs per node (2026-10-26):** `test-gpu-vm-pair.sh` ran two VMs with 2 GPUs each on `moc-r4pcc02u16`, in one project. Both passed tiers 1–3, and while both were running each guest's `nvidia-smi` listed its own 2 GPUs: 4 distinct UUIDs, none shared. In that first run tier 3's CUDA kernel ran on each VM's first GPU only; tier 3 now runs on every GPU in a guest, and a rerun the same day passed with CUDA on all four. GPU firmware (VBIOS) `96.00.DA.00.17` in both guests.
>
> `test-gpu-switch.sh` has not been run. Node-level modality switching *has* been measured independently: see `tests/gpu-switch-timing.sh` (73s / 208s, no reboot).

## Cost warning

**Claimed GPUs are billable on MOC — idle or not, pod or VM.** Anything in
here that creates a user-space GPU workload costs money for as long as it
exists:

| File | Claims a GPU |
|---|---|
| `gpu-vm.yaml` / `test-gpu-vm.sh` | yes — a VM with a GPU hostDevice |
| `test-gpu-switch.sh` | yes — a pod requesting `nvidia.com/gpu: 1` |
| `test-gpu-memclear.sh` | yes — every passthrough GPU on one node |
| `preflight.sh`, `setup-passthrough.sh` | no |
| `../../tests/gpu-switch-timing.sh` | no — and refuses to run if anything else is holding one |
| `../../tests/verify.sh` (T-06/T-07) | no — reads node state only |

**Delete the workload when you are finished.** The GPU Operator's own
daemonsets (driver, device plugin, `vfio-manager`, DCGM) bind and advertise
the hardware but never request it as a pod resource, so they are not
billable — that is just the operator doing its job.

### Target cluster: `jetty`, reinstalled (as of 2026-10-28)

jetty was reinstalled on 2026-10-28 as a spoke of `oac-dev-infra` (FIPS on,
nothing else installed), and set up again by hand for these tests. The
results below from before that date are from the first install, on the same
hardware.

| | State |
|---|---|
| GPU nodes | `a0-88-c2-27-c2-d4` (`moc-r4pcc02u15`) and `a0-88-c2-27-c0-d4` (`moc-r4pcc02u16`), named by MAC since the reinstall — 4× NVIDIA H100-80GB-HBM3 each (8 total) |
| GPU PCI id | `10DE:2330` (GH100 SXM5 80GB) |
| OpenShift | 4.22.14, kernel `5.14.0-687.46.1.el9_8` (4.22.16 and `687.50.1` before the reinstall) |
| OpenShift Virtualization | 4.22.12, from `install-operators.sh` |
| NVIDIA GPU Operator | 26.7.2, `ClusterPolicy` state `ready`, `sandboxWorkloads` on with `defaultWorkload: container` |
| `HyperConverged.permittedHostDevices` | (under `spec.virtualization` in HyperConverged v1) `10DE:2330` → `nvidia.com/GH100_H100_SXM5_80GB`, set by `setup-passthrough.sh` |
| `nvidia.com/gpu.workload.config` | **u16 = `vm-passthrough`** (`GH100_H100_SXM5_80GB=4`); u15 = `container` (`nvidia.com/gpu=4`) |
| `vfio_iommu_type1` | Loaded at boot on both workers (`vfio-iommu-type1-machineconfig.yaml`) |
| **Storage** | `pure-fb-nfsv4` (default) — Portworx CSI → Pure FlashBlade NFSv4.1, cleartext. Installed by hand from oac-apps' `nmstate` and `portworx` charts (below) |
| Control plane | 3 masters, standalone, MachineConfig API present |

Setting it up again, by hand, took these steps beyond the ones in
"Prerequisites", in this order:

1. `vfio-iommu-type1-machineconfig.yaml` (reboots both workers), then
   `install-operators.sh`, then `setup-passthrough.sh` on u16.
2. Storage: oac-apps' `nmstate` and `portworx` charts, rendered with
   `helm template` from jetty's values and applied with `oc apply`. The
   NodeNetworkConfigurationPolicies in those values select the old
   hostnames (`moc-r4p...`), so they were rendered with the MAC-based node
   names instead, and the ExternalSecret was replaced by `px-pure-secret`
   created from AWS by hand (jetty has no External Secrets Operator).
3. **The CDI StorageProfile for `pure-fb-nfsv4`:** ReadWriteMany,
   Filesystem. Without it CDI picks Block for Portworx, and every import
   fails with `MapVolume.MapBlockVolume failed`. oac-apps'
   `openshift-virtualization` chart sets this (`storageProfilePatch`); a
   hand install does not. Virtualization's own boot images
   (`openshift-virtualization-os-images`) made before the patch stay stuck
   until their DataVolumes are deleted.

Re-run `./preflight.sh` rather than trusting this table — it is a snapshot, and
it is the script's whole job to produce a current one.

### Previously inspected: `oac-dev-workload0` (read-only, 2026-10-01)

Kept because it is the contrasting case. 4× H100 on `moc-r4pcc02u05`/`u09`, CNV installed, `sandboxWorkloads.enabled=false`, and `controlPlaneTopology=External` — a hosted control plane with **no MachineConfig API**, so `iommu-machineconfig.yaml` cannot be applied there at all. Access was read-only, so nothing was changed.

## The thing to understand first

A GPU node's cards serve **either** containers **or** VMs. Not both, and not some of each.

With `sandboxWorkloads` enabled, the NVIDIA GPU Operator reads a per-node label, `nvidia.com/gpu.workload.config`, and deploys one of two mutually exclusive stacks on that node:

| Label value | What the operator runs | What the node advertises |
|---|---|---|
| `container` | driver, container-toolkit, device-plugin, DCGM, GFD | `nvidia.com/gpu` |
| `vm-passthrough` | `vfio-manager` (binds the cards to `vfio-pci`), sandbox-device-plugin | a device-specific name, e.g. `nvidia.com/GH100_H100_SXM5_80GB` |
| `vm-vgpu` | vGPU host driver + vgpu-device-manager | mediated-device resources — **out of scope here**, needs an NVIDIA AI Enterprise entitlement and a license server |

The granularity is the **node**. There is no supported way to leave two of a node's four H100s serving containers while the other two back VMs. The unit of mixed use is a node, for as long as you hold it.

Switching is a label change, and after one-time setup it needs no reboot — but it does need every GPU-holding pod off the node first, because the NVIDIA kernel driver will not release a card another process has open. `test-gpu-switch.sh` exists to put a number on that.

### GPU VMs and RDMA do not share a node

A node can host **GPU VMs** or run **RDMA workloads** (RoCEv2, NCCL across nodes), not both. The two need the IOMMU in opposite states:

- **GPU passthrough needs the IOMMU on.** `vfio-pci` cannot claim a card without it (prerequisite 2 below).
- **RDMA needs it off.** On an earlier, non-compliant cluster (early 2026), NCCL tests and even plain `ib_write_bw` failed badly until the IOMMU was disabled. Not yet reproduced on `jetty`.

On these AMD nodes the IOMMU is on by default (firmware, Translated mode) with no kernel argument. So:

- **An RDMA node needs `amd_iommu=off`**: a kernel argument, so a dedicated MachineConfigPool and a reboot.
- **Moving a node between the RDMA role and the GPU-VM role costs a reboot.** The "label change, no reboot" switch above holds only between containers and GPU VMs on a node whose IOMMU stays on.
- **Plan GPU nodes as two pools:** RDMA (IOMMU off) and GPU VMs (IOMMU on). Container workloads that don't use RDMA can run in either.

What this does *not* restrict:

- **VMs without a GPU.** KVM does not need the IOMMU, so ordinary VMs run on RDMA nodes.
- **Compliance.** No Compliance Operator profile checks the IOMMU (all 49 shipped on `jetty` checked 2026-10-10; the rule `rhcos4-grub2-enable-iommu-force` is in none of them), and FIPS does not involve it. Running RDMA nodes without DMA remapping is at most a sentence in the SSP.

Untested options, recorded so nobody re-derives them:

- **`iommu=pt`** (host devices bypass translation, `vfio` still isolated) might let one node do both. Whether it fixes the RDMA failures is unknown here. `iommu-machineconfig.yaml` already carries it.
- **GPUDirect RDMA** usually also wants PCIe ACS off, which merges IOMMU groups and can break per-GPU passthrough even under `iommu=pt`.
- **RDMA inside a VM** needs a NIC or SR-IOV VF passed through, which needs the IOMMU on the host. Out of scope here.

## Layout

| File | Who runs it | What it does |
|---|---|---|
| `preflight.sh` | anyone, first | **Start here on any cluster.** Read-only: reports whether GPU passthrough is feasible, what is missing, and what *you* are allowed to do. Creates nothing, needs no admin. |
| `install-operators.sh` | admin, once | Installs NFD, the NVIDIA GPU Operator and OpenShift Virtualization on a cluster that has the hardware but none of the software. Report-only until `APPLY=1`. |
| `vfio-iommu-type1-machineconfig.yaml` | admin, once | Loads `vfio_iommu_type1` at boot. Reboots the pool's nodes. Standalone OpenShift only |
| `iommu-machineconfig.yaml` | admin, once, **if needed** | Dedicated MachineConfigPool + IOMMU kernel arguments. Costs reboots. Standalone OpenShift only — not usable on a hosted control plane, and expected to be unnecessary on AMD. |
| `setup-passthrough.sh` | admin | Reports, and with `APPLY=1` configures, one node for passthrough; teaches KubeVirt the device |
| `test-gpu-vm.sh` | project user | Boots a VM with a GPU and verifies it in three tiers. `NODE=` pins it to a node, `BW_RUNS=` repeats the bandwidth measurement |
| `test-gpu-vm-pair.sh` | project user | Two VMs with `GPUS_PER_VM` GPUs each (default 2), side by side on one node, all three tiers; checks no GPU is shared. About 20 minutes of 4 GPUs |
| `test-gpu-memclear.sh` | project user | Whether GPU memory is cleared when a VM hands its GPUs back. `HANDOFF=restart` (default) restarts the same VM; `HANDOFF=new-vm` deletes it and scans from a new VM in a second project with no GPU driver. `HANDOFF=host` also reads the GPUs from the host while no VM holds them (privileged debug pod), and `HOST_AWAKE=1` keeps them out of D3 for it. Then writes through the same window and reads back, to show the scan reached memory. Holds every passthrough GPU on a node for 30 to 40 minutes |
| `test-gpu-nvlink.sh` | project user | One VM with `GPU_COUNT` GPUs (default 4): topology and link state from the guest, then 1 GiB copies between every pair with peer access on and off. Passes if every pair gets NVLink-speed peer access. About 20 minutes of 4 GPUs |
| `test-gpu-container-memclear.sh` | project user | The container version: pod A fills all GPU memory (or every MIG slice) on a container-mode node and exits, is killed or is deleted; pod B takes the same GPUs and counts what is left. `RELABEL=` repartitions MIG between the two (not yet shown to work, below). About 5 minutes of the node's GPUs per handoff, plus pulling a CUDA devel image |
| `test-gpu-sharing.sh` | project user | Pods using one GPU at the same time (MIG, time-slicing or MPS): holder pods fill and keep checking their memory while a neighbour pod reads what `nvidia-smi` shows, scans what it can allocate, and faults. Reports whether the neighbour read, changed or killed anything. About 10 minutes of every share on the node |
| `memtest.cu`, `memtest-run.sh` | (used by the two above) | The CUDA program both run in their pods, and the wrapper that compiles it and runs one process per MIG slice |
| `device-plugin-sharing.yaml` | admin | Device plugin configs for time-slicing and MPS (4 pods per GPU), chosen per node by label; apply and undo commands in its header |
| `gpu-vm.yaml` | project user | The same VM as a hand-applied Template, for poking at by console |
| `test-gpu-switch.sh` | admin | **Destructive.** Times a container → VM → container round trip on a node |
| `cleanup.sh` | either | Tears down test objects; `REVERT_NODE=1` also puts the node back |

## Taking this to a different cluster

Nothing here is specific to `oac-dev-workload0`; the resource names, PCI ids and GPU node names are all discovered at runtime rather than hardcoded. On a new cluster:

```bash
cd compliance/vms/gpu
./preflight.sh                              # what works, what is missing, what you may do
AS_ADMIN=--as=system:admin ./preflight.sh   # same, plus what impersonation buys you
```

It reads only, so it is safe on a cluster you have just been handed and do not yet trust. The two cluster properties that most change the plan are the ones it checks first: whether the GPU nodes carry `kubevirt.io/schedulable=true`, and whether `controlPlaneTopology` is `External` — the latter decides whether IOMMU kernel arguments are something you can apply at all.

## Prerequisites

Beyond `oc`, `virtctl`, `python3` and the OpenShift Virtualization install the rest of `vms/` needs:

0. **The three operators.** On a cluster that has GPU hardware and nothing else — which is exactly what `jetty` was — `install-operators.sh` puts NFD, the NVIDIA GPU Operator and OpenShift Virtualization in place:

   ```bash
   ./install-operators.sh              # report only
   APPLY=1 ./install-operators.sh      # ~12 min, mostly waiting on the driver build
   ```

   It takes the operand CRs from each CSV's own `alm-examples` annotation rather than hardcoding them, so the shapes match the installed version instead of whatever was current when this was written. The only field it overrides is `sandboxWorkloads`, set to `enabled: true` with `defaultWorkload: container` — which changes no node's behaviour, and only makes the per-node `nvidia.com/gpu.workload.config` label meaningful.

   Expect `nvidia-dcgm-exporter` to crashloop a few times on the way up: it dials the DCGM hostengine before the hostengine is listening. It resolves itself. Nothing in the passthrough path depends on it.

1. **OpenShift Virtualization running on the GPU nodes.** ✅ **Confirmed on `jetty`** (2026-10-01): both H100 nodes report `kubevirt.io/schedulable=true` and `machine-type.node.kubevirt.io/q35=true`.

   ```bash
   oc get nodes -l nvidia.com/gpu.present=true \
     -o custom-columns='NODE:.metadata.name,KUBEVIRT:.metadata.labels.kubevirt\.io/schedulable,GPUS:.status.allocatable.nvidia\.com/gpu'
   ```

   A GPU node without `kubevirt.io/schedulable=true` cannot host a VM at all and nothing else here applies. Re-check on any other cluster before assuming.

2. **IOMMU enabled on the node.** `vfio-pci` cannot claim a device without it. Ground truth is whether the kernel populated IOMMU groups:

   ```bash
   oc debug node/<node> -- chroot /host ls /sys/kernel/iommu_groups | wc -l   # want > 0
   ```

   That needs permission to create a debug pod. Without it, NFD's copy of the kernel build config is readable by any authenticated user and is a strong indication:

   ```bash
   oc get nodefeature <node> -n openshift-nfd \
     -o jsonpath='{.spec.features.attributes.kernel\.config.elements.AMD_IOMMU}'
   ```

   On both the oac-dev and the jetty H100 nodes this returns `y`. **`CONFIG_AMD_IOMMU=y` means the driver is built in, and on AMD it initialises from the firmware IVRS table by default** — `amd_iommu=on` is the default, not an opt-in. So the expectation is that no kernel-argument change is needed at all.

   ✅ **This has now been checked directly on `jetty`, and it holds.** Both H100 nodes report **103 IOMMU groups**, and their `/proc/cmdline` contains no `amd_iommu=` or `iommu=` argument of any kind. The IOMMU is on because the firmware says so, not because anyone asked for it. No kernel arguments, no MachineConfig, no reboots.

   The NFD route remains an indication rather than proof on an unknown cluster: an explicit `amd_iommu=off`, or the IOMMU disabled in the BIOS, would still leave zero groups and is invisible from the API. `vfio-manager` is the backstop — with the IOMMU off it fails loudly rather than mis-binding.

   **If kernel arguments *are* needed, how to apply them depends on the cluster topology.** `iommu-machineconfig.yaml` creates a dedicated MachineConfigPool so the reboots hit only the GPU-VM nodes rather than rolling the whole `worker` pool (budget two reboots per node: one to join the pool, one to apply the arguments). But it **only works on standalone OpenShift**. On a hosted control plane there is no MachineConfig API in the guest cluster:

   ```bash
   oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}'   # External => hosted
   ```

   `oac-dev-workload0` returns `External`, and `machineconfigs`/`machineconfigpools` are not served there. Kernel arguments for those workers live on the `NodePool` object in the **management** cluster, which a guest-cluster admin cannot reach — it is a platform-team request. `setup-passthrough.sh` detects which case it is and prints the applicable instructions.

3. **The GPU Operator with `sandboxWorkloads.enabled`.** ✅ Already on in jetty's `gpu-cluster-policy`, set by `install-operators.sh`. On a cluster where it is off, `setup-passthrough.sh` turns it on, pinning `defaultWorkload: container` so that unlabelled nodes keep behaving exactly as they do today.

## Setting a node up

Read-only first. It reports current state and what it would change, and exits:

```bash
cd compliance/vms/gpu
NODE=moc-r4pcc02u16 ./setup-passthrough.sh
```

Then, after the node's GPU workloads are drained:

```bash
NODE=moc-r4pcc02u16 APPLY=1 ./setup-passthrough.sh
```

That enables `sandboxWorkloads`, labels the node `vm-passthrough`, waits for the sandbox device plugin to advertise the card, **discovers** the resource name rather than guessing it, and adds the PCI id to `HyperConverged.spec.permittedHostDevices` with `externalResourceProvider: true` — which tells KubeVirt the NVIDIA plugin owns advertising that device, so the two do not both try to manage it.

Going back:

```bash
NODE=moc-r4pcc02u16 APPLY=1 TARGET_WORKLOAD=container ./setup-passthrough.sh
```

| Variable | Default | Notes |
|---|---|---|
| `NODE` | — | required; the script will not pick a node for you |
| `APPLY` | `0` | `1` mutates; otherwise report only |
| `TARGET_WORKLOAD` | `vm-passthrough` | or `container` |
| `PCI_ID` | discovered | e.g. `10DE:2330`; set it if `oc debug` is blocked |
| `GPU_OPERATOR_NS` | `nvidia-gpu-operator` | |
| `AS_ADMIN` | `--as=system:admin` | set empty if you are cluster-admin without impersonate rights |

---

# GPU VM Test

```bash
cd compliance/vms/gpu
./test-gpu-vm.sh
```

Provisions a root disk through CDI, boots a VM with the GPU attached, and verifies it in three tiers. The tiers exist because the three claims fail independently and a partial result is still worth having — when a tier fails the ones above it are reported as **skipped**, not failed, so the output says how far the platform got rather than just "no".

| Tier | Check | What it proves |
|---|---|---|
| 0 | DataVolume `Succeeded`, VM reaches `Ready` | Setup. A GPU VM that cannot be scheduled is diagnosed early with the virt-launcher pod's own events, rather than sitting `Pending` until the boot timeout |
| 0 | `deviceStatus.gpuStatuses` names the device | KubeVirt's own record of what it handed over — stronger than "the spec asked for one" |
| **1** | Guest's PCI bus has an NVIDIA 3D controller | The passthrough plumbing works end to end: IOMMU, `vfio-pci`, `permittedHostDevices`, q35 |
| **2** | `nvidia-smi` in the guest reports the card | The device is functional, not merely visible |
| **3** | A CUDA kernel runs and returns correct results | The GPU does real work, and yields a host-to-device bandwidth number measured across the passthrough path |

Tier 1 reads `/sys/bus/pci/devices` rather than shelling out to `lspci`, because `pciutils` is not in every cloud image and sysfs always is.

It also reports, without failing: the VMI's `LiveMigratable` condition, and `nvidia-smi nvlink -s` / `topo -m` from inside the guest.

### Guest image

Defaults to Ubuntu 24.04 (`quay.io/containerdisks/ubuntu:24.04`) rather than the Fedora the other `vms/` scripts use. Ubuntu ships NVIDIA's datacenter drivers in its own archive, so tier 2 is one `apt-get install` with no third-party repo and no akmod rebuild against a kernel that moves under it. Tier 3 uses the distro's own `nvidia-cuda-toolkit` package for the same reason: one stable package name instead of a repo URL and version-suffixed names that change every CUDA release. It is a large download — set `MAX_TIER=2` to skip it.

The driver install is deliberately **not** in cloud-init. Inline `userData` is capped at 2048 bytes and these namespaces cannot create Secrets, so anything substantial has to go over `virtctl ssh` after boot.

| Variable | Default | Notes |
|---|---|---|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `GPU_RESOURCE` | discovered | the sandbox plugin's resource name; found by scanning node allocatables |
| `GPU_COUNT` | `1` | |
| `IMAGE_URL` | `docker://quay.io/containerdisks/ubuntu:24.04` | |
| `BOOT_MODE` | auto | `dv` imports the image into a PVC via CDI; `containerdisk` boots it ephemerally with no storage at all. Auto-selects `dv` when a StorageClass exists. **`containerdisk` does not work with a GPU** — see below |
| `GUEST_USER` | `ubuntu` | |
| `DRIVER_BRANCH` | `580` | tried first; falls back to `ubuntu-drivers install --gpgpu` |
| `DRIVER_INSTALL` | unset | override the whole tier-2 install command for a non-Ubuntu guest |
| `MAX_TIER` | `3` | `2` skips the CUDA toolkit download |
| `MEMORY` | `16Gi` | every byte is pinned in host RAM — see below |
| `DISK_SIZE` | `40Gi` | distro + driver + toolkit |
| `KEEP_VM` | `0` | `1` leaves the VM up for `virtctl console` |

### Two things that bite

**Guest memory is locked, not requested.** VFIO DMA needs every guest page present and pinned, so a 16Gi GPU VM reserves 16Gi of host RAM outright. None of it is overcommittable, and the virt-launcher pod carries additional overhead for the card's BARs — an 80 GB H100 has large ones. If VMs fail to start with memory errors, `HyperConverged.spec.additionalGuestMemoryOverheadRatio` is the knob.

**A GPU VM cannot live migrate.** A host device's state has nowhere to go, so KubeVirt reports `LiveMigratable=False` and the VM is pinned to its node. The VMs in this directory therefore set `evictionStrategy: None` rather than the `LiveMigrate` that `test-vm-storage.sh` and `test-vm-migration.sh` use — `None` states the truth plainly instead of leaving a node drain blocked forever on a migration that can never be scheduled.

This directly inverts what `../test-vm-migration.sh` proves for an ordinary VM. Everything that makes node maintenance survivable for a normal VM user — drains, upgrades, MachineConfig rollouts — hard-kills a GPU VM instead. That is a platform property, not a bug, but it needs saying out loud before anyone offers GPU VMs to researchers.

**A third thing bites, and it is the one that stopped this run.** `containerDisk` is the obvious way to boot a VM on a cluster with no storage — the image is pulled by the node, nothing is provisioned, no PVC, no CDI. It does not work with PCI passthrough on CNV 4.22.9. Measured on `jetty` on 2026-10-01, isolated to a single variable: a `containerDisk` VM with no GPU boots and reports `Ready=True` on `moc-r4pcc02u16`; the identical VM with one `nvidia.com/GH100_H100_SXM5_80GB` added reproducibly hangs, virt-handler logging `containerdisk rootdisk still not ready after one minute` while the `volumerootdisk` sidecar has already exited 0 after ~6s saying its socket "does not exist anymore".

Ruled out, each by direct observation rather than reasoning: **memory** (reproduced at `MEMORY=2Gi`), **SELinux** (Enforcing, zero AVC denials on the node during the failure), and **QoS / ephemeral-storage eviction** (the pod is `Burstable` either way — this was my own hypothesis and it was wrong). The root cause is not known. What is known is that the combination does not work there, so a GPU VM needs a real PVC, which means a real StorageClass. `preflight.sh` now checks for one up front and `test-gpu-vm.sh` warns if you force `BOOT_MODE=containerdisk` with a GPU attached.

## Result: proven on `jetty` (2026-10-20), again after the reinstall (2026-10-28); the first attempt, 2026-10-01

The 2026-10-20 run passed tiers 1 to 3 (status at the top of this page).
After the reinstall, on u16 (2026-10-28): `test-gpu-vm.sh` with one GPU
passed all 6 checks at 15.52 GB/s host-to-device, `test-gpu-vm-pair.sh` ran
two 2-GPU VMs side by side on 4 distinct GPUs, all passing, and the VBIOS
was again `96.00.DA.00.17`. `../test-vm-storage.sh` passed 9 of 9 on
`pure-fb-nfsv4` first. What follows is the first attempt, kept for what it
ruled out.

Run on 2026-10-01 against `jetty` (OpenShift Virtualization 4.22.9, GPU Operator 26.7.1, NFD 4.22.0, node `moc-r4pcc02u16`).

**Established:**

- The node flipped to `vm-passthrough` cleanly. `nvidia.com/GH100_H100_SXM5_80GB: 4` appeared, `nvidia.com/gpu` went to `0`, and `moc-r4pcc02u15` was untouched at `nvidia.com/gpu: 4` throughout — `defaultWorkload: container` really does confine the change to the labelled node.
- `10DE:2330` is allow-listed on the HyperConverged as `nvidia.com/GH100_H100_SXM5_80GB` with `externalResourceProvider: true`, and that propagated to the KubeVirt CR, so the webhook accepts a VM requesting it.
- A GPU VM **schedules onto the node and is allocated an H100** — the virt-launcher pod gets the device. The scheduling and admission half of the problem is solved.
- IOMMU needed no intervention at all: 103 IOMMU groups on both workers, no `amd_iommu=` or `iommu=` anywhere in `/proc/cmdline`. See prerequisite 2.
- `fips=1` is set on these nodes and did not impede the NVIDIA driver build, which was a plausible failure mode that simply did not materialise.

**Not established then:** the guest never booted, so tiers 1–3 (does the guest see the card, load the driver, run CUDA) stayed open until 2026-10-20. At the time (2026-10-01) `jetty` had no working storage, so the DataVolume path could not provision a root disk, and the containerDisk path is incompatible with passthrough as described above. Storage has worked since 2026-10-02 (Pure FlashBlade via Portworx, now `nfs-over-tls`); the 2026-10-20 re-run booted from a DataVolume on it.

---

# Context-Switch Test

**This test is destructive.** It cordons the node and deletes every GPU-holding pod on it, in every namespace, twice. It restores the original label and uncordons on exit including on failure, but evicted pods are not recreated — controller-managed ones reschedule themselves, bare pods and Notebooks do not. It refuses to start without an explicit confirmation, and prints the pods at risk first.

```bash
cd compliance/vms/gpu
NODE=moc-r4pcc02u16 ./test-gpu-switch.sh                              # lists what it would evict, then stops
NODE=moc-r4pcc02u16 CONFIRM=yes-drain-this-node ./test-gpu-switch.sh  # runs
```

### What it asserts

| # | Check | Why it matters |
|---|---|---|
| 1 | Node starts out advertising `nvidia.com/gpu` | Establishes the baseline the round trip has to return to |
| 2 | A container workload can get a GPU on the node | Not "is the driver loaded" but "can an ordinary user still get a card here" — the thing that actually breaks |
| 3 | GPU pods clear within `DRAIN_TIMEOUT` | The drain is mandatory: the NVIDIA driver will not release a card another process holds, so `vfio-pci` cannot claim it and the switch stalls silently |
| 4 | Container GPU capacity is withdrawn after the flip | The operator tore the container stack down |
| 5 | `vfio-manager` is Running on the node | Reported, not fatal — check 6 is the real evidence |
| 6 | The passthrough resource appears | The node can now host a GPU VM |
| 7 | KubeVirt permits that resource | Without it the device is allocatable but every VM requesting it is rejected by the webhook |
| 8 | The passthrough resource is withdrawn after flipping back | |
| 9 | All *N* container GPUs come back | The slow half: the driver daemonset has to reload the kernel module before any card is advertised again |
| 10 | A container workload can get a GPU again | The node is genuinely returned to service, not just labelled as if it were |

Each transition is timed separately, and the drain is timed apart from the flip, because on a busy node the drain dominates and conflating the two would make the operator look slow for someone else's reason.

### What it reports

A table of per-milestone and total durations:

```
  drain N GPU pod(s)                         __s
    container GPUs withdrawn                 __s
    vfio-manager running                     __s
    passthrough resource advertised          __s
  container -> vm-passthrough TOTAL          __s
    including drain                          __s
    passthrough resource withdrawn           __s
    container GPUs restored                  __s
  vm-passthrough -> container TOTAL          __s
  ROUND TRIP TOTAL                           __s
```

| Variable | Default | Notes |
|---|---|---|
| `NODE` | — | required |
| `CONFIRM` | — | must be `yes-drain-this-node` |
| `NAMESPACE` | `mm-test` | where the throwaway probe pod goes |
| `GPU_PROBE_IMAGE` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | any small image: the container toolkit injects `nvidia-smi` and the driver libraries into a pod that requests a GPU, so the image needs nothing NVIDIA-specific |
| `SWITCH_TIMEOUT` | `600` | per direction |
| `DRAIN_TIMEOUT` | `300` | |

## Result: not yet run

Never boots a VM, so storage was never a factor. Note that `tests/gpu-switch-timing.sh` has since measured the label-flip switch (73s / 208s, no reboot) without a drain; this test adds the drain and the eviction cost. It needs a node in `container` mode to start from, so `moc-r4pcc02u16` has to be flipped back first:

```bash
NODE=moc-r4pcc02u16 APPLY=1 TARGET_WORKLOAD=container ./setup-passthrough.sh
NODE=moc-r4pcc02u16 CONFIRM=yes-drain-this-node ./test-gpu-switch.sh
```

Both nodes on `jetty` currently have zero GPU-holding pods, so the drain half of the measurement will be a floor — the cost on a node with real tenants on it will be higher, and the script times the drain separately for that reason.

---

## Open questions these tests should settle

Written down because they are the reason to run this at all, not afterthoughts.

- **Does passing a subset of an NVLink clique work?** **Yes (2026-10-20).** With four 1-GPU VMs on one node, each guest ran CUDA normally. `nvidia-smi nvlink -s` in three guests showed all 18 links up at 26.562 GB/s, and in one guest 12 up and 6 inactive (one peer's links, likely while that peer's guest was still loading its driver). A 1-GPU VM cannot use NVLink, since its peers are not in the guest, but the usable unit is one GPU, not four. **Open:** links between GPUs held by different tenants are physically up. A guest with the stock driver sees no peers; whether one running its own driver can reach a peer over NVLink is a question for NVIDIA (see OPTIONS.md, next steps). Until then, compliant spokes give one tenant whole nodes or 4-GPU VMs.
- **Can one VM use NVLink between its own GPUs?** **Yes (2026-10-28).** `test-gpu-nvlink.sh`, one VM with all four of u16's GPUs: `nvidia-smi topo -m` in the guest shows `NV6` (six bonded links) between every pair, all 18 links up on each GPU, and peer access between all 12 ordered pairs. A 1 GiB copy took the NVLink path at 133.1 GB/s for every pair (about 89% of six links' 150 GB/s), against 22.8–23.4 GB/s staged through host memory. No Fabric Manager is needed: this 4-GPU board has no NVSwitch. Between GPUs held by different VMs, see the bullet above.
- **Can containers share a GPU without a licence?** **Yes (2026-10-28), with MIG.** u15 (container mode) labelled `nvidia.com/mig.config=all-1g.10gb`: the MIG manager split its 4 H100s into 28 slices of 10 GB and 16 SMs, and eight CUDA pods ran at once, each on its own slice (8 distinct MIG UUIDs over all four GPUs), all passing NVIDIA's `vectorAdd`. Reverted with `all-disabled`. With the ClusterPolicy's default `mig.strategy: single` a slice is advertised as plain `nvidia.com/gpu`, the same name as a whole GPU; only the node label (`NVIDIA-H100-80GB-HBM3-MIG-1g.10gb`) says otherwise. Billing per slice needs `mixed` (`nvidia.com/mig-1g.10gb`) or a collector that reads the label. `mixed` was not tried: it is a cluster-wide ClusterPolicy change.
- **How long does the driver stack actually take to come back?** This is the number that decides whether node-level time-sharing is practical or whether GPU VM nodes should just be permanently dedicated.
- **What is the CUDA bandwidth penalty, if any?** **About 8% on the same node (2026-10-26).** The tier-3 program (pageable host memory, 512 MiB host-to-device) gave 16.6–16.8 GB/s in a container on `moc-r4pcc02u15` (5 runs, 2026-10-20) and 15.09–15.42 GB/s in a VM on the same node (5 runs, 2026-10-26; nothing on jetty changed in between): 7–10%. VMs on `moc-r4pcc02u16` gave 15.4–15.7 GB/s (2026-10-20), about 7% against u15's containers. Same program throughout, but not the card's peak.
- **Does any of this survive a node reboot?** **Yes (2026-10-20).** After the MachineConfig rebooted both nodes, `u16` came back with its 4 GPUs on `vfio-pci` and `vfio_iommu_type1` loaded, and the four-VM run above passed on it.
- **Is GPU memory cleared between tenants?** `test-gpu-memclear.sh` fills every GPU's memory with a pattern, stops the VM so the GPUs go back to the host, starts it and scans. A control scan without the reset shows whether the method can see leftovers at all. **Cleared (2026-10-20).** CUDA alone could not answer it: the guest's NVIDIA driver clears memory before handing it out. So `pramin.py` reads memory through BAR0's PRAMIN window, bypassing the driver. With the pattern held on all 4 GPUs, it found the pattern in 98.7% of sampled words (the rest are driver-reserved). The VM was then stopped mid-hold, as a tenant's VM would be, and started with the NVIDIA driver blocked from loading: every sampled word on every GPU read zero. **Repeated in a new VM (2026-10-26):** with `HANDOFF=new-vm`, VM A (pattern in 5,111,808 of 5,177,344 sampled words on each GPU) was deleted with its disk, and a new VM in a second project, with no GPU driver loaded, logged or bound, took the same four GPUs: every sampled word read zero. A second run added a positive control: a value written through the same window to 4 KiB of every GiB read back on all four GPUs, so the scan reached memory and its zeros are real. Firmware `96.00.DA.00.17`. What it ran on: [memclear-record.md](memclear-record.md), which also says what it does not show. Limits: 256 KiB sampled per GiB, not every byte; one node, one firmware. **Repeated after the reinstall (2026-10-28)**, on kernel `687.46.1`, with the same numbers and the positive control. The acceptance suite compares that record with every passthrough node.
- **What clears it?** **The reset vfio does when a VM lets go (2026-10-28).** `HANDOFF=host` reads the GPUs from the host, in a privileged debug pod, between stopping the VM and starting it again. With the pattern held when the VM stopped, the host read zero in every sampled word on all four GPUs, values it wrote through the same window read back (80,896 of 80,896 each), and the window register was back at its power-on value (`0x00000000`, from the driver's `0x0013e960`). So memory is clear before any next VM opens the GPUs. vfio also suspends an idle GPU to D3hot, where reads fail slowly (the first host read never finished); `HOST_AWAKE=1` holds runtime power management on from before the stop, and with the GPUs in D0 throughout, memory was still clear: the reset (`flr`, then `bus`) does it, not the suspend. Whether the H100's firmware clears memory on every function-level reset, and whether that is guaranteed, is NVIDIA's to say: PCIe does not require it.
- **Is GPU memory cleared between containers?** **Yes, by the host's NVIDIA driver (2026-10-28).** Between pods nothing resets the GPU, so this is a different mechanism. `test-gpu-container-memclear.sh` on u15: pod A filled 78.6 GiB on each of the 4 GPUs, then exited, killed itself with SIGKILL, or was deleted while holding the memory; pod B took the same 4 GPUs (UUIDs checked), allocated the same amount without writing it, and read zero in every word, all three times. The driver zeroes memory on every allocation, even within one process (pod A's free-and-reallocate control read zero too), so CUDA, which is all a container tenant has, cannot reach memory it did not get from a zeroing allocation. Unprivileged pods, whole GPUs. **The same on MIG slices (2026-10-29):** with `all-1g.10gb`, pod A filled 9.6 GiB on each of the 28 slices, and pod B, on the same 28 slices, read zero in every word for all three handoffs. Clearing between *different* slice layouts (`RELABEL=`) is not shown: the one attempt scanned nothing (the device plugin advertised 0 GPUs while restarting, since fixed in the script) and left two GPUs in the old layout until relabelled. Not tested: anything CUDA cannot see.
- **What can pods sharing a GPU at once see of, or do to, each other?** `test-gpu-sharing.sh` on u15 (2026-10-29): holder pods on every share but one fill their memory and recount it every 10 s; a neighbour on the last share, on a physical GPU three to six holders are using, reads `nvidia-smi`, scans all it can allocate, then writes through an invalid address.

  | Sharing | Neighbour read others' memory | `nvidia-smi` showed others' use | Neighbour's fault killed others | Per-pod limits |
  |---|---|---|---|---|
  | MIG `all-1g.10gb` (6 holders on its GPU) | No | No (`Insufficient Permissions`) | No | Memory and compute, in hardware |
  | Time-slicing ×4 (3 holders) | No | Yes: 60,073 of 81,559 MiB in use, utilisation | No | **None**: a pod can take the whole GPU |
  | MPS ×4 (3 holders) | No | Yes: 59,004 MiB in use | **Yes: all 3 died** with the neighbour's `cudaErrorIllegalAddress` | Memory and compute caps |

  Memory never leaks: every allocation is zeroed by the driver. The differences are side channels and availability. MPS runs every pod on a GPU through one server, so a fatal fault in one kills them all, as NVIDIA documents. Pods on other GPUs were unaffected in every case. So between tenants: MIG slices or whole GPUs; time-slicing and MPS only within one tenant.
- **Can a pod use a GPU it did not request?** **On a default GPU Operator install, yes; jetty's is now set so it cannot (2026-10-29).** With the container toolkit's defaults, an unprivileged pod could use GPUs it never requested, outside the device plugin, quotas and billing, including GPUs and MIG slices other pods held. Setting `ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED=false` in the ClusterPolicy's `toolkit.env`, as NVIDIA advises for multi-tenant clusters, closed it on jetty; pods requesting GPUs still got them (through CDI). Every GPU cluster with more than one tenant needs that setting.
