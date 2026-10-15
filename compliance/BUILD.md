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

### 2. Install: the decisions that cannot change later

In `ai-ivp` (`open-accelerator` branch), as upstream, plus:

1. **FIPS:** set `fips_enabled: true` in the hub's inventory group.
2. **SSH key:** ECDSA or RSA. FIPS rejects Ed25519.
3. **Disk encryption:** LUKS with TPM2 or Tang, set in the install
   configuration. How to do this with OAC's agent-install templates is
   **to verify (E6)**. Do not install without it: adding it later means a
   rebuild.
4. Generate the media, boot the nodes, and record the kubeadmin
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
- **`nfs-tls`:** `nfsServer`, `nfsPolicy`, and the CA (an `externalSecret`
  from the hub's secret store), if the hub mounts FlashBlade NFS.
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
3. Check the admission policy is in place:

```
oc get validatingadmissionpolicy compliant-hosted-clusters
oc get validatingadmissionpolicybinding compliant-hosted-clusters -o jsonpath='{.spec.validationActions}'   # ["Deny"]
```

4. Check that the hub refuses a non-compliant cluster, without creating
   one. This is a server-side dry run:

```
oc create --dry-run=server -f - <<'EOF'
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata: {name: policy-test, namespace: clusters}
spec:
  fips: false
  # ...minimal required fields...
EOF
```

The dry run must be denied by `compliant-hosted-clusters`. The field names
in the policy have **not yet been checked** against real HyperShift objects.
This is the first place they are.

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
