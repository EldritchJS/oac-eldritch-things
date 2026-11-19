# Namespace and data boundaries: what we learned

Where one tenant's data, or one cluster's, is kept apart from another's on
the OAC clusters, as found while building jetty, nist-dev-infra,
nist-dev-workload0 and compliant-dev-infra (2026-10 to 2026-11). For each
boundary: what holds it, how we know, and what is still open or unknown.
800-171 controls are given where they apply (mostly 3.13.4, shared
resources; 3.8.3, sanitization; 3.1.3, flow of CUI; 3.13.1 and 3.13.5,
boundaries).

Most of the testing was on GPUs, VMs and containers, because that is where
the platform's own isolation was least documented. Test scripts and full
results are in [vms/gpu/README.md](vms/gpu/README.md); the GPU tests used
Ahmed Sanaullah's AI UAT Harness as well as our own scripts.

## In short

- **The real boundary is the cluster, and for hosted clusters, the hub.**
  FIPS, node hardening, etcd, the audit log and the identity provider are
  cluster-wide, so every tenant on a cluster shares them. A hub holds its
  hosted clusters' control planes and etcd, so a compliant cluster needs a
  compliant hub.
- **Between tenants on one GPU cluster, give each tenant whole GPUs or MIG
  slices, never a time-sliced or MPS share.** GPU memory was cleared
  between tenants in every test, for VMs and containers. The one leak we
  found (pods using GPUs they never requested) is closed on every cluster.
- **Between projects, the boundaries hold where the platform puts them**
  (RBAC, project node selectors, the metrics tenancy port), and **fail open
  where a project has nothing set**: a new project has no node selector and
  no NetworkPolicy.
- **Open questions that only vendors can answer:** NVLink between two
  tenants' GPUs when a guest runs its own driver (NVIDIA), and why the GPU
  reset clears memory (NVIDIA firmware).

## 1. Cluster and hub

| Boundary | What holds it | How we know | Open |
|---|---|---|---|
| Compliant vs non-compliant tenants | Separate clusters. FIPS is a boot setting and node hardening applies to every workload on a node, so tenants cannot opt out on a shared cluster | Hardening jetty: 377 of 383 remediations were MachineConfigs (STANDARDS.md 4) | A tenant that cannot live with hardening (USB passthrough, SCTP) needs its own cluster: a governance decision |
| Hosted cluster vs hub | None: the hub holds each hosted cluster's etcd (every Secret), its API server and audit log, its admin kubeconfig, and its etcd encryption key | Reading the oac-apps charts and nist-dev-infra (HUB-SPOKE.md 2) | Decided 2026-10-13: compliance is per hub. Compliant hubs carry only compliant clusters, and an admission policy refuses a hosted cluster without FIPS, the audit profile or secret encryption ([#752](https://github.com/CCI-MOC/MOC-issues/issues/752)) |
| Hosted etcd's disks | On compliant-dev-infra: LVM Storage on the hub's workers, LUKS-encrypted, unlocked by Tang ([#811](https://github.com/CCI-MOC/MOC-issues/issues/811)) | Built 2026-11-18 | Hosted etcd on NFS stalled on a stale FlashBlade lock (2026-10-23) and is unsupported; production placement is [#772](https://github.com/CCI-MOC/MOC-issues/issues/772) |
| Hardware moving between hubs | A node that served a non-compliant cluster is wiped before joining a compliant one (3.8.3) | The SD665s were wiped from the discovery image when they left jetty (2026-11-18) | No automated check that a node was wiped |
| Shared services | The compliant hub depends on AWS Secrets Manager, Keycloak, Route 53, the OIDC bucket and the `oac-apps` repo, all shared with non-compliant hubs | HUB-SPOKE.md 2 | Each is in the compliant boundary and must meet its baseline. Whoever can merge to `oac-apps` main can change the compliant hub ([#803](https://github.com/CCI-MOC/MOC-issues/issues/803)) |

## 2. GPUs

| Boundary | What holds it | How we know | Open |
|---|---|---|---|
| GPU memory between VMs | vfio resets each GPU when a VM releases it (function-level reset, then bus reset), and that clears memory | Filled every GPU, handed them to a new VM in another project, read memory through BAR0 with no driver: every sampled word zero, with a positive control (2026-10-20, 10-26, 10-28; [memclear-record.md](vms/gpu/memclear-record.md)) | One node, one firmware (`96.00.DA.00.17`), 256 KiB sampled per GiB. Why the reset clears memory is not known. The acceptance suite flags any passthrough node whose kernel, device or firmware differs from the tested one |
| GPU memory between containers | The host NVIDIA driver zeroes every allocation | A pod filled 78.6 GiB per GPU, exited or was killed; the next pod read zero, on whole GPUs, MIG slices and across MIG repartitioning (2026-10-28, 10-29) | Only tested through CUDA, which is all a container tenant has |
| GPU sharing between pods | MIG: hardware limits, no visibility of neighbours. Time-slicing: neighbours see each other's memory use and utilisation, no limits. MPS: one pod's fault killed every pod on the GPU | `test-gpu-sharing.sh` (2026-10-29) | **Time-slicing and MPS only within one tenant.** Nothing enforces that today; the oac-apps chart sets no sharing, so it holds by default |
| GPUs a pod did not request | Toolkit setting `ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED=false` and an admission policy refusing the `nvidia*` RuntimeClasses outside the operator | **Found open:** with GPU Operator defaults, a tenant with `edit` listed all four H100s on a node, including GPUs held by others (jetty and oac-dev-workload0). Closed by oac-apps [#208](https://github.com/CCI-MOC/oac-apps/pull/208), verified on workload0 2026-10-29 ([#738](https://github.com/CCI-MOC/MOC-issues/issues/738)) | `test-gpu-unrequested.sh` checks a cluster still has both. Also a billing hole ([#766](https://github.com/CCI-MOC/MOC-issues/issues/766)) |
| NVLink between tenants' GPUs | With the stock driver, a guest sees no peers and none of a neighbour's traffic | Tenant A moved about 8 TiB over NVLink; tenant B's counters on the same board stayed at zero (2026-10-29) | **The links stay physically up.** What a guest running its own driver could do over them is NVIDIA's to answer. Until then, compliant tenants get whole nodes or VMs holding all of a node's GPUs |
| Tenants on separate GPU nodes | A project node selector (`openshift.io/node-selector`), which tenants cannot change or override | Selector, affinity, tolerations and a GPU VM all failed to reach another tenant's node (2026-10-29) | **Projects without a selector run anywhere**, and users can create projects. Needs a cluster default node selector or a project template; not in oac-apps |

## 3. VMs

| Boundary | What holds it | How we know | Open |
|---|---|---|---|
| A tenant's VM | Its own kernel, and through KubeVirt hosted clusters its own cluster; the GPU memory results above apply between VMs | GPU VMs and a hosted cluster on a GPU VM, within 2-4% of bare metal ([WRITEUP-draft.md](vms/gpu/WRITEUP-draft.md)) | Running more than one hosted cluster on one GPU node is untested |
| One tenant's GPU VMs per node | A check in the acceptance suite | `cluster-acceptance.sh` | It reports, it does not prevent |
| Live migration of GPU VMs | Refused: a GPU VM with `evictionStrategy: LiveMigrate` fails the acceptance suite | Same | |
| Hosted cluster storage | The hosted cluster's StorageClass passes volumes through from the hypervisor | Block-mode ReadWriteMany only; new volumes owned by root | Whether the hypervisor's admins can read a hosted cluster's volumes is the same as the hub question: yes. The hypervisor is in the boundary |
| VM-specific hardening | None: there is no `moderate-vm-extension` profile | Compliance Operator profiles | Manual |

## 4. Projects and namespaces

| Boundary | What holds it | How we know | Open |
|---|---|---|---|
| Metrics | Thanos Querier holds every namespace's metrics in one pile; the tenancy port pins a query to namespaces the caller may read, and only cluster monitors may use the web port | The AI UAT Harness `metrics-isolation` test (Ahmed Sanaullah) | Not yet run on a compliant cluster |
| Network between namespaces | Default-deny NetworkPolicies from the `namespace-guardrails` chart, written from measured traffic | jetty's six namespaces (2026-10-08). Guessing broke things: default-deny cut external-dns off from DNS on the test hub until its traffic was measured | Hub platform namespaces ([#756](https://github.com/CCI-MOC/MOC-issues/issues/756)). A new tenant project has no policy at all. Egress: route allowlist ([#764](https://github.com/CCI-MOC/MOC-issues/issues/764)), egress proxy ([#771](https://github.com/CCI-MOC/MOC-issues/issues/771)) |
| Privileged workloads | A register of every privileged workload and why ([PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md)); a test fails on any new privileged SCC | T-11 | The GPU Operator, Portworx and ACS run privileged by necessity. Portworx's operator has cluster-wide RBAC ([#769](https://github.com/CCI-MOC/MOC-issues/issues/769)) |
| Audit logs | Per hosted cluster, a service account on the hub that may only write the audit tenant; its token is never in git | nist-dev-infra (2026-10) | Every hosted cluster's API audit lands in the same Loki tenant. Who may read it is the hub's access control |

## 5. Storage

| Boundary | What holds it | How we know | Open |
|---|---|---|---|
| Cluster vs cluster on the FlashBlade | A FlashBlade realm per cluster: its own network, address, certificate and credentials ([#789](https://github.com/CCI-MOC/MOC-issues/issues/789)) | compliant-dev-infra and compliant-dev-workload0, 2026-11-19 | The realm's certificate is self-signed until MOC's CA exists ([#715](https://github.com/CCI-MOC/MOC-issues/issues/715), [#768](https://github.com/CCI-MOC/MOC-issues/issues/768)) |
| Data in transit to the FlashBlade | NFS over TLS: tlshd on every node, volumes mount with `xprtsec=tls`; a hub admission policy refuses cleartext storage classes ([#752](https://github.com/CCI-MOC/MOC-issues/issues/752)) | 8 volumes on compliant-dev-infra mount with `xprtsec=tls` (2026-11-19); T-13 reports the TLS-to-cleartext ratio | Pure's answers on the FlashBlade's own crypto and PX-CSI FIPS ([#743](https://github.com/CCI-MOC/MOC-issues/issues/743)) |
| Local disks | LUKS2 on every disk, unlocked by Tang only on the cluster network ([#672](https://github.com/CCI-MOC/MOC-issues/issues/672), [#811](https://github.com/CCI-MOC/MOC-issues/issues/811)) | compliant-dev-infra install, 2026-11-18 | Tang runs on one server today ([#810](https://github.com/CCI-MOC/MOC-issues/issues/810)) |
| Which data is CUI | Nothing yet. Everything on a compliant cluster's realm is treated as CUI | | The gap analysis's point (3.8.4): with CUI and non-CUI on one FlashBlade, which media hold CUI cannot be told apart |
| Backups | etcd backups on the FlashBlade | T-14 | Backups on the same FlashBlade as the data ([#782](https://github.com/CCI-MOC/MOC-issues/issues/782)) |

## Still open, in one list

1. NVLink between tenants with their own drivers: NVIDIA.
2. Why the GPU reset clears memory, and whether it holds on other firmware: NVIDIA.
3. A default node selector or project template, so new projects cannot land on a tenant's GPU node.
4. Default NetworkPolicies for new tenant projects, and the hub's own ([#756](https://github.com/CCI-MOC/MOC-issues/issues/756)).
5. Enforcing "time-slicing and MPS only within one tenant", if sharing is ever turned on.
6. Metrics isolation run on a compliant cluster.
7. Shared services (Secrets Manager, Keycloak, Route 53, `oac-apps`) inside the compliant boundary ([#803](https://github.com/CCI-MOC/MOC-issues/issues/803)).
8. Hosted etcd placement for production ([#772](https://github.com/CCI-MOC/MOC-issues/issues/772)), and Tang's home ([#810](https://github.com/CCI-MOC/MOC-issues/issues/810)).
9. Marking which FlashBlade data is CUI.
