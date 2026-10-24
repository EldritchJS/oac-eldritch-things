# Rebuilding nist-dev-infra and nist-dev-workload0

*Draft, 2026-10-23. For review: not yet run. Open items are marked
**TODO**. Nothing here is torn down without the hub owner's explicit
go-ahead at the time.*

**What it produces today (2026-10-23):** a workload cluster at 1 moderate
failure (the cluster-wide proxy, a recorded gap) and 0 CIS, and a hub
that is **not yet compliant**: 15 moderate and 7 CIS failures, listed with
their fixes in 2.9. The hub's own controls (SSO, API server audit and
encryption, image allowlists, guardrails on its own namespaces) were
deferred while the work went into the workload cluster.

This is the order to rebuild the test hub and its first hosted cluster
from nothing, as they were actually built, so that someone other than the
original builder can do it. It sequences the steps and points to where
each is explained:

- [BUILD.md](../BUILD.md): how to build any compliant hub and workload
  cluster, and why.
- [README.md](README.md): what happened on this hub, stage by stage.
- [STORAGE-BRINGUP.md](STORAGE-BRINGUP.md): the storage prerequisites.

Times in this document are UTC unless they say EDT.

---

## 0. What is kept, and what is rebuilt

**Kept** (long-lived, reused by name):

- The FlashBlade realm `nist-dev-infra`, its certificate
  (`nist-dev-infra::realm-cert`) and its export policies.
- Route 53 zones (`nist.int.massopen.cloud`, `hcp.nist.int.massopen.cloud`)
  and their records, including `s3.nist-dev-infra...` (moc-aws [#59](https://github.com/CCI-MOC/moc-aws/pull/59)).
- moc-aws: the OIDC providers and roles for both clusters (`eso-*`,
  `cert-manager-*`), and the `moc-aws-cluster-operators` memberships.
- moc-keycloak: the `nist-dev-workload0` client and its secret.
- oac-apps: every values file on `main` and on the fork's test branch.
- AWS Secrets Manager: `cluster/nist-dev-infra/portworx`, `pure-cosi`,
  `nfs-tls-ca`, and the hosted cluster's `keycloak-oidc`.

**Rebuilt** (cluster-specific):

- Both clusters.
- Their credentials: the hub's kubeadmin kubeconfig, workload0's admin
  kubeconfig (it lives on the hub), ACS init bundles.
- Each cluster's OIDC signing keys. The issuer URLs stay the same, so the
  AWS providers stay valid, but the new keys must be uploaded (steps 2.3
  and 4.2).
- The COSI buckets for Loki and ACM observability, and their contents.

**TODO:** confirm the kept list with the owners of each (moc-aws,
FlashBlade, Keycloak) before teardown.

---

## 1. Teardown

**Only with the hub owner's explicit go-ahead.** Order matters: remove
the hosted cluster first, while the hub can still clean up after it.

1. Remove workload0 from oac-apps (`hosted-clusters/nist-dev-infra/nist-dev-workload0/`)
   by PR, and let the hub delete the HostedCluster. Stuck deletion:
   oac-apps `docs/hypershift-issues.md`.
2. Wipe workload0's workers before any reuse (800-171 3.8.3).
3. Delete the fork stage ApplicationSets on the hub
   (`nist-compliance-test`, `nist-compliance-test-managed`).
4. Reinstall the hub's nodes (step 2). This wipes them.
5. Delete the cluster-specific credentials listed in §0 from Secrets
   Manager, and the old ACS init bundles in Central (if Central survives
   that long; otherwise they die with it).

**TODO:** which COSI buckets to empty or delete, and who holds the
FlashBlade access to do it.

---

## 2. The hub

Upstream: oac-apps `docs/infra-cluster-deployment.md`. Details:
[BUILD.md](../BUILD.md) Part 1.

### 2.1 Hardware

- Three FC830 masters (compact), 176 threads each. These are the wrong
  shape for a FIPS hub (BUILD.md Part 1 step 1): **boot them with
  `nr_cpus=40`** ([nr-cpus-machineconfig.yaml](nr-cpus-machineconfig.yaml)).
  Without it, etcd crashes under TLS handshake load (README, "Stage C
  results" and "40 CPUs on the masters").
- Second port on the storage VLAN, untagged.

### 2.2 Install

In `ai-ivp`, as upstream, plus (BUILD.md Part 1 step 2):

- `fips_enabled: true`.
- An ECDSA or RSA SSH key (FIPS rejects Ed25519).
- `serviceAccountIssuer` =
  `https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/nist-dev-infra`,
  at install, so the existing AWS provider matches.
- Disk encryption: **not available** (E6). Recorded as an exception.
- Store the kubeadmin kubeconfig in the hub's secret store scope. Never in
  a repo.

Check FIPS on every node (BUILD.md Part 1 step 2) before going on.

### 2.3 OIDC keys, before anything uses AWS

The new install has new signing keys. Upload them before external-secrets
or cert-manager start (`ClusterOperatorAccess` profile, logged in):

```
oac-apps/bootstrap/setup-oidc.sh -n      # -n: the issuer is already set at install
curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/nist-dev-infra/.well-known/openid-configuration
```

### 2.4 Bootstrap ArgoCD

```
helm template bootstrap ./bootstrap --set hubName=nist-dev-infra | oc apply -f -
```

The hub's components come from CCI-MOC/oac-apps `main`, with the hub's
values already there. Use `applications.argoproj.io` when checking Argo.

### 2.5 Storage, TLS only, before any volume (stage S)

`hub-portworx` and `hub-nfs-tls` sync from main with the existing values
(`portworx.tls: true`; the realm certificate from `nfs-tls-ca`). Check:

```
../tests/hub-preflight.sh nist-dev-infra
oc get sc                          # pure-fb-nfsv4 (default), and nothing cleartext
oc -n nfs-tls get pods             # tlshd Ready on every node
```

If `hub-portworx` failed before the preflight passed, re-sync it by hand:
Argo does not retry a failed commit.

### 2.6 Object storage

`pure-cosi` and `object-storage-proxy` sync from main. The proxy verifies
the FlashBlade's certificate against its IP (oac-apps [#173](https://github.com/CCI-MOC/oac-apps/pull/173), [#174](https://github.com/CCI-MOC/oac-apps/pull/174)). Check
that a BucketClaim is Ready and that the hub resolves
`s3.nist-dev-infra.nist.int.massopen.cloud`. Then read the COSI driver's
log once: wrong realm or endpoint values fail quietly (BUILD.md I8).

### 2.7 The compliance stages, from the fork

Apply on the hub, one at a time, in order (README, "Stages"):

| File | Adds | Before applying |
|---|---|---|
| [stage-a.yaml](stage-a.yaml) | Compliance Operator | nothing |
| [stage-b.yaml](stage-b.yaml) | Admission policy, FIO, notice, etcd backup, ACS, guardrails, nfs-tls | Default StorageClass exists (2.5). After it: apply the hub's ACS init bundle by hand (`../manifests/05-*`), never committed |
| [stage-c.yaml](stage-c.yaml) | Node hardening, about 380 MachineConfigs. **Reboots every node** | Agree a time. Pause the master pool, apply, check the rendered configs, unpause (BUILD.md Part 1 step 5). Watch etcd threads with [watch-etcd-threads.sh](watch-etcd-threads.sh) |
| [stage-e.yaml](stage-e.yaml) | Audit logging: Loki on COSI, the forwarder | Object storage works (2.6) |

### 2.8 Scan, tailor, verify

BUILD.md Part 1 steps 6 and 7: scan, fix in git, and the admission policy
dry runs. Archive the first results as the hub's baseline.

### 2.9 What the hub does not pass yet

nist-dev-infra's scans of 2026-10-24 (UTC): `ocp4-moderate` 15 FAIL
(02:42), `ocp4-cis` 7 FAIL (02:18), `ocp4-moderate-node-master` 1 FAIL.
Fixed since the first count (19), on the fork: `resource-requests-quota`
(quotas for seven namespaces) and `audit-log-forwarding-uses-tls` (a
scanner false positive, tailored), in `325ad26`; the DaemonSet and
StatefulSet limits rules (operator namespaces exempted, `vendorLimits`),
in `8490e2c`. A rebuild following
this runbook reaches the same. Remove rows as fixes land.

| Failing (moderate; * also CIS) | Fix | Status |
|---|---|---|
| `ingress-controller-certificate`, `default-ingress-ca-replaced` | `cluster-certificates` values for the hub (`clusterDomain`, the prod issuer): Let's Encrypt API and apps certificates, as on workload0. The CA rule then gets workload0's `ingressCert` tailoring | oac-apps [#184](https://github.com/CCI-MOC/oac-apps/pull/184), open (ingress only). Then verify workload0's audit forwarding still reaches the hub's Loki |
| `idp-is-configured`*, `kubeadmin-removed`*, `oauth-or-oauthclient-inactivity-timeout`, `-token-maxage` | Hub SSO: a Keycloak client for the hub (moc-keycloak), `keycloak-oauth` values, and a `tokenConfig` option in that chart. Then remove the kubeadmin password by hand | Planned: needs the Keycloak client (computate) and a small chart change |
| `audit-profile-set`*, `api-server-encryption-provider-cipher`* | `cluster-certificates` hard-codes `audit.profile: Default` on the APIServer, and nothing enables etcd encryption; `compliance/oac-apps/patches/0001` does both. **etcd encryption is off on this hub.** Enabling it re-encrypts every Secret and ConfigMap: schedule it with someone who can power-cycle the masters | Needs agreement on the chart change (oac-apps maintainers) |
| `routes-rate-limit`, `route-ip-whitelist` | Annotate the routes made since stage D (16: workload0's hosted routes, ACM observability, ACS). IP allowlists need the allowed client ranges. Operator-owned routes that reset become recorded exceptions | Planned: fork values and `route-rate-limits.sh` |
| `resource-requests-limits-in-deployment` | Operator namespaces are exempted (`8490e2c`); the last two Deployments are oac-apps' own COSI controller and driver, which get requests and limits | oac-apps [#185](https://github.com/CCI-MOC/oac-apps/pull/185), open |
| `configure-network-policies-namespaces`* | Policies for 20 namespaces, many of them ACM, HyperShift and storage. Each needs its traffic measured first; a wrong policy cuts off a hub component | Partly planned; the rest go in the exception register |
| `ocp-allowed-registries`*, `-for-import`* | Inventory the hub's images (ACS lists them), then `platform-hardening` `imageConfig.enabled: true` | Planned: fork values, after the inventory |
| `cluster-wide-proxy-set` | None planned | POA&M gap, as on workload0 |
| `reject-unsigned-images-by-default` (node scan) | A signature policy for every allowed registry | POA&M |

---

## 3. What has to be true before workload0

- Hub stages A to E done. The hub's scans are not clean yet (2.9); the
  workload cluster does not depend on them.
- The hub's Central is up, so the cluster's SecuredCluster can join.
- `auditWriters.clusters` in the hub's audit-logging values lists
  `nist-dev-workload0` (it does on the test branch).

---

## 4. workload0

Upstream: oac-apps `docs/workload-cluster-deployment.md`. Details:
[BUILD.md](../BUILD.md) Part 2.

### 4.1 Workers

Two FC430s, booted from **this hub's** discovery ISO. Their storage NIC
needs `never-default` (oac-apps [#166](https://github.com/CCI-MOC/oac-apps/pull/166), already in the cluster's NodePool
values): otherwise a reboot can put `br-ex` on the wrong NIC.

### 4.2 The cluster

Its values are already on oac-apps main
(`hosted-clusters/nist-dev-infra/nist-dev-workload0/`), so the
HostedCluster is created as soon as the hub's `hosted-clusters`
ApplicationSet syncs. Then, in order:

1. **OIDC keys.** HyperShift sets the issuer; upload the new keys with
   the cluster's admin kubeconfig before external-secrets or cert-manager
   need AWS (the script used for this: `setup-oidc.sh -n`, as in
   BUILD.md I4).
2. **SSO.** The Keycloak client and secret are kept, and
   `oauth.mocsso.enabled: true` is in the values, so login works once
   oauth-openshift is up. HyperShift then removes kubeadmin. The OAuth
   route is internal: log in over the VPN.
3. **Certificates and secrets.** external-secrets, cert-manager and
   cluster-certificates sync with the values from oac-apps [#175](https://github.com/CCI-MOC/oac-apps/pull/175): a Let's
   Encrypt ingress certificate by DNS-01 in `hcp.nist.int.massopen.cloud`.
   [#175](https://github.com/CCI-MOC/oac-apps/pull/175) merged 2026-10-23; ESO's ClusterSecretStore is Valid.
   Checked: the certificate was issued in about two minutes once the
   ClusterIssuers synced, and the router serves it. A router pod created
   before the secret exists waits in ContainerCreating, then starts.
4. **COO.** Installs without its capacity dashboards (oac-apps [#170](https://github.com/CCI-MOC/oac-apps/pull/170)).

### 4.3 The compliance stages, from the fork

Apply on the hub, in order. Each lists everything so far:

| File | Adds | Before applying |
|---|---|---|
| [workload-stage-a.yaml](workload-stage-a.yaml) | Compliance Operator (hosted tailoring), FIO, notice | nothing |
| [workload-stage-b.yaml](workload-stage-b.yaml) | ACS SecuredCluster | Generate the cluster's init bundle in the hub's Central and apply it to the cluster's `stackrox` namespace by hand. Never committed |
| [workload-stage-c.yaml](workload-stage-c.yaml) | NetworkPolicies and quotas | If a policy cuts the cluster off from the hub, delete it with the admin kubeconfig: Argo cannot reach the cluster to fix it |
| [workload-stage-d.yaml](workload-stage-d.yaml) | Audit forwarding to the hub's Loki | The hub lists the cluster in `auditWriters.clusters` (§3) |

### 4.4 Scan and verify

BUILD.md Part 2 step 4. Expected (workload0, 2026-10-23):
`hosted-ocp4-moderate` **1 FAIL**, `hosted-ocp4-cis` **0 FAIL**, and the
worker node profiles compliant. The last failures and what closed them:

| Was failing | Closed by |
|---|---|
| `ocp-allowed-registries-for-import` (also CIS) | [#172](https://github.com/CCI-MOC/oac-apps/pull/172) |
| `oauth-or-oauthclient-inactivity-timeout`, `-token-maxage` | [#172](https://github.com/CCI-MOC/oac-apps/pull/172) sets them on the HostedCluster; tailored (`oauthTokens`), because HyperShift does not copy them to the guest |
| `default-ingress-ca-replaced` | [#175](https://github.com/CCI-MOC/oac-apps/pull/175)'s Let's Encrypt certificate; tailored (`ingressCert`), because the rule only reads `proxy/cluster` `trustedCA` |
| `resource-requests-limits-in-deployment`, `resource-requests-quota` | Appeared with External Secrets (#175): `external-secrets` added to the exempt regex, and given a quota |
| `cluster-wide-proxy-set` | Still fails: a POA&M gap, recorded in the SSP |

A new operator namespace on a hosted cluster brings these two quota and
limits failures with it, until its guardrails are added.

Archive the first results as the cluster's baseline.

---

## 5. Known failures, and what to do

| Symptom | Cause | Fix |
|---|---|---|
| moc-aws apply fails: "Please check .well-known/openid-configuration" | The OIDC documents were not uploaded yet | Upload (2.3 or 4.2), re-run the apply |
| An Argo app keeps failing with an error your fix already removed | Argo retries a failed sync at the commit it started with (five times, about 15 minutes) | Wait for the retries to end, or terminate the operation |
| New volumes fail; tlshd logs "Certificate signer not found" | tlshd reads its CA only at startup | `oc -n nfs-tls rollout restart daemonset/tlshd` |
| Every S3 request returns 503, proxy health checks pass | HAProxy verified the FlashBlade's certificate against the client's Host header | Fixed in oac-apps [#174](https://github.com/CCI-MOC/oac-apps/pull/174). The realm certificate must also be a CA (BUILD.md, storage notes) |
| Loki discards hosted audit lines | The application tenant's line size and rate limits | `loki.tenantLimits` in the hub's audit-logging values (already set) |
| COO never installs: Perses CRD missing | The dashboard needed a CRD the operator installs | Fixed in oac-apps [#170](https://github.com/CCI-MOC/oac-apps/pull/170) |
| A hosted cluster's API returns 500, "failing health checks: etcd"; etcd logs "took too long" | etcd's WAL file creation blocked on a stale NFS lock on the FlashBlade (2026-10-23, 17:05 to 18:30) | Delete the stale `member/wal/*.tmp` file in etcd-0, then delete the etcd-0 pod. Hosted etcd on NFS is not supported: a POA&M item. **TODO:** a better home for hosted etcd |
| Masters go NotReady in turn, etcd restarts | FIPS TLS handshakes on large-core nodes | `nr_cpus=40` (2.1) |
| A hosted cluster loses its compliance namespaces | An ApplicationSet deleted its Applications when the cluster left the placement | `preserveResourcesOnDeletion: true` (already set; BUILD.md Part 2 step 3) |

---

## 6. Changes during the rebuild

Every fix goes through a PR, as during the build:

- One commit per PR, whose message is the full description: why, and
  which clusters it changes and how. Open the PR with `gh pr create -f`.
- oac-apps needs two approvals. Name reviewers by topic.
- A PR that rolls workers or reboots nodes says so, and is merged by hand
  at an agreed time.

---

## 7. Still open

- The ACS chart is on main ([#181](https://github.com/CCI-MOC/oac-apps/pull/181)), but no ApplicationSet uses it
  yet; stage B still installs ACS from the fork.
- **TODO:** the stages come from the fork's `nist-dev-infra-test` branch.
  Moving the compliance charts to CCI-MOC/oac-apps main is a separate
  piece of work; until then the fork is part of the build.
- **TODO:** a home for hosted etcd that is not NFS.
- **TODO:** have someone other than the original builder walk through
  this before the teardown, and fix what is unclear.
