# GPU Passthrough for VMs

Giving a VM a physical NVIDIA GPU, and measuring what it costs to move a node between serving containers and serving VMs.

> **Status: the passthrough path is built and partly proven on `jetty`.** `preflight.sh`, `install-operators.sh` and `setup-passthrough.sh` (including `APPLY=1`) have all run against real hardware. A GPU VM **schedules and is allocated an H100**. The original blocker — no working storage — was resolved on 2026-10-02, but `test-gpu-vm.sh` has **not been re-run since**, so a full guest boot is still unproven. `test-gpu-switch.sh` has not been run. Node-level modality switching *has* been measured independently: see `tests/gpu-switch-timing.sh` (73s / 208s, no reboot).

## Cost warning

**Claimed GPUs are billable on MOC — idle or not, pod or VM.** Anything in
here that creates a user-space GPU workload costs money for as long as it
exists:

| File | Claims a GPU |
|---|---|
| `gpu-vm.yaml` / `test-gpu-vm.sh` | yes — a VM with a GPU hostDevice |
| `test-gpu-switch.sh` | yes — a pod requesting `nvidia.com/gpu: 1` |
| `preflight.sh`, `setup-passthrough.sh` | no |
| `../../tests/gpu-switch-timing.sh` | no — and refuses to run if anything else is holding one |
| `../../tests/verify.sh` (T-06/T-07) | no — reads node state only |

**Delete the workload when you are finished.** The GPU Operator's own
daemonsets (driver, device plugin, `vfio-manager`, DCGM) bind and advertise
the hardware but never request it as a pod resource, so they are not
billable — that is just the operator doing its job.

### Target cluster: `jetty` (as of 2026-10-01)

| | State |
|---|---|
| GPU nodes | `moc-r4pcc02u15`, `moc-r4pcc02u16` — 4× NVIDIA H100-80GB-HBM3 each (8 total) |
| GPU PCI id | `10DE:2330` (GH100 SXM5 80GB) at `06:00.0`, `26:00.0`, `a6:00.0`, `c6:00.0` |
| OpenShift Virtualization | 4.22.9 — **both GPU nodes `kubevirt.io/schedulable=true`**, q35 available |
| NVIDIA GPU Operator | 26.7.1, `ClusterPolicy` state `ready`, 4 allocatable `nvidia.com/gpu` per node |
| `ClusterPolicy.sandboxWorkloads` | `{"mode":"kubevirt","defaultWorkload":"container","enabled":true}` — ready to accept the node label |
| `HyperConverged.permittedHostDevices` | ✅ `10DE:2330` → `nvidia.com/GH100_H100_SXM5_80GB`, `externalResourceProvider: true` |
| `nvidia.com/gpu.workload.config` | **`u16` = `vm-passthrough`** (`GH100_H100_SXM5_80GB=4`, `nvidia.com/gpu=0`); `u15` unset, still serving containers with `nvidia.com/gpu=4` |
| **Storage** | ✅ **`pure-fb-nfsv4` (default)** — Portworx CSI → Pure FlashBlade NFSv4.1. Was broken until 2026-10-02 (storage VLAN not trunked to the array); now working. The 7 TB `nvme1n1` on each worker remains untouched and unused |
| IOMMU | ✅ **confirmed active: 103 groups**, and `/proc/cmdline` carries no `amd_iommu=`/`iommu=` argument at all |
| Current GPU load | both nodes idle of **GPU** workloads — but see the warning below |
| Control plane | `HighlyAvailable` — standalone, MachineConfig API present |

The node kernel also runs `fips=1`, which did not impede the driver build.

> ### ⚠️ `test-gpu-switch.sh` is NOT safe to run as-is (2026-10-02)
>
> It cordons and drains **`moc-r4pcc02u16`**, which now hosts **RHACS `central`
> and `central-db`** — the ACS control plane and its PostgreSQL database.
>
> "Both nodes idle" is true of *GPU* workloads only, and is now misleading:
> the node is not idle. RHACS pods hold no GPUs so a GPU-scoped drain would not
> evict them, but a full drain would, and taking `central-db` down mid-write is
> not something to do casually.
>
> Check before running:
> ```sh
> oc get pods -n stackrox -o wide | grep central
> ```
> Prefer `moc-r4pcc02u15` for switch testing, or stop RHACS first.

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

## Layout

| File | Who runs it | What it does |
|---|---|---|
| `preflight.sh` | anyone, first | **Start here on any cluster.** Read-only: reports whether GPU passthrough is feasible, what is missing, and what *you* are allowed to do. Creates nothing, needs no admin. |
| `install-operators.sh` | admin, once | Installs NFD, the NVIDIA GPU Operator and OpenShift Virtualization on a cluster that has the hardware but none of the software. Report-only until `APPLY=1`. |
| `iommu-machineconfig.yaml` | admin, once, **if needed** | Dedicated MachineConfigPool + IOMMU kernel arguments. Costs reboots. Standalone OpenShift only — not usable on a hosted control plane, and expected to be unnecessary on AMD. |
| `setup-passthrough.sh` | admin | Reports, and with `APPLY=1` configures, one node for passthrough; teaches KubeVirt the device |
| `test-gpu-vm.sh` | project user | Boots a VM with a GPU and verifies it in three tiers |
| `gpu-vm.yaml` | project user | The same VM as a hand-applied Template, for poking at by console |
| `test-gpu-switch.sh` | admin | **Destructive.** Times a container → VM → container round trip on a node |
| `cleanup.sh` | either | Tears down test objects; `REVERT_NODE=1` also puts the node back |

## Taking this to a different cluster

Nothing here is specific to `oac-dev-workload0`; the resource names, PCI ids and GPU node names are all discovered at runtime rather than hardcoded. On a new cluster:

```bash
cd vm-testing/gpu
./preflight.sh                              # what works, what is missing, what you may do
AS_ADMIN=--as=system:admin ./preflight.sh   # same, plus what impersonation buys you
```

It reads only, so it is safe on a cluster you have just been handed and do not yet trust. The two cluster properties that most change the plan are the ones it checks first: whether the GPU nodes carry `kubevirt.io/schedulable=true`, and whether `controlPlaneTopology` is `External` — the latter decides whether IOMMU kernel arguments are something you can apply at all.

## Prerequisites

Beyond `oc`, `virtctl`, `python3` and the OpenShift Virtualization install the rest of `vm-testing` needs:

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
cd vm-testing/gpu
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
cd vm-testing/gpu
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

Defaults to Ubuntu 24.04 (`quay.io/containerdisks/ubuntu:24.04`) rather than the Fedora the other `vm-testing` scripts use. Ubuntu ships NVIDIA's datacenter drivers in its own archive, so tier 2 is one `apt-get install` with no third-party repo and no akmod rebuild against a kernel that moves under it. Tier 3 uses the distro's own `nvidia-cuda-toolkit` package for the same reason: one stable package name instead of a repo URL and version-suffixed names that change every CUDA release. It is a large download — set `MAX_TIER=2` to skip it.

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

## Result: partly proven on `jetty`, blocked on storage

Run on 2026-10-01 against `jetty` (OpenShift Virtualization 4.22.9, GPU Operator 26.7.1, NFD 4.22.0, node `moc-r4pcc02u16`).

**Established:**

- The node flipped to `vm-passthrough` cleanly. `nvidia.com/GH100_H100_SXM5_80GB: 4` appeared, `nvidia.com/gpu` went to `0`, and `moc-r4pcc02u15` was untouched at `nvidia.com/gpu: 4` throughout — `defaultWorkload: container` really does confine the change to the labelled node.
- `10DE:2330` is allow-listed on the HyperConverged as `nvidia.com/GH100_H100_SXM5_80GB` with `externalResourceProvider: true`, and that propagated to the KubeVirt CR, so the webhook accepts a VM requesting it.
- A GPU VM **schedules onto the node and is allocated an H100** — the virt-launcher pod gets the device. The scheduling and admission half of the problem is solved.
- IOMMU needed no intervention at all: 103 IOMMU groups on both workers, no `amd_iommu=` or `iommu=` anywhere in `/proc/cmdline`. See prerequisite 2.
- `fips=1` is set on these nodes and did not impede the NVIDIA driver build, which was a plausible failure mode that simply did not materialise.

**Not established:** the guest never boots, so tiers 1–3 (does the guest see the card, load the driver, run CUDA) are all still open. `jetty` has no StorageClass, no CSI driver and no PV, so the DataVolume path cannot provision a root disk; the containerDisk path is incompatible with passthrough as described above. Each worker has an untouched 7 TB `nvme1n1`, so the fix is a storage provider — LVM Storage is the usual answer on bare metal — but that is a deliberate decision about those disks, not a step this test should take on its own.

---

# Context-Switch Test

**This test is destructive.** It cordons the node and deletes every GPU-holding pod on it, in every namespace, twice. It restores the original label and uncordons on exit including on failure, but evicted pods are not recreated — controller-managed ones reschedule themselves, bare pods and Notebooks do not. It refuses to start without an explicit confirmation, and prints the pods at risk first.

```bash
cd vm-testing/gpu
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

This is the only remaining test, and **it is not blocked by the storage problem** — it never boots a VM. It needs a node in `container` mode to start from, so `moc-r4pcc02u16` has to be flipped back first:

```bash
NODE=moc-r4pcc02u16 APPLY=1 TARGET_WORKLOAD=container ./setup-passthrough.sh
NODE=moc-r4pcc02u16 CONFIRM=yes-drain-this-node ./test-gpu-switch.sh
```

Both nodes on `jetty` currently have zero GPU-holding pods, so the drain half of the measurement will be a floor — the cost on a node with real tenants on it will be higher, and the script times the drain separately for that reason.

---

## Open questions these tests should settle

Written down because they are the reason to run this at all, not afterthoughts.

- **Does passing a subset of an NVLink clique work?** The jetty GPU nodes are 4× H100-80GB-HBM3 SXM. SXM boards are not discrete PCIe cards; handing one GPU of a directly-linked mesh to a VM leaves its peers absent. `test-gpu-vm.sh` reports `nvidia-smi nvlink -s` and `topo -m` from inside the guest for exactly this reason. If the links read as inactive with one GPU passed through, the usable unit is **all four to one VM**, which changes the economics considerably.
- **How long does the driver stack actually take to come back?** This is the number that decides whether node-level time-sharing is practical or whether GPU VM nodes should just be permanently dedicated.
- **What is the CUDA bandwidth penalty, if any?** Tier 3 reports host-to-device bandwidth measured in the guest. Comparing it against a container on the same node is the obvious follow-on.
- **Does any of this survive a node reboot?** The label is persistent and `vfio-manager` re-binds on boot, but that is a claim worth checking rather than assuming.
