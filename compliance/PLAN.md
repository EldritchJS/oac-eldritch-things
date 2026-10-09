# Jetty cluster — compliance baseline

> **Last updated 2026-10-08.** Node hardening is complete: 385/385
> remediations applied plus stage 3, node failures **377 → 2**, both GPU modalities
> survived, and all NFS traffic is encrypted. Figures in §3b and §6 marked
> "initial" are the **pre-remediation** baseline, kept as a historical record.
> For current numbers see §7 "Done", `tests/baseline-fail-counts.txt`, or run
> `./remediate.sh status`. Current state of record: [README.md](README.md).

Cluster: `jetty` / `https://<cluster-api-fqdn>:6443`
OpenShift 4.22.16 (from 4.22.14, 2026-10-08), baremetal (Assisted
Installer), 3 masters + 2 workers.
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

ACS `Central`, `SecuredCluster`, and the `ScanSettingBinding`s followed once
storage worked (§3, §7) — all deployed and healthy.

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

Portworx CSI → Pure FlashBlade NFSv4.1. Was unusable for ~3h because the
storage VLAN was not trunked to the Pure appliance; fixed 2026-10-02.
Diagnostic record: **[STORAGE-ISSUE.md](STORAGE-ISSUE.md)**

The default StorageClass is now **`nfs-over-tls`**, and every PVC in use has
been migrated to it from the original cleartext `pure-fb-nfsv4` (2026-10-07,
see [NFS-TLS.md](NFS-TLS.md)).

| Component | PVC | State |
|---|---|---|
| Compliance raw results | 10Gi, one per scan | ✅ Bound, ARF archiving |
| ACS Central DB | 100Gi | ✅ Bound, Postgres healthy |
| ACS Central DB backup | 200Gi | ✅ Bound (operator-created, not requested) |
| ACS Scanner V4 DB | 50Gi | ✅ Bound |
| CNV golden images | 30Gi RWX ×6 | ✅ Imported 2026-10-07 — see note |

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
> **Note — CNV imports.** The six golden-image DataVolumes sat in
> `ImportScheduled` from cluster build. The cause was not the outage: CDI's
> auto-detected storage profile advertised `Block` first, which FlashBlade NFS
> cannot serve. Pinning `Filesystem` (`manifests/12-cdi-storageprofile.yaml`)
> and deleting the stuck DataVolumes fixed all six. See
> [README.md](README.md) §7.

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
| 6 | ~~**TLS security profile**~~ | ✅ **CLOSED BY MEASUREMENT 2026-10-08** — profile still unset (Intermediate), deliberately | All 31 TLS compliance checks already PASS. Handshake probes of the API server, ingress, OAuth and all 5 kubelets: only TLS 1.3 and TLS 1.2 ECDHE+AES-GCM are accepted; TLS 1.0/1.1, CBC, ChaCha20 and static-RSA key exchange are refused — FIPS mode strips what Intermediate would otherwise allow. That meets NIST SP 800-52r2. `verify.sh` T-15 guards it (negative-tested against a weak server). `Modern` (TLS 1.3 only) was not adopted: the only gain is dropping TLS 1.2, it costs a full rolling reboot for the kubelet, the 4.22 docs contradict themselves on ingress support, and TLS 1.2-only clients cannot be ruled out. Revisit if a requirement names TLS 1.3. |
| 7 | ~~**etcd backup**~~ | ✅ **CLOSED 2026-10-08** — nightly CronJob, 14 retained | `manifests/15-etcd-backup.yaml`; `tests/verify.sh` T-14 guards it. Backups hold the `aesgcm` key, so the volume is Secret-grade. Same array as the cluster's data (no off-array copy yet). **Restore rehearsed 2026-10-08** (`tests/etcd-restore-rehearsal.sh`); the full control-plane recovery procedure is not. |
| 8 | ~~**NetworkPolicies**~~ | ✅ **CLOSED 2026-10-08, ingress and egress** | Default-deny ingress (`manifests/17-*`) and egress (`manifests/18-*`) with measured allows, on our six namespaces plus egress for `stackrox`; `openshift-*` namespaces largely ship their own. Internet egress remains only for ACS Central and scanner-v4-indexer (vulnerability feeds, registry scans). The Portworx version-manifest fetch is blocked. |
| 9 | **Image provenance / signing** | **partial** (2026-10-08) | Registry allowlist in force (default `reject`, 8 registries). Signature-verified at runtime: OpenShift release images only. `nvcr.io` cannot be: NVIDIA signs the index, CRI-O verifies the platform manifest (FEASIBILITY.md §3 #2). Remaining options: ACS deploy-time signature checks; sign `ghcr.io/eldritchjs/tlshd` ourselves. |
| 10 | **FIPS scope discipline** | cluster OK | Workloads must also use FIPS-validated crypto. A Go binary built without BoringCrypto on a FIPS cluster is still non-compliant — the cluster being FIPS does not make applications FIPS. |
| 11 | ~~**NFS traffic to Pure is cleartext**~~ | ✅ **CLOSED 2026-10-07** | All NFS traffic is now encrypted (RFC 9289). `tests/verify.sh` T-13 reports no cleartext mounts remain; 18/18 PVCs on `nfs-over-tls`, which is also the default class. Proven by packet capture, not just by the mount succeeding. **No scanner checks this** — T-13 is the only guard. See **[NFS-TLS.md](NFS-TLS.md)**. |
| 12 | **Metrics have no persistence** | Prometheus `retention=15d`, **no `volumeClaimTemplate`** | Monitoring data is on emptyDir, so it is lost whenever the pod restarts or reschedules — "15 days" is nominal. There is no `cluster-monitoring-config` ConfigMap at all. Pairs with gap #3: the AU workstream needs a destination for *metrics* as well as logs. **Also (measured 2026-10-08): Portworx and rhacs-operator metrics are scraped by nothing** — their namespaces lack the cluster-monitoring label (Portworx) or a ServiceMonitor (rhacs-operator), and user-workload monitoring is off. **Owned elsewhere (2026-10-08):** another team is deciding how monitoring storage is done; not ours to change. Measurements handed over: 22.5k samples/s and 659k series per replica (apiserver 279k, kubelet 150k), 2.32 bytes/sample on disk → **~68 GB per replica for 15 days** (~140 GB for the pair). Only NFS StorageClasses exist (Prometheus upstream does not support NFS; Red Hat recommends block). Each GPU worker has an unpartitioned 7.68 TB NVMe (`nvme1n1`, no holders) that might suit LVM Storage, if the owner hasn't earmarked it — not checked from the host. |

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

- **Stage 2 round two applied 2026-10-07** — the 6 usbguard remediations that
  were dependency-blocked during round one became eligible after the
  post-hardening rescan. One more rolling reboot, ~2h, all 5 nodes, nothing
  degraded.

  **Node failures 10 → 4:** `rhcos4-moderate-master` and `-worker` both
  4 → **1**. The four survivors are both genuinely manual —
  `sshd-limit-user-access` (no remediation offered) and
  `reject-unsigned-images-by-default` (stage 3, GPU-dangerous, deferred).
  **Node hardening is effectively complete.**

  Two things survived the reboot that are worth recording: both GPU
  modalities (T-06/T-07 pass), and the `tlshd` DaemonSet came back 2/2, so
  the storage data path recovers on its own. `usbguard` is `enabled` and
  `active`, with the HID/hub allow rule applied in the same rendered config —
  the ordering guard in `lib/select-remediations.py` doing its job on its
  first real outing.

  Timing note for next time: this was run while **zero** TLS-backed mounts
  were in use, so `tlshd` restarting cost nothing. After volume migration,
  every reboot has to wait for it.

- **Stage 3, first check: SCC capability exception recorded 2026-10-08.**
  `scc-limit-container-allowed-capabilities` now PASSes via TailoredProfiles
  `jetty-ocp4-cis` / `jetty-ocp4-moderate` (`manifests/13-*`), which add the
  nine NVIDIA SCCs and `kubevirt-controller` to the rule's allowlist **by
  exact name** — a new SCC with capabilities still fails. No workload change,
  no reboot. `ocp4-cis` 8 → **7**, `ocp4-moderate` 21 → **20**.

  Binding the TailoredProfiles **renames the platform scans** (to
  `jetty-ocp4-*`) and deletes the old ones. Measured consequences, worth
  knowing before doing this anywhere else:
  - The stage 1 ComplianceRemediation objects were owned by the old scans'
    results and were garbage-collected. They carry no finalizers, so the
    settings they applied **stayed** — etcd encryption, audit profile,
    customRules and OAuth timeouts snapshotted before and after: identical.
  - The operator **deletes the old scans' result PVCs**. Their PVs survived
    only because they had been patched to `Retain` first. The evidence for
    `ocp4-cis` and `ocp4-moderate` (both the 10-02 cleartext and 10-07 TLS
    generations) is on `Released` PVs. All result PVs are now `Retain`.
  - `manifests/03` had drifted from live (still named the cleartext
    `pure-fb-nfsv4` class). Applying it unchecked would have moved evidence
    back to unencrypted storage. `oc diff` before every `oc apply`.

- **Default-deny ingress NetworkPolicies 2026-10-08** (gap #8, SC-7).
  `manifests/17-network-policies.yaml` on the six namespaces the check
  covers. Closes `configure-network-policies-namespaces` (**high**);
  `jetty-ocp4-cis` 5 → **4**, `jetty-ocp4-moderate` 16 → **15**.

  Allows derived from measurement, not guessed: ACS observed flows since
  10-02, plus Services, ServiceMonitors, the one webhook, and which
  Prometheus actually scrapes each namespace. Applied lowest-risk first,
  verified after each: `tlshd` 5/5 and a backup run (hostNetwork pods,
  unaffected); rhacs-operator Ready through ~18 HTTP probes with no allow
  rule — **OVN-K admits kubelet probes, proven not assumed**; all 14 GPU pods
  unchanged, all 3 GPU scrape targets `up`, live DCGM data, T-06/T-07 pass;
  Portworx pods unchanged, a fresh PVC provisioned and mounted over TLS.
  Each namespace rolls back with `oc delete networkpolicy --all -n <ns>`.

  **Modality switch under the policies, same day:** `gpu-switch-timing.sh` on
  u15, both directions — 68s / 247s (baseline 73s / 208s). Every pod the
  switch creates came up Ready; all 3 scrape targets `up`, 4 GPUs reporting,
  T-06/T-07 pass. The return leg's extra ~40s is all in the driver pod
  building and loading the kernel module (node-local, no network) —
  variance, not blocked traffic. dcgm-exporter crashed twice while DCGM was
  still starting, then came up cleanly; it reaches DCGM through the
  in-namespace Service, which the same-namespace rule covers.

  Known limits: ingress only (egress followed — next entry). The check passes on ANY
  NetworkPolicy — these are real, but the
  scanner cannot tell. Side findings: the Portworx data-path pods
  (`px-pure-csi-node`) are hostNetwork, so no NetworkPolicy can protect
  them; the Portworx operator makes undocumented outbound HTTPS to the
  internet; Portworx and rhacs-operator metrics are scraped by nothing.

- **AC-8 system use notice 2026-10-08 — PLACEHOLDER TEXT.**
  `manifests/16-system-use-notice.yaml`: a console banner and the `oc login`
  MOTD, same notice in both. Closes `banner-or-login-template-set` and
  `openshift-motd-exists`; `jetty-ocp4-moderate` 18 → **16**. The wording is
  a clearly marked placeholder, acceptable only because jetty will not be
  formally assessed. Trap: the banner check requires the ConsoleNotification
  to be **named `classification-banner`** — stated only in the rule's
  instructions; any other name shows the banner and still FAILs.

- **etcd backups running 2026-10-08** (gap #7, CP-9). `manifests/15-etcd-
  backup.yaml`: nightly 02:30 UTC CronJob that runs the operator-installed
  `cluster-backup.sh` on a master and copies the result to a 10Gi
  `nfs-over-tls` PVC (PV `Retain`), keeping 14. A CronJob because the
  built-in API (`AutomatedEtcdBackup`) is disabled in the Default feature set
  and enabling it means irreversible `TechPreviewNoUpgrade`.

  First run: 24s, 164 MB snapshot, 11,307 keys. Verified **independently of
  the job** by a read-back pod: SHA256SUMS match, `etcdutl snapshot status`
  on the stored copy agrees with the host-side check (revision 8120221; hash
  `67a8b3a3` = the host's decimal `1739109283`), files 0600, dirs 0700.

  Things to know: (a) the tarball contains
  `secrets/encryption-config/encryption-config` — **a backup can decrypt its
  own Secrets**; protect it accordingly and say so in the SSP. (b) The
  script refuses to run while a control-plane operator is Progressing — a
  night landing mid-rollout fails and retries. (c) Backups share the
  FlashBlade with everything else — they survive losing masters, not the
  array. (d) A full control-plane restore has not been tested; the
  backup itself was restore-rehearsed later the same day (below). T-14 fails if the newest
  successful backup is over 26h old; verified that it does fail.

- **Stage 3 complete 2026-10-08: registry allowlist.**
  `manifests/14-image-registry-allowlist.yaml` sets `allowedRegistries` (the
  8 measured registries) and `allowedRegistriesForImport`. One change closed
  three checks — `ocp-allowed-registries`, `-for-import`, and
  `reject-unsigned-images-by-default`, which only wants `policy.json` to
  default to `reject`. **No reboots** (CRI-O reload; boot IDs unchanged).
  Node failures 4 → **2** (`ocp4-moderate-node-*` now COMPLIANT);
  `jetty-ocp4-cis` 7 → **5**, `jetty-ocp4-moderate` 20 → **18**.
  `tests/verify.sh` **46 PASS / 0 FAIL / 2 WARN**; an uncached `nvcr.io`
  pull still succeeds, a non-allowed registry is refused.

  Before it, real signature verification for `nvcr.io` was tried via a
  ClusterImagePolicy and **reverted after ~4 minutes**: NVIDIA signs only the
  multi-arch index, CRI-O verifies the platform manifest, so signed GPU
  images were refused. Nothing pulled in that window. Full account:
  FEASIBILITY.md §3 #2.

- **Cluster upgraded 4.22.14 → 4.22.16 on 2026-10-08** (17:28Z → 18:51Z,
  1h23m). Fresh etcd backup taken first (`etcd-backup-preupgrade`). One
  reboot per node; the compliance MachineConfigs carried through. RHCOS
  `9.8.20260908-0` → `9.8.20260922-1`, kubelet 1.35.6 → 1.35.8. FIPS still
  on all 5 nodes, GPUs back on `u15` without intervention, no Failing
  condition at any point. Fresh rescans match the baseline exactly;
  `verify.sh` **49 PASS / 0 FAIL / 2 WARN**, identical to pre-upgrade.

  **It did not clear the HIPAA CVE finding** — still 124 images, 77 of them
  the new release payload, now correctly scanned. The prediction that a
  z-stream would clear it was wrong; see STANDARDS.md §5 for why and what
  that control actually needs.

- **Default-deny egress 2026-10-08** (`manifests/18-*`), seven namespaces:
  our six plus `stackrox`. Allows derived from 72 ACS-observed flows (window
  covers GPU switches and the upgrade) and live sockets; API as port 6443
  (OVN matches post-DNAT — Red Hat's own pattern), DNS 53 + 5353.
  Applied one namespace at a time, 19:17Z–19:25Z, each proven by a fresh
  pod start, not just by the policy existing:
  - `rhacs-operator`: pod deleted, re-acquired its leader lease. Probe pod
    under the policy: DNS and the API reachable, internet blocked (:443/:80).
  - `nvidia-gpu-operator`: operator and dcgm-exporter restarted; 4 GPUs
    still allocatable, ClusterPolicy `ready`, all 3 scrape targets `up`,
    fresh `DCGM_FI_DEV_GPU_TEMP` for all 4 GPUs (exporter -> DCGM path).
  - `portworx`: operator and CSI controllers restarted; a test PVC on
    `nfs-over-tls` provisioned, mounted, wrote, deleted (array mgmt path,
    allowed as `10.0.0.0/8:443` so no address is committed). The blocked
    version-manifest fetch logs no error; the operator carries on.
  - `stackrox`: all components restarted; Central reports every component
    HEALTHY; a forced Scanner V4 scan of a registry.redhat.io image
    succeeded (246 components).

  HIPAA rerun: 28 of our 31 deployments now pass the network controls;
  the 3 left are hostNetwork. Score still 9/18 (platform deployments).
  **Side finding:** ACS has never scanned the NVIDIA images (no `nvcr.io`
  integration) — the earlier "NVIDIA images clean" was wrong.
  Central's first post-restart download from `definitions.stackrox.io`
  ended in `unexpected EOF`; that instance later also hung on image scans
  (next entry). A further Central restart cleared both.

- **NVIDIA images scanned for the first time 2026-10-08.** Added ACS image
  integration *NVIDIA NGC (nvcr.io, anonymous)* — ACS config, not in a
  manifest. All 10 images have fixable CVEs (13–49 each); HIPAA 306(e) count
  124 → 134, still 9/18. Critical CVE-2025-23266 in mig-parted turned out to be a pseudo-version
  false positive (Open #3).
  On the way, Central's image API hung for ~20 minutes with no network
  cause found; a Central restart fixed it. Details: STANDARDS.md §5.

- **etcd restore rehearsed 2026-10-08** (`tests/etcd-restore-rehearsal.sh`,
  ~55 s end to end). The pre-upgrade backup (`2026-10-08T172636Z`, revision
  8288126, 10,577 keys) restored with `etcdutl` in 2 s; a real etcd 3.6.13
  served it 3 s after restore start, all inside one temporary pod with the
  control plane untouched. Checked against live:
  - 93 of 94 live resource types present; the missing one is
    `certificatesigningrequests` (2 transient CSRs). Namespaces 86/86, CRDs
    233/233. **Every other difference is explained by the work after the
    backup:** NetworkPolicies +14 = exactly the 14 egress policies in
    `manifests/18-*`; MachineConfigs +2 = the upgrade's new rendered
    configs; images +740 = the 4.22.16 payload. All three confirmed exactly
    by counting objects created after the backup timestamp. Events fell
    (TTL); pods/replicasets churned with the upgrade.
  - **Every Secret (387) and ConfigMap (678) in the backup is `aesgcm`
    encrypted, all with key `1`, and that key is in the backup's own
    encryption-config.** The backup can decrypt itself. Only key names were
    read.
  - Not proven: the full recovery procedure (`cluster-restore.sh` on a
    master, static pods stopped, members re-added). It takes the API down;
    do it on a disposable cluster.
  - Two script bugs gave a false first run (`oc exec` without `-i`; a
    `grep -m1` SIGPIPE), both now guarded — tests/README.md gotchas 8–9.

  **Side finding: the backup CronJob still ran the 4.22.14 `cli` image**
  (pinned by digest; the manifest says to refresh after an upgrade, and the
  upgrade checklist did not). Manifest updated to the 4.22.16 digest
  (`b36a4c…`); T-14 now WARNs when the job image differs from the current
  release. **Not yet applied to the cluster** — see Open.

- **TLS posture measured, gap #6 closed without a change 2026-10-08.**
  Read-only survey: every TLS-related compliance rule already PASSes, and
  handshake probes show FIPS mode already limits every endpoint to TLS 1.3
  and TLS 1.2 ECDHE+AES-GCM (table in gap #6). Added `verify.sh` T-15
  (`lib/tls-probe.py`): 8/8 PASS; against a deliberately weak local server
  it reports CBC/ChaCha20/static-RSA as ACCEPTED (→ FAIL), and an
  unreachable port as ERROR (→ WARN), so it cannot pass by not probing.
  etcd :2379 refused TLS 1.2 to the probe, most likely because it requires
  a client certificate; not included in T-15.

- **Patch cadence drafted, first class-(c) remediation done 2026-10-09.**
  [PATCHING.md](PATCHING.md). Scoped ACS policy applied as code
  (`manifests/19-*`); `mig-parted` false positive recorded as ACS exceptions.
  `tlshd` rebuilt for CVE-2026-84782 (openssl 3.5.8-1 → -2) and rolled
  out 01:51–01:56Z; verified in every pod, T-13 4/4, live session survived,
  fresh TLS mount on u16 OK. Took three builds: (1) the new `nfs-tls`
  default-deny egress blocked builds — `allow-egress-builds` added to
  `manifests/18-*`; (2) a plain rebuild kept the stale `ubi9:latest`
  openssl — Dockerfile now runs `dnf upgrade`; (3) fixed. **ACS has not
  yet rescanned the new digest** (Central stalls fetching ghcr metadata,
  no network cause), so its alerts stay active until it does.

### Standards confirmed: NIST 800-171 + HIPAA + FIPS

Full mapping, baseline results, FIPS 140-3 position, and the mixed-VM-tenancy
scope analysis: **[STANDARDS.md](STANDARDS.md)**

Headline: 800-171 maps to `ocp4-moderate`/`rhcos4-moderate` (bound and run);
HIPAA lives in ACS (`HIPAA_164`). The 383 remediations initially available
(377 of them MachineConfigs) — 385 once the dependency-gated usbguard ones
surfaced — are all applied.

### Decided 2026-10-08: whole cluster in scope

The entire cluster is in scope for 800-171 — no split by MachineConfigPool or
tenant. Rationale and the alternatives considered: STANDARDS.md §4.

### Open

1. **Audit log forwarding** (gap #3, §6b) — the most urgent gap. Decide the
   destination first. **The same destination should take ACS policy
   notifications** — HIPAA 308(a)(6)(ii) and 314(a)(2)(i)(C) fail because
   ACS violations go nowhere (STANDARDS.md §5).
2. **Fixable CVEs (HIPAA 306(e)) are a standing condition, not a task.**
   Staying on current z-streams and operator versions is the control; the
   upgrade did that and the count did not move (STANDARDS.md §5). What
   remains to decide is a **patch cadence** to write into the SSP, and
   whether to add an ACS policy enforcing a severity floor on *our* images.
   **Drafted 2026-10-08: [PATCHING.md](PATCHING.md)** — day counts to
   decide, a scoped ACS policy and an exception to approve. Found on the
   way: our own `tlshd` image has a fixable Important openssl CVE
   (CVE-2026-84782); **remediated 2026-10-09** (next entry list, and
   PATCHING.md §3). Day counts still **[decide]**.
3. ~~CVE-2025-23266 / -23267 in `mig-parted`~~ **False positive, resolved
   2026-10-08.** ACS matched a Go pseudo-version (`v0.0.0-20260921…`, a
   2026 commit) as older than the fixed 0.12.2. Remaining step: record an
   ACS exception carrying that reasoning (STANDARDS.md §5).
3a. **Apply the refreshed etcd-backup CronJob** (`manifests/15-*`, image
   digest only; `oc diff` shows that one line) and run one backup on it:
   `oc apply -f manifests/15-etcd-backup.yaml`, then
   `oc create job etcd-backup-postupgrade --from=cronjob/etcd-backup -n etcd-backup`.
   T-14 WARNs until done.
4. **Identity provider** (gaps #4, #5). Sequencing note that matters: **wire
   an IdP and verify login before removing kubeadmin**, or you lose cluster
   access. Also unblocks flipping the GPU-switch policy to `Deny`.
5. Still unaddressed and invisible to scanners — the rest of the §6 gaps:
   image signature verification beyond the release images (gap #9),
   metrics persistence (owned by another team; sizing in gap #12), plus
   the non-technical controls.

### Not covered by any of this

The §6 gaps that no scanner will flag — audit log retention/forwarding, etcd
backups, image signing policy — plus the non-technical controls (SSP, access
reviews, IR plan, training), which are usually the larger share of an
authorization package.
