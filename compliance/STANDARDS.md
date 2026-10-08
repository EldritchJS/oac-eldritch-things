# Standards: NIST 800-171, HIPAA, FIPS — mapping and scope

> **Last updated 2026-10-05.** The framework mapping below is current. The
> **scan results are not** — the counts in §2 (209/21/10, and 191 per node)
> are the **pre-remediation** baseline, kept as a record of the starting
> position. Hardening is complete: node failures **377 → 4**,
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

`jetty` was built on 2026-09-30, after the sunset. It is a new deployment,
so **140-3 is the
target.** If your requirement document says "FIPS 140-2", that is not wrong —
it is simply pre-sunset wording. Satisfying 140-3 satisfies the intent.

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
2. Whether the module **versions** on RHCOS `9.8.20260908-0` match the
   certified versions.
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

383 remediations are now available; **377 of them are MachineConfigs.**
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
| **Whole cluster in scope** | **Recommended.** Uniform, simplest to defend to an assessor. |
| Separate MachineConfigPools for CUI vs general workers | Technically real — label nodes, create an MCP, scope remediation by role. But the control plane stays shared and in scope, and with **2 workers** there is nothing to split. Revisit if the cluster grows. |
| Separate clusters | The only truly clean separation, and the honest answer if some tenants must stay unhardened. |

**Recommendation:** treat the whole cluster as in scope. If a tenant genuinely
cannot live with node hardening, they need a different cluster — that is a
governance decision, not a technical one.

### CNV-specific note

`ocp4-cis-vm-extension` and `ocp4-stig-vm-extension` profiles exist, but there
is **no `moderate-vm-extension`**. So for an 800-171 posture, CNV/VM-specific
hardening is not covered by any profile and needs manual attention.
