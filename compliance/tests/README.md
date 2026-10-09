# Verification suite

*Last updated 2026-10-07. Current result: 38 PASS / 0 FAIL / 3 WARN.*

A regression net for `jetty`, covering compliance posture, FIPS, RHACS, and
**both GPU modalities**.

## Why it exists

Hardening this cluster to the 800-171 baseline means applying ~377
MachineConfigs — a rolling reboot of every node, one at a time. The cluster
also serves GPUs in two different modes, on different nodes, with different
drivers. **Run this before and after hardening** so you can prove nothing
broke, rather than hoping.

## Usage

```sh
export KUBECONFIG=/path/to/kubeadmin-jetty    # see ../README.md § Prerequisites

./verify.sh                  # everything (read-only, ~2 min)
./verify.sh -t t06,t07       # just the GPU checks
./verify.sh -l               # list tests
./verify.sh --save-baseline  # re-record current FAIL counts
```

Exit code is `0` if nothing FAILed. `WARN` and `SKIP` do not fail the run —
they flag things needing a human, not broken things.

## What each test asserts

| ID | Test | Catches |
|---|---|---|
| T-01 | FIPS mode on every node | `fips=1`, `fips_enabled=1`, crypto policy `FIPS`. FIPS cannot be enabled post-install, so a failure means drift or a rebuilt node. |
| T-02 | FIPS *validation* | Reads `fips-cmvp-certificates.md`: WARNs if the running RHCOS differs from the one the record was reviewed against (re-review every upgrade), and compares each node's running OpenSSL FIPS provider version (read via the machine-config-daemon pods) with the certified one. Currently WARNs: the nodes run a post-certification security build. |
| T-03 | Scan freshness + regression | Suites `DONE`, results < 48h, FAIL counts not above `baseline-fail-counts.txt`. **This is the main hardening regression check.** Also checks directly any control whose scanner rule is disabled as a false positive (today: openshift-apiserver `audit-log-path`, OCPBUGS-126610). |
| T-04 | Raw ARF archived | `rawResultStorage.enabled` and bound PVCs — i.e. durable audit evidence actually exists. |
| T-05 | RHACS healthy | Central + SecuredCluster Available, all pods ready, collector on every node. |
| T-06 | GPU container modality | Node advertises `nvidia.com/gpu`, host driver Running. |
| T-07 | GPU passthrough modality | Node advertises the device resource, `vfio-manager` Running, **host driver absent**, and `permittedHostDevices` present on **both** HCO and the KubeVirt CR. |
| T-10 | Registry allowlist | Compares registries in use against `allowedRegistries`. Prevents the `ocp-allowed-registries` foot-gun. |
| T-11 | SCC exceptions known | The 10 privileged SCCs are the expected NVIDIA/KubeVirt set — a *new* one fails the test. |
| T-13 | Storage traffic encrypted | `tlshd` Ready on every eligible node, `nfs-over-tls` requests `xprtsec=tls`, and reports the TLS-vs-cleartext mount ratio. **The only check for this** — no scanner inspects CSI mount options. |
| T-14 | etcd backups running | CronJob present and not suspended, newest **successful** job ≤ `BACKUP_MAX_AGE_HOURS` (26) old, backup PV `Retain`. Reads job completion times, not `lastSuccessfulTime`, so manual runs count. No scanner checks for backups at all. |
| T-15 | Effective TLS | Handshakes against the API server, ingress, OAuth and every kubelet (`../lib/tls-probe.py`). PASS only if TLS 1.3 and TLS 1.2 ECDHE+AES-GCM are accepted and TLS 1.0/1.1, CBC, ChaCha20 and static-RSA are **refused by the server**. A probe that could not be made is a WARN, never a PASS. Config checks cannot see this; only a handshake shows what FIPS actually leaves on offer. |
| T-16 | File integrity monitoring | The `all-nodes` FileIntegrity is Active, every node's AIDE result is `Succeeded`, and the `file-integrity` alert rule exists. FAIL names the node; an intended change needs a per-node re-init (see `manifests/20-*`). Negative-tested with a canary file in `/etc` on a master. |
| T-17 | No GPU claimed (billing) | GPUs on MOC are billed while claimed. FAILs on any non-terminal pod requesting an `nvidia.com/*` resource (pending included), any Deployment/StatefulSet/DaemonSet/Job/CronJob template requesting one (a template at 0 replicas claims tomorrow), any VM/VMI with a GPU or host device, and any GPU node whose own allocation count is non-zero. `GPU_CLAIM_ALLOW_NS=<regex>` downgrades approved namespaces to WARN; the GPU operator's seconds-long CUDA validator is always a WARN. Logic in `../lib/gpu-claims.py`; negative-tested offline with synthetic objects (no real GPU claimed). |
| T-12 | GPU switch is delegated & constrained | `gpu-modality-switcher` can patch only the GPU nodes (verified by SubjectAccessReview), cannot touch masters or delete nodes, and the admission policy exists. WARNs while the policy is non-enforcing. |

### Unit test — no cluster needed

`./test-remediation-ordering.sh` exercises `lib/select-remediations.py`, the
stage 2 selector, against synthetic fixtures. It guards the invariant that
`service-usbguard-enabled` is never applied without
`usbguard-allow-hid-and-hub` in the same batch — enabling usbguard without the
HID/hub allow rule can block console keyboards on baremetal.

It exists because that path **cannot be exercised on the live cluster**: the
operator happened to mark the service rule dependency-blocked, so the
`BLOCKED` branch short-circuits before the ordering check runs. Untested
lockout protection is not protection.

### Not covered here

| What | Where | Why separate |
|---|---|---|
| GPU switch turnaround | `./gpu-switch-timing.sh` | **Mutating** — unloads/reloads the driver |
| etcd restore rehearsal | `./etcd-restore-rehearsal.sh` | Creates one temporary pod in `etcd-backup`; restores the newest backup into it, serves it, compares with live. Control plane untouched. |
| VM networking / storage / migration | `../vms/test-vm*.sh` | Creates VMs |
| GPU-to-VM end-to-end | `../vms/gpu/test-gpu-vm.sh` | Creates a GPU VM |

## Baseline

`baseline-fail-counts.txt` records expected compliance FAIL counts per scan.
T-03 fails if any scan regresses above it. **Re-save it after each remediation
stage**, once you have confirmed the new numbers are the ones you wanted:

```sh
./verify.sh -t t03 --save-baseline
```

Current baseline (2026-10-07, **after stage 2 round two**):

```
ocp4-cis                     8
ocp4-cis-node-master         0
ocp4-cis-node-worker         0
ocp4-moderate               21
ocp4-moderate-node-master    1
ocp4-moderate-node-worker    1
rhcos4-moderate-master       1
rhcos4-moderate-worker       1
```

Progression:

| Scan | initial | after stage 1 | after stage 2 | after round two |
|---|---|---|---|---|
| `ocp4-cis` | 10 | 8 | 8 | 8 |
| `ocp4-moderate` | 25 | 21 | 21 | 21 |
| `ocp4-moderate-node-master` | 4 | 4 | 1 | 1 |
| `rhcos4-moderate-master` | 191 | 191 | 4 | **1** |
| `rhcos4-moderate-worker` | 191 | 191 | 4 | **1** |

Stage 3 (2026-10-08) took platform to 5 / 18 and `ocp4-moderate-node-*` to
0 / 0; the AC-8 notice then took moderate to 16, and NetworkPolicies took
platform to 4 / 15. The platform scans are now named `jetty-ocp4-cis` and
`jetty-ocp4-moderate`, because they run TailoredProfiles. The baseline file
uses the new names.

**Node failures: 377 -> 10 -> 4 -> 2.** The two survivors are one rule on
both pools, `sshd-limit-user-access`, which offers no remediation.

Stage 1 was platform-only (6 rules, 2 CIS + 4 moderate). Stage 2 was node-only
(377 MachineConfigs): **377 node failures → 10**, platform untouched.

## GPU switch turnaround — measured

`./gpu-switch-timing.sh` flips a node between modalities and times how long
until the target mode is actually serviceable (resource advertised **and** the
right pods Ready **and**, for passthrough, the host driver gone).

Measured on `moc-r4pcc02u15`, 2026-10-02, idle cluster:

| Direction | Time |
|---|---|
| `container` → `vm-passthrough` | **73s** |
| `vm-passthrough` → `container` | **208s** |

Re-measured 2026-10-08, after hardening and with default-deny NetworkPolicies
in `nvidia-gpu-operator`: **68s** / **247s**. The return leg's extra time is
in the driver pod's kernel-module build and load, not the network — treat
~3.5–4 minutes as the realistic figure for that direction.

**No reboot in either direction.** The asymmetry is expected: going to
passthrough only unloads the driver and binds `vfio-pci`; coming back has to
load the driver and start the toolkit, device plugin, and validators.

Treat these as a floor. An idle node with images already pulled is the best
case; a node with GPU workloads to evict will be slower.

### Safety

The script refuses to run if any pod requests a GPU or any VMI is running, and
warns if the target node hosts RHACS Central. A label flip evicts nothing, so
it is safe alongside running non-GPU workloads — but **do not** use the
cordon/drain path in `../vms/gpu/test-gpu-switch.sh` on whichever worker is
currently hosting `central` and `central-db`.

> **Check, do not assume.** Those pods move. They were on `moc-r4pcc02u16`
> when this was first written and are on `moc-r4pcc02u15` as of 2026-10-07,
> having relocated during the stage 2 reboots. Run
> `oc get pods -n stackrox -o wide | grep central` before draining anything.

## Known WARNs (expected, not bugs)

Current state: **49 PASS, 0 FAIL, 2 WARN** (2026-10-08, after stage 3 and
etcd backups).

- **T-02** — no CMVP certificate record yet. Paperwork, not a cluster problem.

T-10 no longer warns: `allowedRegistries` is set (`manifests/14-*`), and T-10
now checks every in-use registry against it. Its blind spot is that it only
sees **running** containers — a registry used only by a CronJob, a
scaled-to-zero workload, an operator's `relatedImages` or an ImageStream will
not appear. Inventory those too before editing the allowlist (the manifest
header lists what was checked).
- **T-12** — the GPU-switch admission policy is in `Warn`+`Audit`, not `Deny`.
  Deliberate: enforcing a node admission policy before an identity provider
  exists risks locking yourself out. Switch to `Deny` once an IdP is in place.

## Gotchas baked into these scripts

Three traps cost real debugging time here. They are commented at the point of
use, and listed together so nobody reintroduces them:

1. **`set -o pipefail` + `grep -q`.** `grep -q` exits on the first match, the
   upstream command gets SIGPIPE (141), and pipefail reports the pipeline as
   failed *despite the match*. This produced a false "no driver daemonset
   Running" in T-06. Both scripts now capture output into a variable and match
   against that instead of piping.
2. **ERE backreferences are not portable.** `grep -E '([0-9]+)/\1'` works in
   BSD/GNU grep and fails in `ugrep`; a grep that errors returns empty, which
   can read as "nothing wrong". Pod readiness is checked with `awk`.
3. **`oc auth can-i --as/--as-group` lies** about impersonated group
   membership — it returned "no" for permissions a `SubjectAccessReview`
   confirmed as allowed. T-12 uses SubjectAccessReview, which is authoritative.
4. **Rescan: annotate the `ComplianceScan`, not the `ComplianceSuite`.**
   `oc annotate compliancesuite <name> compliance.openshift.io/rescan=` is
   accepted and then **silently ignored** — the annotation just sits there
   unconsumed, no scan pods are created, and the suite keeps its old `DONE`
   phase and old results. Annotate each `ComplianceScan` instead; the operator
   consumes (removes) the annotation and re-runs. Verify with:
   ```sh
   oc get compliancescan -n openshift-compliance \
     -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,END:.status.endTimestamp'
   ```
5. **"Fresh" is not the same as "newer than the change you are verifying."**
   T-03's age check passed at 12h (well inside 48h) immediately after stage 2 —
   but the newest scan was the 01:02Z nightly and the nodes had rebooted at
   12:58Z. It reported "matches baseline" for a cluster that no longer existed.
   T-03 now also compares the newest scan against the newest MachineConfig and
   WARNs loudly when the scan is older. **Always rescan after a remediation
   stage; never trust the nightly.**
6. **Scan freshness must come from `ComplianceScan .status.endTimestamp`.** A
   rescan *updates* existing `ComplianceCheckResult` objects rather than
   recreating them, so their `creationTimestamp` is frozen at whenever the rule
   first appeared. T-03 originally measured that and reported freshly-finished
   scans as "2h old"; left alone it drifts upward forever and eventually
   false-WARNs "scans may have stopped" on a healthy nightly schedule. Fixed.
7. **Never wait on `phase` alone after triggering a rescan.** A scan that has
   not started yet still reads `DONE` from the *previous* run, so a poll loop
   checking `phase == DONE` returns instantly and reports stale results as
   fresh. This produced a bogus "nothing changed" comparison after stage 1.
   Gate on `endTimestamp` being newer than the moment you triggered the rescan.
8. **`oc exec ... bash -s <<EOF` needs `-i`.** Without it `oc exec` sends no
   stdin, so `bash -s` runs an empty script and exits 0. The first restore
   rehearsal "completed" having done nothing; only the empty comparison
   afterwards gave it away. Every in-pod block in
   `etcd-restore-rehearsal.sh` now prints a sentinel that the caller checks.
9. **`grep -m1` is the same SIGPIPE trap as #1** (`tar tzf | grep -m1` →
   exit 141 under pipefail). Use a reader that consumes all input
   (`| tail -1`).
