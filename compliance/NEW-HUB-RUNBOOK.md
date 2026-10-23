# A new compliant hub and workload cluster, from nothing

*Draft, 2026-10-23. For review: not yet run end to end. Open items are
marked **TODO**.*

This is every step to stand up a compliant (FIPS, NIST 800-171, HIPAA)
OAC hub and its first hosted workload cluster, including the long-lived
pieces that a rebuild of an existing pair keeps: DNS zones, the
FlashBlade realm, AWS roles, the Keycloak client and the oac-apps values.
Each step names the repo, who acts, an example PR from nist-dev-infra
(NDI) and nist-dev-workload0, and how to tell it is done.

Related:

- [BUILD.md](BUILD.md): the why behind each step, and the general rules.
- [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md): rebuilding NDI
  and workload0, keeping the long-lived pieces.
- [nist-dev-infra/README.md](nist-dev-infra/README.md): what happened on
  NDI, step by step.

Names below: `<hub>`, `<cluster>`, and `<zone>` for the hub's internal DNS
zone (NDI: `nist.int.massopen.cloud`).

---

## 0. Decide first

These block the build (BUILD.md, "Before either"):

- Which workloads hold CUI or ePHI, and so whether this hub is needed (P4).
- The system-use notice text (P5).
- The registry allowlist (P6).
- An audit and alert destination, or keep audit on the hub's Loki for
  now (P9).
- Disk encryption: no tested install path yet (P10, E6). Record it as an
  exception or wait.
- Hardware: see 3.1. The wrong shape costs weeks.

---

## 1. Day one: request in parallel

Open one tracking issue that links every PR below. Each has a different
owner, and most take days. Ask a named reviewer on each.

| # | What | Repo | Owner | NDI example | Done when |
|---|---|---|---|---|---|
| 1.1 | The hub's DNS zone in Route 53 | `moc-aws` | moc-aws maintainers | [#54](https://github.com/CCI-MOC/moc-aws/pull/54) | The zone exists |
| 1.2 | Delegate `<zone>` to it from internal DNS | `moc-dns` | DNS admins | [#33](https://github.com/CCI-MOC/moc-dns/pull/33) (after [#30](https://github.com/CCI-MOC/moc-dns/pull/30), [#31](https://github.com/CCI-MOC/moc-dns/pull/31)) | `dig NS <zone>` answers with Route 53 |
| 1.3 | Hub records: `api`, `api-int`, `*.apps` | `moc-aws` (in the zone) | moc-aws maintainers | [#54](https://github.com/CCI-MOC/moc-aws/pull/54) | They resolve on the VPN |
| 1.4 | A FlashBlade realm for the hub | `everpure-moc` `realms.yaml` | FlashBlade admins | [#26](https://github.com/CCI-MOC/everpure-moc/pull/26) | Merged |
| 1.5 | Run the realm playbook | `everpure-moc` | FlashBlade admins | (by hand) | `cluster/<hub>/portworx` in Secrets Manager |
| 1.6 | A realm certificate marked as a CA (BUILD.md storage notes) | on the FlashBlade | FlashBlade admins and hub owner | (by hand) | `<realm>::realm-cert` imported; `.crt` in `cluster/<hub>/nfs-tls-ca` |
| 1.7 | Membership in `moc-aws-cluster-operators` for the hub owner | `moc-aws` `sso-users.tf` | moc-aws maintainers | in [#60](https://github.com/CCI-MOC/moc-aws/pull/60) | `ClusterOperatorAccess` profile logs in |
| 1.8 | Storage VLAN, untagged, on each node's second port | switches | network admins | | DHCP lease on `br-storage` |
| 1.9 | Nodes on the management network, VPN only, inventory entries | `open-accelerator-infra` | infra admins | | Nodes PXE or ISO boot |

On NDI, the hub's records were first made by hand in `int.massopen.cloud`;
[#54](https://github.com/CCI-MOC/moc-aws/pull/54) copied them into the new
zone and created the delegation only after them, so the names never stopped
resolving. A new hub can put its records in the zone's PR from the start.

---

## 2. Before install: the AWS identity, in two halves

The hub's external-secrets and cert-manager authenticate to AWS through
the hub's OIDC issuer. AWS checks the issuer's documents when the
provider is created, so the order is fixed:

1. Open the moc-aws PR now: an `openshift_oidc_clusters` entry and
   `eso-<hub>`, `cert-manager-<hub>` roles, with cert-manager allowed in
   `<zone>` (NDI: [#53](https://github.com/CCI-MOC/moc-aws/pull/53)). **Do not merge yet.**
2. After install (3.3), upload the hub's OIDC documents.
3. Then merge and apply. Merging first fails with "Please check
   .well-known/openid-configuration" (moc-aws [#60](https://github.com/CCI-MOC/moc-aws/pull/60)), and the apply has to
   be re-run.

---

## 3. The hub

### 3.1 Hardware

- Three dedicated control-plane nodes plus workers (not compact), on
  current one- or two-socket hardware of about 40 cores (BUILD.md Part 1
  step 1). Under FIPS, large many-socket nodes crash etcd under TLS load.
- If only large nodes exist, boot them with `nr_cpus=40`
  ([nist-dev-infra/nr-cpus-machineconfig.yaml](nist-dev-infra/nr-cpus-machineconfig.yaml)).
- Nodes new, or wiped since their last use (3.8.3).

### 3.2 Install

`ai-ivp`, as upstream (oac-apps `docs/infra-cluster-deployment.md`), plus:

- `fips_enabled: true`; an ECDSA or RSA SSH key.
- `serviceAccountIssuer` =
  `https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/<hub>` at install.
  Setting it later restarts most pods.
- Disk encryption if 0 settled it.
- The kubeadmin kubeconfig into the hub's secret store scope, never a repo.

Check FIPS on every node before going on (BUILD.md Part 1 step 2).

### 3.3 OIDC documents, then the moc-aws merge

```
AWS_PROFILE=ClusterOperatorAccess-<account> oac-apps/bootstrap/setup-oidc.sh -n
```

Then merge and apply the PR from step 2. Done when the providers and
roles exist and `cluster/<hub>/aws-oidc` is written.

### 3.4 The hub in oac-apps

One PR for the hub's own values, as upstream (NDI: [#142](https://github.com/CCI-MOC/oac-apps/pull/142)), in
`values/<hub>/local-cluster/`:

| File | What | NDI example |
|---|---|---|
| `external-secrets.yaml` | The `eso-<hub>` role | [#142](https://github.com/CCI-MOC/oac-apps/pull/142) |
| `portworx.yaml` | Nodes, storage ports and subnet, `tls: true` | [#142](https://github.com/CCI-MOC/oac-apps/pull/142), [#148](https://github.com/CCI-MOC/oac-apps/pull/148), [#179](https://github.com/CCI-MOC/oac-apps/pull/179) |
| `nfs-tls.yaml` | `tlshd` on every node, CA from `cluster/<hub>/nfs-tls-ca`, `storageClass.enabled: false` | test branch |
| `cert-manager.yaml`, `external-dns-operator.yaml` | The `cert-manager-<hub>` role, the zone | on main |
| `openshift-gitops.yaml` | Argo controller at 8Gi, or it OOMs once clusters arrive | [#162](https://github.com/CCI-MOC/oac-apps/pull/162) |
| `acm.yaml`, `acm-placements.yaml`, `hcp-config.yaml`, `metallb.yaml` | ACM, agent install service, hosted-clusters router | [#156](https://github.com/CCI-MOC/oac-apps/pull/156) |

**Storage is TLS only from the first volume:** `portworx.yaml` and
`nfs-tls.yaml` go in together, or `nfs-tls` first (BUILD.md, "Storage is
TLS-only from its first volume").

### 3.5 Bootstrap

```
helm template bootstrap ./bootstrap --set hubName=<hub> | oc apply -f -
../tests/hub-preflight.sh <hub>         # storage steps, read-only
```

If `hub-portworx` failed before the preflight passed, re-sync it: Argo
does not retry a failed commit.

### 3.6 Object storage

| What | Where | NDI example |
|---|---|---|
| `cluster/<hub>/pure-cosi` with `PUREFB_REALM` and `S3_ENDPOINT=s3.<hub domain>` | Secrets Manager (from the realm playbook) | |
| pure-cosi overlay, `object-storage-proxy.yaml` with `verify: true` and the realm CA | `oac-apps` | [#168](https://github.com/CCI-MOC/oac-apps/pull/168), [#169](https://github.com/CCI-MOC/oac-apps/pull/169), [#173](https://github.com/CCI-MOC/oac-apps/pull/173), [#174](https://github.com/CCI-MOC/oac-apps/pull/174) |
| `s3.<hub domain>` → the proxy's ClusterIP | `moc-aws` | [#59](https://github.com/CCI-MOC/moc-aws/pull/59) |

Done when a BucketClaim is Ready and the COSI driver's log is clean
(wrong realm values fail quietly, BUILD.md I8).

### 3.7 Compliance components

Today these come from the fork's `nist-dev-infra-test` branch as stage
ApplicationSets ([nist-dev-infra/](nist-dev-infra/) `stage-*.yaml`),
because the compliance charts are not on oac-apps main yet. For a new hub,
copy those files with the hub's name, and copy NDI's compliance values
on the branch (`values/nist-dev-infra/local-cluster/`: compliance
operator, node hardening, platform hardening, etcd backup, ACS, guardrails,
audit logging).

Apply in order, as in [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md)
2.7: A (scanner), B (policy, FIO, notice, backup, ACS, guardrails;
apply the hub's ACS init bundle by hand), C (node hardening: reboots every
node; pause pools first), E (audit logging).

**TODO:** once the compliance charts are upstream (ACS: oac-apps [#181](https://github.com/CCI-MOC/oac-apps/pull/181)),
replace this step with values on main and the hub's ApplicationSets.

### 3.8 Scan, tailor, verify

BUILD.md Part 1 steps 6 and 7. Archive the first clean results.

---

## 4. Hosted clusters: what the hub needs first

| # | What | Repo | NDI example |
|---|---|---|---|
| 4.1 | Agent install service and FIPS discovery image | `oac-apps` | [#156](https://github.com/CCI-MOC/oac-apps/pull/156), [#158](https://github.com/CCI-MOC/oac-apps/pull/158) |
| 4.2 | Hub-wide values for every hosted cluster: FIPS, node hardening, audit profile, registry allowlist, import allowlist, token timeouts | `oac-apps` `hosted-clusters/<hub>/values.yaml` | [#157](https://github.com/CCI-MOC/oac-apps/pull/157), [#172](https://github.com/CCI-MOC/oac-apps/pull/172) (open) |
| 4.3 | Zones for hosted clusters (`hcp.<zone>`, `hcp-int.<zone>`), an external-dns user, ESO prefixes | `moc-aws` | [#55](https://github.com/CCI-MOC/moc-aws/pull/55) |
| 4.4 | cert-manager may answer DNS-01 in those zones | `moc-aws` | [#56](https://github.com/CCI-MOC/moc-aws/pull/56) |
| 4.5 | Wildcards to the hosted-clusters router, for Ignition, Konnectivity, OAuth, and the agents' `api` checks | `moc-aws` | [#57](https://github.com/CCI-MOC/moc-aws/pull/57), [#58](https://github.com/CCI-MOC/moc-aws/pull/58) |
| 4.6 | Hosted compliance values, all hosted clusters: tailoring, guardrails, ACS, audit forwarding | fork test branch, `values/<hub>/hosted-clusters/` | test branch |

---

## 5. The workload cluster

### 5.1 Requests (in parallel)

| # | What | Repo | NDI example | Done when |
|---|---|---|---|---|
| 5.1.1 | The cluster's values: name, NodePools, agent selectors, network, release | `oac-apps` `hosted-clusters/<hub>/<cluster>/` | [#159](https://github.com/CCI-MOC/oac-apps/pull/159), [#163](https://github.com/CCI-MOC/oac-apps/pull/163) | HostedCluster created |
| 5.1.2 | One storage NIC with `never-default`, or reboots can lose the node | same | [#166](https://github.com/CCI-MOC/oac-apps/pull/166) | |
| 5.1.3 | On a compact FIPS hub: `SingleReplica` control plane | same | [#164](https://github.com/CCI-MOC/oac-apps/pull/164) | |
| 5.1.4 | A Keycloak client, redirect URI from the HostedCluster's `oauthCallbackURLTemplate` with `mocsso` | `moc-keycloak` | [#54](https://github.com/CCI-MOC/moc-keycloak/pull/54) | Secret in `cluster/<hub>/hostedcluster/<cluster>/keycloak-oidc` |
| 5.1.5 | A FlashBlade realm, if the cluster gets storage | `everpure-moc` | [#29](https://github.com/CCI-MOC/everpure-moc/pull/29) | |

### 5.2 After the cluster exists

1. **Workers:** boot from the hub's discovery ISO, label as upstream.
2. **SSO:** `oauth.mocsso.enabled: true` (NDI: [#171](https://github.com/CCI-MOC/oac-apps/pull/171)). HyperShift removes
   kubeadmin. The OAuth route is internal: log in over the VPN.
3. **AWS identity, same order as the hub:** open the moc-aws PR
   (`openshift_oidc_clusters` entry, `eso-<cluster>`,
   `cert-manager-<cluster>`), upload the cluster's OIDC documents with
   its admin kubeconfig (`setup-oidc.sh -n`), then merge and apply (NDI:
   moc-aws [#60](https://github.com/CCI-MOC/moc-aws/pull/60)).
4. **Its component values:** external-secrets, cert-manager,
   cluster-certificates (a Let's Encrypt ingress certificate), and COO
   without capacity dashboards (NDI: [#175](https://github.com/CCI-MOC/oac-apps/pull/175), [#170](https://github.com/CCI-MOC/oac-apps/pull/170)).
5. **Compliance:** the workload stage files, A to D
   ([nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) 4.3), with the
   cluster's ACS init bundle by hand and the cluster in the hub's
   `auditWriters.clusters`. The hub-side audit alert comes from a
   `compliance.yaml` in the cluster's directory (NDI: [#167](https://github.com/CCI-MOC/oac-apps/pull/167)).
6. **Scan, tailor, verify:** BUILD.md Part 2 step 4. Expected leftovers
   are in [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) 4.4.

---

## 6. Known failures

The table in [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) §5
applies to any new pair.

---

## 7. How changes are made

- Every step above is a reviewed PR, except the by-hand items marked
  (the realm playbook, ACS init bundles, OIDC uploads).
- One commit per PR, whose message is the full description: why, and
  which clusters it changes and how. Open it with `gh pr create -f`.
- oac-apps needs two approvals.
- A change that reboots nodes or rolls workers says so and is merged at
  an agreed time.

---

## 8. Still open

- **TODO:** the compliance charts and stage files live on a fork. Until
  they are on oac-apps main, a new hub depends on that fork.
- **TODO:** disk encryption (E6).
- **TODO:** hosted etcd on FlashBlade NFS is test-only, and it failed on
  2026-10-23 (a stale NFS lock); a supported home for it.
- **TODO:** a central audit and alert destination (P9).
- **TODO:** SSO for the hub itself, not only its hosted clusters.
- **TODO:** a walk-through by someone who has not built a hub before.
