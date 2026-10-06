# Jetty cluster — compliance baseline

> **Last updated 2026-10-05.** Stages 1 and 2 are applied: node failures
> **377 → 10**, both GPU modalities survived. Figures in §3b and §6 marked
> "initial" are the **pre-remediation** baseline, kept as a historical record.
> For current numbers see §7 "Done", `tests/baseline-fail-counts.txt`, or run
> `./remediate.sh status`. Current state of record: [README.md](README.md).

Cluster: `jetty` / `https://<cluster-api-fqdn>:6443`
OpenShift 4.22.14, baremetal (Assisted Installer), 3 masters + 2 workers.
Kubeconfig: **not in this repo** — set `KUBECONFIG` to a cluster-admin
kubeconfig for `jetty`. See [README.md](README.md) § Prerequisites.

---

## 1. FIPS — verified enabled

Confirmed at three independent layers, not just the declared intent:

| Evidence | Result |
|---|---|
| `MachineConfig 99-master-fips` / `99-worker-fips` → `spec.fips` | `true` |
| Rendered MCs for both pools → `spec.fips` | `true` |
| `/proc/sys/crypto/fips_enabled` on all 5 nodes | `1` |
| `fips=1` in `/proc/cmdline` on all 5 nodes | present |
| `update-crypto-policies --show` on all 5 nodes | `FIPS` |
| MCPs `master`/`worker` | Updated, 0 degraded |

**Verdict: the cluster genuinely boots in FIPS mode and the system-wide crypto
policy is FIPS.** All 5/5 nodes agree.

One wrinkle worth knowing: the stored `install-config` in
`cm/cluster-config-v1 -n kube-system` has **no `fips:` key**. That is expected
here — this cluster was built by the **Assisted Installer** (note the
`99-assisted-installer-master-ssh` MachineConfig), which expresses FIPS as
discrete `99-*-fips` MachineConfigs rather than through install-config. So the
absence of `fips: true` in install-config is *not* evidence against FIPS, but it
does mean **install-config is not a valid audit artifact for this cluster** —
cite the node-level evidence above instead.

FIPS cannot be toggled post-install. It is correct now; the task is to not
regress it (e.g. don't add non-FIPS workloads and claim cluster-wide FIPS).

---

## 2. Operators — installed and healthy

| Operator | Namespace | Version | Status |
|---|---|---|---|
| Compliance Operator | `openshift-compliance` | v1.10.0 | Succeeded |
| RHACS (StackRox) | `rhacs-operator` | v4.11.4 | Succeeded |

Both ProfileBundles (`ocp4`, `rhcos4`) parsed to **VALID**, yielding 48 profiles.

Manifests used are in `manifests/01-*` and `manifests/02-*` — re-appliable.

**Only the operators are installed.** No ACS `Central`, no `SecuredCluster`, no
`ScanSettingBinding` yet — all of those need storage (see §3).

### Available profiles (the standards menu)

Platform profiles (`ocp4-*`) audit the control plane and cluster config.
Node profiles (`rhcos4-*`, `ocp4-*-node`) audit the RHCOS hosts. **Most standards
require both halves** — binding only the platform profile leaves the OS unscanned.

| Standard | Platform | Node |
|---|---|---|
| CIS Benchmark | `ocp4-cis` (2.0.0), `ocp4-cis-1-9` | `ocp4-cis-node` |
| NIST 800-53 Moderate | `ocp4-moderate` (Rev 4) | `ocp4-moderate-node`, `rhcos4-moderate` |
| NIST 800-53 High | `ocp4-high` (Rev 4) | `ocp4-high-node`, `rhcos4-high` |
| DISA STIG | `ocp4-stig` (V2R6) | `ocp4-stig-node`, `rhcos4-stig` |
| PCI-DSS | `ocp4-pci-dss` (3.2.1), `ocp4-pci-dss-4-0` | `ocp4-pci-dss-node` |
| BSI (German) | `ocp4-bsi` (2022) | `ocp4-bsi-node`, `rhcos4-bsi` |
| Essential Eight | `ocp4-e8` | `rhcos4-e8` |
| NERC-CIP | `ocp4-nerc-cip` | `ocp4-nerc-cip-node`, `rhcos4-nerc-cip` |
| CIS / STIG for VMs (CNV) | `ocp4-cis-vm-extension`, `ocp4-stig-vm-extension` | `ocp4-cis-vm-extension-node` |

Since CNV/KubeVirt is already installed on this cluster, the `*-vm-extension`
profiles are relevant if VMs are in scope.

> When you get your standards, tell me which and I'll build the
> `ScanSettingBinding` plus a `TailoredProfile` for any justified exceptions.

---

## 3. Storage — RESOLVED

`pure-fb-nfsv4` (Portworx CSI → Pure FlashBlade NFSv4.1), default StorageClass.
Was unusable for ~3h because the storage VLAN was not trunked to the Pure
appliance; fixed 2026-10-02. Diagnostic record: **[STORAGE-ISSUE.md](STORAGE-ISSUE.md)**

| Component | PVC | State |
|---|---|---|
| Compliance raw results | 10Gi ×3 | ✅ Bound, ARF archiving |
| ACS Central DB | 100Gi | ✅ Bound, Postgres healthy |
| ACS Central DB backup | 200Gi | ✅ Bound (operator-created, not requested) |
| ACS Scanner V4 DB | 50Gi | ✅ Bound |
| CNV golden images | 30Gi RWX ×6 | ⚠️ Still `ImportScheduled` — see note |

**Block storage is tabled permanently.** FlashBlade is file/object only and
there is no FlashArray, so NFS is the only class there will ever be. Central DB
therefore runs on NFS — a deviation from Red Hat's block-preferred guidance,
but **empirically validated**: the canary confirmed initdb, server start,
write/read, and forced `CHECKPOINT` (fsync to NFS) all succeed. Mount options
are correct for Postgres (`hard,vers=4.1,proto=tcp,local_lock=none`).

> **Note — 350Gi total, not 150Gi.** The operator auto-created a 200Gi
> `central-db-backup` PVC that was not in our manifest. Worth knowing for
> capacity planning.
>
> **Note — CNV imports.** The six golden-image DataVolumes are still
> `ImportScheduled` with importer pods from the outage window. These are
> leftovers that likely need a pod delete to retry. **Not our workload** —
> flag to whoever owns CNV.

---

## 3b. CIS baseline — RUN, with archival evidence

Ran twice: first storage-less as a stopgap, then re-run on PVC-backed storage
once mounts worked. **Identical results both times**, and raw ARF/XCCDF is now
archived to `pure-fb-nfsv4` (verified: `/rawresults/0/*.xml.bzip2`), so these
results are durable audit evidence rather than a transient read.

| Scan | Result |
|---|---|
| `ocp4-cis` (platform) | **NON-COMPLIANT** |
| `ocp4-cis-node-master` | COMPLIANT |
| `ocp4-cis-node-worker` | COMPLIANT |

**209 PASS · 21 MANUAL · 10 FAIL**

The nodes pass clean — consistent with a FIPS-enabled, stock-hardened RHCOS.
Every failure is cluster/platform configuration:

| Severity | Check | Matches gap |
|---|---|---|
| **high** | `configure-network-policies-namespaces` | #8 |
| **high** | `openshift-api-server-audit-log-path` | #3 |
| medium | `api-server-encryption-provider-cipher` | #1 etcd encryption |
| medium | `audit-log-forwarding-enabled` | #3 |
| medium | `audit-profile-set` | #2 |
| medium | `idp-is-configured` | #4 |
| medium | `kubeadmin-removed` | #5 |
| medium | `ocp-allowed-registries` | new |
| medium | `ocp-allowed-registries-for-import` | new |
| medium | `scc-limit-container-allowed-capabilities` | new |

Seven of ten were predicted in §6 before the scan ran. Only 2 auto-remediations
are offered — the rest need deliberate decisions, which is the normal shape of
this work.

Scans now run nightly at 01:00 via the ScanSetting schedule, with 10 rotations
retained.

Useful queries:
```sh
oc get ccr -n openshift-compliance -l compliance.openshift.io/check-status=FAIL
oc get ccr -n openshift-compliance <name> -o jsonpath='{.description}{"\n"}'
oc get complianceremediation -n openshift-compliance
```

---

## 4. Order of operations once storage lands

```sh
export KUBECONFIG=/path/to/kubeadmin-jetty    # see README.md § Prerequisites
```

1. **Verify the SC.** `oc get sc` — note whether it is the default
   (`storageclass.kubernetes.io/is-default-class`), and which nodes it serves.
2. **Replace `REPLACE_ME`** with the StorageClass name in `manifests/03`,
   `manifests/04`.
3. **Deploy ACS Central:** `oc apply -f manifests/04-acs-central.yaml`
   Wait for `oc get pods -n stackrox` to settle; get the UI:
   `oc -n stackrox get route central`
   Admin password:
   `oc -n stackrox get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}'`
4. **Generate an init bundle**, then `oc apply` it into `stackrox`
   (exact command is in the header of `manifests/05`). This is cluster-join
   credential material — do not commit it.
5. **Deploy SecuredCluster:** `oc apply -f manifests/05-acs-securedcluster.yaml`
   This brings up Sensor, Collector (DaemonSet), and the admission controller.
6. **Bind compliance profiles:** `oc apply -f manifests/03-scansetting-binding.yaml`
   Then watch: `oc get compliancescan,compliancesuite -n openshift-compliance -w`
7. **Read results:**
   `oc get compliancecheckresult -n openshift-compliance --sort-by=.status`
   Failures only:
   `oc get ccr -n openshift-compliance -l compliance.openshift.io/check-status=FAIL`

---

## 5. What the two operators actually buy you

They solve **different, non-overlapping problems**. Neither is a superset.

### Compliance Operator — *configuration* compliance, audit evidence
- Runs OpenSCAP/CEL scans against the cluster API and the RHCOS hosts.
- Maps findings to **named control frameworks** (CIS, NIST, STIG, PCI-DSS…),
  which is the part auditors actually want — a rule ID traceable to a control.
- Emits a `ComplianceCheckResult` per rule, and a `ComplianceRemediation` object
  for many failures that can be **auto-applied** (usually as a MachineConfig).
- `TailoredProfile` lets you formally document exceptions — a scoped,
  version-controlled deviation rather than an undocumented drift.
- Scheduled rescans (cron) give you continuous, dated evidence.

**It does not:** inspect images, see runtime behaviour, understand workloads, or
look at anything outside cluster/node configuration.

### RHACS / StackRox — *workload and runtime* security
- Image CVE scanning (Scanner V4) across registries and running deployments.
- Runtime threat detection via eBPF Collector — process and network baselining.
- Policy enforcement at **deploy time** (admission controller) and **runtime**
  (kill/alert), which is the enforcement arm the Compliance Operator lacks.
- Network graph and NetworkPolicy generation — practical help closing §6's
  network gap.
- Risk ranking, RBAC/service-account analysis, exposed-secret detection.
- Its own compliance dashboards (CIS, NIST 800-190, PCI, HIPAA) — these are
  **workload-centric** and complement, not duplicate, the Compliance Operator.

**It does not:** harden the OS, check STIG node rules, or remediate node config.

**Rough division:** Compliance Operator answers *"is the cluster built and
configured to the standard?"*. ACS answers *"is what's running on it safe, and
can I stop it when it isn't?"*. Most frameworks require both.

---

## 6. Gaps the operators will NOT close — found on this cluster

These are real findings from the live cluster, and every one of them maps to
common control families. The scanners will flag several, but **flagging is not
fixing** — these need deliberate work.

| # | Gap | Live state | Why it matters |
|---|---|---|---|
| 1 | ~~**etcd encryption at rest**~~ | ✅ **CLOSED** — `aesgcm`, `EncryptionCompleted` | Was unencrypted (SC-28). Fixed in stage 1, 2026-10-02. |
| 2 | ~~**Audit log profile**~~ | ✅ **CLOSED** — `WriteRequestBodies` | Was `Default`, metadata only (AU-3). Fixed in stage 1, 2026-10-02. **Raises gap #3's urgency** — more audit data, still nowhere to put it. |
| 3 | **Audit log retention/forwarding** | **still open** — no logging stack. Retention measured at **1.6 h**, cut to **5.8 h** by the volume work below | Audit logs stay on masters and **rotate away**. Nothing on the audited host satisfies AU-9 at any retention. Needs forwarding off-cluster (no object storage required) or LokiStack (needs FlashBlade S3, not currently provisioned). **The single most urgent remaining gap.** See §6b. |
| 4 | **Identity provider** | **none configured** | Auth is via `kubeadmin` only — a shared break-glass account. No per-user attribution, which breaks accountability controls (AC-2, IA-2). |
| 5 | **kubeadmin still present** | secret exists | Standard hardening says remove it once a real IdP works. Do *not* remove before step 4 or you lose access. |
| 6 | **TLS security profile** | unset (Intermediate default) | FIPS-aligned deployments usually pin `Modern` or an explicit `Custom` profile. |
| 7 | **etcd backup** | no backup CronJob | Not a scanner finding, but a contingency-planning control (CP-9) and plain operational sanity. |
| 8 | **NetworkPolicies** | no default-deny posture | Flat pod network by default. ACS can *generate* policies, but someone must apply and own them (SC-7). |
| 9 | **Image provenance / signing** | not configured | ACS scans for CVEs but does not enforce signature verification. Needs sigstore policy / `ClusterImagePolicy`. |
| 10 | **FIPS scope discipline** | cluster OK | Workloads must also use FIPS-validated crypto. A Go binary built without BoringCrypto on a FIPS cluster is still non-compliant — the cluster being FIPS does not make applications FIPS. |
| 11 | **NFS traffic to Pure is cleartext** | `sec=sys`, no `xprtsec` | All storage traffic, including model training data, is unencrypted on the wire (800-171 **3.13.8**, SC-8). **No scanner inspects CSI mount options**, so this never appears in scan results. The kernel already supports TLS; only `tlshd` is missing, and a colleague has proven the fix in this environment. See **[NFS-TLS.md](NFS-TLS.md)**. |
| 12 | **Metrics have no persistence** | Prometheus `retention=15d`, **no `volumeClaimTemplate`** | Monitoring data is on emptyDir, so it is lost whenever the pod restarts or reschedules — "15 days" is nominal. There is no `cluster-monitoring-config` ConfigMap at all. Pairs with gap #3: the AU workstream needs a destination for *metrics* as well as logs. |

Also note: **non-technical controls** (policies, SSPs, access reviews, IR plans,
training) are typically the larger share of an authorization package, and no
operator produces them.

---

## 6b. Audit volume — measured, and partly mitigated

Stage 1 set `audit.profile: WriteRequestBodies` (AU-3). The measured cost was
severe enough to be its own finding.

### The problem

kube-apiserver keeps **10 × 200MB rotations = a 2.0 GB cap**, which is not an
exposed tunable. At the post-stage-1 write rate that cap held **94 minutes** of
history (oldest `22:04:36Z`, newest `23:38:19Z` on 2026-10-02). A security
event noticed the next morning had already lost its evidence.

### What the volume was

Measured over one full 200MB rotation, bytes attributed by caller:

| Share | Source |
|---|---|
| 96.3% | service accounts |
| **3.7%** | **everything else — all humans, nodes, anonymous** |
| 71.4% | `openshift-operator-lifecycle-manager` alone |
| 9.7% | `openshift-cnv` |

Ranking by *bytes* matters: by event count the top talker is
`openshift-authentication-operator`, which is only 0.2% of bytes. Size is what
consumes the retention window, so size is what to target.

### The mitigation

`manifests/09-audit-customrules.yaml` — ten platform namespaces downgraded to
`Default` via `apiserver.spec.audit.customRules`. Applied 2026-10-03.

`Default` does **not** stop auditing them: it drops request/response bodies and
still records identity, timestamp, source IP, verb, object and outcome — the
full AU-3 content set. Humans, application service accounts, and `stackrox`
keep full `WriteRequestBodies` fidelity.

| | Before | After |
|---|---|---|
| Rate per master | 1,310 MB/h | **351 MB/h** |
| Cluster per day | 92.0 GB | **24.7 GB** |
| Retention window | 1.6 h | **5.8 h** |
| 90-day raw volume | 8.3 TB | **2.17 TB** |

**73.2% reduction.** Verified working, not assumed: in a post-convergence
sample the excluded namespaces emit **100% `Metadata` and zero
`RequestResponse`**, while non-excluded callers still emit `RequestResponse`.
Rescan confirms **no compliance regression** — all counts unchanged and
`audit-profile-set` still PASSes (it reads top-level `.spec.audit.profile`,
which is untouched).

### What this does and does not buy

It does **not** make the cluster compliant. 5.8 hours is not months, and logs
on the audited host fail AU-9 regardless of retention. What it buys is margin,
and a much smaller bill for the real fix: a 90-day store drops from ~8.3 TB raw
to ~2.17 TB (roughly 200–250 GB compressed) — a modest storage ask rather than
a capacity project.

A further ~10 points is available by also excluding
`openshift-controller-manager-operator` (now the top producer at ~50%, up from
2.4% once the larger sources were cut) and a few smaller operators, at one
~20-minute apiserver roll per iteration. Judged not worth it: it still would
not reach compliance.

### Destination options (undecided)

| Path | Needs | Note |
|---|---|---|
| `ClusterLogForwarder` → SIEM/syslog | a destination endpoint | **No object storage.** Strongest AU-9 posture — logs leave the host. |
| LokiStack | **FlashBlade S3** account/bucket/creds | Not provisioned: `px-pure-secret` is `backend: pure_file`, NFS only. Loki cannot use the NFS StorageClass. |

Operators are available in `redhat-operators`: `cluster-logging` **6.6.1** and
`loki-operator` **6.6.1**. Nothing logging-related is installed.

> **Unverified:** Logging 6.6 is Vector-based; its FIPS posture on this cluster
> has not been confirmed. Check before committing, since FIPS is a named
> standard here.

---

## 7. Decisions taken and next steps

### Done (2026-10-02)

- FIPS verified at runtime on all 5 nodes (§1).
- Compliance Operator + RHACS operators installed (§2).
- Storage VLAN fixed by admins; Postgres-on-NFS validated by canary (§3).
- **ACS fully deployed and HEALTHY** — Central, Central DB, Scanner V4,
  Sensor, 5 Collectors, 3 admission controllers. Cluster `jetty` registered
  with all components reporting `HEALTHY`.
- CIS baseline run with archival ARF evidence (§3b).
- **Stage 1 remediation applied** (`./remediate.sh stage1`) — the first cluster
  config changes of the engagement:

  | Setting | Before | After |
  |---|---|---|
  | etcd encryption | *(empty)* | `aesgcm` |
  | Audit profile | `Default` | `WriteRequestBodies` |
  | OAuth inactivity timeout | unset | `10m0s` |
  | OAuth token max age | unset | `86400` (24h) |

  Took ~22 min, **no node reboots**, no ClusterOperator ever Degraded, etcd
  reported `EncryptionCompleted — All resources encrypted: secrets, configmaps`.
  Rescan confirms all 6 rules now PASS: `ocp4-cis` 10 → **8**,
  `ocp4-moderate` 25 → **21**, node scans unchanged. Closes gaps #1 and #2.
  `tests/verify.sh`: 34 PASS / 0 FAIL / 3 WARN — FIPS, both GPU modalities and
  ACS all intact. Baseline re-saved.
- **Stage 2 applied 2026-10-05** (run by the cluster owner). 377 MachineConfigs
  behind an MCP pause, then one rolling reboot per pool. One node went
  Degraded mid-run and recovered on its own — normal MCO drain-and-retry.
  All 5 nodes rebooted (bootIDs changed), 373 `75-*` MachineConfigs rendered,
  both MCPs `Updated`, no ClusterOperator degraded.

  **Node failures 377 → 10:**

  | Scan | before | after |
  |---|---|---|
  | `rhcos4-moderate-master` | 191 | **4** |
  | `rhcos4-moderate-worker` | 191 | **4** |
  | `ocp4-moderate-node-master` | 4 | **1** |
  | `ocp4-moderate-node-worker` | 1 | 1 |
  | platform (`ocp4-cis` / `ocp4-moderate`) | 8 / 21 | unchanged |

  **GPU survived hardening — the headline result.** `tests/verify.sh`: 34 PASS
  / 0 FAIL / 3 WARN. Container modality (`nvidia.com/gpu=4`, driver Running)
  and VM passthrough (`GH100...=4`, `vfio-manager` Running, host driver absent,
  `permittedHostDevices` intact on both HCO and KubeVirt CR) both still work
  after a full node-hardening reboot. This converts FEASIBILITY.md §3 #4 from a
  prediction into a measurement.

- **Remediation is ITERATIVE — stage 2 is not one-and-done.** 6 remediations
  remain `NotApplied`, all usbguard, all `kind: MachineConfig`, all
  `spec.apply: false`. They carry
  `compliance.openshift.io/depends-on: ...package_usbguard_installed` and were
  labelled `compliance.openshift.io/has-unmet-dependencies` when stage 2 ran —
  the operator **will not apply a remediation until its prerequisite is applied
  and a rescan re-evaluates it**. Stage 2 installed the usbguard package; the
  post-hardening rescan then flipped them to `dependencies-met` and generated
  2 brand-new ones (`configure-usbguard-auditbackend`, total 383 → 385).
  **A second `./remediate.sh stage2` pass (plus another reboot) is required**,
  and possibly a third. See §7 "Open".

### Standards confirmed: NIST 800-171 + HIPAA + FIPS

Full mapping, baseline results, FIPS 140-3 position, and the mixed-VM-tenancy
scope analysis: **[STANDARDS.md](STANDARDS.md)**

Headline: 800-171 maps to `ocp4-moderate`/`rhcos4-moderate` (bound and run);
HIPAA lives in ACS (`HIPAA_164`); **383 remediations now available, 377 of them
MachineConfigs — i.e. a cluster-wide rolling reboot.** That must be scheduled
around VM work.

### Open

1. **You:** decide the scope posture for mixed VM tenancy (STANDARDS.md §4),
   and schedule the remediation reboot window.
2. **Then** triage remediation. The ten failures are catalogued in §3b.
   Sequencing note that matters: **wire an identity provider and verify login
   before removing kubeadmin**, or you lose cluster access.
3. **Someone else:** the six stuck CNV golden-image imports (§3).
4. Still unaddressed and invisible to scanners — the §6 gaps: audit log
   retention/forwarding, etcd backups, image signing policy, plus the
   non-technical controls.

### Not covered by any of this

The §6 gaps that no scanner will flag — audit log retention/forwarding, etcd
backups, image signing policy — plus the non-technical controls (SSP, access
reviews, IR plan, training), which are usually the larger share of an
authorization package.
