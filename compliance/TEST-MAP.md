# Compliance tests: what checks what (MOC-issues #675)

This lines up the automated checks from the compliance work (#729, #777)
with the NIST Gap Analysis (2026-11-05, #463) and with the AI UAT Harness
tests (Ahmed Sanaullah, CCI-MOC `ai-uat-harness`). The aim is one set of
checks for the MOC 1.5 clusters, without two suites testing the same thing.

## Where the checks live

| Suite | Runs on | What it is |
|---|---|---|
| `tests/cluster-acceptance.sh` | Any cluster, hub or hosted | Read-only checks, plus `--functional` (VMs) and `--gpu` |
| `tests/verify.sh` | jetty only, today | The full T-xx regression net. A hub version is #777 |
| `tests/hub-preflight.sh` | A hub, before storage | Secrets, realm, TLS StorageClass |
| Compliance Operator | Every compliant cluster | `ocp4-moderate` and CIS scans, scan-only (oac-apps #196) |
| ACS | Every compliant cluster | Image vulnerability and HIPAA 164 policy results |
| AI UAT Harness | Any cluster | Platform, isolation, GPU, VM and inference tests |

## Checks against the gap analysis

| Control | Gap analysis says | Check | Where | Harness overlap |
|---|---|---|---|---|
| 3.13.11 FIPS crypto | Bigger tactical gap; clusters use FIPS mode | T-01 FIPS on every node | verify, acceptance | **platform-check #21** (same check) |
| 3.13.11 | | T-02 running RHCOS matches the reviewed CMVP record | verify | none |
| 3.13.11 | Container images may need to be FIPS too | T-18 every operator claims FIPS or has a recorded exception; `fips-image-scan.sh` | verify | none |
| 3.13.8, 3.13.15 Encryption in transit, sessions | Bigger tactical gap; NFS over TLS via the local CA | T-13 tlshd on every node, volumes mount with `xprtsec=tls` | verify, acceptance | none |
| 3.13.8, 3.13.15 | | T-15 API, ingress, OAuth, kubelets refuse old TLS and weak ciphers | verify | none |
| 3.13.16 Encryption at rest | LUKS with FIPS crypto for local storage "requires separate research" | Not yet a check. **Done on compliant-dev-infra:** every local disk LUKS2, FIPS PBKDF, unlocked by Tang (#672, #811) | none yet | none |
| 3.4.1, 3.4.2 Baseline, security settings | Satisfied through GitOps | T-03 scans within 48h, FAIL counts not above baseline | verify | none |
| 3.12.1 Continuous monitoring | Plan drafted, needs review | T-03; T-04 raw scan results kept as evidence | verify | none |
| 3.11.2 Vulnerability scanning | ACS and Compliance Operator well underway | T-05 ACS up, collector on every node | verify | none |
| 3.4.8 Allowlist | Production hardening passes needed | T-10 every registry in use is allowed | verify | none |
| 3.4.6, 3.1.5 Least functionality, privilege | Hardening pass needed | T-11 no unexpected privileged SCC; T-12 GPU switch limited to GPU nodes | verify | platform-check's sandbox permission checks (the test's own account) |
| 3.14.1, 3.14.6, 3.14.7 Integrity | Strategic: patching, EDR, SIEM not chosen | T-16 AIDE Active and Succeeded on every node, alert rule present | verify | none |
| 3.8.9 Backups | Facility and client environment questions | T-14 newest etcd backup under 26h; restore rehearsal | verify, `etcd-restore-rehearsal.sh` | none |
| 3.13.4, 3.8.3 Shared resources, sanitization | VRAM must be zeroed between tenants; one tenant per GPU node, no MIG or time-sharing | Acceptance: one tenant's GPU VMs per node; passthrough nodes match the recorded memory-clearing test (`vms/gpu/memclear-record.md`) | acceptance | none |
| 3.13.4, 3.1.3 Shared resources, CUI flow | | Tenant metrics isolation: one project cannot read another's | none of ours | **metrics-isolation #19** |
| 3.3.1, 3.3.2 Audit logs | Big gap; needs the observability stack | Audit logging to Loki on FlashBlade S3 ran on nist-dev-infra (#735); no automated check | none yet | none |
| 3.1.11, 3.13.9 Session timeout, idle termination | Small tactical gaps | Clusters set OAuth token timeouts (a day, 10 minutes idle; #753); no automated check | none yet | none |
| (function) | | T-06, T-07 GPU in containers and passthrough | verify, acceptance | platform-check GPU checks |
| (function) | | VM networking, storage, migration | acceptance `--functional` | **vm-network, vm-storage, vm-migration** (same ground, more thorough) |
| (availability) | | Impossible requests stay Pending | none of ours | negative #21 |
| (billing) | | T-17 no GPU left claimed | verify, acceptance | none |

## What this shows

- **Ahead of the gap analysis:** encryption at rest on local disks
  (3.13.16), which it lists as research, is done on compliant-dev-infra;
  NFS over TLS (3.13.8) runs, with self-signed CA certificates until the
  local CA (#715) exists; GPU tenancy (3.13.4) has a recorded
  memory-clearing test and a one-tenant-per-node check.
- **Overlap with the harness:** FIPS mode and the VM tests. Keep the
  harness VM tests; ours stay as quick smoke tests.
- **Only the harness:** tenant metrics isolation. It belongs in the
  compliance set.
- **Only ours:** crypto in transit, scans and evidence, ACS, file
  integrity, the allowlist, backups. They need cluster-admin or debug
  pods, which the harness's sandboxed account deliberately lacks.

## Gap-analysis items with no automated check yet

| Control | Could be checked by |
|---|---|
| 3.13.16 Encryption at rest | Every data disk is LUKS2 with a clevis Tang binding (debug pod per node) |
| 3.13.6 Deny by default | Every namespace has a default-deny NetworkPolicy (#756) |
| 3.1.11, 3.13.9 Session timeouts | OAuth `accessTokenMaxAgeSeconds` and `accessTokenInactivityTimeout` set |
| 3.3.7 Time sync | chrony synchronised on every node |
| 3.3.1 Audit logs | API server audit profile set, and logs arriving in Loki |
| 3.5.3, 3.1.8 MFA, lockout | Keycloak realm settings (outside the clusters) |

## Next

1. Hub version of `verify.sh` (#777), with the new checks above, run on
   compliant-dev-infra after stage C.
2. Agree with Ahmed whether the T-xx checks join the harness as a
   privileged suite, or stay separate with one combined report.
