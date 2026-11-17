# RHADS on the compliance clusters: plan

*Draft, 2026-11-16. Nothing here is installed. Findings behind it:
[tests/operator-fips-inventory.md](tests/operator-fips-inventory.md#rhads-explored-on-andalusia-2026-11-16).*

## What we are adding

Red Hat Advanced Developer Suite (software supply chain):

| Product | What it does | FIPS today |
|---|---|---|
| Trusted Artifact Signer (RHTAS) | Signs and verifies images and artifacts (Sigstore: Fulcio, Rekor, Trillian, TSA) | Flagged `true`; operator and all services pass check-payload |
| Trusted Profile Analyzer (RHTPA) | Stores SBOMs and VEX, reports CVEs | Flagged `false`; server (`trustd`, Rust, bundled aws-lc/ring) fails |
| Developer Hub (RHDH) | Developer portal (Backstage) | Flagged `false`; portal image fails (non-certified OpenSSL) |
| Enterprise Contract | Policy check that an image was built and signed as required | CLI and Tekton tasks, no operator; not scanned |

Alongside: OpenShift Pipelines (flagged `true`), which runs the build,
sign and verify flow.

We would not use Red Hat's installer (`tssc`). It always deploys its own
Keycloak and makes RHTAS and RHTPA trust only that, adds plain-text
PostgreSQL, a second ACS and Argo CD, and Automatic subscriptions. We
install the operators ourselves, against mocsso.

## The hub problem

andalusia is a hosted cluster on **oac-dev-infra**, and oac-dev-infra is not
FIPS and not a compliant hub. By our rule
([HUB-SPOKE.md](HUB-SPOKE.md#compliant-and-non-compliant-hubs)), a
non-compliant hub cannot have compliant workload clusters: andalusia's
control plane, etcd and audit logs live on oac-dev-infra. andalusia is
FIPS-built (`fips: true`, so its worker VM runs RHCOS in FIPS mode), not
compliant: it has none of a compliant hub's hardening, and its control
plane pods run on oac-dev-infra's non-FIPS nodes. RHADS on andalusia can
only ever be a functional test. No compliant hub is running today
(nist-dev-infra retired 2026-10-28).

That gives two tracks: try RHADS now where it does not matter, and get a
compliant cluster to put it on for real.

## Track 1: functional test on andalusia (now)

No compliance claim. Learns what RHADS needs and how it fits mocsso,
Pipelines and our registries. andalusia has room: one 64 vCPU / 128 GiB
worker, nearly idle, storage `kubevirt-csi-infra-default` (RWO).

1. **Check what andalusia already gets** from oac-dev-infra's placements
   (`all-managed-clusters` and others), so we do not collide with or get
   pruned by the hub's Argo CD.
2. **OIDC clients in mocsso** for RHTAS (Fulcio's issuer), RHTPA and RHDH.
   One moc-keycloak PR, like #64.
3. **RHTAS first**: the one FIPS-clean product, and on its own enough for
   signing. Securesign CR, Fulcio against mocsso, Routes through jetty's
   passthrough (#226). Sign and verify one image with `cosign`.
4. **Pipelines and Enterprise Contract**: a pipeline that builds, signs
   (Tekton Chains to RHTAS) and verifies with Enterprise Contract.
5. **RHTPA**: PostgreSQL with TLS (not the installer's `sslMode: disable`),
   OIDC against mocsso, import the SBOMs the pipeline makes.
6. **RHDH last**, and only if someone wants the portal: it is the least
   needed for supply chain security and fails FIPS.
7. Record what each step needed: Secrets, Routes, storage, egress, images
   and registries. That list becomes the oac-apps charts.

By hand on andalusia, removed afterwards. No changes to oac-apps until
Track 2 has a place to put them.

## Track 2: a compliant place to run it

Pick one. This is a team decision; the recommendation is A.

### A. Build the replacement compliant hub (recommended)

The plan already exists: [NEW-HUB-RUNBOOK.md](NEW-HUB-RUNBOOK.md) and
[nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md), the nist-dev-infra
replacement on new nodes. RHADS then goes on a hosted cluster of that hub,
built FIPS and hardened by the hub's charts like nist-dev-workload0 was.

- For: matches the hub-and-spoke design; the runbooks need their
  walk-through anyway; nothing existing changes role.
- Against: needs hardware of the right shape (runbook 3.1) and the
  week-scale prerequisites (DNS, realm, Keycloak client, AWS roles).
  Slowest.

### B. Make jetty compliant

jetty: 5 nodes (3 masters, 2 GPU workers), FIPS on, reinstalled
2026-10-28 without the compliance hardening. Two variants:

- **B1. jetty as a compliant standalone cluster.** Re-apply the hardening
  from the first engagement ([JETTY.md](JETTY.md)) and run RHADS on jetty
  itself. jetty is an ACM ManagedCluster and hive spoke of oac-dev-infra,
  a non-compliant hub, so it would have to be detached from it first.
  Quickest to a compliant cluster, but outside the hub design: a one-off
  to keep in step by hand.
- **B2. A compliant hub on jetty's hardware, laid out like the other
  hubs.** jetty itself is the odd one out: a hive-installed standalone
  spoke used directly as a hypervisor, without hosted control planes. B2
  does not keep that. The hardware is reinstalled as a standard compliant
  hub with the standard hypervisor pattern below, so nothing about it is
  a one-off.
- For: hardware we have, already FIPS.
- Against: jetty is oac-dev-infra's GPU hypervisor (andalusia's VMs, the
  GPU NodePool work in #212/#219) and the GPU test bed; detaching it
  breaks andalusia as it is built today. Either variant is a rebuild in
  all but name; agree it with tzumainn and larsks first.

#### B2 hardware

What jetty has (checked 2026-11-17):

| Nodes | Hardware |
|---|---|
| 3 masters | Dell FC430, 2 x Xeon E5-2640 v4, 40 threads, 126 GiB, 2 x 186 GB SSD, no TPM |
| 2 workers | Lenovo SD665-N V3, 2 x EPYC 9754 (512 threads), 1.5 TiB, 4 x H100, 894 GB and 7 TB NVMe |

The pattern to copy is oac-dev-infra's (checked 2026-11-17): the hub runs
control planes only; oac-dev-workload1 is a hosted cluster whose two
bare-metal Agent workers are the hypervisor; oac-dev-workload2 is a
KubeVirt hosted cluster whose workers are VMs on workload1. For B2:

```
compliant hub (3 control plane + 3 workers)
  runs the control planes of:
    gpu-hypervisor   hosted cluster, Agent workers = the 2 SD665-N V3s
    andalusia        hosted cluster, KubeVirt workers = GPU VMs on gpu-hypervisor
```

| Role | Count | Spec |
|---|---|---|
| Hub control plane | 3 | The FC430s: about 40 cores on 2 sockets is the shape BUILD.md asks for. Separate SSDs for the OS and etcd |
| Hub workers | 3, new | CPU only, no GPUs. About 32 to 64 cores on 1 or 2 sockets, 256 GiB, 1 to 2 TB local NVMe for LVM Storage (the hosted clusters' etcd on local disk), a port on the storage VLAN. They run the hub's own components and both hosted control planes |
| Hypervisor cluster workers | 2 | The SD665-N V3s, booted from the hub's discovery ISO as Agents, like workload1's nodes |

- **Not a hub without the three workers.** The standard layout is not
  compact (BUILD.md Part 1 step 4), and with no hub workers the hosted
  etcds would run beside the hub's etcd on the FC430s.
- **Two compliant hosted clusters, not one.** The hypervisor cluster is
  in scope too: andalusia's VMs and their disks run on it. It gets the
  same node hardening through its NodePool as any hosted cluster.
- **GPU passthrough on a hosted hypervisor cluster** is what oac-apps #212
  and #219 set up on jetty as a spoke; on an Agent hosted cluster it is
  untested. workload1 is a hypervisor without GPUs.
- **Disk encryption: a recorded exception.** None of the nodes will use a
  TPM, as on nist-dev-infra. Encrypt at install once nodes with working
  TPMs are available (MOC-issues #672).
- **Wipe every node first** (800-171 3.8.3), including the SD665s' NVMe,
  which holds andalusia's VM disks today.
- **andalusia is rebuilt, not moved:** a HostedCluster cannot change hubs.

### C. Wait

Keep Track 1 only, and put RHADS on the first compliant hub whenever one
exists. Costs nothing; delays the compliance answer.

## Track 3: what compliance needs from RHADS, wherever it runs

Each becomes an item in the SSP or a POA&M entry.

| Item | Control | Plan |
|---|---|---|
| RHTPA server not a FIPS build | SC-13 | Ask Red Hat for plans; POA&M, or leave RHTPA out until fixed |
| RHDH portal not a FIPS build | SC-13 | Same; or leave RHDH out (not needed for signing) |
| RHTPA operator scan inconclusive | SC-13 | Ask Red Hat; rescan with a newer check-payload |
| Enterprise Contract images not scanned | SC-13 | Scan the task images during Track 1 |
| One identity provider | AC-2, IA-2 | mocsso for everything; no second Keycloak |
| Database traffic | SC-8 | TLS to PostgreSQL for RHTPA (and RHDH) |
| Operator updates | CM-3, SI-2 | Manual install plans, as for the other operators ([PATCHING.md](PATCHING.md)) |
| Registries | CM-7 | All images from `registry.redhat.io`; check nothing pulls from quay.io or GitHub at run time |
| T-18 | | Add RHDH and RHTPA to [operator-fips-accepted.txt](tests/operator-fips-accepted.txt) only with a recorded decision |

## Open questions

- **Who wants RHADS, and which parts?** If the need is signed images,
  RHTAS plus Pipelines and Enterprise Contract covers it, and both FIPS
  gaps (RHTPA, RHDH) drop out.
- **Red Hat:** FIPS plans for RHTPA and RHDH; is RHTAS with an external
  Keycloak (mocsso) supported; is RHADS supported on hosted control planes.
- **Hardware** for option A, and when.
- **jetty's future role** if option B: hypervisor and GPU test bed, or
  compliant cluster.
