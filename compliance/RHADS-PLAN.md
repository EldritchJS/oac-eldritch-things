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
- **B2. Build `compliant-dev-infra` with R440s as its control plane and
  three workers still to be assigned, from nist-dev-infra's configuration, with
  jetty's GPU nodes as its hypervisor.** The layout
  oac-dev-infra uses, as tzumainn proposed. jetty itself, a
  hive-installed spoke used directly as a hypervisor, is
  not kept: its three FC430s go back to the pool, and its two GPU nodes
  become a hosted cluster's workers.

- For: nist-dev-infra's configuration is still in every repo and is the
  template, copied under the new name; only three R440s are needed, none
  as compute; nothing about the result is a one-off.
- Against: jetty stops being oac-dev-infra's GPU hypervisor and test bed,
  and andalusia as built today goes with it. Agree it with tzumainn and
  larsks first.

#### B2 layout

```
compliant-dev-infra  compliant hub: 3 R440s control plane + 3 workers (to be assigned)
  runs the control planes of:
    compliant-dev-workload0  Agent hosted cluster (GPU hypervisor) on jetty's 2 SD665-N V3s (like oac-dev-workload1)
    andalusia       KubeVirt hosted cluster, GPU VMs on the hypervisor (like oac-dev-workload2)
```

| Role | Nodes |
|---|---|
| Hub control plane | 3 R440s |
| Hub workers | 3 nodes, to be assigned (2026-11-17). They run the hub's own components and both hosted control planes; each needs a second disk for LVM Storage (hosted etcd) |
| GPU hypervisor workers | jetty's 2 Lenovo SD665-N V3s (2 x EPYC 9754, 1.5 TiB, 4 x H100 each), booted from the hub's discovery ISO as Agents |

R440s `MOC-R440-U14` to `U16` (BMCs `10.3.10.114` to `.116`) are this
hub's control plane (tzumainn, 2026-11-17). No R440 is used as compute. The layout is
oac-prod-infra's (dedicated control plane plus workers), the only
standard hub; the dev hubs are compact, and compact under FIPS is what
failed on nist-dev-infra.

The hub is installed with all six nodes at once. jetty and andalusia,
only in use by this work, are taken down once the hub's ISO is made
(jetty is the FIPS node it is made on) and before the GPU hypervisor
cluster (runbook section 1). There is no GPU VM cluster until andalusia
is rebuilt.

#### B2 steps that differ from nist-dev-infra's build

The full procedure is [compliant-dev-infra/RUNBOOK.md](compliant-dev-infra/RUNBOOK.md)
(sections 0 to 2), following oac-apps `docs/infra-cluster-deployment.md`.
Section 0 lists what the new name changes in each repo.

- **oac-infra `hub-images/group_vars/compliant-dev-infra/vars.yml`:** a
  copy of nist-dev-infra's with the new cluster name, the R440s in place
  of the three FC830 masters (names, IPs, MACs, install disk serials, etcd
  disk WWNs), and a `workers:` list for the three workers, as oac-prod-infra's
  has. The base domain, networks, VIPs and `fips_enabled`
  stay.
- **Set `diskencryption_mode` to none.** Disk encryption is a recorded
  exception, as on the first build (MOC-issues #672). The R440s' TPMs
  are faulty (#670), and on the FC830s `tpmv2` with no working TPM
  installed unencrypted without saying so; make the exception explicit.
- **Network:** nist-dev-infra was on `10.20.18.0/23`. tzumainn believes
  the R440s are on that VLAN; confirm with whoever cabled them.
- **Core count:** if the control-plane R440s have much more than about 40
  threads, boot them with `nr_cpus=40`
  ([nist-dev-infra/nr-cpus-machineconfig.yaml](nist-dev-infra/nr-cpus-machineconfig.yaml)),
  as BUILD.md Part 1 step 1 explains.
- **The runbook:** [compliant-dev-infra/RUNBOOK.md](compliant-dev-infra/RUNBOOK.md),
  drafted from nist-dev-infra's for oac-prod-infra's layout, with etcd encryption from
  install. nist-dev-infra's documents stay as the record of the first
  build.
- **OIDC:** new provider and roles in moc-aws, since the issuer URL has
  the cluster's name; `setup-oidc.sh` before the apply.
- **Hosted clusters in oac-apps:**
  `hosted-clusters/nist-dev-infra/nist-dev-workload0`, copied under
  `hosted-clusters/compliant-dev-infra/`,
  (an Agent cluster) is the starting point for the GPU hypervisor: change
  NIC names, node count and GPU settings. andalusia gets an entry under
  `hosted-clusters/compliant-dev-infra/`; its current one belongs to
  oac-dev-infra.
- **Two compliant hosted clusters, not one.** The hypervisor cluster is in
  scope: andalusia's VMs and their disks run on it.
- **GPU passthrough on an Agent hosted cluster is untested.** oac-apps
  #212 and #219 set it up on jetty as a spoke; oac-dev-workload1 is a
  hypervisor without GPUs.
- **Wipe every node first** (800-171 3.8.3). andalusia's VM disks and
  the test volumes are on the FlashBlade, not the nodes: delete them
  while jetty runs (runbook section 1).
- **andalusia is rebuilt, not moved:** a HostedCluster cannot change hubs.
- **jetty's records go afterwards:** `values/oac-dev-infra/jetty` in
  oac-apps, jetty's roles in moc-aws (#66), its records in moc-dns's
  `int.massopen.cloud` zone, and the ManagedCluster and hive
  ClusterDeployment on oac-dev-infra.

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
