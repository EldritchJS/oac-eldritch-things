# Feasibility: compliance + dual-modality GPU (containers ⇄ VMs)

> **Last updated 2026-10-05.** The central question of this document —
> *does compliance hardening break GPU support?* — has since been **answered
> empirically: no.** Stage 2 applied 377 MachineConfigs and rebooted all 5
> nodes on 2026-10-05; both GPU modalities still work. §3 #4 below was written
> as a prediction and is now a measurement, confirmed across two separate
> full-cluster rolling reboots. Failure counts quoted here
> (25 platform / 191 per-node) are the **pre-remediation** baseline; current
> figures are in [README.md](README.md) §3.

Scope of this assessment:
1. Can this cluster be made compliant (NIST 800-171 / HIPAA / FIPS)?
2. Can it serve GPUs to **either** containers **or** VMs, per node, on demand?
3. What is the turnaround time to switch a node between modalities?
4. What test suite proves all of the above stays true?

**Overall verdict: feasible.** Both halves already work independently today.
The risk is not in either one — it is in a small number of specific compliance
remediations that will break GPU support if applied naively. Those are
enumerated in §3 and all have workarounds.

---

## 1. Current state: dual-modality already works

This is not a greenfield question. The switching mechanism is live right now,
with the two workers in **opposite** modalities:

| | `moc-r4pcc02u15` | `moc-r4pcc02u16` |
|---|---|---|
| `nvidia.com/gpu.workload.config` | *(unset → `container` default)* | **`vm-passthrough`** |
| Allocatable | `nvidia.com/gpu: 4` | `nvidia.com/GH100_H100_SXM5_80GB: 4`, `nvidia.com/gpu: 0` |
| Driver | `nvidia-driver-daemonset` running | **not running** |
| Device plugin | `nvidia-device-plugin-daemonset` | `nvidia-sandbox-device-plugin` |
| Also running | container-toolkit, dcgm, mig-manager, operator-validator | **`nvidia-vfio-manager`**, sandbox-validator |

Confirmed `vfio-manager` bound all four H100s to `vfio-pci`:
`0000:06:00.0`, `0000:26:00.0`, `0000:a6:00.0`, `0000:c6:00.0`.

### The mechanism

Your understanding is right — the driver differs per modality, and the GPU
Operator handles the swap:

- **Container mode**: host NVIDIA kernel driver loaded; GPUs exposed as
  `nvidia.com/gpu` via the standard device plugin.
- **VM passthrough**: host driver **must not** claim the device.
  `vfio-manager` binds each GPU to `vfio-pci`; the sandbox device plugin
  advertises `nvidia.com/GH100_H100_SXM5_80GB`; KubeVirt assigns it to a guest,
  which runs its own driver inside the VM.

The switch is driven entirely by one node label:
```sh
oc label node <node> nvidia.com/gpu.workload.config=vm-passthrough --overwrite
oc label node <node> nvidia.com/gpu.workload.config=container     --overwrite
```
Enabled by `ClusterPolicy.sandboxWorkloads = {"enabled":true,"mode":"kubevirt","defaultWorkload":"container"}`.

**So you never have to "move over to VMs".** Modality is per-node and
reversible, which is exactly the posture you want.

### Two configuration risks found

**(a) `permittedHostDevices` — NOT a risk. Correctly configured.**
*An earlier draft of this document called this fragile. That was wrong, caused
by checking the wrong API path. Recorded here because the trap is easy to
fall into twice.*

It **is** set declaratively on the HyperConverged CR, which then propagates it
to the KubeVirt CR it manages:

```
HCO   spec.virtualization.permittedHostDevices.pciHostDevices[0]
        pciDeviceSelector: "10DE:2330"   resourceName: nvidia.com/GH100_H100_SXM5_80GB
KubeVirt  spec.configuration.permittedHostDevices.pciHostDevices[0]
        pciVendorSelector: "10DE:2330"   resourceName: nvidia.com/GH100_H100_SXM5_80GB
```

`managedFields` confirms `hyperconverged-cluster-operator` owns the field, and
HCO reports `ReconcileComplete=True`, `Degraded=False`. This survives upgrades.

### The trap — two gotchas, both silent

1. **Wrong API path.** This cluster's HCO object is `hco.kubevirt.io/v1`, whose
   spec is restructured. The field lives at
   **`spec.virtualization.permittedHostDevices`**. In `v1beta1` it was at the
   top level, `spec.permittedHostDevices`. Query the v1beta1 path on a v1
   object and you get **empty** — a correct configuration looks missing.
2. **Different field names across the two CRs.** HCO takes
   `pciDeviceSelector`; the KubeVirt CR it generates uses `pciVendorSelector`.
   Copying the KubeVirt spelling into an HCO manifest is rejected.

Correct check:
```sh
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.permittedHostDevices}'
```

The one residual point is ordinary config hygiene, not fragility: the value
lived only in cluster state and in no tracked file. It is now captured in
`manifests/07-cnv-permitted-host-devices.yaml` — verified a **no-op** when
applied (HCO unchanged, KubeVirt CR unchanged, 4 GPUs still allocatable).

**(b) No `gpu-virt` MachineConfigPool exists.** Only `master` and `worker`.
`vms/gpu/iommu-machineconfig.yaml` defines one but has not been applied — and
per its own notes it is **unnecessary here**: AMD IOMMU is already active (103
groups) with no kernel argument. Do not apply it reflexively. Its remaining
value is `iommu=pt` and the Intel case.

---

## 2. Compliance feasibility

Already established (PLAN.md, STANDARDS.md):

- **FIPS**: verified at runtime on all 5 nodes. The NVIDIA driver **builds and
  runs under `fips=1`** — already proven on this hardware. No conflict.
- **800-171** via `ocp4-moderate`/`rhcos4-moderate`: 25 platform + 191 per-node
  failures, **383 remediations available (377 MachineConfigs)**.
- **HIPAA** via ACS `HIPAA_164`.

Nothing here is infeasible. The work is large but mechanical, and the node-level
majority (112 audit rules, sysctls, kernel modules) is auto-remediable.

---

## 3. Where compliance will break GPU support

**This is the real content of this assessment.**

### First, the reassuring part

**All three GPU-dangerous checks are `MANUAL` — none has an auto-remediation.**
Verified:

| Check | Auto-remediation? |
|---|---|
| `ocp-allowed-registries` / `...-for-import` | **None — manual** |
| `reject-unsigned-images-by-default` | **None — manual** |
| `scc-limit-container-allowed-capabilities` | **None — manual** |

So a bulk "apply all 383 remediations" will **not** break GPU support. The 377
MachineConfigs do not include any of these. The risk is strictly that a human
applies one of them without thinking — which is exactly what this section is
for.

### The three, with specifics

**1. `ocp-allowed-registries` — highest risk, and it is a one-shot foot-gun.**

Currently unset (`registrySources` is empty). The rule wants
`image.config.openshift.io/cluster` `.spec.registrySources.allowedRegistries`
populated. Anything not listed is blocked **at the container runtime**, so a
missed entry means cluster-wide `ImagePullBackOff` — and setting it rewrites
`/etc/containers/registries.conf`, which triggers a **MachineConfig rollout
and node reboots**.

Registries actually in use, measured:

| Registry | Used by |
|---|---|
| `nvcr.io` | **all 9 NVIDIA GPU Operator images** |
| `quay.io` | GPU Operator release image (`openshift-release-dev`) |
| `registry.redhat.io` | CNV, RHACS, Compliance Operator |

Any allowlist must contain at least those three, plus the internal registry
(`image-registry.openshift-image-registry.svc:5000`) and
`registry.access.redhat.com`. Re-measure immediately before applying — this
list is a snapshot:
```sh
oc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sed 's|/.*||' | sort -u
```

**2. `reject-unsigned-images-by-default` — needs a verification step first.**

Wants `/etc/containers/policy.json` to have `"default": [{"type": "reject"}]`,
delivered by MachineConfig. Every image then needs an explicit trust entry.

**Unknown and worth checking before anyone attempts this:** whether the
`nvcr.io` images carry signatures OpenShift can verify. If they do not, a
reject-by-default policy blocks the GPU driver, and the pragmatic path is a
per-transport `insecureAcceptAnything` entry for `nvcr.io` — which weakens the
control and should be recorded as an accepted deviation rather than quietly
applied.

**3. `scc-limit-container-allowed-capabilities` — this finding *is* your GPU stack.**

The rule compares SCCs having `allowedCapabilities` against
`ocp4-var-sccs-with-allowed-capabilities-regex`, currently:
```
^privileged$|^hostnetwork-v2$|^restricted-v2$|^restricted-v3$|^nonroot-v2$|^insights-runtime-extractor-scc|^nested-container$
```

**10 SCCs fail it — 9 are NVIDIA, 1 is KubeVirt:**

```
nvidia-driver                 -> ['*']      nvidia-operator-validator  -> ['*']
nvidia-dcgm                   -> ['*']      nvidia-sandbox-validator   -> ['*']
nvidia-dcgm-exporter          -> ['*']      nvidia-vgpu-device-manager -> ['*']
nvidia-gpu-feature-discovery  -> ['*']      nvidia-mig-manager         -> ['*']
nvidia-node-status-exporter   -> ['*']
kubevirt-controller           -> ['SYS_NICE','NET_BIND_SERVICE']
```

In other words **this check is failing 100% because of GPU + virtualisation** —
remove those two workloads and it passes. There is nothing else to fix.

The rule documents its own sanctioned fix: a **`TailoredProfile`** extending
the regex variable to include these SCCs. That is the right mechanism — a
recorded, version-controlled deviation rather than an undocumented exception.

Be honest in the SSP about what is being accepted, though:
`allowedCapabilities: ['*']` on nine SCCs grants **every** Linux capability,
and an assessor will ask. `kubevirt-controller` is narrow and easy to defend;
the NVIDIA nine are not. The defensible position is that they are vendor-shipped,
namespace-scoped, and required for kernel module loading — documented as a
compensating control, with ACS runtime monitoring as the mitigation.

**4. Node hardening (the 377 MachineConfigs) — safe for GPUs.**

Verified: **no remediation touches `vfio`, `kvm`, `iommu`, `nvidia`, or PCI
binding.** GPU passthrough survives hardening in both modalities. The cost is
the rolling reboot. Disabled modules (`usb-storage`, `bluetooth`, `sctp`,
`cramfs`, `udf`, …) mean **VM USB passthrough will not work** — design around it.

### Access control: the switch is a privileged operation

Flipping `nvidia.com/gpu.workload.config` is a **node label write**, which is
effectively cluster-admin. Under 800-171 3.1 (Access Control) and HIPAA
§164.312(a), an operation this consequential should be delegated explicitly
rather than handed out as cluster-admin.

You already solved the identical problem for live migration in
`vms/migrate-rbac.yaml`. The same pattern applies here: a Role granting
`patch` on `nodes` restricted to the workload-config label. **Recommend
building `gpu-switch-rbac.yaml` to match.**

### ACS will alert on GPU workloads

The driver daemonset is privileged and mounts host paths. Expect ACS policy
violations. They are legitimate and expected — the action is to document them
as accepted exceptions, not to silence the policies.

---

## 4. Proposed test suite

The existing suites (`vms/test-vm*.sh`, `vms/gpu/*.sh`) cover VM and GPU
function. What is missing is **compliance verification** and **the interaction
between the two**. Proposed additions, runnable as one harness:

| ID | Test | Asserts |
|---|---|---|
| **T-01** | FIPS runtime | `fips=1`, `/proc/sys/crypto/fips_enabled=1`, crypto policy `FIPS` on **every** node. Fails if any node drifts. |
| **T-02** | FIPS validation | CMVP **140-3** certificate numbers recorded, and module versions on RHCOS match the certified versions (STANDARDS.md §3). Mode ≠ validation. |
| **T-03** | Compliance scan freshness | Last `ComplianceSuite` is `DONE`, within 48h, and FAIL count has not regressed above an agreed baseline. |
| **T-04** | Raw evidence archived | `rawResultStorage.enabled: true` and ARF files present on the PVC — audit evidence actually exists. |
| **T-05** | ACS health | Central reachable; cluster registered; sensor/collector/admission all `HEALTHY`. |
| **T-06** | GPU modality — container | On a `container` node: `nvidia.com/gpu > 0`, driver daemonset Running, a CUDA pod schedules and runs. |
| **T-07** | GPU modality — passthrough | On a `vm-passthrough` node: `GH100...` allocatable, `vfio-manager` Running, driver daemonset **absent**, and `permittedHostDevices` present at **`HCO .spec.virtualization.permittedHostDevices`** *and* mirrored to the KubeVirt CR. Assert both — a value on KubeVirt but not HCO would mean propagation has stopped. |
| **T-08** | **Switch turnaround** | Flip the label, measure wall-clock until the target modality is fully serviceable. Both directions. This is the headline number. |
| **T-09** | GPU survives hardening | After remediation: GPU still allocatable in both modalities. Guards the §3 regressions. |
| **T-10** | Registry allowlist sanity | Every image in `nvidia-gpu-operator` and `openshift-cnv` comes from an allowlisted registry — catches §3 #1 *before* it breaks production. |
| **T-11** | VM function | Existing `test-vm.sh`, `test-vm-storage.sh`, `test-vm-migration.sh`. |
| **T-12** | GPU VM end-to-end | `vms/gpu/test-gpu-vm.sh` — a VM actually receives and uses an H100. |

Design notes:
- Must be **non-destructive by default**, with mutating tests (T-08, T-09)
  behind an explicit flag. T-08 unloads a driver; T-09 follows a reboot.
- Must be **safe about node selection**. `test-gpu-switch.sh` currently cordons
  `moc-r4pcc02u16`, which hosts RHACS `central` and `central-db`. Any test that
  drains must check what it is about to evict.
- Should emit machine-readable output so T-03/T-04 can feed evidence collection.

---

## 5. Turnaround time — MEASURED

Measured on `moc-r4pcc02u15`, 2026-10-02, idle cluster (no GPU workloads, no
VMs), using `tests/gpu-switch-timing.sh`. "Ready" means the target resource is
advertised **and** the right pods are Ready **and**, for passthrough, the host
driver is gone — not merely that the label was accepted.

| Direction | Time |
|---|---|
| `container` → `vm-passthrough` | **73 s** |
| `vm-passthrough` → `container` | **208 s** |

**Neither direction rebooted the node.** Confirms the prediction: because AMD
IOMMU is already active, no kernel-argument change is needed, so the `gpu-virt`
MachineConfigPool is unnecessary and the switch is pure operator reconcile.

The asymmetry is expected and informative:
- **To passthrough (73s)** — stop the driver daemonset, bind the four cards to
  `vfio-pci`, start the sandbox device plugin. Mostly teardown.
- **Back to container (208s)** — load the host driver, then start the container
  toolkit, device plugin, DCGM, MIG manager and validators. Mostly bring-up.

**Treat these as a floor.** An idle node with images already cached is the best
case. A node with GPU workloads to evict, or one that must pull the driver
image, will be slower.

**Practical read:** a node moves between modalities in roughly one to three and
a half minutes, with no reboot. That is fast enough to treat modality as a
scheduling decision rather than a maintenance event — which is the answer to
whether this cluster can serve both audiences.

The node was returned to `container` mode and verified healthy
(`nvidia.com/gpu=4`, driver Running) by the suite afterwards.

---

## 6. Recommended order

1. ~~Measure turnaround~~ — **DONE** (§5): 73s / 208s, no reboot.
2. ~~Move `permittedHostDevices` to HCO~~ — **was never needed** (§1a).
   Captured in `manifests/07-cnv-permitted-host-devices.yaml` for rebuild.
3. ~~Build the test suite~~ — **DONE**: `tests/verify.sh` (read-only, 9 checks)
   plus `tests/gpu-switch-timing.sh` (mutating). Baseline recorded.
   Current state: **29 PASS, 0 FAIL, 2 WARN** — both WARNs are open human
   tasks (CMVP record, registry allowlist), not defects.
4. ~~Build `gpu-switch-rbac.yaml`~~ — **DONE**:
   `manifests/08-gpu-switch-rbac.yaml`, applied and verified.
   RBAC (`gpu-modality-switcher`) scopes writes to the two GPU nodes;
   a ValidatingAdmissionPolicy restricts holders to changing only the
   `nvidia.com/gpu.workload.config` label, with a valid value, and blocks
   node-spec edits (cordon, taints) that plain `patch nodes` would allow.
   Shipped in **Warn+Audit**; switch to `Deny` once an IdP exists.
   Regression-tested as T-12.
5. **Remediate in stages**, GPU-dangerous ones last and individually verified:
   platform → node hardening → registries/signing/SCC.
6. **Re-run `tests/verify.sh` after each stage**, then re-save the baseline
   once the new numbers are confirmed to be the intended ones.

Doing 3 before 5 is the important ordering. Remediation is a 377-MachineConfig
rolling reboot; you want an automated way to prove GPUs still work afterwards.
