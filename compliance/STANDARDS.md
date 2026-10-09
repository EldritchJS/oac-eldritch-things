# Standards: NIST 800-171, HIPAA, FIPS — mapping and scope

> **Last updated 2026-10-05.** The framework mapping below is current. The
> **scan results are not** — the counts in §2 (209/21/10, and 191 per node)
> are the **pre-remediation** baseline, kept as a record of the starting
> position. Hardening is complete: node failures **377 → 2**,
> `rhcos4-moderate-*` **191 → 1** per node. Current figures:
> [README.md](README.md) §3 and `tests/baseline-fail-counts.txt`.

## 1. Neither tool ships an 800-171 or HIPAA profile

Verified on the cluster: `oc get profiles.compliance` has **no 800-171 and no
HIPAA profile**, and none is coming. That is not a gap in the tooling — it is
what these frameworks are.

| Framework | Covered by | Why |
|---|---|---|
| **NIST 800-171** | Compliance Operator → `ocp4-moderate`, `ocp4-moderate-node`, `rhcos4-moderate` | 800-171 is not a configuration standard. It is a tailored subset of **NIST 800-53** for protecting CUI in nonfederal systems, and **800-171 Appendix D maps every requirement to its 800-53 control**. The 800-53 Moderate baseline is the correct technical proxy and the mapping an assessor recognises. |
| **HIPAA** | **ACS** → `HIPAA_164` standard | No Compliance Operator profile exists. ACS ships HIPAA 164 as a workload-centric standard. |
| **Container security** | **ACS** → `NIST_800_190` | Bonus; directly relevant to both frameworks. |
| **FIPS** | Verified at runtime (PLAN.md §1) | See §3 below — mode is not validation. |

ACS standards confirmed present: `HIPAA_164`, `NIST_800_190`,
`NIST_SP_800_53_Rev_4`, `PCI_DSS_3_2`, `CIS_Kubernetes_v1_5`, plus the
Compliance Operator's `ocp4-cis` results surfaced into ACS.

**Important limit.** Both tools only cover the *technical* subset. 800-171 has
110 requirements across 14 families; whole families (3.2 Awareness & Training,
3.9 Personnel Security, 3.12 Security Assessment) are policy and process. HIPAA
splits into Administrative, Physical, and Technical safeguards — only
§164.312 Technical is partly tool-addressable. BAAs, workforce training,
contingency plans, and risk assessments are not produced by any scanner.

---

## 2. Baseline results (2026-10-02)

`ocp4-cis` + `ocp4-cis-node` → **209 PASS / 21 MANUAL / 10 FAIL**

NIST 800-53 Moderate (the 800-171 proxy) is a much larger gap:

| Scan | FAIL | MANUAL | PASS |
|---|---|---|---|
| `ocp4-moderate` (platform) | 25 | 22 | 78 |
| `ocp4-moderate-node-master` | 4 | 3 | 107 |
| `ocp4-moderate-node-worker` | 1 | 3 | 61 |
| `rhcos4-moderate-master` | **191** | 4 | 43 |
| `rhcos4-moderate-worker` | **191** | 4 | 43 |

The RHCOS failures dominate and are heavily concentrated:

| Category | Count (per node) |
|---|---|
| **auditd rules** | **112** |
| sysctl hardening | 27 |
| kernel module disabling | 18 |
| coreos kernel args | 6 |
| chronyd / sshd / services | 10 |

New platform findings beyond the CIS set, notable for these frameworks:
`audit-log-forwarding-uses-tls`, `file-integrity-exists`,
`file-integrity-notification-enabled`, `reject-unsigned-images-by-default`,
`oauth-or-oauthclient-inactivity-timeout`, `oauth-or-oauthclient-token-maxage`,
`banner-or-login-template-set`, `default-ingress-ca-replaced`,
`ingress-controller-certificate`, `directory-access-var-log-*-audit`.

> `file-integrity-exists` points at the **File Integrity Operator**, a third
> operator we have not installed. 800-53 SI-7 / 800-171 3.14 expect file
> integrity monitoring. Worth adding.

---

## 3. FIPS: target 140-3, not 140-2

**FIPS 140-2 sunset on 21 September 2026.** All remaining 140-2 certificates
moved to the CMVP **Historical List** the following day; only 140-3
certificates are Active. This cluster was built after that date, so 140-3 is
the only sensible target.

What that does and does not mean:

- **Historical ≠ revoked.** NIST supports continued purchase and use of
  Historical modules for *existing* systems, and says agencies should keep
  using them until 140-3 replacements are available.
- But federal procurement language is that agencies **"should not include"**
  Historical modules in **new acquisitions**.

`jetty` was built on 2026-09-30, after the sunset. It is a new deployment, so
**140-3 is the target.** If your requirement document says "FIPS 140-2", that
is not wrong — it is simply pre-sunset wording. Satisfying 140-3 satisfies the
intent.

### The distinction that actually matters

**FIPS mode enabled is not FIPS validated.** We verified *mode*: `fips=1`,
`/proc/sys/crypto/fips_enabled=1`, crypto policy `FIPS` on all 5 nodes
(PLAN.md §1). That proves the OS is operating in FIPS mode. It does **not**
prove the cryptographic modules carry active CMVP certificates — and
certificates are tied to **specific module versions**, so an updated module can
drift past its certified version.

**What to dig up** (this is the useful ask, more than the standard number):
1. Active **FIPS 140-3 CMVP certificate numbers** for the RHEL 9 / RHCOS 9.8
   modules in use — kernel crypto API, OpenSSL, GnuTLS, NSS, libgcrypt.
2. Whether the module **versions** on the running RHCOS (currently
   `9.8.20260922-1`, since the 4.22.16 upgrade) match the certified
   versions. This changes with **every** upgrade, so it is a recurring
   check, not a one-time lookup.
3. Whether your assessor wants those certificate numbers recorded in the SSP.

Verify against the CMVP Validated Modules Search at csrc.nist.gov (Active and
Historical are separate searchable views).

### Where FIPS binds in each framework

- **800-171 3.13.11** — employ FIPS-validated cryptography to protect CUI.
- **HIPAA** — encryption is an *addressable* specification, but HHS/NIST
  guidance treats FIPS 140-validated encryption as the bar, and it provides
  **breach-notification safe harbour** under HITECH for encrypted ePHI.

> That safe harbour makes **etcd encryption (currently OFF)** materially more
> important than its "medium" severity suggests. Kubernetes Secrets sit
> unencrypted in etcd today.

---

## 4. Scope: mixed VM tenancy

> The question: some VM users care about compliance, some do not. Does that
> matter?

**Yes — and more than it looks, because of how the remediation lands.**

### The hard constraint

383 remediations were available initially; **377 of them were MachineConfigs**
(all since applied — two rolling reboots, 2026-10-05 and 2026-10-07).
Applying the 800-171 baseline is therefore a **cluster-wide rolling reboot**:
the MCO drains and reboots each node in turn. On 5 nodes that is hours, and
with only **2 workers** draining one pushes every VM onto the other.

This is not a soft conflict with VM work. It is a scheduled-maintenance event
that must be coordinated.

### Why you cannot simply exempt the "don't care" tenants

The in-scope boundary for CUI/ePHI includes the shared control plane, so:

- **FIPS is cluster-wide** — a kernel boot argument, not a per-tenant setting.
- **etcd holds every Secret**; the API audit log is cluster-wide; the identity
  provider is cluster-wide. These apply to all tenants by construction.
- **Node hardening is per-MachineConfigPool**, i.e. per node role — it changes
  OS behaviour for *everything* scheduled on those nodes.

Cluster-level controls therefore apply to everyone regardless of preference,
and most users will not notice: log in via SSO, do not run privileged
workloads, pull images from approved registries.

### Where it genuinely bites

Node hardening changes the OS underneath every workload on that node:
disabled kernel modules (`usb-storage`, `bluetooth`, `sctp`, `cramfs`,
`firewire`, …), `usbguard` enforcement, sysctl changes, 112 new audit rules.

A VM needing USB passthrough, SCTP, or an exotic filesystem **will break**, and
the owner will not have asked for the hardening. That is the real collision —
not policy preference, but kernel behaviour.

### Options

| Option | Viability here |
|---|---|
| **Whole cluster in scope** | **Chosen.** Uniform, simplest to defend to an assessor. |
| Separate MachineConfigPools for CUI vs general workers | Technically real — label nodes, create an MCP, scope remediation by role. But the control plane stays shared and in scope, and with **2 workers** there is nothing to split. Revisit if the cluster grows. |
| Separate clusters | The only truly clean separation, and the honest answer if some tenants must stay unhardened. |

**Decision (2026-10-08): the whole cluster is in scope.** If a tenant genuinely
cannot live with node hardening, they need a different cluster — that is a
governance decision, not a technical one. Revisit if the cluster grows enough
workers for a separate MachineConfigPool to mean something.

### CNV-specific note

`ocp4-cis-vm-extension` and `ocp4-stig-vm-extension` profiles exist, but there
is **no `moderate-vm-extension`**. So for an 800-171 posture, CNV/VM-specific
hardening is not covered by any profile and needs manual attention.

---

## 5. HIPAA 164 in ACS — first run 2026-10-08

ACS had **never run a compliance scan** before this date, so its `HIPAA_164`
results did not exist — nobody could have reviewed them. Triggered via the
API (`POST /v1/compliancemanagement/runs`, standard `HIPAA_164`); it reads
cluster state only and finished in 6 seconds. Re-run it the same way after
any change worth measuring — results do not refresh on their own.

**18 controls.** 9 pass outright. The failures reduce to five causes:

| Cause | Controls | Where | Disposition |
|---|---|---|---|
| **124 running images have CVEs with fixes available** — 77 are the OpenShift release payload, 24 OpenShift Virtualization, 9 ACS, rest storage/sidecars. NVIDIA images were **never scanned** until 2026-10-08; now scanned, all 10 have fixable CVEs → **134** total (see below). | 306(e), 308(a)(6)(ii) | cluster | **Standing condition, not fixable by us.** The 4.22.16 upgrade did not move it — see below. The control is a documented patch cadence. |
| **No ACS policy has a notifier** — violations are detected and go nowhere | 308(a)(6)(ii), 314(a)(2)(i)(C) | cluster | **Fix:** needs a destination (email, webhook, SIEM). Same open decision as audit log forwarding — likely the same answer. |
| **No egress NetworkPolicy** | 308(a)(4)(ii)(B), 308(a)(6)(ii), 312(c), 312(e), 312(e)(1) | 31 of our deployments (GPU operator, Portworx, ACS, tlshd, etcd-backup); 59 platform | ✅ **Ours fixed 2026-10-08** (`manifests/18-*`): 28 of 31 now pass; the other 3 are the hostNetwork row below. Platform: Red Hat's to own. |
| **Host networking** (bypasses NetworkPolicy) | same | `tlshd`, `etcd-backup`, Portworx `px-pure-csi-node`; 54 platform | **Document:** inherent to node-level agents. No fix exists short of not running them. |
| **Cluster-wide `*` on all core resources** | 308(a)(3)(ii)(B), 308(a)(4), 312(e)(1) | `portworx-operator`, `rhacs-operator`; 18 platform | **Document** as vendor-required, like the SCC exception — effectively cluster-admin over the core API, Secrets included. Say so plainly. |

Notes for reading these numbers:

- **The no-ingress finding is gone for everything we own** — zero
  non-platform deployments fail it, a direct result of `manifests/17-*`.
  What remains is all `openshift-*`.
- **ACS evaluates platform namespaces; the Compliance Operator's
  NetworkPolicy check exempts them.** Most of the raw failure count (185 of
  217 deployments are platform) is Red Hat-managed components. Report them
  separately rather than letting them swamp the actionable items.
- **These are technical safeguards only.** HIPAA's administrative and
  physical safeguards — risk analysis, workforce training, BAAs, facility
  controls — are outside what any scanner sees, and usually the larger part.

### Rerun after the 4.22.16 upgrade (2026-10-08) — the CVE finding did not move

Upgraded 4.22.14 → 4.22.16 specifically to clear 306(e). Rerun result:
**still 9/18, still 124 images**, 77 of them release payload. ACS is not
stale: 115 of the 116 flagged digests are images running *now*, i.e. the
new 4.22.16 payload. Every operator subscription was already at its latest
CSV, so there is no further update available to apply.

Why a newer z-stream does not help: ACS calls a CVE "fixable" when **any**
newer version of the component exists upstream — for a Go module, a newer
`golang.org/x/crypto` tag; for an RPM, a newer RHEL erratum. Vendor images
are rebuilt on the vendor's schedule, so at any moment a fresh release
carries components that already have newer versions somewhere. The count
resets with each release and refills.

Severity snapshot across the 116 flagged images (distinct CVEs):

| Severity | Distinct CVEs | Image × CVE |
|---|---|---|
| Critical | 12 | 345 |
| Important | 101 | 1006 |
| Moderate | 103 | 922 |
| Low | 18 | 291 |
| Unknown | 25 | 880 |

The criticals are almost all **one library**: `golang.org/x/crypto`
(CVE-2026-39830/32/33/34, -42508, -46595), each in ~54 images. The top
importants are `google.golang.org/grpc` and OpenTelemetry. These are
**language-module** findings matched by version; whether the vulnerable
code path is reachable in each binary is not something ACS determines —
Red Hat's own security data (VEX) is the authority on whether a given
OpenShift image is affected. RPM-level findings (`openssl-libs`,
`libxml2`, `libcurl-minimal`, `libevent`) are smaller in count.

**What satisfies 306(e) / 308(a)(6)(ii) in practice** is not a zero count,
which no cluster running vendor images will reach, but:

1. A **written patch cadence** — e.g. apply recommended z-streams within N
   days of release, operators on `Automatic` approval (already the case for
   all seven).
2. **Evidence of following it** — this upgrade, with before/after
   `verify.sh` runs, is the first instance.
3. Optionally, an **ACS policy** flagging fixable Critical/Important CVEs in
   *our own* namespaces (`vms-test`, `nfs-tls`, `etcd-backup`), where we
   control the image and can actually act on it. Pairs naturally with the
   notifier once a destination exists.

### Correction: the NVIDIA images were never scanned (found 2026-10-08)

The first write-up of this run said "all NVIDIA images clean". **That was
wrong.** ACS reported "has no fixed CVEs" for every `nvcr.io` image because
it has **no data on them**: all 10 show `scanTime` never, and a forced scan
fails with *"no matching image registries found: please add an image
integration for nvcr.io"*. ACS has integrations for quay.io, the Red Hat
registries, ghcr.io, docker.io and registry.k8s.io, but not `nvcr.io` —
so the GPU stack, which runs privileged and loads a kernel module, is the
one part of the cluster nobody is vulnerability-scanning.

The HIPAA control passed those images by default; "no evidence of fixable
CVEs" and "evidence of no fixable CVEs" are different statements, and the
check does not distinguish them.

**Fixed the same day.** Added an ACS image integration — type `docker`,
endpoint `nvcr.io`, no credentials (anonymous pull works for these public
images), named *NVIDIA NGC (nvcr.io, anonymous)*. It is ACS configuration,
not a manifest; recreate it the same way after an ACS rebuild. All 10
images then scanned in 2–27s each. HIPAA rerun: **134** images with fixable
CVEs (124 + the 10 NVIDIA), still 9/18 controls.

| Image | OS | CVEs | Fixable | of which Critical / Important |
|---|---|---|---|---|
| `driver` | rhel 9 | 414 | 49 | 0 / 17 |
| `cloud-native/dcgm` | rhel 10 | 255 | 33 | 0 / 9 |
| `kubevirt-gpu-device-plugin` | debian 13 | 47 | 26 | 0 / 1 |
| `cloud-native/vgpu-device-manager` | debian 13 | 39 | 17 | **1** / 1 |
| `cloud-native/k8s-mig-manager` | debian 13 | 36 | 15 | **1** / 1 |
| `gpu-operator`, `container-toolkit`, `k8s-driver-manager`, `k8s-device-plugin`, `dcgm-exporter` | debian 13 | 34–39 | 13–15 | 0 / 0–1 |

The RHEL-based images (driver, DCGM) carry the bulk: `openssl-libs`,
`libxml2`, `expat`, `libevent`, `sqlite-libs`, `curl` — the same pattern as
the OpenShift payload.

**CVE-2025-23266 (Critical) and CVE-2025-23267: a false positive, resolved
2026-10-08.** ACS attributes both to the Go module
`github.com/NVIDIA/mig-parted` in `k8s-mig-manager` (`usr/bin/nvidia-mig-manager`)
and `vgpu-device-manager` (`usr/bin/nvidia-mig-parted`), "fixed by 0.12.2".
The version it found is the Go **pseudo-version
`v0.0.0-20260921144545-a24171d5bed3`**, a mig-parted commit from
2026-09-21. That is fourteen months after the fix (NVIDIA bulletin 5659,
July 2025: mig-parted ≤ 0.12.1 affected, and only with CDI), but `v0.0.0-…`
sorts below `0.12.2` in semver, so ACS's version range matches it. The
binaries ship in mig-manager **v0.15.1** and vgpu-device-manager **v0.5.1**
(GPU operator 26.7.1, the latest channel), and the toolkit is **v1.20.1**
(fixed in 1.17.8). Nothing to patch. Record it as an exception in ACS with
this reasoning, rather than deleting the finding, so the next reviewer sees
why it was dismissed.

The general lesson: **a Go pseudo-version (`v0.0.0-<date>-<commit>`) in a
scanner finding means "built from an untagged commit", not "version 0".**
Check the commit date against the fix date before treating it as real.

**Second occurrence, 2026-10-09:** scans of a new `ghcr.io/eldritchjs/tlshd`
digest stalled at the enricher's "Getting metadata" step for 25+ minutes,
three times, with Central holding an established connection to GitHub's
registry; other scans (cached Red Hat image, 2 s) worked meanwhile. So the
hang is per-image metadata fetch with no client-side timeout, not a
blocked network. Not restarted this time: it completed on its own after
~3 h (04:15Z). So waiting works; a restart is the faster fix.

**Incident during this work:** before the integration could be tested,
Central stopped answering image scans and integration changes (reads still
worked) for ~20 minutes. No egress was being dropped: no `SYN_SENT`
sockets, and the identical integration created cleanly after a Central
restart. The first Central instance after the 19:25 egress restart had
also logged a mid-transfer `unexpected EOF` from `definitions.stackrox.io`;
the post-restart instance logged neither problem. Root cause not
established — if Central's image API hangs again, restart Central first.

### Egress policies applied (2026-10-08)

`manifests/18-egress-network-policies.yaml`, applied one namespace at a
time with a functional check after each (details: PLAN.md §7). HIPAA rerun
afterwards: **28 of our 31 deployments now pass** 308(a)(4)(ii)(B),
308(a)(6)(ii), 312(c) and 312(e) — evidence *"has both ingress and egress
network policies applied to it, and does not use host network namespace"*.
Still failing, as expected: the 3 hostNetwork agents, and the 2 operators'
cluster-wide RBAC. Control-level score is **unchanged at 9/18**, because
platform (`openshift-*`) deployments fail the same controls — the score
alone will never show this work.
