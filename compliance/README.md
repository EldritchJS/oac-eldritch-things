# jetty: compliance, VMs, and GPUs

*Read this one. Everything else is detail you can drill into if you want it.*

Last updated 2026-10-07.

---

## What this is

`jetty` is a 5-node baremetal OpenShift 4.22.14 cluster (3 masters, 2 workers)
built with the Assisted Installer. The two workers are large — 512 CPU, 1.5 TB
RAM, **4× NVIDIA H100** each.

Two efforts live here, merged into one tree because they genuinely collide:

1. **Compliance** — getting the cluster to NIST 800-171, HIPAA, and FIPS.
2. **Virtualisation** — running VMs, including handing them physical GPUs.

### Prerequisites

**This repo does not ship a kubeconfig, and must not.** A `jetty` kubeconfig
carries cluster-admin; `.gitignore` deliberately excludes `kubeadmin-*`,
`*kubeconfig*`, and `*init-bundle*` so credential material never lands in
version control.

Before running anything here, point `KUBECONFIG` at a cluster-admin kubeconfig
for `jetty`. Every script and command in these docs assumes it is set:

```sh
export KUBECONFIG=/path/to/kubeadmin-jetty    # ← you must supply this
oc whoami                                      # confirm: system:admin
```

Obtain it from whoever administers the cluster, or from the Assisted Installer
output for `jetty`. Keep it outside this working tree.

---

## Where things stand

| | Status |
|---|---|
| FIPS | ✅ Verified at runtime, all 5 nodes |
| Compliance Operator | ✅ v1.10.0 — CIS and NIST scans running nightly |
| RHACS (StackRox) | ✅ v4.11.4 — fully deployed, all components healthy |
| Storage | ✅ Working (was broken most of the day; fixed) |
| GPU — container mode | ✅ Live on `u15` |
| GPU — VM passthrough | ✅ Live on `u16` |
| **Cluster hardening** | ✅ **Complete.** 385/385 remediations applied; node failures 377 → 4 |
| Audit retention | ⚠️ 5.8 h — volume cut 73%, but still no forwarding |
| Storage encryption | ✅ **All NFS traffic encrypted** — 18/18 PVCs on NFS-over-TLS |
| CNV golden images | ✅ Fixed — all 6 imported, on encrypted storage |

The headline: **the cluster is hardened and the GPUs survived it.** Platform
and node remediation are applied — node failures went **377 → 4** — and both
GPU modalities still work after two full rolling reboots. That was the central
open question and it is now answered with a measurement, not a prediction.

Node hardening is finished: all 385 remediations are applied and the four
remaining node failures are both genuinely manual (`sshd-limit-user-access`,
which offers no remediation, and `reject-unsigned-images-by-default`, a stage
3 GPU-dangerous check deliberately deferred).

What remains is deliberate, not blocked: the three GPU-dangerous manual checks
(stage 3) are untouched on purpose, and **audit log forwarding is now the one
genuinely open gap.**

---

## 1. FIPS is genuinely on

Checked three independent ways on every node, not just the declared intent:
`fips=1` in the kernel command line, `/proc/sys/crypto/fips_enabled = 1`, and
the system-wide crypto policy set to `FIPS`. All 5/5 agree, and both
MachineConfigPools carry `fips: true`.

Two things worth knowing.

**The install-config is not usable as evidence here.** It has no `fips:` key at
all. That is expected — this cluster came from the Assisted Installer, which
expresses FIPS as separate `99-master-fips`/`99-worker-fips` MachineConfigs
rather than through install-config. So cite the node-level evidence to an
assessor, not the install-config.

And the distinction that actually matters: **FIPS mode is not FIPS validation.**
We proved the OS runs in FIPS mode. That is not the same as proving the
cryptographic modules carry active CMVP certificates — those are tied to
specific module *versions*, which can drift. Getting the 140-3 certificate
numbers for the RHEL 9 modules is a documentation task nobody has done yet.

→ Detail: [STANDARDS.md](STANDARDS.md) §3

---

## 2. What the two security tools actually do

They solve different problems. Neither is a superset of the other, and most
frameworks need both.

**The Compliance Operator** answers *"is the cluster built to the standard?"*
It scans the cluster API and the RHCOS hosts against named control frameworks,
maps each finding to a rule an auditor recognises, and can auto-generate fixes.
It knows nothing about running workloads.

**RHACS** answers *"is what's running on it safe, and can I stop it?"* Image
CVE scanning, runtime detection via eBPF, and — the part the Compliance
Operator entirely lacks — **enforcement**, at both deploy time and runtime.

Neither ships an 800-171 or a HIPAA profile, which sounds alarming and is not.
800-171 is not a configuration standard; it is a tailored subset of NIST 800-53
for protecting CUI, and its Appendix D maps every requirement back to an 800-53
control. So the **800-53 Moderate baseline is the correct proxy**, and it is the
mapping an assessor expects. HIPAA lives in ACS as the `HIPAA_164` standard.

Both tools only cover the *technical* subset. Whole 800-171 families — training,
personnel security, assessment — are policy and process. HIPAA's Administrative
and Physical safeguards likewise. No scanner produces a BAA or an incident
response plan.

→ Detail: [STANDARDS.md](STANDARDS.md) §1

---

## 3. What the scans found

Failure counts, as first measured and as they stand after remediation:

| Scan | Initial | After stage 1 | **Now (after stage 2, both rounds)** |
|---|---|---|---|
| `ocp4-cis` (platform) | 10 | 8 | **8** |
| `ocp4-moderate` (platform) | 25 | 21 | **21** |
| Node-level OpenShift config | 4 master / 1 worker | 4 / 1 | **1 / 1** |
| **RHCOS operating system** | **191 per node** | 191 | **1 per node** |

The RHCOS number looked frightening and mostly was not: 112 of the 191 were
audit rules, 27 sysctls, 18 kernel modules — bulk, not depth, and nearly all
auto-remediable. **Node failures went 377 → 4.**

Getting there meant 377 MachineConfigs and a rolling reboot of every node, one
at a time. That was the single biggest operational fact in this document, and
it has now been paid: all 5 nodes rebooted on 2026-10-05, one went Degraded
mid-run and recovered on its own. A second, smaller round on 2026-10-07
applied 6 usbguard remediations that only became eligible after the first
round's rescan, taking failures 10 → 4.

The 4 survivors are two rules, each failing on both pools, and both genuinely
manual: `sshd-limit-user-access` (no remediation offered) and
`reject-unsigned-images-by-default`, a stage 3 GPU-dangerous check deliberately
left alone.

Raw ARF evidence is archived to persistent storage, so these results are
durable audit artefacts rather than a transient read.

> **Trap:** the nightly scan is not sufficient evidence after a remediation
> stage. `verify.sh` once reported "matches baseline" from a scan that predated
> the hardening by 12 hours. Always rescan before trusting a comparison.

---

## 4. The gaps no scanner will fix for you

The scans flag configuration. These are real and mostly invisible to them:

- ~~**etcd encryption is off.**~~ ✅ **Closed** — `aesgcm`, re-encryption
  completed 2026-10-02. Matters more than its "medium" severity implies,
  because HIPAA treats FIPS-validated encryption as **breach-notification
  safe harbour**.
- **Audit logs are still not retained or forwarded.** ⚠️ **The one genuinely
  open gap.** Measured: retention was **94 minutes**, now **5.8 hours** after
  a 73% volume cut. Still not the months 800-171 3.3.1 / HIPAA §164.312(b)
  expect — and logs sitting on the host they audit fail AU-9 at *any*
  retention. No scanner checks for this. See PLAN.md §6b.
- **No identity provider.** Authentication is `kubeadmin` — one shared
  break-glass account, so no per-user attribution at all. Also why the
  GPU-switch admission policy ships in Warn rather than Deny.
- **No etcd backups**, no default-deny network policies, no image signing
  policy, no file integrity monitoring.

Plus the non-technical half of both frameworks, which is usually the larger
share of an authorisation package and which no tool produces.

→ Detail: [PLAN.md](PLAN.md) §6

---

## 5. GPUs work in both modes, today

Your two workers are in **opposite modalities right now**:

| | `u15` | `u16` |
|---|---|---|
| Mode | container | **VM passthrough** |
| Advertises | `nvidia.com/gpu: 4` | `GH100_H100_SXM5_80GB: 4` |
| Host driver | loaded | **not loaded** |
| Special | device plugin, DCGM, MIG manager | **`vfio-manager`**, sandbox plugin |

The driver genuinely differs per mode, as you thought. In container mode the
host NVIDIA driver owns the GPU. In passthrough mode it must *not* —
`vfio-manager` binds each card to `vfio-pci` and the guest runs its own driver.
The GPU Operator handles the swap, driven entirely by one node label:

```sh
oc label node <node> nvidia.com/gpu.workload.config=vm-passthrough --overwrite
```

**So you never have to commit the cluster to VMs.** Modality is per-node and
reversible.

Better still: switching needs **no reboot on this hardware**. The usual reason
it would is a kernel-argument change to enable the IOMMU — but AMD IOMMU is
already active here (103 groups, no kernel argument needed). The `gpu-virt`
MachineConfigPool that exists in the templates is unnecessary and should not be
applied reflexively.

**Turnaround is now measured**, on an idle `u15`:

| Direction | Time |
|---|---|
| container → VM passthrough | **73 seconds** |
| VM passthrough → container | **208 seconds** |

No reboot either way. The asymmetry is expected — going to passthrough just
unloads the driver and binds `vfio-pci`; coming back has to load the driver
and start the toolkit, device plugin and validators. Treat these as a floor:
an idle node with images cached is the best case.

So a node can move between serving containers and serving VMs in **about one
to three and a half minutes**. That is fast enough to treat modality as a
scheduling decision rather than a maintenance event.

→ Detail: [FEASIBILITY.md](FEASIBILITY.md) §1, §5 · [tests/README.md](tests/README.md)

---

## 6. The interesting part: where compliance breaks GPUs

This is the reason the two efforts share a directory.

**First, the reassuring bit.** The three remediations that would break GPU
support are all **manual** — none has an auto-remediation. A bulk "apply
everything" will not touch them. The risk is only a human applying one without
thinking.

**`ocp-allowed-registries` is a one-shot foot-gun.** It restricts which
registries the container runtime may pull from. Miss an entry and you get
cluster-wide `ImagePullBackOff` — and it rewrites a node config file, so it
reboots everything too. **Eight** registries are actually in use cluster-wide:
`nvcr.io` (all nine NVIDIA images), `quay.io`, `registry.redhat.io`,
`registry.connect.redhat.com`, `docker.io`, `registry.k8s.io`, `ghcr.io`
(the `tlshd` image), and `registry.access.redhat.com` (the `tlshd` build's
base image). **All eight must be in any allowlist** — `docker.io` and
`registry.k8s.io` are easy to miss if you only inspect the GPU and CNV
namespaces. Leave out `nvcr.io` and the GPU stack dies in both modalities.
Leave out `ghcr.io` and the next reboot takes encrypted storage with it: no
`tlshd`, no TLS mounts, on any node. `verify.sh` T-10 re-measures this live;
re-run it immediately before applying, since the list is a snapshot.

**`reject-unsigned-images-by-default` has an open question.** It would require
every image to carry a verifiable signature. Nobody has checked whether the
`nvcr.io` images satisfy that. If they do not, enforcing it blocks the GPU
driver, and the workaround weakens the control enough that it should be a
recorded deviation rather than a quiet fix.

**`scc-limit-container-allowed-capabilities` is failing entirely because of
your own stack.** Exactly 10 security contexts fail it: **nine NVIDIA ones**
(all granting `allowedCapabilities: ['*']` — every Linux capability) and
`kubevirt-controller`. Nothing else. Remove GPUs and virtualisation and the
check passes. The sanctioned fix is a TailoredProfile recording the exception,
but be straight about it in the SSP: nine SCCs with blanket `*` is something an
assessor will ask about. The defensible argument is that they are
vendor-shipped, namespace-scoped, needed for kernel module loading, and
monitored at runtime by ACS.

**The good news on node hardening — now VERIFIED, not predicted.** No
remediation touches `vfio`, `kvm`, `iommu`, or PCI binding, and stage 2 proved
it: all 5 nodes rebooted onto 373 compliance MachineConfigs on 2026-10-05 and
**both GPU modalities still work** — `u15` still advertises `nvidia.com/gpu=4`
with the driver loaded, `u16` still advertises `GH100_H100_SXM5_80GB=4` with
`vfio-manager` running and the host driver correctly absent. This was the
central open question of the whole feasibility assessment.

What does break is **VM USB passthrough** — `usb-storage`, `bluetooth`, `sctp`
and friends all get disabled. Design around that rather than discovering it
later. `usbguard` points the same direction: it is now enforcing, with only
HID devices and hubs allowed.

One more, easy to miss: **flipping the GPU modality label is a node write**,
which is effectively cluster-admin. Under 800-171's access control family an
operation that consequential wants explicit delegation. **Solved** —
`manifests/08-gpu-switch-rbac.yaml` scopes writes to the two GPU nodes, and a
ValidatingAdmissionPolicy restricts holders to changing just that one label
(RBAC alone cannot express that; plain `patch nodes` would also permit
cordoning and editing taints). Ships in Warn+Audit until an IdP exists.

→ Detail: [FEASIBILITY.md](FEASIBILITY.md) §3

---

## 7. Two loose ends

~~**CNV golden images are blocked.**~~ ✅ **Fixed 2026-10-07.** CDI's
auto-detected storage profile advertised `Block` first — correct for a
FlashArray, wrong for FlashBlade NFS — so all six DataVolumes were created as
block devices and hung in `ImportScheduled` from cluster build. Six days, with
no error that said so.

Pinning `Filesystem` in the StorageProfile
(`manifests/12-cdi-storageprofile.yaml`) and deleting the stuck DataVolumes
released them: all six imported to `Succeeded`, DataSources Ready. They landed
on `nfs-over-tls`, so they are encrypted in transit too.

> `pure-fb-nfsv4` has the identical defect and is deliberately left unfixed —
> everything is migrating off it. Apply the same override if anything is ever
> provisioned there again.

**Every node has a stray second default route** on `br-storage` via DHCP.
Harmless today because `br-ex` wins on metric, but it wants `auto-gateway:
false` in the NNCPs. Nobody owns this yet.

---

## 8. What happens next

Open decisions for you:

1. **Scope.** Treat the whole cluster as in-scope for 800-171? With two
   workers there is no meaningful way to split it, and the control plane is
   shared regardless. Recommended: yes, whole cluster.
2. ~~**Finish remediation**~~ — **done 2026-10-07.** It took two passes:
   6 usbguard remediations were dependency-gated during the first and only
   became eligible after the post-hardening rescan. `remediate.sh` now reports
   `BLOCKED` and `HOLD` counts instead of silently appearing complete, so the
   iteration is visible.
3. **Get the FIPS 140-3 certificate numbers** — a paperwork task, not a
   cluster one.
4. **Audit log forwarding is the most urgent gap.** Measured: retention was
   **94 minutes**, now **5.8 hours** after a 73.2% volume cut
   (`manifests/09-audit-customrules.yaml`, PLAN.md §6b). Still nowhere near
   the months 800-171 3.3.1 / HIPAA §164.312(b) expect, and logs on the
   audited host fail AU-9 at any retention. **Decide the destination:**
   forwarding to an existing SIEM needs no object storage; LokiStack needs a
   FlashBlade S3 bucket the storage team has not provisioned.

Recommended order of work:

1. ~~Measure the GPU switch turnaround~~ — **done**: 73s / 208s, no reboot.
2. ~~Build the test suite~~ — **done**: `tests/verify.sh`, 34 PASS / 0 FAIL,
   baseline recorded. The regression net exists.
3. ~~**Stage 1** — platform remediations~~ — **done 2026-10-02**: etcd
   encryption `aesgcm`, audit `WriteRequestBodies`, OAuth timeouts. No reboots,
   nothing degraded. `ocp4-cis` 10 → **8**, `ocp4-moderate` 25 → **21**.
3b. ~~**Audit volume cut**~~ — **done 2026-10-03**: ten platform namespaces to
   `Default` via `customRules`. 92.0 → **24.7 GB/day**, retention 1.6 → **5.8 h**,
   90-day store 8.3 TB → **2.17 TB**. No compliance regression.
4. ~~**Stage 2** — node hardening~~ — **done 2026-10-05**: 377 MachineConfigs,
   full rolling reboot. **Node failures 377 → 10** (`rhcos4-moderate-*`
   191 → 4 each). **Both GPU modalities survived** — the headline result.
4b. ~~**Stage 2, round two**~~ — **done 2026-10-07**: the 6 dependency-gated
   usbguard remediations, one more rolling reboot. **Node failures 10 → 4**,
   `rhcos4-moderate-*` 4 → 1 each. 385/385 applied. Both GPU modalities and
   the tlshd storage path survived.
5. **Stage 3** — the three GPU-dangerous manual checks, individually and last.
6. **Re-run `tests/verify.sh` after each stage** and re-save the baseline once
   the new numbers are the intended ones.

The GPU-switch delegation is **done** (`manifests/08-gpu-switch-rbac.yaml`).
Flipping modality no longer needs cluster-admin: a `gpu-modality-switcher`
ClusterRole grants patch on the two GPU nodes only, and a
ValidatingAdmissionPolicy restricts holders to changing *just* that one label —
RBAC alone cannot express that, and `patch nodes` would otherwise also permit
cordoning and editing taints. The policy ships in **Warn+Audit**, not Deny,
because enforcing node admission before an identity provider exists is how you
lock yourself out. Flip it to Deny once the IdP is in place.

The ordering matters more than the speed. Remediation is a 377-MachineConfig
rolling reboot of a cluster with GPUs in two different modes; you want an
automated way to prove it still works on the other side.

---

## Where the detail lives

| File | What |
|---|---|
| [FEASIBILITY.md](FEASIBILITY.md) | Compliance × GPU × VMs — the collision analysis and proposed test suite |
| [STANDARDS.md](STANDARDS.md) | 800-171 / HIPAA / FIPS mapping, full scan results, scope analysis |
| [PLAN.md](PLAN.md) | FIPS verification, operator install, gap list, decisions log |
| [STORAGE-ISSUE.md](STORAGE-ISSUE.md) | The FlashBlade outage — diagnosis and resolution |
| [NFS-TLS.md](NFS-TLS.md) | **Storage traffic is cleartext** — the gap, the evidence, and a proven fix |
| `manifests/` | Everything applied, in numeric order |
| [tests/README.md](tests/README.md) | **Verification suite** — run before and after hardening |
| `remediate.sh` | **Staged hardening runbook** — `status`, `stage1`, `stage2`, all with `--dry-run` |
| `vms/`, `vms/gpu/` | VM and GPU test suites |

**Note on `vms/` — the overlap with `open-science-test-cases` is deliberate.**
Five files here started as copies of ones tracked by that repo:

```
migrate-rbac.yaml  net-test-vm.yaml
test-vm.sh         test-vm-storage.sh  test-vm-migration.sh
```

They were byte-identical as of 2026-10-05. **This repo is intentionally
separate** — that one is a public test-cases repo with a different purpose and
audience; this one is the compliance engagement. The copies are expected to
diverge over time, and that is fine: edit them here freely without worrying
about keeping the other repo in step.

`vms/gpu/` and `vms/README.md` exist **only here** — the GPU test suite has no
counterpart upstream, so do not treat `vms/` as a mirror of anything.
