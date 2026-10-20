# Building a compliant hub and its workload clusters

*Runbook, 2026-10-14. Not yet run end to end: no compliant hub exists. Steps
that depend on an unfinished experiment are marked **to verify** with the
experiment number from [HUB-SPOKE.md](HUB-SPOKE.md) §7.*

This runbook adds steps to OAC's own procedures. It does not replace them.
Each part names the upstream document it builds on:

- `oac-apps/docs/infra-cluster-deployment.md` (hub)
- `oac-apps/docs/workload-cluster-deployment.md` (workload cluster)

Everything not listed here (VLANs, firewall, internal DNS, Keycloak client,
Pure realm, Route 53) is done as those documents say.

The rules behind it ([HUB-SPOKE.md](HUB-SPOKE.md) §2):

- Compliance is a property of the hub.
- A compliant hub carries only compliant workload clusters.
- A workload cluster is never made compliant on its own.

So the hub is built first, and a workload cluster on it is compliant because
of the hub-wide settings, not because of anything in its own files.

The file examples are in
[oac-apps/examples/compliant-hub/](oac-apps/examples/compliant-hub/), and
the charts are on the fork's `compliance-charts` branch
([oac-apps/README.md](oac-apps/README.md)).

---

## Before either: what has to exist first

These are not cluster steps, but the build cannot start without them.

| # | Needed | Why | Owner |
|---|---|---|---|
| P1 | The compliance charts merged into the repo the hub's ArgoCD reads (`CCI-MOC/oac-apps` `main`, or a separate repo; HUB-SPOKE.md §9) | The ApplicationSets point at `main`. The hosted-cluster changes (`hosted-cluster-nodepool-config`) are needed too | oac-apps maintainers |
| P2 | Branch protection and required review on that repo's `main` | Whoever can merge can change the compliant hub (CM-3/CM-5, 3.4.3/3.4.5) | oac-apps maintainers |
| P3 | A decision on how the hub's API audit settings are delivered (`patches/0001`, `cluster-certificates`) | Otherwise ArgoCD resets the audit profile to `Default` | oac-apps maintainers |
| P4 | Which workloads hold CUI or ePHI, and so which hub is compliant | Decides whether this hub is needed at all | Compliance office |
| P5 | The approved system-use notice text | `platform-hardening` will not render without it | Legal or compliance office |
| P6 | The registry allowlist inventory | A missing registry stops pods from pulling | Cluster owners |
| P7 | NTP servers, if not `pool.ntp.org` | Tailor `var-multiple-time-servers` **before** exporting node remediations | MOC infrastructure |
| P8 | A secret store scope (or a separate store) and credentials for this hub only | Shared services are in the compliant hub's boundary | AWS and Keycloak owners |
| P9 | An audit and alert destination (B1) | Without it, audit records last hours (on jetty, 5.8 h) | Security or SIEM owners |
| P10 | A tested way to install with disk encryption (E6) | It cannot be added after install | Hub team |
| P11 | At least two FlashBlade admins, each with their own account, and the playbook's token in a shared, audited store | The realm steps need FlashBlade access; sharing it keeps hub builds moving | FlashBlade admins |

### Hub infrastructure: request all of it on day one

Every OAC hub needs these outside the cluster. They have different
owners, so request them all when the hub is planned, in parallel, from one
tracking issue that links each PR. Request a named reviewer on each PR. The storage steps in more detail:
[nist-dev-infra/STORAGE-BRINGUP.md](nist-dev-infra/STORAGE-BRINGUP.md).

| # | Needed | Where (example) | Owner | Done when |
|---|---|---|---|---|
| I1 | FlashBlade realm | `everpure-moc` `realms.yaml` (#26) | FlashBlade admins | PR merged |
| I2 | Realm playbook run | `everpure-moc` `ansible/flashblade-realm.yaml` | FlashBlade admins | `cluster/<hub>/portworx` exists |
| I3 | Signing keys in S3, issuer set | `oac-apps/bootstrap/setup-oidc.sh`; needs S3 write on `oac-clusters-oidc` | Hub owner | The OIDC document is public, and the hub's issuer matches it |
| I4 | OIDC provider and `eso-<hub>`, `cert-manager-<hub>` roles | `moc-aws` `openshift_oidc_clusters`, `cert-manager-policies.tf` (#53). The PR can open on day one, but merge it after I3: AWS reads the hub's OIDC document when it creates the provider | moc-aws maintainers | `cluster/<hub>/aws-oidc` exists |
| I5 | Storage VLAN untagged on each node's second port, reaching DHCP, the gateway and the FlashBlade | Switch configuration | Network admins | Each node's `br-storage` has a DHCP lease (after I6) |
| I6 | The hub's values: `external-secrets.yaml`, and `portworx.yaml` with `portworx.tls: true` and `nfs_policy: export-policy-tls` (CCI-MOC/oac-apps#148) | `oac-apps` `values/<hub>/local-cluster/` (#142) | Hub owner | `hub-external-secrets` and `hub-portworx` Synced; `pure-fb-nfsv4` mounts with `xprtsec=tls` |
| I7 | `tlshd` on every node, before the first volume: the realm certificate in `cluster/<hub>/nfs-tls-ca`, and the `nfs-tls` values with `storageClass.enabled: false` | AWS Secrets Manager; `oac-apps` `values/<hub>/local-cluster/nfs-tls.yaml` | Hub owner (the certificate comes from the FlashBlade admins) | `tlshd` Ready on every node, one default StorageClass that mounts with `xprtsec=tls`, and no FlashBlade volume without it |

`tests/hub-preflight.sh <hub>` checks I2 to I7, read-only. Run it before
calling any of them done.

**Storage is TLS-only from its first volume.** A node that has a cleartext
NFS mount to the FlashBlade reuses that session for later `xprtsec=tls`
mounts to the same FlashBlade. On a TLS-only export the mount then fails
with `Operation not permitted`. On an export that allows cleartext, the
mount most likely succeeds over the cleartext session, unencrypted.
Standard hub components, such as ACS and Perses, claim volumes as soon as a
default StorageClass exists. So if the default class is ever cleartext,
volumes land on it, and they have to be recreated later (nist-dev-infra,
2026-10-19). To avoid that, a compliant hub has no cleartext FlashBlade
class at all:

- `portworx.tls: true` makes the hub's only FlashBlade class,
  `pure-fb-nfsv4`, a TLS class, and it stays the default. Set it in I6,
  so the class is TLS from the moment Portworx creates it.
- Merge I6 and I7 together, or I7 first. A TLS mount needs `tlshd` on the
  node, and `tlshd` needs the certificate.
- The FlashBlade realm should refuse cleartext as well: on a compliant
  realm, the cleartext `export-policy` also requires TLS. Keep the policy
  rather than deleting it: the CSI driver creates any policy a StorageClass
  names that does not exist, with its own defaults. **To agree with the
  FlashBlade admins** (CCI-MOC/everpure-moc#28: `tls_only` realms).
- The `flashblade-nfs-tls` admission policy in `compliance-hub-policy`
  (`storage.requireNfsTls`, on by default) refuses a FlashBlade StorageClass
  without `xprtsec=tls`, and a FlashBlade volume created without it. Turn
  it on only once the hub's Portworx class is TLS (`portworx.tls: true`):
  it would refuse the cleartext class when ArgoCD replaces it. Tested on
  nist-dev-infra on 2026-10-19 (Part 1 step 7).
- Re-running the realm playbook makes a new certificate. Update
  `cluster/<hub>/nfs-tls-ca` when that happens, or every mount fails.

I6 can merge before the others, and is a useful test of I5: the storage
bridges come up as soon as it applies. But until I2 to I4 are done, the
`hub-portworx` sync fails, and ArgoCD does not retry the same commit. When
the preflight passes, re-sync `hub-portworx` by hand.

---

## Part 1: the compliant hub

Upstream: `infra-cluster-deployment.md`. Hub name below: `<hub>`.

### 1. Hardware

1. Use nodes that are new, or that were wiped and re-provisioned after any
   earlier use (800-171 3.8.3). Do not take nodes from a non-compliant hub's
   pool without that step.
2. Put the hub on the management network, VPN-only. Do not expose the hub
   API publicly (HUB-SPOKE.md §3).
3. Networking, firewall and `open-accelerator-infra` inventory: as upstream.
4. **A standard layout: three dedicated control-plane nodes, plus workers.**
   Not compact. A drain then moves workloads onto workers, never onto the
   nodes that run etcd.
5. **Control-plane nodes on current, one- or two-socket hardware, about
   40 cores.** Under FIPS, every TLS handshake etcd serves is an OpenSSL
   call that holds a thread, and contended locks get slower with more
   cores and more sockets. On nist-dev-infra's 4-socket, 176-thread
   Broadwell nodes, reconnection bursts after drains pushed etcd past its
   4,096-thread limit and crashed it. Extra cores add no handshake
   throughput, only contention ([nist-dev-infra/README.md](nist-dev-infra/README.md),
   "Why etcd had thousands of handshakes in flight" and after).

### 2. Install: the decisions that cannot change later

In `ai-ivp` (`open-accelerator` branch), as upstream, plus:

1. **FIPS:** set `fips_enabled: true` in the hub's inventory group.
2. **SSH key:** ECDSA or RSA. FIPS rejects Ed25519.
3. **Disk encryption:** LUKS with TPM2 or Tang, set in the install
   configuration. How to do this with OAC's agent-install templates is
   **to verify (E6)**. Do not install without it: adding it later means a
   rebuild.
4. **Service account issuer:** set `serviceAccountIssuer` to
   `https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/<hub>` in the
   install configuration. Setting it later, as `setup-oidc.sh` offers to,
   invalidates every service account token and restarts most pods.
   Where OAC's install templates take it is **to verify**.
5. Generate the media, boot the nodes, and record the kubeadmin
   credentials in the hub's own secret store scope (P8), as upstream.

Check before going further. If any check fails, reinstall:

```
oc get cm cluster-config-v1 -n kube-system -o yaml | grep fips     # fips: true
for n in $(oc get nodes -o name); do
  oc debug $n -q -- chroot /host sh -c \
    'cat /proc/sys/crypto/fips_enabled; lsblk -o NAME,TYPE | grep crypt'
done                                                               # 1, and a crypt device
```

### 3. Bootstrap ArgoCD

As upstream:

```
helm template bootstrap ./bootstrap --set hubName=<hub> | oc apply -f -
```

Use the full name, `applications.argoproj.io`, when checking ArgoCD.
ACM installs a second `Application` type (`app.k8s.io`), and plain
`oc get applications` then lists that one instead, which is empty.

### 4. The hub's oac-apps PR

This is one PR to the repo, with the hub's usual files plus the compliance
files. Copy them from `examples/compliant-hub/` and replace `oac-dev-infra`
with `<hub>`:

| Example file | Goes to | Fill in |
|---|---|---|
| `apps-compliance.yaml` | `apps/<hub>/compliance.yaml` | Hub name in the value file paths |
| `hosted-clusters-values.yaml` | merged into `hosted-clusters/<hub>/values.yaml` | Registry allowlist (P6) |
| `values.yaml`, one section per `# file:` line | `values/<hub>/...` | Notice text (P5), Central endpoint, etcd-backup image digest, StorageClass, audit settings (P3) |

Also set:

- **`compliance-hub-policy`:** this is a new hub with no hosted clusters
  yet, so leave the chart default (`Deny`). Do not copy the example's
  `[Warn, Audit]` line; that line is for a hub that already has clusters.
- **`nfs-tls`:** the `tlshd` image digest and the CA (an `externalSecret`
  from `cluster/<hub>/nfs-tls-ca`), with `storageClass.enabled: false`: the
  hub's Portworx class is the TLS class (I6, I7).
- **`namespace-guardrails`:** the hub's own namespaces. Start from what
  HyperShift creates in its control-plane namespaces (HUB-SPOKE.md §6).
- **Log forwarding:** when B1 exists (P9).

### 5. First sync: node hardening reboots every node

`compliance-node-hardening` adds about 380 MachineConfigs. Before the PR
merges, pause the pools so each node reboots once, not once per rule:

```
oc patch mcp master worker --type=merge -p '{"spec":{"paused":true}}'
```

Merge. Wait for ArgoCD to sync, then check the rendered configs:

```
oc get applications.argoproj.io -n openshift-gitops      # all Synced, Healthy
oc get mc | grep -c '^75-'                               # about 380
oc get mcp                                               # UPDATED=False, paused
```

Unpause one pool at a time, starting with `worker` on a standard hub:

```
oc patch mcp worker --type=merge -p '{"spec":{"paused":false}}'
oc wait mcp/worker --for=condition=Updated --timeout=60m
oc patch mcp master --type=merge -p '{"spec":{"paused":false}}'
oc wait mcp/master --for=condition=Updated --timeout=60m
```

A compact hub has only `master` nodes, so unpausing `master` restarts every
node, one at a time.

**Expect etcd to crash on a compact FIPS hub, or on hardware like
nist-dev-infra's** (step 1, items 4 and 5). There, each drain moved a node's
workloads onto the other two, TLS reconnections held enough threads in
OpenSSL to push etcd past its limit of 4,096, and it crashed. The first
drain cost about ten minutes of API availability; all three recovered
without intervention. Upgrades drain nodes the same way. On such a hub,
record etcd's threads during the rollout with
[nist-dev-infra/watch-etcd-threads.sh](nist-dev-infra/watch-etcd-threads.sh),
and allow a quiet window. Details:
[nist-dev-infra/README.md](nist-dev-infra/README.md), "Stage C results".

### 6. Scan, fix in git, repeat

The Compliance Operator only scans (`autoApplyRemediations: false`). Each
round:

1. Wait for the scans (`oc get compliancesuite -n openshift-compliance`).
2. List the failures:
   `oc get compliancecheckresult -n openshift-compliance -l compliance.openshift.io/check-status=FAIL`.
3. For each failure, choose one of these:
   - **A remediation exists:** review the operator's suggestion
     (`oc get complianceremediation <name> -n openshift-compliance -o yaml`,
     `.spec.current.object`). Add it to
     `charts/compliance-node-hardening/files/` in the same format as the
     existing files, and open a PR. Do not set `apply: true` on the hub:
     the operator would then own a MachineConfig that ArgoCD does not.
     `scripts/export-remediations.py` only exports remediations that were
     applied (it was written to copy jetty's). For a scan-only hub it needs
     an option to export the ones that were not applied. That option has
     not been written yet.
   - **Fixed by configuration:** change the chart values and open a PR.
   - **Not fixable, or not applicable:** add it to the tailored profile with
     a reason (the exceptions record), and open a PR.
4. After the merge, the next scan confirms. A check that comes back as
   failing is a regression.

Repeat until only documented exceptions remain. The node remediations come
from jetty, so the hub should start close to clean. The platform checks
(`ocp4-moderate`) are the hub's own.

### 7. Verify and record

1. Run `tests/verify.sh` adapted for the hub. It needs these changes:
   - T-01: all nodes.
   - T-03: the hub's baseline.
   - T-05: Central.
   - Remove the GPU tests.
2. Archive the first clean scan results (raw ARF) and the exceptions list.
   That is the hub's baseline evidence.
3. Check the admission policies are in place:

```
oc get validatingadmissionpolicy compliant-hosted-clusters flashblade-nfs-tls
for p in compliant-hosted-clusters flashblade-nfs-tls; do
  oc get validatingadmissionpolicybinding $p -o jsonpath='{.spec.validationActions}{"\n"}'   # ["Deny"]
done
```

   Check that the hub refuses a cleartext FlashBlade StorageClass, without
   creating one:

```
oc create --dry-run=server -f - <<'EOF'
{"apiVersion": "storage.k8s.io/v1", "kind": "StorageClass",
 "metadata": {"name": "policy-test"}, "provisioner": "pxd.portworx.com",
 "mountOptions": ["nfsvers=4.1", "tcp"],
 "parameters": {"backend": "pure_file", "pure_nfs_server": "nfs-server", "pure_nfs_policy": "export-policy"}}
EOF
```

   It must be denied by `flashblade-nfs-tls`. With `"xprtsec=tls"` added to
   `mountOptions`, the same dry run must be accepted. On nist-dev-infra
   (2026-10-19) both did.

4. Check that the hub refuses a non-compliant cluster, without creating
   one. Render a HostedCluster and a NodePool from the `hosted-cluster`
   chart with the hub's values, and dry-run them on the server. The
   namespace is `default` because `clusters` does not exist until the
   first cluster:

```
cat > /tmp/policy-test.yaml <<'EOF'
clusterName: policy-test
namespace: default
nodePools: [{name: compute, replicas: 1, agentLabelSelector: {x: y}}]
EOF
render() {
  helm template t charts/hosted-cluster \
    -f hosted-clusters/<hub>/values.yaml -f /tmp/policy-test.yaml \
    --show-only templates/hostedcluster.yaml --show-only templates/nodepool.yaml "$@"
}
render | oc apply --dry-run=server -f -                                    # both accepted
render --set fips=false | oc apply --dry-run=server -f -                   # HostedCluster denied
render --set apiServer.audit.profile=Default | oc apply --dry-run=server -f -  # denied
render --set-json 'nodePoolConfig=[]' | oc apply --dry-run=server -f -     # NodePool denied
```

   Each denial must name `compliant-hosted-clusters`. On nist-dev-infra
   (2026-10-20) all four checks behaved as above, as did a HostedCluster
   with `spec.secretEncryption` removed (denied). That was the first check
   of the policy's field names against real HyperShift objects.

Only then is the hub ready for workload clusters.

---

## Part 2: a compliant workload cluster

Upstream: `workload-cluster-deployment.md`. Cluster name below: `<cluster>`,
on the compliant hub `<hub>`.

Nothing in this part turns compliance on. It comes from the hub. The steps
are about not undoing it, and then checking it.

### 1. Hardware

1. Use worker nodes that are new or wiped (as for the hub, 3.8.3).
2. Disk encryption on agent-provisioned hosted workers: how to request it
   is **to verify (E6)**. Until that is answered, a workload cluster's
   nodes are not encrypted at rest. Record it as an exception, or wait.
3. Networking, firewall, inventory: as upstream. Boot the nodes from **this
   hub's** agent discovery ISO:

```
oc get infraenv -n hardware-inventory hardware-inventory -o jsonpath='{.status.isoDownloadURL}'
```

The agents appear with `oc get agents -n hardware-inventory`. Label them as
upstream.

4. If the cluster's API or ingress will be public, decide that now, and
   record it in the boundary description.

### 2. The cluster's oac-apps PR

As upstream, with these rules:

- **`hosted-clusters/<hub>/<cluster>/values.yaml`** holds only what is
  specific to this cluster: name, NodePools, agent selectors, network
  details. Do **not** set any of these:
  - `fips`
  - `nodePoolConfig`
  - `apiServer.audit`
  - `imageConfig`

  They come from the hub-wide `hosted-clusters/<hub>/values.yaml`. If a
  cluster overrides one of them, the hub refuses the cluster. Secret
  encryption (`aescbc`) is built into the chart's template, so there is no
  value to override.
- A NodePool's own `config` list is allowed. The hub-wide
  `compliance-node-hardening` entry is always added in front of it.
- **`values/<hub>/<cluster>/`** holds the cluster's own component values,
  for example:
  - `rhacs.yaml` with `securedCluster.clusterName: <cluster>`
  - `namespace-guardrails.yaml` for the cluster's namespaces
  - `nfs-tls.yaml` if it uses FlashBlade NFS
- Nothing goes in `apps/<hub>/`. The compliance ApplicationSets already
  cover every cluster the hub manages.

### 3. Merge: what happens, in order

1. ArgoCD on the hub renders the `HostedCluster` and `NodePool`s.
2. The hub's admission policy checks them:
   - the HostedCluster: FIPS, the audit profile and secret encryption;
   - each NodePool: the hardening ConfigMap.

   If a check fails, the sync fails, and ArgoCD shows the policy's message.
   Fix the values; do not change the policy.
3. HyperShift starts the control plane on the hub and installs the agents.
   The nodes take the hardening ConfigMap as part of their first boot
   configuration. Whether that adds a reboot, and how `InPlace` upgrades
   roll it out later, is **to verify (E2)**.
4. The cluster joins ACM as a ManagedCluster. The `all-managed-clusters`
   placement picks it up, and the `managed-compliance` ApplicationSet
   deploys these components to it:
   - Compliance Operator (scan only, worker profiles)
   - FIO
   - namespace guardrails
   - platform hardening (the notice)
   - `tlshd`
   - an ACS SecuredCluster

### 4. Verify and record

From the hub:

```
oc get hostedcluster <cluster> -n clusters -o jsonpath='{.spec.fips} {.spec.configuration.apiServer.audit.profile}'
oc get nodepool -n clusters -o custom-columns=NAME:.metadata.name,CONFIG:.spec.config[*].name
```

In the workload cluster:

```
for n in $(oc get nodes -o name); do
  oc debug $n -q -- chroot /host cat /proc/sys/crypto/fips_enabled   # 1
done
oc get compliancesuite -n openshift-compliance
oc get compliancecheckresult -n openshift-compliance -l compliance.openshift.io/check-status=FAIL
oc get fileintegritynodestatus -n openshift-file-integrity
```

The ACS SecuredCluster should show as healthy in Central.

What the scan reports inside a hosted cluster is **to verify (E1)**: its
control plane is on the hub, so some platform checks will report "not
applicable" or fail. Until E1 is answered, read failures against the
results expected from E1, not against jetty's.

Then archive this cluster's first scan results as its baseline evidence.

### 5. Afterwards

- **Failures after the build** are handled as HUB-SPOKE.md §5 ("What is
  automatic and what is not") describes:
  - drift is reverted without anyone acting;
  - anything else becomes a reviewed PR.

  A bot to open those PRs is planned, not written. Until then, a person
  checks each cluster's results and writes the PR.
- **Node hardening changes** are made once, in the chart, for the whole hub.
  Every NodePool on the hub then rolls (to verify, E2). Schedule the change
  like a maintenance window.
- **Exceptions** for one cluster go in a tailored profile in that cluster's
  `values/<hub>/<cluster>/compliance-operator.yaml`, with a reason.
- **Removing the cluster:** see the upstream notes on stuck deletion
  (`docs/hypershift-issues.md`). Wipe its nodes before they are reused
  anywhere (3.8.3).
- **A cluster that no longer needs to be compliant** moves to a
  non-compliant hub, which means rebuilding it there. It does not stay on
  this hub with lighter settings.
