# Playbook: hardening an OpenShift cluster for NIST 800-171, HIPAA and FIPS

*Written from the jetty engagement (2026-10-02 → 2026-10-08) to be reused on
larger clusters. jetty is the worked example; this document is the method.*

Status: **draft, in progress.** Sections marked *(pending)* will be filled as
the remaining jetty work (TLS profile, metrics persistence, etcd restore
rehearsal, audit forwarding, IdP) produces its lessons.

How this relates to the other documents:

| Document | Role |
|---|---|
| **PLAYBOOK.md** (this) | The method: order, procedures, cautions, scaling. Cluster-agnostic where possible. |
| [README.md](README.md) | jetty's current state, for a reader with five minutes. |
| [PLAN.md](PLAN.md) | jetty's record: what was done, when, with what result. |
| [STANDARDS.md](STANDARDS.md) | Framework mapping, FIPS position, scope, HIPAA results. |
| [FEASIBILITY.md](FEASIBILITY.md) | GPU × compliance interaction; the GPU-dangerous checks. |
| [NFS-TLS.md](NFS-TLS.md) | Storage encryption in transit, end to end. |

---

## 1. Principles

These matter more than any single procedure. Every one of them was learned by
a mistake that this engagement either made or nearly made.

1. **Measure, then change.** Every allow rule, allowlist entry and exception
   on jetty came from a measurement of the live cluster (observed flows, live
   sockets, running images, scheduled pods), not from documentation or
   expectation. Where we guessed, we were wrong at least once (see §5).
2. **Design → approve → apply, one change at a time.** Write the change and
   its verification and rollback *before* touching the cluster. Apply in
   ascending order of risk. Verify after each step, not at the end.
3. **Prove with a fresh operation, not with object state.** A policy existing,
   a rollout completing or a CR reporting `Ready` proves nothing about
   behaviour. Proof is: a pod restarted under the new rule and did its job; an
   uncached image pulled; a PVC provisioned and written; a packet capture
   showed no plaintext.
4. **Build the verification harness before remediating.** `tests/verify.sh`
   existed before the first 377-MachineConfig rollout, so "did the GPUs
   survive?" was a command, not an investigation. Save a baseline; compare to
   it after every change; re-save only once a new number is understood.
5. **`oc diff` before every `oc apply`.** Manifests drift from live. On jetty
   a stale manifest would have silently moved compliance evidence back onto
   unencrypted storage.
6. **Set evidence volumes to `Retain` before anything can delete their
   claims.** Operators delete PVCs as a side effect of renames and
   migrations (§5).
7. **A scanner's silence is not a pass.** Check that the tool actually looked:
   that the scan ran, that the image was scanned, that the check evaluates
   what you think it does.
8. **Record wrong predictions and failed attempts.** They are the most useful
   content for the next cluster. PLAN.md keeps them in line with the
   successes.
9. **Public-repo hygiene from day one.** No credentials, no kubeconfigs (`.gitignore` them), internal addresses as ranges or placeholders.
   Hostnames are fine.

---

## 2. Order of operations

The order is the main thing to copy. Each phase lists why it sits where it
does, how to verify it, how to roll it back, and what it cost on jetty.

### Phase 0 — Before or at install

| Item | Why now |
|---|---|
| **FIPS mode at install time** | Cannot be turned on afterwards. On Assisted Installer clusters it appears as `99-*-fips` MachineConfigs, not in install-config, so cite node-level evidence (`fips=1` on the kernel cmdline, `/proc/sys/crypto/fips_enabled`, crypto policy `FIPS`). |
| **Working persistent storage** | Compliance Operator raw results, ACS Central DB and etcd backups all need it. jetty lost most of day one to an untrunked storage VLAN (STORAGE-ISSUE.md). Test with a real database on the real StorageClass (`manifests/canary-postgres-on-nfs.yaml`), not just a mount. |
| **Encrypted storage transport** | If storage is NFS, decide on NFS-over-TLS *before* data lands; `mountOptions` is immutable, so retrofitting means copying every volume (NFS-TLS.md). |
| **Scope decision** | Whole cluster vs split. The control plane, etcd, audit and IdP are shared, so they are always in scope; FIPS is cluster-wide. Splitting needs separate MachineConfigPools at minimum and separate clusters for real isolation (STANDARDS.md §4). |
| **Identity provider** | Needed for AC-2/IA-2 and for turning Warn-mode admission policies into Deny. Not done on jetty — blocked on others. Do it early elsewhere. |
| **Destination for logs and alerts** | Audit forwarding and ACS notifiers both need one. It was the longest-blocked item on jetty because nobody owned the decision. Ask on day one. |

### Phase 1 — Install the tools

1. Compliance Operator, with a `ScanSetting` whose `rawResultStorage` is on
   encrypted storage and whose PVs are `Retain`. Raw ARF results are the
   audit evidence.
2. RHACS (Central + SecuredCluster). Pin Central's DBs to encrypted storage
   from the start (§5, "ACS operator").
3. Bind the profiles: `ocp4-cis`, `ocp4-moderate`, `rhcos4-moderate` (800-171
   maps to 800-53 Moderate; neither tool ships an 800-171 profile). HIPAA is
   ACS's `HIPAA_164` standard.

**Verify:** scans `DONE`, ARF files present on the PVC (T-03, T-04); every ACS
component `HEALTHY` (T-05).

### Phase 2 — Baseline and harness

1. Run the scans, archive results, record fail counts
   (`tests/baseline-fail-counts.txt`).
2. Run ACS `HIPAA_164` **explicitly** — ACS does not run compliance scans on
   its own. On jetty it had never run until day 6.
3. Write the verification harness for the things you care about that scanners
   do not check (GPU modalities, storage encryption, backups, registry
   allowlist coverage). Read-only by default; mutating tests behind a separate
   script.

### Phase 3 — Platform remediations (`remediate.sh stage1`)

etcd encryption (`aesgcm`), audit profile `WriteRequestBodies`, OAuth token
inactivity and max age. No node reboots; rolls the API servers.

- jetty: ~22 min, nothing degraded.
- **Then immediately measure audit volume.** `WriteRequestBodies` cut jetty's
  on-node audit retention to 94 minutes. Downgrade the noisiest *platform*
  namespaces to `Default` with `apiserver.spec.audit.customRules`
  (`manifests/09-*`); rank by bytes, not event count. jetty: −73%, retention
  1.6 h → 5.8 h. This buys margin only — on-host logs never satisfy AU-9.

### Phase 4 — Node hardening (`remediate.sh stage2`)

Several hundred MachineConfigs (377 on jetty).

- **Pause the MachineConfigPools, apply all, unpause** → one rolling reboot per
  pool instead of hundreds.
- **It is iterative.** Some remediations carry
  `has-unmet-dependencies` and only become applicable after a rescan sees
  their prerequisite. Rescan and run again until nothing is outstanding
  (two rounds on jetty).
- **Some remediations must land together.** Enabling `usbguard` without the
  HID/hub allow rule can lock out baremetal console keyboards.
  `lib/select-remediations.py` enforces "partner already applied or in the
  same batch"; `tests/test-remediation-ordering.sh` tests it.
- Check what the hardening disables before tenants find out: `usb-storage`,
  `sctp`, `cramfs`, `udf`, `bluetooth` and others are gone, so VM USB
  passthrough breaks.

jetty: ~2 h per round on 5 nodes. One node went Degraded mid-run and
recovered on its own (normal MCO drain retry). Node failures 377 → 4.

### Phase 5 — Storage encryption in transit

See NFS-TLS.md for the full procedure. Points to copy:

- The handshake daemon (`tlshd`) runs on **every node that can mount
  storage**, including masters (§5).
- The array certificate needs an **IP SAN** if mounted by IP.
- Prove with a packet capture containing a canary string, not by the mount
  succeeding.
- Make the encrypted class the **default** StorageClass, then migrate existing
  volumes (copy with `tar`, assert on file count).
- Add a guard test (T-13: no cleartext NFS mounts on any node).

### Phase 6 — Manual, workload-dangerous checks

On a GPU cluster these are the ones that break things; FEASIBILITY.md §3 has
the analysis. In order:

1. **SCC capability exceptions** via `TailoredProfile`, naming each SCC
   exactly. Record the exception honestly in the SSP (`allowedCapabilities:
   ['*']` is every capability). Binding a TailoredProfile **renames the
   scans**, which garbage-collects old remediation objects and **deletes old
   result PVCs** (§5).
2. **Registry allowlist** (`image.config` `allowedRegistries`). Inventory from
   *everything* that can pull: running pods, CronJobs, scaled-to-zero
   workloads, CSV `relatedImages`, ImageStreams, BuildConfigs. On 4.22 this is
   a CRI-O reload, not a reboot. The same change satisfies
   `reject-unsigned-images-by-default`.
3. **Signature verification** (`ClusterImagePolicy`). Test with a real
   uncached pull through CRI-O before trusting it (§5, NVIDIA).

### Phase 7 — NetworkPolicies, ingress then egress

1. **Derive allows from evidence**: ACS network graph over a window that
   includes disruptive events (upgrades, GPU modality switches), live sockets
   from `/proc/net/tcp` where the graph is ambiguous, Services,
   ServiceMonitors, webhooks, and which Prometheus actually scrapes each
   namespace.
2. **Ingress first.** Kubelet probes are admitted by OVN-Kubernetes without an
   allow rule — proven on jetty, not assumed.
3. **Egress second.** API server is **TCP 6443 with no `to`** (OVN evaluates
   egress after Service DNAT); DNS is 53 anywhere plus 5353 to
   `openshift-dns`. Copy `manifests/18-*`.
4. Apply one namespace at a time, least critical first, and prove each with a
   restarted pod doing its real job.
5. Internet egress stays only where unavoidable (ACS feeds, registry scans).
   NetworkPolicy cannot match hostnames; an `EgressFirewall` with `dnsName`
   rules can narrow it later.
6. **hostNetwork pods are outside NetworkPolicy entirely.** Document them;
   there is no fix short of not running them.

Rollback per namespace: `oc delete networkpolicy --all -n <ns>` (or the
specific documents).

### Phase 8 — Backups (CP-9)

- etcd: nightly CronJob running the operator's `cluster-backup.sh` on a
  master, copied to an encrypted PVC (`manifests/15-*`). The built-in
  automated backup API needs `TechPreviewNoUpgrade`, which is irreversible.
- **A backup contains the etcd encryption key**, so it can decrypt its own
  Secrets. Protect it as Secret-grade and say so.
- Verify integrity independently of the job (checksums, `etcdutl snapshot
  status` on the stored copy) and add a freshness test (T-14, < 26 h).
- Restore: *(pending — rehearsal planned)*.
- Off-array copy: still needed; backups on the same array survive losing
  masters, not the array.

### Phase 9 — HIPAA in ACS

1. Confirm **every registry in use has an image integration**. jetty's NVIDIA
   images were never scanned for six days because `nvcr.io` had none, and ACS
   showed them as clean.
2. Run `HIPAA_164`; split findings into ours vs platform (`openshift-*` is
   most of the raw count and is Red Hat's to own).
3. Attach a **notifier** to policies once a destination exists.
4. Treat "fixable CVEs" as a standing condition (§4).

### Phase 10 — Upgrades are compliance events

Run each z-stream like this, which is also the evidence for the patch-cadence
control:

1. Pre-flight: all ClusterOperators healthy, MCPs updated, `verify.sh` green.
2. Take an ad-hoc etcd backup (`etcd-backup-preupgrade` pattern).
3. `oc adm upgrade --to=<version>`; monitor; expect one reboot per node.
4. Post: FIPS still on every node, workloads (GPUs) back, `verify.sh` matches
   the pre-upgrade run, **rescan** and compare fail counts, re-run
   `HIPAA_164`.
5. Re-check FIPS module versions against CMVP certificates (versions change
   with RHCOS).

jetty: 4.22.14 → 4.22.16 in 1 h 23 min, compliance MachineConfigs carried
through, identical results before and after.

### Phase 11 — Remaining controls *(pending)*

TLS security profile, metrics persistence, audit forwarding, identity
provider and kubeadmin removal. To be written as jetty does them. The one
ordering rule already known: **an IdP must be working and tested before
kubeadmin is removed**, or the cluster is locked out.

---

## 3. Cautions

Grouped by subsystem. Each one cost time on jetty or would have caused an
outage.

### Compliance Operator

- **Rescan polling:** wait for a new `endTimestamp` later than the trigger,
  not for phase `DONE` — the old scan is already `DONE`.
- **TailoredProfiles rename scans.** Old `ComplianceRemediation` objects are
  garbage-collected (settings stay applied — they have no finalizers) and old
  result PVCs are deleted. Set PVs to `Retain` first.
- **Some checks need specific names.** The AC-8 banner check passes only if
  the ConsoleNotification is named `classification-banner`; any other name
  shows the banner and still fails.
- **Some checks pass on any object.** `configure-network-policies-namespaces`
  passes on any NetworkPolicy, real or not. A pass is not a review.
- **The NetworkPolicy check exempts platform namespaces; ACS does not.** The
  two tools will disagree; neither is wrong.

### Operators and OLM

- **OLM reverts `oc rollout restart` on CSV-owned deployments.** Delete the
  pods instead.
- **Operators revert scale-downs.** Scale the operator's own controller to 0
  first (ACS), then work, then restore.
- **ACS operator and PVCs:** to adopt an existing PVC set `claimName` only
  (no `size`/`storageClassName`); renaming the DB claim orphans its backup
  PVC; Helm-reconciled PVCs need Helm ownership labels and annotations.
  NFS-TLS.md has the exact errors.

### Networking

- **Egress to the API server is port 6443**, not 443 (post-DNAT matching).
- **hostNetwork pods ignore NetworkPolicy.**
- **A dropped connection shows as `SYN_SENT`** in `/proc/net/tcp`. If there
  is no `SYN_SENT`, the policy is not the cause — look elsewhere.
- Minimal images have no `curl`, `ss` or `netstat`; decode `/proc/net/tcp`.

### Images and signatures

- **NVIDIA signs only the multi-arch index**; CRI-O verifies the platform
  manifest, so a signature policy for `nvcr.io` refuses signed images.
  `cosign verify` passes, which is why it looks like it should work.
- **A registry without an ACS integration is never scanned**, and its images
  look clean.
- **Go pseudo-versions cause false positives.** `v0.0.0-<date>-<commit>`
  means "built from an untagged commit"; it sorts below every real release,
  so version-range matching flags long-fixed CVEs (CVE-2025-23266 in
  mig-parted on jetty, from a 2026 commit). Compare the commit date to the
  fix date, then record an exception with the reasoning.
- **"Fixable" never reaches zero** (§4).

### Storage

- A storage daemon scoped to "where pods currently run" broke the first time
  a pod ran elsewhere. Scope to where pods *can* run.
- `cp -a` fails on FlashBlade mount roots (`.snapshot`, `utime`); use `tar`,
  check counts.
- GnuTLS needs an IP SAN for an IP-addressed peer; `Certificate owner
  unexpected` means the chain was fine and only the name failed.

### ACS Central

- On jetty, Central's image API (scans and integration changes) hung for
  ~20 minutes while reads worked. No network cause; a Central pod restart
  fixed it immediately. **If the image API hangs, restart Central first.**
- After restarting Central, check that its definitions download completed;
  a truncated one (`unexpected EOF`) preceded the hang.

### Process

- **Predictions fail.** "A z-stream will clear the CVE control" and "NVIDIA
  images are clean" were both wrong on jetty. Measure the outcome.
- **Billable resources.** GPU-claiming tests cost money on MOC; keep them
  behind explicit flags.
- **Node selection in tests.** A test that cordons or drains must check what
  it will evict (ACS Central lived on a GPU node).
- **Shell traps:** quote anything with `[` or `?` under zsh (glob); avoid
  relying on word-splitting in zsh; URL-encode ACS query parameters.

---

## 4. Standing conditions, not tasks

Some controls are never "done":

| Control | Why it never reaches zero | What satisfies it |
|---|---|---|
| HIPAA 306(e), 308(a)(6)(ii) — fixable CVEs | ACS calls a CVE fixable if *any* newer component version exists upstream. Each vendor release refills the count. | A written patch cadence, evidence of following it (each upgrade's before/after runs), optionally an ACS policy on images *we* build. |
| FIPS module validation | CMVP certificates name module versions, which change with RHCOS. | Re-check per upgrade. |
| Scan freshness | Results describe the cluster at scan time. | Nightly scans + T-03 freshness test. |
| Backup freshness | — | T-14 freshness test, periodic restore test. |

---

## 5. Scaling beyond jetty

jetty is 3 masters + 2 GPU workers. What changes on a larger cluster:

| Area | jetty | Larger cluster |
|---|---|---|
| Node hardening rollout | ~2 h per round, one node at a time | Raise `maxUnavailable` per pool deliberately; budget for PodDisruptionBudgets; schedule maintenance windows per pool. |
| Scope | Whole cluster | Separate MachineConfigPools for in-scope vs general workers become meaningful; the control plane stays in scope regardless. Unhardened tenants belong on another cluster. |
| Audit volume | 24.7 GB/day after tuning | Scales with API traffic, mostly operators. Tune `customRules` early; size the forwarding destination from measured bytes. |
| NetworkPolicies | 7 namespaces, hand-derived | Template per tenant (default-deny + API/DNS + same-namespace) and derive the exceptions from ACS's graph per namespace; consider `AdminNetworkPolicy` for cluster-wide baselines. |
| Registry allowlist | 8 registries | Inventory programmatically; mirror to a controlled registry so the allowlist stays short. |
| GPU modality | Per-node label, delegated RBAC + admission policy | Same pattern; per-node turnaround measured at 68–247 s, no reboot. |
| Evidence | PVCs on one array | Off-cluster, off-array evidence and backup copies. |
| Verification | `verify.sh`, run by hand | Scheduled, with results shipped to the same destination as audit logs. |

*(more pending: TLS profile impact on clients; monitoring storage sizing)*

---

## 6. What no tool covers

Policies, the System Security Plan, access reviews, incident response,
training, risk analysis, BAAs and physical safeguards are usually the larger
share of an authorization package. Nothing in this playbook produces them.
What it does produce is the technical evidence they cite: scan results,
`verify.sh` runs, the manifests, and the record in PLAN.md.

---

## Appendix A — jetty timings

| Operation | Time | Disruption |
|---|---|---|
| Stage 1 platform remediations | ~22 min | API server roll, no reboots |
| Stage 2 node hardening, per round | ~2 h | One rolling reboot, 5 nodes |
| Registry allowlist | minutes | CRI-O reload, no reboot |
| ACS DB migration to encrypted storage | ~40 min | Central offline |
| Node reboot → TLS mounts usable | +6 s after node Ready | none extra |
| GPU container → VM passthrough | 68–73 s | none (no reboot) |
| GPU VM passthrough → container | 208–247 s | none (no reboot) |
| z-stream upgrade 4.22.14 → 4.22.16 | 1 h 23 min | One reboot per node |
| etcd backup | 24 s | none |
| ACS `HIPAA_164` run | 6 s | none |
