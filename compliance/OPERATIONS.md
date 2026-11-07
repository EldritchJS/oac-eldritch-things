# Day to day: keeping a compliant cluster compliant

The build documents ([BUILD.md](BUILD.md),
[NEW-HUB-RUNBOOK.md](NEW-HUB-RUNBOOK.md)) end when a hub and its
workload clusters pass their first scans. This page is what has to keep
happening after that: what runs by itself, what a person has to do and
when, which of this repo's scripts are for it, and what is not in place
yet.

The detail is in the files each row links to. This page is the list that
brings them together.

**No cluster is under this today.** The compliant test hub,
`nist-dev-infra`, was retired on 2026-10-28. jetty was reinstalled the
same day with FIPS on but without its first install's hardening. This is
the plan for the replacement hub.

## 1. What runs by itself

| What | What it does | Who notices a failure today |
|---|---|---|
| Compliance Operator | Scans every node and the platform on a schedule. It only scans, and never applies a fix ([HUB-SPOKE.md](HUB-SPOKE.md) §5) | Nobody is alerted. A person has to look (§2) |
| ArgoCD self-heal | Puts back anything in a cluster that differs from git | Nobody needs to |
| HyperShift NodePools | Put node configuration on workload clusters back to what git says | Nobody needs to |
| Admission policies | The hub refuses a non-compliant hosted cluster (`compliant-hosted-clusters`) and a cleartext FlashBlade StorageClass (`flashblade-nfs-tls`) | The person whose change is refused. CI runs the same checks before merge (`scripts/check_hub_policy_compliance.py` in oac-apps) |
| File Integrity Operator (AIDE) | Reports changed files on the hub's nodes. It does not run on hosted workers (RFE-8168) | Nobody is alerted |
| etcd backup | A nightly backup of the hub's etcd (oac-apps #217, in review) | Nobody is alerted. `verify.sh` T-14 checks how old the newest backup is |
| ACS | Scans images, and runs runtime policies, inform-only | Nobody is alerted: no notifier |
| OLM | Updates operators within their channel (`Automatic`) | Nobody. An update can change scan results or flags (§3) |
| `AuditLogError` alert | Fires when a hosted cluster's API server cannot write its audit log | Nobody is alerted. It has no receiver |

The pattern in the last column is the main gap: until there is an alert
destination (BUILD.md P9), each "nobody" is a person checking by hand.

## 2. On a schedule

The cadences marked *[decide]* are drafts in [PATCHING.md](PATCHING.md)
§1, not agreed yet.

| When | What | How |
|---|---|---|
| Daily, until alerts exist | New scan failures, AIDE results, the backup ran, ACS violations in our own images | `oc get compliancecheckresult -n openshift-compliance -l compliance.openshift.io/check-status=FAIL`; `oc get fileintegritynodestatuses -A`; `verify.sh -t t03,t14,t16` on jetty-style clusters; the ACS policy for our images ([PATCHING.md](PATCHING.md) §4) |
| Weekly *[decide]* | Review fixable Important or Critical findings in images we build | ACS, our-images policy ([PATCHING.md](PATCHING.md) §4) |
| Monthly *[decide]* | Rebuild the images we build: `tlshd` (nfs-tls), and the Grafana image if #230 merges | [PATCHING.md](PATCHING.md) §3, [GRAFANA-FIPS-IMAGE.md](GRAFANA-FIPS-IMAGE.md) "Keeping it current" |
| Within 30 days *[decide]* of a z-stream reaching `stable` | Upgrade the platform | §3, "Platform upgrade" |
| Now and then (no cadence set) | Check that the newest etcd backup restores | `tests/etcd-restore-rehearsal.sh` |
| Yearly | Review the patch policy | [PATCHING.md](PATCHING.md) §1 |

## 3. When something happens

| Event | What to do | Detail |
|---|---|---|
| Any change to a cluster | Run the checks before and after; the results should match | `tests/cluster-acceptance.sh` on any cluster. `tests/verify.sh` was written for jetty and needs changes for a hub ([BUILD.md](BUILD.md) Part 1 §7) |
| A scan failure that self-heal does not fix | Fix it in git: add the remediation to node hardening, change chart values, or record an exception with a reason. One PR each | [BUILD.md](BUILD.md) Part 1 §6, [HUB-SPOKE.md](HUB-SPOKE.md) §5 |
| A node hardening change merges | Every NodePool on the hub rolls. Merge it at an agreed time, like a maintenance window. A usbguard rule must never go in before its HID allow rule | [BUILD.md](BUILD.md) Part 2 §5, `tests/test-remediation-ordering.sh` |
| Platform upgrade | Pre-upgrade backup; checks before and after; rescan and compare; rerun ACS `HIPAA_164`; refresh images pinned to the release payload; re-review the FIPS certificate record (T-02) and the privileged-workloads register. Write a dated record | [PLAYBOOK.md](PLAYBOOK.md) Phase 10, [tests/fips-cmvp-certificates.md](tests/fips-cmvp-certificates.md), [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md) |
| Rollout or upgrade on large control-plane nodes | Watch etcd's threads during it | `nist-dev-infra/watch-etcd-threads.sh`, [nist-dev-infra/MASTER-ROUND.md](nist-dev-infra/MASTER-ROUND.md) |
| Operator upgrade | Re-check each tailored or disabled rule's revisit condition. If `routes-rate-limit` fails again, rerun the rate-limit script. If its images changed, rescan them | [PLAYBOOK.md](PLAYBOOK.md) §4, `nist-dev-infra/route-rate-limits.sh`, `tests/fips-image-scan.sh` |
| A new operator | T-18 fails until it is flagged `fips-compliant` or has a recorded decision. Scan its images, add it to the inventory, and, if it is kept without the flag, to the accepted list with a POA&M item | [tests/operator-fips-inventory.md](tests/operator-fips-inventory.md), `tests/operator-fips-accepted.txt` |
| A new workload or namespace | Measure its egress, then give it guardrails (NetworkPolicies and quotas). If it is privileged, add it to the register. Accept its ACS alerts, do not silence them | `namespace-guardrails` chart, [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md) |
| An intended change to files AIDE watches (a GPU mode switch, for example) | Re-initialise that node's baseline, and investigate every other change | [PLAYBOOK.md](PLAYBOOK.md) Phase 12 |
| A fixable finding in an image we build | Rebuild it within the class (c) timeline | [PATCHING.md](PATCHING.md) §1, §3 |
| A finding that does not apply | Record an ACS exception with the reasoning. A deferral expires *[decide]* | [PATCHING.md](PATCHING.md) §1 |
| An incident that needs a fix by hand | Self-heal undoes a hand fix within minutes. Pause the app's sync first (`scripts/pause-app-sync.sh` in oac-apps), fix, commit, resume | [HUB-SPOKE.md](HUB-SPOKE.md) §5. A written procedure does not exist yet (§5) |
| Building a hub, or re-syncing `hub-portworx` | Check the hub's infrastructure first | `tests/hub-preflight.sh` |
| Changing the TLS profile | Measure what clients use before changing it | `lib/tls-probe.py`, [PLAYBOOK.md](PLAYBOOK.md) Phase 11 |
| GPU tests | Leave no GPU claimed: MOC bills claimed GPUs | `cluster-acceptance.sh` checks last; `vms/gpu/cleanup.sh` |
| Removing a cluster | Wipe its nodes before they are reused anywhere | [BUILD.md](BUILD.md) Part 2 §5 |

## 4. The scripts, and which still matter

| Script | For | Changes the cluster? | Status |
|---|---|---|---|
| `tests/cluster-acceptance.sh` | Is any cluster set up properly for containers, VMs and GPUs | Only with `--functional` or `--gpu` | Current, any cluster |
| `tests/verify.sh` | Regression checks for compliance, FIPS, ACS and GPUs | No | Written for jetty's first install, so most tests fail on today's jetty. Needs a hub version |
| `tests/fips-image-scan.sh` | Do an operator's images use FIPS-capable crypto | A throwaway project, deleted after | Current. Run it on a cluster, never on a laptop |
| `tests/operator-fips-accepted.txt` | The operators T-18 accepts without the flag, with reasons | - | Current |
| `tests/etcd-restore-rehearsal.sh` | Does the newest backup restore | One temporary pod | Current. Needs the etcd backup chart |
| `tests/hub-preflight.sh` | Is the hub's infrastructure in place (BUILD.md I2 to I7) | No | Current |
| `nist-dev-infra/route-rate-limits.sh` | Rate limits on operator-owned routes (800-53 SC-5) | Yes, annotations | Current, for hubs. Rerun when a scan says the limits are gone |
| `nist-dev-infra/watch-etcd-threads.sh` | Records etcd threads during a rollout | One debug pod per node | Current, for large control-plane nodes |
| `lib/tls-probe.py` | Which TLS versions endpoints accept | No | Current |
| `tests/test-remediation-ordering.sh`, `tests/test-gpu-vm-checks.sh` | Unit tests, no cluster | No | Current |
| `remediate.sh`, `lib/select-remediations.py` | Applies the Compliance Operator's remediations in stages | Yes, reboots every node | jetty only. A GitOps hub never applies remediations from the operator. Kept as the record, and for a standalone cluster |
| `manifests/23-acs-route-rate-limits.sh` | jetty's version of the rate-limit script | Yes | jetty only |
| `tests/gpu-switch-timing.sh`, `vms/gpu/test-gpu-switch.sh` | GPU mode switch, timed | Yes, reloads the driver | GPU clusters |
| `oac-apps/scripts/validate.sh` | Compared the fork's charts with the first jetty | No | Historical: that jetty and branch are gone |

## 5. Not in place yet

Each of these is needed to run a compliant hub day to day.

- **An alert and audit destination** (BUILD.md P9; [HANDOFF.md](HANDOFF.md)
  §2). Without it, every "nobody is alerted" in §1 is a daily check by a
  person.
- **Scan results from every cluster in one place.** ACS or ACM
  governance, not chosen ([HUB-SPOKE.md](HUB-SPOKE.md) §5). Raw results
  (ARF) also have to be archived per cluster as evidence; how is open.
- **A bot that opens remediation PRs**, and the option for
  `export-remediations.py` that it needs ([HUB-SPOKE.md](HUB-SPOKE.md) §5).
- **A written break-glass procedure** for incidents.
- **`verify.sh` for a hub** ([BUILD.md](BUILD.md) Part 1 §7).
- **Agreed cadences:** the *[decide]* items in [PATCHING.md](PATCHING.md),
  and a cadence for restore rehearsals. A full disaster-recovery test
  needs a disposable cluster.
- **A single register of exceptions and POA&M items.** They are
  recorded today in several files (the tailored profiles, the accepted
  operators list, [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md)
  2.9).
- **File integrity on hosted workers:** AIDE does not run there
  (RFE-8168).
- **Separation of duties** for exceptions and approvals: it needs real user
  accounts, not shared admin ones ([PATCHING.md](PATCHING.md) §4).
