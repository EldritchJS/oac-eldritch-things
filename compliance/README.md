# Compliant OAC clusters: FIPS, HIPAA and NIST 800-171

*Start here. Last updated 2026-11-07. What is still open, with next steps
and who to ask: [HANDOFF.md](HANDOFF.md). What keeps a cluster compliant
after it is built: [OPERATIONS.md](OPERATIONS.md).*

The goal is OAC hubs and workload clusters that are compliant from first
boot, and kept that way by GitOps from
[CCI-MOC/oac-apps](https://github.com/CCI-MOC/oac-apps). A compliant hub
carries only compliant workload clusters. A workload cluster is compliant
because of the hub-wide settings, not its own files
([HUB-SPOKE.md](HUB-SPOKE.md) §2).

## How it got here

| Step | Question | Answer | Record |
|---|---|---|---|
| 1. jetty | Can this stack be made compliant, with GPUs in containers and VMs? | **Yes.** Hardened by hand: node failures 377 → 0, `ocp4-moderate` 25 → 8, both GPU modalities intact. Reinstalled 2026-10-28 with FIPS on, without this hardening | [JETTY.md](JETTY.md), [PLAYBOOK.md](PLAYBOOK.md) |
| 2. Charts | Can that work ship as oac-apps charts? | **Yes.** Nine charts reproduce jetty: an empty `oc diff` against the live cluster | [oac-apps/README.md](oac-apps/README.md) |
| 3. nist-dev-infra (retired 2026-10-28) | Do the charts work on a FIPS hub built the OAC way? | **Yes, in stages.** RHCOS failures 191 → 1 on the masters, storage TLS-only, ACS, etcd backups, NetworkPolicies | [nist-dev-infra/README.md](nist-dev-infra/README.md) |
| 4. nist-dev-workload0 (retired with the hub) | Can a compliant hub build a compliant workload cluster? | **Mostly yes.** Two FIPS workers, hardened from first boot (`rhcos4-moderate` 1 failure). With tailoring for the hidden control plane, `hosted-ocp4-moderate` is at 1 failure (the cluster-wide proxy, a recorded gap) and CIS at 0. MOC SSO, audit to the hub's Loki. AIDE does not run on hosted workers (RFE-8168) | [nist-dev-infra/README.md](nist-dev-infra/README.md), stage D |

## Where things stand (2026-11-02)

| | Status |
|---|---|
| Design and runbooks | [HUB-SPOKE.md](HUB-SPOKE.md) (design), [BUILD.md](BUILD.md) (method), [NEW-HUB-RUNBOOK.md](NEW-HUB-RUNBOOK.md) (draft) and [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) (final for this hub). Neither has been run end to end; the next step is a walk-through by someone else, building the replacement hub on new nodes |
| Upstream in oac-apps | NodePool config, API server audit and image config for hosted clusters ([#153](https://github.com/CCI-MOC/oac-apps/pull/153)); NFS over TLS on Portworx ([#148](https://github.com/CCI-MOC/oac-apps/pull/148), [#179](https://github.com/CCI-MOC/oac-apps/pull/179)); FIPS agent discovery ([#158](https://github.com/CCI-MOC/oac-apps/pull/158)); hub-wide hosted-cluster values ([#157](https://github.com/CCI-MOC/oac-apps/pull/157)); nist-dev-workload0 ([#159](https://github.com/CCI-MOC/oac-apps/pull/159) to [#166](https://github.com/CCI-MOC/oac-apps/pull/166), SSO [#171](https://github.com/CCI-MOC/oac-apps/pull/171)); object storage proxy ([#168](https://github.com/CCI-MOC/oac-apps/pull/168) to [#174](https://github.com/CCI-MOC/oac-apps/pull/174)); hub-side audit alert for hosted clusters ([#167](https://github.com/CCI-MOC/oac-apps/pull/167)); COO on workload0 ([#170](https://github.com/CCI-MOC/oac-apps/pull/170)); token timeouts and image allowlists ([#172](https://github.com/CCI-MOC/oac-apps/pull/172)); workload0's ESO, cert-manager and ingress certificate ([#175](https://github.com/CCI-MOC/oac-apps/pull/175)); the ACS chart [#181](https://github.com/CCI-MOC/oac-apps/pull/181); the hub's Let's Encrypt ingress certificate ([#184](https://github.com/CCI-MOC/oac-apps/pull/184)); the hub's SSO and token timeouts ([#188](https://github.com/CCI-MOC/oac-apps/pull/188), after moc-keycloak [#55](https://github.com/CCI-MOC/moc-keycloak/pull/55)); COSI requests and limits on every cluster ([#185](https://github.com/CCI-MOC/oac-apps/pull/185), from [pure-cosi#11](https://github.com/CCI-MOC/pure-cosi/pull/11)); no GPUs for pods that did not request them, on every GPU cluster ([#208](https://github.com/CCI-MOC/oac-apps/pull/208)); hosted-cluster compliance switched on per hub by `hosted-clusters/<hub>/compliance.yaml` ([#195](https://github.com/CCI-MOC/oac-apps/pull/195), 2026-11-02) |
| Compliance charts | Built and tested on the fork's `nist-dev-infra-test` branch. Moving to main, one PR per chart. Merged: Compliance Operator ([#196](https://github.com/CCI-MOC/oac-apps/pull/196)), compliant-hub admission policy ([#197](https://github.com/CCI-MOC/oac-apps/pull/197)), platform hardening ([#215](https://github.com/CCI-MOC/oac-apps/pull/215)), namespace guardrails ([#216](https://github.com/CCI-MOC/oac-apps/pull/216), a library chart) and the NFS over TLS handshake daemon ([#218](https://github.com/CCI-MOC/oac-apps/pull/218)). In review: File Integrity ([#198](https://github.com/CCI-MOC/oac-apps/pull/198)), node hardening ([#214](https://github.com/CCI-MOC/oac-apps/pull/214)) and etcd backup ([#217](https://github.com/CCI-MOC/oac-apps/pull/217)). ACS's chart is on main ([#181](https://github.com/CCI-MOC/oac-apps/pull/181)). No ApplicationSet uses them yet; one PR will wire them to #195's hub marker. Audit logging waits for a log destination (BUILD.md P9) |
| Test hub `nist-dev-infra` | **Retired 2026-10-28.** Compact, FIPS, 4.22.14. Stages A, S, B, C, D and E done (E: audit logging to Loki on FlashBlade object storage). Masters capped at 40 CPUs since 2026-10-21. 4 failing rules (2026-10-27): three accepted gaps (2 POA&M items and kubeadmin) and NetworkPolicies, to be done for production, each with a fix and status ([nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) 2.9). Its replacement, on new nodes, is to be built from the runbook |
| First workload cluster | Installed 2026-10-22: 4.22.18, single-replica control plane, two workers. Compliance stages A to D delivered by the hub's Argo; MOC SSO; its own audit forwarded to the hub. Retired with the hub on 2026-10-28 |
| GPUs for VMs | Passthrough proven on both of jetty's GPU nodes: 1-, 2- and 4-GPU VMs, several per node, CUDA on every GPU, about 8% less host-to-device bandwidth than a container on the same node. GPU memory is cleared before a new VM in another project can read it (2026-10-26). jetty was reinstalled on 2026-10-28 and all of it passed again; a 4-GPU VM also gets full NVLink between its GPUs (133 GB/s per pair), and containers can share a GPU through MIG without a licence. Between tenants, containers get MIG slices or whole GPUs: time-slicing and MPS keep memory private but expose usage, and under MPS one pod can crash its neighbours. GPU memory is cleared between pods too, including across MIG repartitioning, and pods can run on a GPU inside a tenant's own VM. The GPU Operator needs one toolkit setting and an admission policy on any multi-tenant cluster, shown on oac-dev-workload0 as well as jetty (oac-apps PR #208, vms/gpu/OPTIONS.md). One tenant per GPU node until cross-tenant NVLink is answered. The acceptance suite checks placement and configuration. Sharing one GPU between VMs needs an NVIDIA vGPU licence. Pods in a 4-GPU VM matched bare metal in the AI UAT Harness inference tests, given dedicated CPUs and SMT off in the guest (2026-10-29). jetty is now a hypervisor candidate for oac-dev-infra's KubeVirt clusters: GPU NodePools are proposed in oac-apps [#212](https://github.com/CCI-MOC/oac-apps/pull/212), [#213](https://github.com/CCI-MOC/oac-apps/pull/213) and [#219](https://github.com/CCI-MOC/oac-apps/pull/219) ([vms/gpu/README.md](vms/gpu/README.md), [vms/gpu/OPTIONS.md](vms/gpu/OPTIONS.md)) |

## Operators without a FIPS claim

FIPS mode on the nodes and clean compliance scans do not cover add-on
operators, and the scans do not look at them. **6 of the 21 operators
installed on jetty and oac-dev-infra are not flagged `fips-compliant: true`
(checked 2026-11-05; oac-prod-infra and the hosted clusters are not checked).
Each has a recorded route forward, and two are settled, but none has a
final team decision yet.** No flag means the vendor makes no claim. It
does not prove the operator uses unapproved crypto, but an assessor goes by
the claim. The scan column is a separate check of the images with
`check-payload`.

| Operator | Flag | Image scan | What it touches |
|---|---|---|---|
| Cluster Observability Operator | false | Pass (the flag looks wrong) | Perses dashboards in the console; reads metrics |
| Grafana operator | none | Fail | Per-project Grafana; sends each project's data source token over plain HTTP |
| Portworx operator | false | Fail | Storage driver for FlashBlade volumes; holds the FlashBlade API token |
| NVIDIA GPU Operator | false | Fail | GPU drivers and device plugins; privileged on GPU nodes |
| patch-operator | none | Fail | Patches cluster resources; broad API write access |
| group-sync-operator | none | Fail | Syncs the groups that decide who can access what. Only on `oac-dev-infra`; compliant hubs use Keycloak's `groups` claim instead |

Full record, including vendor statements and each operator's likely route:
[tests/operator-fips-inventory.md](tests/operator-fips-inventory.md). Next
steps and who to ask: [HANDOFF.md](HANDOFF.md) §3. `tests/verify.sh -t t18`
fails on any new operator without the flag.

## What the hub taught that jetty did not

- **Storage is TLS-only from its first volume.** A node with a cleartext
  NFS mount to the FlashBlade reuses that session, and later TLS mounts
  fail. The TLS StorageClass goes in with Portworx, before anything else
  ([nist-dev-infra/STORAGE-BRINGUP.md](nist-dev-infra/STORAGE-BRINGUP.md)).
- **Under FIPS, large control-plane nodes kept dropping out.** The 176-CPU masters
  went NotReady about once an hour, with etcd and kubelet thread pile-ups,
  with or without a hosted control plane. Capped at 40 CPUs, like jetty's,
  they stall less often, but still do, a few times a day. Cap with
  `nr_cpus`; a udev rule undoes `maxcpus` ([nist-dev-infra/MASTER-ROUND.md](nist-dev-infra/MASTER-ROUND.md)).
- **An API server rollout can freeze a master.** On 2026-10-26 a new
  kube-apiserver revision froze the kubelet on two of the three masters
  at their switch; a graceful shutdown hung, and each came back after a
  power cycle from its iDRAC ([nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) §5).
- **Changing the hub's ingress certificate breaks whatever pinned the old
  CA.** workload0's audit forwarder trusted only the hub's ingress CA; with
  a Let's Encrypt certificate it now uses system trust.
- **Default-deny egress catches hub components.** external-dns could not
  reach Route 53 until its namespace got an egress rule. Measure each
  component's egress before the guardrails go on.
- **FIPS reaches the edges.** sshd on a FIPS node refuses ed25519 keys, so
  agent discovery uses ECDSA. USBGuard arrived in the same update that
  enabled it and stayed disabled until a boot-time unit enabled it.
- **Hosted control planes need their own DNS.** The hosted-cluster router
  needs a static wildcard record, as the oac hubs have (moc-aws #57).

## Still open

The full list, with next steps, is in [HANDOFF.md](HANDOFF.md). In short:

- The compliance charts merged upstream (in review, above) and wired to
  the hub marker, with branch protection on the repo the hubs read
  (BUILD.md, P1 to P3).
- An audit and alert destination (BUILD.md P9): audit records on a node
  last hours, and nothing alerts on a new scan failure.
- A decision on each of the six [operators without a FIPS
  claim](#operators-without-a-fips-claim).
- Storage for workload clusters: Portworx and NFS over TLS, as on the
  hub. The cluster-wide proxy is a recorded POA&M gap.
- Hosted etcd on FlashBlade NFS, accepted for the test only; a later hub
  gives it local disks.
- The replacement hub, with etcd encryption from install (a POA&M item on
  the old one); disk encryption still needs a tested method (BUILD.md P10).
- NetworkPolicies for the hub's namespaces for production ([nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) §7).

## Where the detail lives

| File | What |
|---|---|
| [OPERATIONS.md](OPERATIONS.md) | **Day to day:** what runs by itself, what a person does and when, which scripts are for it, and what is not in place yet |
| [HANDOFF.md](HANDOFF.md) | **Open work:** every open item, next step and who to ask. Diagrams of the clusters, how a cluster gets its components, COSI and Connectivity Link |
| [tests/operator-fips-inventory.md](tests/operator-fips-inventory.md) | **Operators:** which installed operators claim FIPS support, the six that don't, and what their images contain |
| [HUB-SPOKE.md](HUB-SPOKE.md) | **Design:** compliant hubs and hosted clusters under GitOps; where each jetty control goes. Diagram of a compliant hub (§2) |
| [BUILD.md](BUILD.md) | **Method:** a compliant hub, then a compliant workload cluster on it |
| [NEW-HUB-RUNBOOK.md](NEW-HUB-RUNBOOK.md) | **Runbook:** a new hub and workload cluster from nothing, with example PRs |
| [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) | **Runbook:** rebuild nist-dev-infra and workload0 |
| [oac-apps/README.md](oac-apps/README.md) | **Proof:** jetty's manifests as oac-apps charts, checked against jetty |
| [nist-dev-infra/README.md](nist-dev-infra/README.md) | **Test:** the charts on the nist-dev-infra hub, stage by stage, and the first workload cluster |
| [nist-dev-infra/STORAGE-BRINGUP.md](nist-dev-infra/STORAGE-BRINGUP.md) | The steps that give an OAC hub storage |
| [nist-dev-infra/MASTER-ROUND.md](nist-dev-infra/MASTER-ROUND.md) | One reboot round on the masters: 40 CPUs and USBGuard |
| [vms/gpu/README.md](vms/gpu/README.md) | GPU passthrough to VMs: setup, results, open questions |
| [vms/gpu/OPTIONS.md](vms/gpu/OPTIONS.md) | GPUs for VMs on OAC: passthrough and vGPU |
| [PLAYBOOK.md](PLAYBOOK.md) | The method, from jetty: order of operations and cautions |
| [JETTY.md](JETTY.md) | jetty's record: FIPS, scans, gaps, GPUs in both modes |
| [STANDARDS.md](STANDARDS.md) | 800-171, HIPAA and FIPS mapping; scope |
| [FEASIBILITY.md](FEASIBILITY.md) | Compliance against GPUs and VMs: where they collide |
| [PLAN.md](PLAN.md) | jetty's decisions log |
| [NFS-TLS.md](NFS-TLS.md) | Storage encryption in transit |
| [GRAFANA.md](GRAFANA.md) | Grafana under FIPS, 800-171 and HIPAA: per-project dashboards and access control |
| [GRAFANA-FIPS-IMAGE.md](GRAFANA-FIPS-IMAGE.md) | FIPS Grafana from RHEL's package in a UBI image, and running it without the operator (oac-apps #230), tested on jetty |
| [STORAGE-ISSUE.md](STORAGE-ISSUE.md) | jetty's FlashBlade outage |
| [PATCHING.md](PATCHING.md) | Patch cadence: draft SSP text |
| [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md) | Exception register for privileged workloads |
| [tests/README.md](tests/README.md) | Verification suite and hub preflight |
| `manifests/`, `remediate.sh` | jetty's manifests and staged hardening script (first install; not for GitOps hubs) |
| `vms/`, `vms/gpu/` | VM and GPU test suites |

## Before you run anything

No kubeconfig is in this repo, and none should be. Point `KUBECONFIG` at a
cluster-admin kubeconfig kept outside the working tree, and check with
`oc whoami`.
