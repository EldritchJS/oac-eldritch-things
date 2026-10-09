# Playbook: hardening an OpenShift cluster for NIST 800-171, HIPAA and FIPS

*Written from the jetty engagement (2026-10-02 → 2026-10-09) to be reused on
larger clusters. jetty is the worked example; this document is the method.*

Status: **draft, reviewed 2026-10-09.** Phase 14 is *pending*: audit
forwarding, the identity provider and metrics persistence were blocked on
other people on jetty, and will be written up when they happen.

Where jetty ended (2026-10-09): `ocp4-moderate` 25 → 8, `ocp4-cis` 10 → 3,
node scans 377 → 0 failures; every remaining failure is blocked on another
team or is a documented gap. Both GPU modalities intact throughout.

How this relates to the other documents:

| Document | Role |
|---|---|
| **PLAYBOOK.md** (this) | The method: order, procedures, cautions, scaling. Cluster-agnostic where possible. |
| [README.md](README.md) | jetty's current state, for a reader with five minutes. |
| [PLAN.md](PLAN.md) | jetty's record: what was done, when, with what result. |
| [STANDARDS.md](STANDARDS.md) | Framework mapping, FIPS position, scope, HIPAA results. |
| [FEASIBILITY.md](FEASIBILITY.md) | GPU × compliance interaction; the GPU-dangerous checks. |
| [NFS-TLS.md](NFS-TLS.md) | Storage encryption in transit, end to end. |
| [PATCHING.md](PATCHING.md) | Patch cadence: draft SSP text, current state, ACS policy proposal. |
| [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md) | Exception register for privileged workloads and wildcard-RBAC operators. |

---

## 1. Principles

These matter more than any single procedure. Every one of them was learned by
a mistake that this engagement either made or nearly made.

1. **Measure, then change.** Every allow rule, allowlist entry and exception
   on jetty came from a measurement of the live cluster (observed flows, live
   sockets, running images, scheduled pods), not from documentation or
   expectation. Where we guessed, we were wrong at least once (see §3).
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
   migrations (§3).
7. **Scanners are wrong in both directions.** Silence is not a pass: check
   that the scan ran and the image was actually scanned (jetty's NVIDIA images
   showed clean for six days because nothing scanned them). And a FAIL is not
   proof: one high-severity check read the wrong ConfigMap, and a Critical CVE
   was a Go pseudo-version mis-sorted. Read what each check evaluates.
8. **Record wrong predictions and failed attempts.** They are the most useful
   content for the next cluster. PLAN.md keeps them in line with the
   successes.
9. **Public-repo hygiene from day one.** No credentials, no kubeconfigs
   (`.gitignore` them), internal addresses as ranges or placeholders.
   Hostnames are fine.
10. **Prefer changes that do not reboot.** Many controls that look like node
    changes are not: the registry allowlist is a CRI-O reload, and a
    `nodeDisruptionPolicy` turns a one-file MachineConfig into a service
    restart. Check `machineconfiguration/cluster` before assuming a reboot.

---

## Checklist

One line per phase; the detail is in §2. "Done when" is the evidence, not
the action.

| Phase | Done when | jetty |
|---|---|---|
| 0 Decisions before install | FIPS on at install; storage proven with a real DB; scope, IdP and log/alert destination have owners | IdP and destination were not owned → longest-blocked items |
| 1 Tools | Scans `DONE`, ARF on Retain PVs, ACS all `HEALTHY` | ✓ |
| 2 Baseline + harness | Fail counts recorded; `verify.sh` green; HIPAA_164 run once | ✓ |
| 3 Platform remediation | Rescan shows the 6 rules PASS; audit volume measured and tuned | ✓ 22 min, no reboot |
| 4 Node hardening | Node failures only the manual rules; GPUs re-verified | ✓ 377 → 4, two rounds |
| 5 Storage encryption | Packet capture shows no plaintext; no cleartext mounts on any node | ✓ 18/18 PVCs |
| 6 Workload-dangerous checks | Each applied singly with an uncached pull / GPU check after | ✓ (signature policy reverted) |
| 7 NetworkPolicies | Each namespace proven by a restarted pod doing its job, incl. builds/jobs | ✓ (builds missed, fixed later) |
| 8 Backups | Freshness test; restore rehearsed; off-array copy | ✓ except off-array |
| 9 HIPAA in ACS | Every registry scanned; findings split ours/platform; notifier | ✓ except notifier |
| 10 Upgrades | Before/after `verify.sh` identical; rescans; pinned digests refreshed | ✓ 4.22.14 → .16 |
| 11 TLS posture | Handshake probes on every endpoint (T-15) | ✓ no change needed |
| 12 File integrity | Canary detected, alert fired, per-node re-init clean | ✓ (no receiver) |
| 13 Triage | Every remaining failure is fixed, an exception with rationale, or blocked with an owner | ✓ moderate 13 → 8 |
| 14 Identity, logging, metrics | — | pending |

---

## 2. Order of operations

The order is the main thing to copy. Each phase lists why it sits where it
does, how to verify it, how to roll it back, and what it cost on jetty.

### Phase 0 — Before or at install

| Item | Why now |
|---|---|
| **FIPS validation status** | Know before you promise "FIPS validated": for the RHEL minor your OpenShift version maps to, which modules have Active 140-3 certificates? On OpenShift 4.22 / RHEL 9.8 only the OpenSSL provider does — not the kernel crypto API or GnuTLS, which carry NFS-over-TLS, IPsec and kTLS. If a requirement demands validated modules for a specific data path, pick the platform version and design around what is certified. |
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
   from the start (§3, "Operators and OLM").
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
recovered on its own (normal MCO drain retry). Node failures 377 → 4; the
registry allowlist (Phase 6) took it to 2 and `sshd AllowUsers` (Phase 13)
to 0.

### Phase 5 — Storage encryption in transit

See NFS-TLS.md for the full procedure. Points to copy:

- The handshake daemon (`tlshd`) runs on **every node that can mount
  storage**, including masters (§3, "Storage").
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
   result PVCs** (§3, "Compliance Operator").
2. **Registry allowlist** (`image.config` `allowedRegistries`). Inventory from
   *everything* that can pull: running pods, CronJobs, scaled-to-zero
   workloads, CSV `relatedImages`, ImageStreams, BuildConfigs. On 4.22 this is
   a CRI-O reload, not a reboot. The same change satisfies
   `reject-unsigned-images-by-default`.
3. **Signature verification** (`ClusterImagePolicy`). Test with a real
   uncached pull through CRI-O before trusting it (§3, "Images and
   signatures").

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
   restarted pod doing its real job. Include the workloads that are *not*
   running at the time — builds, Jobs, CronJobs. jetty's egress policy
   silently broke in-cluster image builds two days later.
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
- **Rehearse the restore without touching the control plane**
  (`tests/etcd-restore-rehearsal.sh`): in a throwaway pod, `etcdutl snapshot
  restore` the newest backup, start a real etcd on it (localhost only, in a
  namespace with default-deny egress and ingress), compare key counts by
  resource type with live etcd, and confirm every Secret/ConfigMap is
  encrypted with a key the backup's own encryption-config holds. jetty: 167
  MB snapshot, restore 2 s, serving at 3 s, ~55 s end to end. Explain every
  difference from live (on jetty each one traced to a known change since
  the backup) rather than accepting "close enough".
- The **full recovery procedure** (`cluster-restore.sh`, static pods
  stopped, members re-added) takes the API down. Rehearse it on a
  disposable cluster of the same version; record the RTO.
- Off-array copy: still needed; backups on the same array survive losing
  masters, not the array.

### Phase 9 — HIPAA in ACS

1. Confirm **every registry in use has an image integration**. jetty's NVIDIA
   images were never scanned for six days because `nvcr.io` had none, and ACS
   showed them as clean.
2. Run `HIPAA_164`; split findings into ours vs platform (`openshift-*` is
   most of the raw count and is Red Hat's to own).
3. Attach a **notifier** to policies once a destination exists.
4. Treat "fixable CVEs" as a standing condition (§4). Scope an alerting
   policy to the images *you build* — the cluster-wide default is mostly
   vendor images you cannot rebuild (187 violations, 164 platform). Keep it
   as code (`SecurityPolicy` CR, synced by ACS's config-controller).
5. Record scanner false positives as ACS vulnerability exceptions with the
   reasoning (not by deleting findings). ACS lets one account request and
   approve; separation of duties needs real user accounts.

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
   with RHCOS); T-02 WARNs until the record is re-reviewed (§4).
6. **Refresh every image pinned by digest to the release payload** (on
   jetty: the etcd-backup job's `cli` image, from `oc adm release info
   --image-for=cli`). The old image keeps working, which is why this is easy
   to miss; jetty missed it and T-14 now checks.

jetty: 4.22.14 → 4.22.16 in 1 h 23 min, compliance MachineConfigs carried
through, identical results before and after.

### Phase 11 — TLS posture: measure before changing the profile

Hardening guides say "pin `Modern` or a `Custom` TLS profile". Measure first:

1. Check the compliance results (`oc get compliancecheckresult | grep -iE
   'tls|cipher'`). On jetty all 31 already passed on the default profile.
2. Probe the real endpoints by handshake (`lib/tls-probe.py`, `verify.sh`
   T-15): API server, ingress, OAuth, every kubelet. Treat only a
   server-sent TLS alert as "refused"; a probe that could not be made is not
   a pass. Negative-test the probe against a deliberately weak server.
3. On a FIPS cluster the default Intermediate profile is already narrowed:
   jetty offers only TLS 1.3 and TLS 1.2 ECDHE+AES-GCM; ChaCha20 and CBC,
   which Intermediate lists, are refused. That meets NIST SP 800-52r2.
4. `Modern` (TLS 1.3 only) then buys only "no TLS 1.2", at the cost of a
   kubelet rolling reboot and the risk of breaking TLS 1.2-only clients you
   cannot enumerate; the 4.22 docs also contradict themselves on ingress
   support. Adopt it when a requirement names TLS 1.3, after inventorying
   clients — not by default.

### Phase 12 — File integrity monitoring (SI-7)

1. Install the File Integrity Operator; create **one FileIntegrity for all
   nodes** — its default nodeSelector is workers only, and masters hold
   etcd, the API server and the audit logs. Tolerate the master taint.
2. Start from the operator's default AIDE config (`/boot`, `/root`, `/usr`,
   `/etc`; `/var` and platform-rewritten `/etc` paths excluded). Before
   tailoring, inventory what your add-ons write to the host: on jetty the
   GPU toolkit writes a CRI-O drop-in under `/etc/crio`. Keep such files
   watched — runtime config is what an attacker would change — and
   re-initialise the node after an intended change instead.
3. Prove it with a canary file in `/etc` on one node: the node must report
   exactly that file, the alert must fire, and a per-node re-init
   (`file-integrity.openshift.io/re-init=<node>`) must clear it. jetty:
   baselines 1–2 min per node, detection within one scan interval (15 min)
   plus the alert delay.
   MachineConfig rollouts need no manual step: the operator re-initialised
   every node by itself after an MCO update (observed on jetty).
4. The compliance check for notification passes when the alert rule
   exists. Wire an Alertmanager receiver, or the alert reaches nobody.

### Phase 13 — Triage what the scanners still report

After the remediation stages, read every remaining failure's instructions
and sort it into fixable, exception, or blocked. On jetty this took
moderate 13 → 8 and the node scans to 0 in an afternoon:

- **Suspect the scanner too.** A high-severity failure with a correctly set
  value was a content bug (OCPBUGS-126610: wrong ConfigMap). Disable it in
  the TailoredProfile with the bug as rationale, and test the real value in
  your own harness so the control is still checked.
- **Avoid reboots with a nodeDisruptionPolicy.** A one-file MachineConfig
  (sshd `AllowUsers`) reboots every node by default; a policy that restarts
  just `sshd` made it a 3-minute, reboot-free rollout.
- **ResourceQuotas: counts and storage, not cpu/memory,** wherever vendor
  pods declare no requests — a cpu/memory quota rejects them on their next
  restart. Prove it by restarting one.
- **Operator-owned routes:** add annotations and force a reconcile to see if
  they stick, then read the router's `haproxy.config` to see them enforced.
- **Use the rules' own exemption variables** for vendor-managed workloads you
  cannot safely change, with a rationale and a revisit condition.
- **Do not tailor away real gaps** (no egress proxy): leave them failing and
  documented.
- **Write the privileged-workload register from a measurement**, not from
  the ACS alert list: enumerate privileged/host-namespace/hostPath pods with
  their admitting SCC, and every wildcard ClusterRoleBinding to a service
  account. On jetty this surfaced findings no alert names — an operator
  allowed to `use` any SCC, and pods admitted under another vendor's SCC.

### Phase 14 — Remaining controls *(pending)*

Metrics persistence (another team's decision on jetty), audit forwarding,
identity provider and kubeadmin removal, route IP allowlists (need the
users' source ranges), and an egress proxy if one is required. To be written
as jetty does them. The one ordering rule already known: **an IdP must be
working and tested before kubeadmin is removed**, or the cluster is locked
out. Sizing data for the audit and metrics destinations is in §5.

---

## 3. Cautions

Grouped by subsystem. Each one cost time on jetty or would have caused an
outage.

### Compliance Operator

- **Rescan polling:** wait for a new `endTimestamp` later than the trigger,
  not for phase `DONE` — the old scan is already `DONE`.
- **Rescan the `ComplianceScan`, not the `ComplianceSuite`.** The rescan
  annotation on a suite is accepted and silently ignored.
- **Content bugs exist.** `openshift-api-server-audit-log-path` reads the
  kube-apiserver ConfigMap (OCPBUGS-126610) and cannot pass. Disable such a
  rule in the TailoredProfile with the bug as rationale, test the real value
  yourself, and re-check after each Compliance Operator upgrade.
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
- **Operators installed for all namespaces copy their CSV into every
  namespace.** A wait loop on "any CSV Succeeded" in a new namespace
  returns at once on the copy. Select the CSV by name or display name.
- **Server-side dry run cannot validate objects in a namespace the same
  file creates** (and cannot validate a CR whose CRD the operator has not
  installed yet). Apply namespace → OperatorGroup/Subscription → wait for
  the CSV → custom resources.

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

### Patching our own images

- **A rebuild is not a patch.** Rebuilding on `ubi9:latest` reproduced the
  vulnerable openssl because the base lagged the RHEL repos. The build must
  run `dnf upgrade` (or pin a fixed base), and the new image must be
  scanned or inspected *before* rollout.
- **Default-deny egress breaks in-cluster builds** (and any Job or CronJob
  that wasn't running during validation). Validate egress policies against
  every kind of workload a namespace runs, not just what is running now.
- **Check how a manifest was applied before re-applying it.** A kustomize
  directory (`oc apply -k`) with a `configMapGenerator` produces hashed
  names; `oc apply -f` on one file from it silently re-points references.
  `oc diff` caught it.
- ACS raises "Exec into Pod" alerts for verification `oc exec`s — expected,
  and proof the runtime detection works; note them rather than silence them.

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
- It recurred the next day as a per-image stall: Central sat at "Getting
  metadata" for one new ghcr.io digest (established connection, no block)
  while other scans worked. Do not make a rollout depend on ACS alone;
  have an independent check (`rpm -q` in the pod, the build's package
  transaction).

### Process

- **Predictions fail.** "A z-stream will clear the CVE control" and "NVIDIA
  images are clean" were both wrong on jetty. Measure the outcome.
- **Billable resources.** GPU-claiming tests cost money on MOC; keep them
  behind explicit flags.
- **Node selection in tests.** A test that cordons or drains must check what
  it will evict (ACS Central lived on a GPU node).
- **Shell traps:** quote anything with `[` or `?` under zsh (glob); zsh does
  not word-split `$VAR`, so `for s in $S` iterates once over the whole string
  (a rescan "ran" against a scan that does not exist) — use bash for loops;
  macOS has no `timeout`; URL-encode ACS query parameters.
- **Harness scripts can pass by doing nothing.** `oc exec pod -- bash -s
  <<EOF` without `-i` runs an empty script and exits 0; `grep -q`/`grep -m1`
  under `pipefail` fail a pipeline that matched. Make each remote block print
  a sentinel and check for it, and sanity-check that results are non-empty.

---

## 4. Standing conditions, not tasks

Some controls are never "done":

| Control | Why it never reaches zero | What satisfies it |
|---|---|---|
| HIPAA 306(e), 308(a)(6)(ii) — fixable CVEs | ACS calls a CVE fixable if *any* newer component version exists upstream. Each vendor release refills the count. | A written patch cadence, evidence of following it (each upgrade's before/after runs), and an ACS policy scoped to images *we* build, since those are the only ones we can rebuild. Template: [PATCHING.md](PATCHING.md). Split the timelines by class (platform, operators, own images) — the remedies differ. |
| FIPS module validation | CMVP certificates name module versions, which change with RHCOS, and validation lags releases by a year or more. A security fix to a certified module yields an uncertified binary until revalidation. | Record per upgrade which modules are certified for the RHEL minor OpenShift maps to, compare the *running* module version (`openssl list -providers`), and state "validation in process" plainly in the SSP. jetty: [tests/fips-cmvp-certificates.md](tests/fips-cmvp-certificates.md), checked by T-02. |
| Scan freshness | Results describe the cluster at scan time. | Nightly scans + T-03 freshness test. |
| Backup freshness | — | T-14 freshness test, periodic restore test. |
| File integrity baseline | Every intended change to watched paths (e.g. a GPU modality switch touching `/etc/crio`) reports as a change. | Re-init the node after intended changes; investigate everything else. T-16. |
| Disabled / exempted rules | Content gets fixed; vendors start setting limits. | Re-check each tailoring's revisit condition after Compliance Operator and vendor operator upgrades. |

---

## 5. Scaling beyond jetty

jetty is 3 masters + 2 GPU workers. What changes on a larger cluster:

| Area | jetty | Larger cluster |
|---|---|---|
| Node hardening rollout | ~2 h per round, one node at a time | Raise `maxUnavailable` per pool deliberately; budget for PodDisruptionBudgets; schedule maintenance windows per pool. Add `nodeDisruptionPolicy` entries so later single-file changes restart a service instead of rebooting every node. |
| Quotas | 7 namespaces, counts + storage | Per-tenant quotas from a template; cpu/memory quotas only where every pod declares requests (enforce that with a LimitRange first). |
| File integrity | AIDE on 5 nodes, manual re-init | Script the per-node re-init into the procedures that intentionally change watched files (modality switches, manual fixes); alert routing is mandatory at scale. |
| Scope | Whole cluster | Separate MachineConfigPools for in-scope vs general workers become meaningful; the control plane stays in scope regardless. Unhardened tenants belong on another cluster. |
| Audit volume | 24.7 GB/day after tuning | Scales with API traffic, mostly operators. Tune `customRules` early; size the forwarding destination from measured bytes. |
| NetworkPolicies | 7 namespaces, hand-derived | Template per tenant (default-deny + API/DNS + same-namespace) and derive the exceptions from ACS's graph per namespace; consider `AdminNetworkPolicy` for cluster-wide baselines. |
| Registry allowlist | 8 registries | Inventory programmatically; mirror to a controlled registry so the allowlist stays short. |
| GPU modality | Per-node label, delegated RBAC + admission policy | Same pattern; per-node turnaround measured at 68–247 s, no reboot. |
| Evidence | PVCs on one array | Off-cluster, off-array evidence and backup copies. |
| Verification | `verify.sh`, run by hand | Scheduled, with results shipped to the same destination as audit logs. |

**Monitoring storage sizing.** Measure before choosing: per replica,
`rate(prometheus_tsdb_head_samples_appended_total[1h])` × retention seconds ×
on-disk bytes per sample (`prometheus_tsdb_storage_blocks_bytes` over the
samples those blocks cover). jetty: 22.5k samples/s, 2.32 B/sample → ~68 GB
per replica for 15 days, with the API server and kubelet producing two
thirds of the series. Series count scales with nodes and pods, so expect
this to grow roughly linearly. Prometheus needs block storage (NFS is not
supported upstream), and keeping monitoring off the array it monitors means
it still works when that array fails.

**TLS profile.** The probe-first method in Phase 11 scales unchanged; on a
large cluster the client inventory before `Modern` is the expensive part
(external integrations, appliances, older CLIs), and a kubelet profile
change is a full rolling reboot of every pool.

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
| etcd restore rehearsal (restore 2 s, serving 3 s) | ~55 s | one temporary pod |
| ACS `HIPAA_164` run | 6 s | none |
| One-file MachineConfig with `nodeDisruptionPolicy` (sshd) | ~3 min, both pools | sshd restart, no reboot |
| File Integrity Operator: install → first clean scan | ~1 min install, 1–2 min baselines, first scan at +15 min | none |
| FIM canary → alert firing | ~17.5 min (scan interval + alert delay) | none |
| Own-image rebuild (`tlshd`) → rollout to 5 nodes | ~8 min build, ~5.5 min rollout | storage handshakes briefly per node; live sessions unaffected |
