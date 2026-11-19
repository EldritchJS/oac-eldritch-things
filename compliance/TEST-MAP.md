# Compliance tests: what checks what (MOC-issues #675)

This lines up the automated checks from the compliance work (#729, #777)
with the controls they give evidence for, and with the AI UAT Harness
tests (Ahmed Sanaullah, CCI-MOC `ai-uat-harness`). The aim is one set of
checks for the MOC 1.5 clusters, without two suites testing the same thing.

**Still to fill:** the gap analysis's requirement IDs (#463). Each row
here names the NIST 800-171 control; the gap analysis column is filled
once it is lined up against that document.

## Where the checks live

| Suite | Runs on | What it is |
|---|---|---|
| `tests/cluster-acceptance.sh` | Any cluster, hub or hosted | Read-only checks, plus `--functional` (VMs) and `--gpu` |
| `tests/verify.sh` | jetty only, today | The full T-xx regression net. A hub version is #777 |
| `tests/hub-preflight.sh` | A hub, before storage | Secrets, realm, TLS StorageClass |
| Compliance Operator | Every compliant cluster | `ocp4-moderate` and CIS scans, scan-only (oac-apps #196) |
| ACS | Every compliant cluster | Image vulnerability and HIPAA 164 policy results |
| AI UAT Harness | Any cluster | Platform, isolation, GPU, VM and inference tests |

## Checks against controls

| Check | What it proves | 800-171 | Where | Harness overlap |
|---|---|---|---|---|
| T-01 FIPS on every node | `fips=1`, `fips_enabled=1`, crypto policy FIPS | 3.13.11 | verify, acceptance | **platform-check #21** (same check) |
| T-02 FIPS validation record | Running RHCOS matches the reviewed CMVP record | 3.13.11 | verify | none |
| T-18 Operators claim FIPS | Every CSV carries the FIPS flag or a recorded exception | 3.13.11 | verify, `fips-image-scan.sh` | none |
| T-15 Effective TLS | API, ingress, OAuth, kubelets refuse TLS 1.0/1.1 and weak ciphers | 3.13.8, 3.13.11 | verify | none |
| T-13 Storage traffic encrypted | tlshd on every node; volumes mount with `xprtsec=tls` | 3.13.8 | verify, acceptance (default class) | none |
| T-03 Scan freshness and regression | Scans done within 48h, FAIL counts not above baseline | 3.4.1, 3.4.2, 3.12.1 | verify | none |
| T-04 Scan evidence archived | Raw ARF results kept on bound volumes | 3.3.1, 3.12.1 | verify | none |
| T-05 ACS healthy | Central and SecuredCluster up, collector on every node | 3.11.2, 3.14.1 | verify | none |
| T-16 File integrity | AIDE Active and Succeeded on every node, alert rule present | 3.14.1, 3.14.6, 3.14.7 | verify | none |
| T-10 Registry allowlist | Every registry in use is allowed | 3.4.8 | verify | none |
| T-11 Privileged SCCs known | No unexpected privileged SCC | 3.1.5, 3.4.6 | verify | platform-check's sandbox permission checks (the test's own account) |
| T-12 GPU switch constrained | The modality switcher can patch only GPU nodes | 3.1.5 | verify | none |
| T-14 etcd backups running | Newest successful backup under 26h old, volume `Retain` | 3.8.9 | verify | none |
| etcd restore rehearsal | A backup actually restores | 3.8.9 | `etcd-restore-rehearsal.sh` | none |
| Tenant metrics isolation | One project cannot read another's metrics | 3.1.3, 3.13.4 | none of ours | **metrics-isolation #19** |
| Failure modes | Impossible requests stay Pending | (availability) | none of ours | negative #21 |
| T-06, T-07 GPU modalities | Containers and passthrough both work | (function, not a control) | verify, acceptance | platform-check GPU checks |
| VM networking, storage, migration | VMs work and move | (function) | acceptance `--functional` | **vm-network, vm-storage, vm-migration** (same ground) |
| T-17 No GPU claimed | Billing hygiene after tests | (billing) | verify, acceptance | none |

## What this shows

- **Overlap:** FIPS mode (T-01 vs platform-check #21) and the VM tests
  (acceptance `--functional` vs vm-network, vm-storage, vm-migration) test
  the same things. The harness versions are the more thorough VM tests;
  ours are quicker smoke tests.
- **Only the harness:** tenant metrics isolation (3.1.3, 3.13.4). It
  belongs in the compliance set.
- **Only ours:** everything on crypto in transit, scans, ACS, file
  integrity, the registry allowlist and backups. These need cluster-admin
  or debug pods, which the harness's sandboxed account deliberately lacks.
- **Gap:** `verify.sh` only knows jetty (#777), so most T-xx checks have no
  runner on a hub until the hub version exists. compliant-dev-infra is the
  first to run it on, after stage C.

## Next

1. Fill the gap analysis column from #463's document.
2. Hub version of `verify.sh` (#777), run on compliant-dev-infra after
   stage C.
3. Agree with Ahmed whether the T-xx checks join the harness as a
   privileged suite or stay separate with one combined report.
