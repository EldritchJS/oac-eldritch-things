# Hub and spoke: building compliant OAC clusters

*Design, 2026-10-13. Every claim is marked as **read** (from source or
docs), **measured** (on jetty, or on the `nist-dev-infra` hub where it says
so) or **to verify**. Hub install state was measured on `nist-dev-infra`
on 2026-10-15 (§3). The first hosted cluster, `nist-dev-workload0`, was
built and scanned on 2026-10-22 (E1, first part of E2; §7).*

> Angle-bracket values are redacted internal addresses. See the top-level
> README § Conventions.

jetty answered *can this hardware and software stack be made compliant?*
(yes, with documented exceptions — [JETTY.md](JETTY.md)). The real OAC
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

### Compliant and non-compliant hubs

There may be both. The rules (decided 2026-10-13):

- **A non-compliant hub cannot have compliant workload clusters.** Their
  control planes, etcd and audit logs would live on it.
- **A compliant hub carries no non-compliant workload clusters.** A cluster
  that will never hold CUI or ePHI goes on a non-compliant hub.

So compliance is a property of the **hub**, and everything is switched per
hub, never per workload cluster. In `oac-apps` terms (built on the fork's
`compliance-charts` branch; example in
[oac-apps/examples/compliant-hub/](oac-apps/examples/compliant-hub/)):

| Per hub | Compliant hub | Non-compliant hub |
|---|---|---|
| Drop-in `apps/<hub>/compliance.yaml` | Compliance charts on the hub, and the in-cluster ones on **every** managed cluster (existing `all-managed-clusters` placement) | absent |
| `hosted-clusters/<hub>/values.yaml` | FIPS, node hardening ConfigMap, audit profile, registry allowlist, inherited by every hosted cluster | as today |
| Admission policy (`compliance-hub-policy`) | Hub refuses a HostedCluster without FIPS, the audit profile or secret encryption, and a NodePool without the hardening ConfigMap | absent |

There is no per-cluster label to set, so none to forget on a compliant hub
or to set by mistake on a non-compliant one. The second would be worse than
nothing: a cluster that scans clean with its control plane on a
non-compliant hub. The admission policy turns "we would not put one there"
into "the hub refuses": it holds even if git or a person asks for a
non-compliant cluster. Whether its field checks match the HostedCluster
API is **to verify** on a hub (it was only compiled against jetty, which
has no HyperShift types); start it in warn-only mode.

**What the two kinds of hub still share**, and so what the compliant hub's
boundary has to reach:

- **The `oac-apps` repository.** Everything on `main` goes to every hub.
  Whoever can merge there can change the compliant hub, so change control
  (800-53 CM-3/CM-5; 800-171 3.4.3/3.4.5) applies to the whole repo, not
  just the compliant hub's files. Branch protection and required review on
  `main` are part of the compliant hub's controls.
- **Shared services:** AWS Secrets Manager (admin kubeconfigs, etcd
  material if pushed), Keycloak, Route 53 and the OIDC bucket. Each one
  that the compliant hub depends on is in its boundary and must meet its
  baseline, whoever else uses it. A separate secret store, or separately
  scoped credentials, for the compliant hub is the simpler boundary.
- **Network and hardware pools.** A node that served a non-compliant
  cluster should be wiped and re-provisioned before it joins a compliant
  one (800-171 3.8.3, media sanitization), so agents should not move
  between hubs' inventories without that step.

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

### Measured on `nist-dev-infra` (2026-10-15)

`nist-dev-infra` is the first hub built for this work: a compact hub of three
FC830s, built from `CCI-MOC/oac-infra` PR #19 (`hub-images`, open at the
time). It runs OpenShift 4.22.14. Checked through the API, then on each node
with `oc debug`:

| Item | Result |
|---|---|
| FIPS | **On**, on every node. `fips: true` in the install config and the rendered MachineConfig. Kernel `fips_enabled=1` and `fips=1`, crypto policy `FIPS`, `fips-mode-setup --check` enabled, OpenSSL FIPS provider active |
| Disk encryption | **None.** The install asked for `tpmv2`, but FC830s have no TPM 2.0, so the root disk is plain xfs. Exception for this dev hub |
| What the encryption setting covers | Only the install disk. The installer's `diskEncryption` setting (AgentClusterInstall) does not reach the separate etcd disk, which `98-master-var-lib-etcd` formats as plain xfs. It would not reach LVMS disks either. Even with a TPM, etcd, the most sensitive data on a hub, would be unencrypted. Fix: Tang (no TPM needed), or LUKS for the extra disks in the install MachineConfigs. Both **to verify (E6)** |
| Disks per node | Two of 1.5 TB: OS and etcd. **No free disk for LVMS**, which OAC uses for hosted-cluster etcd (`lvms-vg0`). For the test, the hosted etcd went on FlashBlade NFS instead, accepted as a test-only gap (2026-10-20) |
| Time and DNS | `us.pool.ntp.org` and a public DNS resolver (read, install vars). Acceptable for dev; a compliant hub wants MOC-run servers |
| Installed | Nothing past the base install: no operators, no ArgoCD, no StorageClasses. All 34 cluster operators healthy |
| First scans (stage A, scan only) | Failures: `ocp4-cis` 9, `ocp4-moderate` 25, `ocp4-moderate-node` 4, `rhcos4-moderate` 191. Within one of jetty's first scan on every profile. 196 remediations generated, **none applied**, so scan-only works. Details and what closes each failure: [nist-dev-infra/README.md](nist-dev-infra/README.md) |

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
| Node hardening (~380 MachineConfigs, sshd `AllowUsers`, kernel args) | Compliance Operator auto-remediation + `manifests/21-*` | MachineConfigs from git | **`NodePool.spec.config`**: ConfigMaps holding MachineConfig, KubeletConfig, ContainerRuntimeConfig, ClusterImagePolicy (read, API reference). **Measured 2026-10-22:** the hub's hardening reached `nist-dev-workload0`'s workers at first boot; `rhcos4-moderate` 1 failure, node scans 0. Changing it rolls the pool; the chart uses `upgradeType: InPlace` (read) — reboot behaviour on bare-metal agents **to verify** |
| Compliance scanning | Compliance Operator, tailored profiles | same as jetty | Installable on HyperShift hosted clusters since CO 1.1.0; on ROSA HCP it loads node profiles only (read, release notes). **Measured 2026-10-22 (E1):** installs and scans on a hosted cluster with `PLATFORM=HyperShift`. Node scans work. Most platform failures (44 of 58 moderate) check control-plane settings the cluster cannot see; they need a tailored profile for hosted clusters. What happens to remediations with no MCO — **to verify** |
| File integrity (AIDE) | FIO, all nodes | same as jetty In-cluster FIO on workers. **Measured 2026-10-22: fails** — the AIDE pods' init container exits because `/etc/kubernetes/static-pod-resources` does not exist on hosted workers |
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

### What is automatic and what is not

Once a hub and its workload clusters are built, there are two kinds of
failure, and they are handled differently:

- **Drift from the approved configuration: automatic.** The approved
  configuration is what is in git. ArgoCD's self-heal restores in-cluster
  objects, and HyperShift restores node configuration from the NodePool.
  No person is involved. A failure of this kind rarely lasts until the next
  scan.
- **A change to the approved configuration: reviewed.** A failure that
  self-heal does not fix means one of these:
  - a Compliance Operator update added or changed rules;
  - the fix needs a local choice (for example, the chrony remediation
    points every node at `pool.ntp.org`);
  - the check cannot pass here and needs a documented exception.

  Each one is a change to what every cluster runs, so it goes through a
  PR.

Why the second kind is not applied automatically:

- **800-171 3.4.3** asks for changes to be reviewed and approved before
  they are made. Enforcing an approved configuration automatically meets
  that. A scanner changing the configuration on its own does not.
- **A node fix restarts every node on the hub.** Node hardening is one
  ConfigMap shared by every NodePool, so one bad remediation reaches every
  workload cluster. jetty's remediations were applied in stages for this
  reason.
- **A workload cluster cannot apply node fixes.** It has no MachineConfig
  operator (what the Compliance Operator does with node remediations there
  is part of E1). Applying them automatically would need a new component
  on the hub that rewrites the hardening ConfigMap outside git.

**Planned automation: a bot that opens the PR.** A job on the hub does the
following:

1. Collects new failures and their suggested remediations from every
   cluster.
2. Writes them into `compliance-node-hardening`, or into chart values, in
   the chart's file format.
3. Opens a PR that lists the clusters and checks affected.

A person reviews and merges it. ArgoCD then rolls it out, and the next scan
confirms. The only manual step left is the approval, and an assessor can
see it in the PR history. This is not written yet. It needs:

- a way to read results from every cluster (below);
- `scripts/export-remediations.py` extended to export remediations that
  were not applied (BUILD.md Part 1 step 6).

**Possible later: pre-approved in-cluster fixes.** A short, reviewed list
of low-risk remediations that are not node-level could be enforced by ACM
policies (`remediationAction: enforce`). Node-level remediations stay out
of that list. Decide after E1, when it is known which checks fail on
workload clusters.

**How results reach the hub: not designed yet.** Each cluster's results
are stored in that cluster, as `ComplianceCheckResult` objects. There are
two candidates for bringing them to the hub:

- **ACS (try first).** Every workload cluster already runs a
  SecuredCluster that reports to Central on the hub. Central can show
  Compliance Operator results from its secured clusters, which would give
  one view for every cluster. **To verify in E1.**
- **ACM governance.** A Policy on the hub that reports each cluster's scan
  status on the ACM dashboard.

Raw scan results (ARF), kept as evidence, also have to be archived per
cluster, as `tests/verify.sh` T-04 does on jetty. The design for that is
open.

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
| E1 | Compliance Operator in a hosted cluster: install, run `ocp4-moderate`, `ocp4-moderate-node`, `rhcos4-moderate`; record which checks are NOT-APPLICABLE, which fail because the control plane is invisible, and what the operator does with MachineConfig remediations | A dev hosted cluster (`oac-dev-workload0`/`1`) with admin | Whether scanning works at all on workload clusters **Done 2026-10-22 on `nist-dev-workload0`:** it works; results in nist-dev-infra/README.md |
| E2 | Deliver a few node remediations through `NodePool.spec.config`, then the full set; measure rollout and reboots under `InPlace` | Same, plus a spare agent or a pool that can reboot | Whether jetty's node hardening transfers **First part done 2026-10-22:** the full set applies at first boot. Rollout under `InPlace` not yet measured |
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
for where they are and how they were checked against jetty. The steps
below, written out as commands and checks, are in [BUILD.md](BUILD.md).

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

**Each workload cluster** (on a compliant hub; nothing here is per-cluster
opt-in, see §2)
1. FIPS, audit, image allowlist and NodePool `config` come from the hub-wide
   `hosted-clusters/<hub>/values.yaml`; the cluster's own values file only
   adds what is specific to it. The hub's admission policy refuses the
   cluster if any of it is overridden.
2. In-cluster components arrive by being managed by the hub: Compliance
   Operator (scan only), FIO, ACS secured cluster, NetworkPolicies, quotas,
   `tlshd` where NFS is used, the GPU billing guard.
3. Scan, confirm, record evidence per cluster.

## 9. Not decided here

- Whether compliance components live in `oac-apps` or a separate repo the hub
  also reads. That is the `oac-apps` maintainers' call.
- ACS topology (one Central on the hub vs. one per environment).
- Which workload clusters hold CUI/ePHI at all. One that never does goes on
  a non-compliant hub (§2); it cannot share a compliant hub with a lighter
  baseline.
