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
| S | Storage, TLS only, before any volume exists: `tlshd` on every node, and `pure-fb-nfsv4` as a TLS class (`portworx.tls: true`), the default and the only FlashBlade class | none |
| B | Admission policy, FIO, system use notice, etcd backup, ACS (Central and the hub's SecuredCluster), NetworkPolicies and quotas for those namespaces | none |
| C | Node hardening: about 380 MachineConfigs | **every node**. On this compact hub that is the whole cluster, one node at a time |

On nist-dev-infra, NFS over TLS went in with stage B, after Portworx had
already made `pure-fb-nfsv4` the default. Five volumes landed on it, and
TLS mounts then failed on every node that held one of them. They were
recreated on `nfs-over-tls` on 2026-10-19. On the next hub, stage S
comes first, in the same merge as the hub's Portworx values (BUILD.md,
"Storage is TLS-only from its first volume").

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
  backups, so it waits for Portworx ([STORAGE-BRINGUP.md](STORAGE-BRINGUP.md);
  `../tests/hub-preflight.sh nist-dev-infra` passes when it is ready). The hub's SecuredCluster also needs an init bundle from Central
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
| `routes-rate-limit` | Route annotations, as jetty did for ACS (D2) |
| `route-ip-whitelist` | Needs the address ranges users come from (PLAN.md F5). On jetty, left as a recorded gap |
| `resource-requests-limits-in-{deployment,daemonset,statefulset}` | Limits on workloads, or documented exceptions (jetty: vendor operators) |
| `cluster-wide-proxy-set` | No egress proxy exists. A real gap (PLAN.md B5): on jetty it was recorded, not tailored away |
| `openshift-api-server-audit-log-path` (CIS and moderate) | Scanner false positive (OCPBUGS-126610); tailored-profile exception, as on jetty. The real path is set on this hub (checked 2026-10-19) |

## Stage B results (2026-10-19)

Applied at 14:13 EDT, once the hub had storage
([STORAGE-BRINGUP.md](STORAGE-BRINGUP.md)). A test volume on `pure-fb-nfsv4`
had bound, mounted over NFS 4.1 and been written to first. All eight
`nist-test-*` Applications were Synced and Healthy by 14:15.

| Component | State |
|---|---|
| Admission policy | `compliant-hosted-clusters` ValidatingAdmissionPolicy present |
| FIO | `all-nodes` Active; first check Succeeded on all three nodes |
| System use notice | `classification-banner` ConsoleNotification present |
| etcd backup | CronJob present, writing to the default StorageClass |
| ACS | Central 4.11.5 up. The hub's SecuredCluster is Available, and Sensor connected to Central at 14:26, after the init bundle was applied by hand |
| NetworkPolicies and quotas | Synced with their namespaces |
| NFS over TLS | `tlshd` Running on all three nodes, CA synced from `cluster/nist-dev-infra/nfs-tls-ca`. At first, mounts failed (below). Since 2026-10-19 `nfs-over-tls` is the only default, and every volume uses it |

ArgoCD reports `nist-test-rhacs` Healthy as soon as the Central resource
exists, before Central is up. Wait for `deploy/central` to be Available
before generating the init bundle.

### NFS over TLS: why mounts failed, and the fix

At first, a volume on `nfs-over-tls` provisioned and attached, but the
mount failed:

```
mount -t nfs -o vers=4.1,xprtsec=tls <data-vip>:/px_...
mount.nfs: Operation not permitted
```

The certificate and the FlashBlade's export policy were not the cause:
`tlshd` logged a successful handshake each time, and the realm's TLS policy
matches jetty's. Kernel tracepoints (`handshake`, `nfs4`) on two nodes
showed the cause:

| Node | NFS mounts already there | TLS mount |
|---|---|---|
| u13 | 2, cleartext, to the same FlashBlade | Handshake and `EXCHANGE_ID` over TLS, then the TLS connection is closed. The client reuses its existing cleartext session; the lookup gets `SECINFO`, and the mount fails with `EPERM` |
| u17 | none | Handshake, `EXCHANGE_ID` and `CREATE_SESSION` over TLS. Mounts, and writes |

The Linux client treats the TLS mount's server as one it already has a
session with, and uses that session. On u13, a TLS mount of a cleartext
export "succeeded" the same way, most likely unencrypted. So a node must
not mix the two: every FlashBlade volume on the hub has to be on
`nfs-over-tls`. Jetty most likely works because all its volumes were moved there.

The fix, on 2026-10-19:

1. `nfs-over-tls` made the default (fork values), and `pure-fb-nfsv4` no
   longer the default (CCI-MOC/oac-apps#147).
2. The five volumes created so far recreated on `nfs-over-tls`: etcd backup,
   Perses, and ACS `central-db`, `central-db-backup` and `scanner-v4-db`.
   Each was hours old, so none was copied.
3. ACS, after its database was recreated: delete the three init bundle
   secrets and apply a new bundle; delete the `tls-cert-*` secrets, which
   carry the old cluster ID; restart Sensor, admission control and the
   collectors. Sensor reconnected at 16:13 EDT.

Afterwards, every NFS mount on every node used `xprtsec=tls` (u13 2 of 2,
u15 6 of 6). A canary written 300 times to a new `nfs-over-tls` volume on
u17 appeared 0 times in 4,370 packets captured on port 2049. The preflight
passes I7.

Later the same day, following a review comment on #147, the Portworx
chart gained `portworx.tls` (CCI-MOC/oac-apps#148): `pure-fb-nfsv4` itself
mounts with `xprtsec=tls`, so a compliant hub has one FlashBlade class, and
it is TLS. On nist-dev-infra, `nfs-over-tls` stays for the five volumes
above, but is no longer the default.

On the next hub, stage S keeps this from happening (Stages, above).

### Rescan after stage B

All five scans were rerun on 2026-10-19, after stage B had synced.

| Scan | Fail, stage A | Fail, stage B |
|---|---|---|
| `ocp4-cis` (platform) | 9 | **9** |
| `ocp4-cis-node` (masters) | 0 | **0** |
| `ocp4-moderate` (platform) | 25 | **21** |
| `ocp4-moderate-node` (masters) | 4 | **4** |
| `rhcos4-moderate` (masters) | 191 | **191** |

Stage B closed four `ocp4-moderate` rules:

- `file-integrity-exists`
- `file-integrity-notification-enabled`. The table above expected this one
  to wait for alerting on FIO results (B1), but the rule passes once FIO is
  configured.
- `banner-or-login-template-set`
- `openshift-motd-exists`

The other failures are unchanged, as expected. The node scans wait for
stage C. `configure-network-policies-namespaces` and `resource-requests-quota`
still fail, because they check every non-platform namespace, not only stage
B's. The rest are closed by the other rows of the table above.

### Tailoring the false positive (2026-10-19)

`openshift-api-server-audit-log-path` fails on CIS and moderate although the
real path is set (`/var/log/openshift-apiserver/audit.log`): OCPBUGS-126610,
as on jetty. The hub's bindings now use tailored profiles,
`nist-ocp4-cis` and `nist-ocp4-moderate`, that disable that rule alone, with
the rationale in the profile. The scans are renamed to match.

| Scan | Fail, before | Fail, after |
|---|---|---|
| `nist-ocp4-cis` (platform) | 9 | **8** |
| `nist-ocp4-moderate` (platform) | 21 | **20** |

Not tailored: `cluster-wide-proxy-set` and `route-ip-whitelist` are gaps to
record, as on jetty. The `resource-requests-limits-*` rules fail on about 65
operator-managed Deployments (ACM, multicluster-engine, Hive, HyperShift,
MetalLB, cert-manager, External Secrets, Portworx). On jetty, exempting two
vendor namespaces covered it. Here it is a decision for the SSP: set limits,
exempt the operators' namespaces, or record a gap.
