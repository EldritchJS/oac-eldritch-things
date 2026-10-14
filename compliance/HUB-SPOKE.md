# Hub and spoke: building compliant OAC clusters

*Design, 2026-10-13. Nothing here has been tested on a hub or a hosted
cluster yet; every claim is marked as **read** (from source or docs),
**measured** (on jetty) or **to verify**.*

> Angle-bracket values are redacted internal addresses. See the top-level
> README § Conventions.

jetty answered *can this hardware and software stack be made compliant?*
(yes, with documented exceptions — [README.md](README.md)). The real OAC
clusters raise a different question: **how is a cluster built compliant from
the start, and kept that way, when a hub creates and manages it?** This
document maps jetty's work onto that model and lists what must be proven
before it can be relied on.

| Document | Scope |
|---|---|
| [PLAYBOOK.md](PLAYBOOK.md) | One standalone cluster, hardened after install, by hand. The method this builds on. |
| **HUB-SPOKE.md** (this) | The hub (infra cluster) and the hosted workload clusters it creates. |

---

## 1. The architecture, as OAC builds it

Read from [CCI-MOC/oac-apps](https://github.com/CCI-MOC/oac-apps) (`main`,
commit `62a149e`, 2026-10-13), `docs/architecture-and-deployment.md` and the
charts it references, and the `open-accelerator` branch of `CCI-MOC/ai-ivp`.

- **Hub ("infra cluster").** A full OpenShift cluster, installed with the
  agent-based installer from `ai-ivp`: compact (3 nodes) for dev, standard
  (3 control plane + 3 workers) for prod. It runs ACM (`MultiClusterHub`),
  HyperShift on the Agent platform, and an ArgoCD instance that configures
  **both the hub itself and every workload cluster** from `oac-apps`.
- **Workload clusters ("spokes").** `HostedCluster`s. Each one's control
  plane — kube-apiserver, **etcd**, OAuth, controllers — runs as pods in a
  namespace on the hub. Its etcd sits on the hub's local disks
  (`storageClassName: lvms-vg0`). Its workers are bare-metal agents that
  join through the hub's `hardware-inventory` InfraEnv. Tenants get only the
  workers and the API.
- **Configuration.** All in git. The hub's `hub-components` ApplicationSet
  deploys a fixed list of charts to the hub; per-cluster values under
  `hosted-clusters/<hub>/<cluster>/` and `values/<hub>/<cluster>/` define each
  workload cluster and its in-cluster components. Credentials come from AWS
  Secrets Manager via external-secrets, not from git.
- **Shared services.** Keycloak ("MOC SSO", on Amazon EKS) for identity;
  cert-manager with Route 53 for certificates; Pure FlashBlade via Portworx
  for storage. Observability is marked *TBD* in OAC's own docs.

**Where jetty sits.** jetty was installed once through the dev hub
(`charts/spoke-cluster`, agent-based, `fips: true`) and has been managed by
hand since: no ArgoCD Application references it. It is a standalone full
cluster, which is why [PLAYBOOK.md](PLAYBOOK.md) is written for one.

## 2. The hub is in the boundary

800-171 scopes by what a system can affect, not only where CUI rests:
systems that provide security protection to in-scope systems are in scope
(CMMC calls them Security Protection Assets). HIPAA's risk analysis reaches
the same answer. For hosted clusters the hub is not just a controller —
**it holds each workload cluster's control plane and data**:

| On the hub, per workload cluster | Consequence |
|---|---|
| etcd: every Secret, ConfigMap and object of the cluster (read) | Tenant data at rest on hub disks |
| The etcd encryption key, generated on the hub by external-secrets and stored only as a hub Secret (`charts/acm/templates/etcd-key-generator.yaml`, read) | Ciphertext and key on the same cluster; losing the hub loses the key |
| kube-apiserver, so its **audit log** (to verify where it is written) | Audit forwarding for workload clusters happens on the hub |
| Admin kubeconfig and kubeadmin password Secrets (optionally pushed to AWS Secrets Manager, `pushsecret.yaml`, read) | Hub admin = admin of every workload cluster |
| ACM and ArgoCD with write access to every cluster | A bad merge or a compromised hub changes every cluster |

So: **the hub's baseline is at least the workload clusters', and its access is
narrower** — a small hub-admin group, MFA through Keycloak, and no tenant
access at all. Losing the hub takes every workload cluster's control plane
with it, so its backup and recovery matter more than any single cluster's.

## 3. Decisions that cannot be changed after install

Like FIPS on jetty, these are fixed when a cluster is created. Getting one
wrong means rebuilding.

| Decision | Hub | Workload cluster | OAC today | jetty |
|---|---|---|---|---|
| **FIPS mode** | `fips_enabled` in the `ai-ivp` inventory group | `HostedCluster.spec.fips` | Hub: `ai-ivp` groups `infra` true; `oac-infra`, `infra-dev`, `staging` **false**; prod hub's config is in an unmerged fork — **to verify on the live hub** (`oc get cm cluster-config-v1 -n kube-system -o yaml \| grep fips`). Workload: chart default **false**, no cluster overrides it (read) | true (measured) |
| **FIPS is immutable on a HostedCluster** | — | **to verify**; the API reference does not say | — | — |
| **Disk encryption at rest** (RHCOS LUKS, TPM2 or Tang) | Install-time config. The hub's local disks hold every workload cluster's etcd | How LUKS is requested for agent-provisioned hosted workers — **to verify** | Not configured (read: nothing in `ai-ivp` or `oac-apps`) | **Not encrypted** (measured 2026-10-13: no crypt layer under `/sysroot`). No OpenShift scanner profile checks this; 800-171 3.13.16 and HIPAA 164.312(a)(2)(iv) still ask |
| **SSH key type** | ECDSA or RSA; FIPS rejects Ed25519 (noted in `ai-ivp`) | Same | ECDSA in use (read) | ECDSA (read) |
| **Network placement** | Management network, VPN-only; hub API not exposed | API and ingress may be NAT'd public | Workload API/ingress optionally public (read) | VPN-only |

## 4. Where each jetty control goes

Three places a control can live, and they are not interchangeable:

- **Hub** — the hub's own configuration, as on jetty.
- **HostedCluster / NodePool spec (on the hub)** — anything about a workload
  cluster's control plane or node OS. The workload cluster cannot change it
  from inside; it has no MachineConfig API.
- **In-cluster** — operators and objects inside the workload cluster,
  delivered per cluster by ArgoCD.

| Control | jetty (how) | Hub | Workload cluster |
|---|---|---|---|
| FIPS | install | install (§3) | `HostedCluster.spec.fips` (§3) |
| etcd encryption | `aesgcm` on APIServer | same as jetty | `spec.secretEncryption` — **already `aescbc`** in the chart (read). Key escrow: see §6 |
| API audit profile | `WriteRequestBodies` (manifests) | same as jetty | `spec.configuration.apiServer` — field exists (read); audit-profile behaviour **to verify** |
| TLS profile | default, verified by probes (T-15) | same | `spec.configuration.apiServer` |
| Identity provider | none (B3) | Keycloak (`keycloak-oauth`, read) | `oauth.mocsso` in chart values (read) |
| Ingress certificate | none (B4) | cert-manager (`cluster-certificates`, read) | same, per cluster (read) |
| Registry allowlist | `image.config` `allowedRegistries` | same | `spec.configuration.image` |
| Node hardening (~380 MachineConfigs, sshd `AllowUsers`, kernel args) | Compliance Operator auto-remediation + `manifests/21-*` | MachineConfigs from git | **`NodePool.spec.config`**: ConfigMaps holding MachineConfig, KubeletConfig, ContainerRuntimeConfig, ClusterImagePolicy (read, API reference). Changing it rolls the pool; the chart uses `upgradeType: InPlace` (read) — reboot behaviour on bare-metal agents **to verify** |
| Compliance scanning | Compliance Operator, tailored profiles | same as jetty | Installable on HyperShift hosted clusters since CO 1.1.0; on ROSA HCP it loads node profiles only (read, release notes). What platform checks mean when the control plane is invisible, and what happens to remediations with no MCO — **to verify** (§7 E1) |
| File integrity (AIDE) | FIO, all nodes | same as jetty | In-cluster FIO on workers; re-init after NodePool rollouts **to verify** |
| NetworkPolicies | default-deny in/out (`17-*`, `18-*`) | same, plus the HCP namespaces (see §6) | In-cluster. OAC already has `restrict-tenant-networks` (a BaselineAdminNetworkPolicy denying cross-tenant traffic) and per-project NetworkPolicies in `user-projects` (read) |
| Quotas | object counts only (`22-*`) | same | In-cluster; `user-projects` already sets ResourceQuota and LimitRange per project (read) |
| ACS | Central + secured cluster on jetty | Central | Secured cluster per workload cluster, reporting to the hub's Central — placement **to decide** |
| NFS over TLS | `tlshd` DaemonSet (`11-*`) | if the hub mounts FlashBlade NFS | In-cluster on workers (Portworx runs in the workload cluster, read) |
| etcd backup | CronJob (`15-*`) | hub etcd — **does not contain workload clusters' etcd**, which are separate pods | Per-HostedCluster etcd backup — method **to verify** |
| Audit forwarding | none (B1) | hub ClusterLogForwarder | Where workload-cluster API audit logs are written (hub pods) and how they are forwarded — **to verify** |
| GPU billing guard (T-17) | `verify.sh` | — | In-cluster, per GPU cluster |

## 5. Delivery: GitOps, with the scanner as a sensor

jetty was remediated by applying the Compliance Operator's own remediations.
On a GitOps-managed cluster that conflicts: ArgoCD runs `selfHeal: true` and
`prune: true` (read), so anything it does not own drifts back, and anything
two controllers both own flaps. The model that fits:

1. **The Compliance Operator scans; it does not apply.** Set
   `autoApplyRemediations: false`.
2. **Remediations become manifests in git.** Export the operator's generated
   remediation objects, review them, and commit them as an `oac-apps`
   component (hub) or as NodePool config ConfigMaps / in-cluster components
   (workload clusters). Exceptions go in tailored profiles, as on jetty.
3. **ArgoCD applies; the next scan confirms.** A failing check after a merge
   is a regression, which is what `tests/verify.sh` T-03 already detects.
4. **Git history is the change record** (800-53 CM-3), and self-heal reverts
   undocumented changes (CM-6). The cost: **a hand-made fix in an incident is
   undone within minutes**, so a break-glass procedure (pause sync, fix,
   commit, resume) has to exist before the first incident.

New workload clusters then arrive compliant. Nothing is remediated after the
fact.

## 6. Hub-specific findings from reading `oac-apps`

- **Workload clusters are not FIPS** (§3). Fix before tenants depend on one,
  since it is likely a rebuild.
- **The etcd encryption key lives only on the hub.** `refreshInterval: "0"`
  generates it once; nothing pushes it elsewhere (read). If the hub is lost,
  a backup of a workload cluster's etcd cannot be decrypted. Key escrow (or a
  KMS) belongs in the design.
- **HCP namespaces ship a restrictive NetworkPolicy** that OAC has had to
  supplement per namespace (`docs/hypershift-issues.md`, read). The hub's own
  default-deny design must start from what HyperShift already creates.
- **Already compliance-relevant in OAC:** Keycloak SSO, cert-manager,
  tenant network isolation, no self-provisioning, per-project quotas and
  LimitRanges, `aescbc` etcd encryption, credentials out of git. These close
  or narrow jetty's B3 and B4 and several moderate checks — **to verify by
  scanning a workload cluster**.

## 7. What must be proven, in order

| # | Experiment | Needs | Settles |
|---|---|---|---|
| E1 | Compliance Operator in a hosted cluster: install, run `ocp4-moderate`, `ocp4-moderate-node`, `rhcos4-moderate`; record which checks are NOT-APPLICABLE, which fail because the control plane is invisible, and what the operator does with MachineConfig remediations | A dev hosted cluster (`oac-dev-workload0`/`1`) with admin | Whether scanning works at all on workload clusters |
| E2 | Deliver a few node remediations through `NodePool.spec.config`, then the full set; measure rollout and reboots under `InPlace` | Same, plus a spare agent or a pool that can reboot | Whether jetty's node hardening transfers |
| E3 | FIPS hosted cluster with GPU nodes; try changing `spec.fips` on an existing one | A spare agent with a GPU (billable while claimed) | §3 immutability; the GPU stack under FIPS on hosted workers |
| E4 | Workload-cluster API audit logs: where written on the hub, forwardable how | Hub admin | B1 for workload clusters |
| E5 | Workload-cluster etcd backup and restore, including key escrow | Hub admin, a disposable hosted cluster | Recovery for tenants |
| E6 | LUKS on the hub at install, and on agent-provisioned hosted workers | A hub install (dev) | §3 disk encryption |

E1 comes first: if the scanner cannot assess a hosted cluster, evidence for
workload clusters has to come from somewhere else, and the rest of the design
changes.

## 8. Build order (once E1–E2 are answered)

The charts for these steps are written (2026-10-13), in the fork's
`compliance-charts` branch; see [oac-apps/README.md](oac-apps/README.md)
for where they are and how they were checked against jetty.

**Hub**
1. Decide §3 items; install with FIPS and disk encryption.
2. Bootstrap ArgoCD from `oac-apps` (existing procedure).
3. Add the compliance components through a drop-in under `apps/<hub>/`
   rather than `hub-components`, so each hub opts in: Compliance Operator
   with tailored profiles and `autoApplyRemediations: false`, FIO,
   NetworkPolicies, etcd backup, ACS Central, log forwarding (when B1
   exists).
4. Scan; turn remediations into git (§5); repeat until only documented
   exceptions remain. jetty's PLAYBOOK phases apply, with git as the delivery.
5. `verify.sh`, adapted for the hub.

**Each workload cluster**
1. Values file with `fips: true`, `spec.configuration` (audit, image allowlist),
   NodePool `config` carrying the node hardening.
2. In-cluster components: Compliance Operator (scan only), FIO, ACS secured
   cluster, NetworkPolicies, quotas, `tlshd` where NFS is used, the GPU
   billing guard.
3. Scan, confirm, record evidence per cluster.

## 9. Not decided here

- Whether compliance components live in `oac-apps` or a separate repo the hub
  also reads. That is the `oac-apps` maintainers' call.
- ACS topology (one Central on the hub vs. one per environment).
- Which workload clusters hold CUI/ePHI at all. A cluster that never does
  can carry a lighter baseline — but the hub cannot, because it hosts every
  cluster's control plane.
