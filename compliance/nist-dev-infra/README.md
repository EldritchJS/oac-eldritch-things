# Testing the compliance charts on nist-dev-infra

`nist-dev-infra` is the first hub built for this work (HUB-SPOKE.md §3,
"Measured on nist-dev-infra"). It runs OAC's standard hub components from
`CCI-MOC/oac-apps` `main`. The compliance charts are not there yet, so they
are added by hand, from the fork:

| Where | What |
|---|---|
| [EldritchJS/oac-apps](https://github.com/EldritchJS/oac-apps), branch `nist-dev-infra-test` | `compliance-charts` plus `values/nist-dev-infra/local-cluster/`: the hub's values |
| `stage-a.yaml`, `stage-b.yaml`, `stage-c.yaml` (here) | One ApplicationSet, `nist-compliance-test`, that points ArgoCD at that branch. Each stage adds to the last |

This is a test setup. A compliant hub would get its compliance charts as an
`apps/<hub>/` drop-in from the repo it already reads (BUILD.md Part 1 step 4).

## Stages

| Stage | Adds | Reboots |
|---|---|---|
| A | Compliance Operator, scanning the stock profiles with no tailoring: a baseline of a fresh FIPS hub | none |
| B | Admission policy, FIO, system use notice, etcd backup, ACS (Central and the hub's SecuredCluster), NetworkPolicies and quotas for those namespaces | none |
| C | Node hardening: about 380 MachineConfigs | **every node**. On this compact hub that is the whole cluster, one node at a time |

Apply a stage:

```
KUBECONFIG=$HOME/kubeadmin-nist-dev-infra oc apply -f stage-a.yaml
```

Remove everything the stages installed:

```
KUBECONFIG=$HOME/kubeadmin-nist-dev-infra oc delete applicationset nist-compliance-test -n openshift-gitops
```

Node hardening is the exception. Deleting its MachineConfigs is a second
rollout, with a second round of reboots.

## Before each stage

- **A:** nothing. The hub has no storage yet: Portworx is not configured
  for it (upstream `docs/pure-storage-configuration.md`: a FlashBlade realm,
  the storage network, and `values/nist-dev-infra/local-cluster/portworx.yaml`
  in CCI-MOC/oac-apps). So raw result storage is off. Results are still
  kept as `ComplianceCheckResult` objects; only the raw ARF files are
  skipped. Turn it back on, with the class, once storage exists.
- **B:** a default StorageClass, for the ACS Central database and etcd
  backups, so it waits for Portworx. The hub's SecuredCluster also needs an init bundle from Central
  (as on jetty, `manifests/05-*`). It is a credential, so it is applied by
  hand and never committed. NetworkPolicies may fail for a few minutes,
  until their namespaces exist, and then succeed on retry.
- **C:** agree a time with the hub's owner. Pause the master pool, apply,
  check the rendered config, then unpause (BUILD.md Part 1 step 5).

## Checked before applying (2026-10-15)

- All eight charts render with the hub's values.
- Server-side dry run on the hub: every object whose type exists was
  accepted. The rest were rejected only because their operator or namespace
  is not there yet.
- The three stage files pass a dry run too.
- `nist-dev-infra-test` is pushed to the fork; ArgoCD reads it from GitHub.

Not set for this hub, on purpose:
- the registry allowlist, until the hub's images have been inventoried;
- NFS over TLS, unless the hub mounts FlashBlade NFS;
- node hardening on NodePools, until there is a hosted cluster.

## Stage A results (2026-10-15)

Applied at 13:46 EDT. Compliance Operator v1.10.0 (as on jetty) installed
through ArgoCD from the fork, and the last scan finished at 13:55. Raw
result storage is off; the results are the `ComplianceCheckResult` objects.

| Scan | Pass | Fail | Manual | jetty, first scan (fails) |
|---|---|---|---|---|
| `ocp4-cis` (platform) | 59 | **9** | 21 | 10 |
| `ocp4-cis-node` (masters) | 94 | **0** | 0 | — |
| `ocp4-moderate` (platform) | 78 | **25** | 22 | 25 |
| `ocp4-moderate-node` (masters) | 107 | **4** | 3 | 4 |
| `rhcos4-moderate` (masters) | 43 | **191** | 4 | 191 per node |

A fresh FIPS install of OpenShift 4.22 starts where jetty did. So jetty's
remediation work should carry over to OAC hubs.

**Scan-only works.** The operator generated 196 remediations and applied
none (`spec.apply: false` on all of them). No `75-*` MachineConfigs exist.
`autoApplyRemediations: false` holds, so nothing changes a node until git
says so.

### What closes each failure

| Failures | Closed by |
|---|---|
| `rhcos4-moderate`: all 191 (4 high, 15 low, 168 medium, 4 unknown) | Stage C, node hardening |
| `ocp4-moderate-node`: 3 `directory-access-var-log-*-audit`, `reject-unsigned-images-by-default` | Stage C (jetty went to 0) |
| `file-integrity-exists` | Stage B (FIO) |
| `banner-or-login-template-set`, `openshift-motd-exists` | Stage B (system use notice) |
| `configure-network-policies-namespaces` (CIS and moderate), `resource-requests-quota` | Stage B covers only its own namespaces. The rule checks every non-platform namespace, so it also needs the standard hub components' namespaces |
| `ocp-allowed-registries`, `ocp-allowed-registries-for-import` (CIS and moderate) | Stage B with the registry allowlist on. Off until the hub's images are inventoried |
| `audit-profile-set`, `api-server-encryption-provider-cipher` (CIS and moderate) | The APIServer object, owned by upstream `cluster-certificates`: needs `patches/0001` or the maintainers' alternative |
| `idp-is-configured`, `kubeadmin-removed` (CIS and moderate), `oauth-or-oauthclient-inactivity-timeout`, `oauth-or-oauthclient-token-maxage` | Keycloak (`keycloak-oauth`, standard hub setup), then removing kubeadmin, and OAuth token settings |
| `ingress-controller-certificate`, `default-ingress-ca-replaced` | `cluster-certificates` (cert-manager), once it syncs for this hub |
| `audit-log-forwarding-enabled` (CIS and moderate), `audit-log-forwarding-uses-tls` | B1, the audit destination |
| `file-integrity-notification-enabled` | Alerting on FIO results (with B1) |
| `route-ip-whitelist`, `routes-rate-limit` | Route annotations, as jetty did for ACS (D2) |
| `resource-requests-limits-in-{deployment,daemonset,statefulset}` | Limits on workloads, or documented exceptions (jetty: vendor operators) |
| `cluster-wide-proxy-set` | Not applicable without a proxy; tailored-profile exception, as on jetty |
| `openshift-api-server-audit-log-path` (CIS and moderate) | Scanner false positive (OCPBUGS-126610); tailored-profile exception, as on jetty |
