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
| D | The first hosted cluster, `nist-dev-workload0`: its hub-side pieces (agent discovery, the hosted-cluster router, DNS, certificates) and the cluster itself | none on the hub; the workers' first boot |

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
| `routes-rate-limit` | Route annotations, as jetty did for ACS (D2): `route-rate-limits.sh`, applied 2026-10-19 |
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

### Route rate limits (2026-10-19)

`route-rate-limits.sh` annotates every route outside `openshift-*` and
`kube-*` with jetty's limits: per source IP, 100 concurrent TCP connections
and 100 new connections per 3 s. On this hub that is seven routes: ACS
Central's two, four in `multicluster-engine`, and ACM's CLI downloads.
The router's configuration shows both limits on all seven backends. Sensor
stayed connected, and every `local-cluster` add-on stayed Available.

`routes-rate-limit` passes, and `nist-ocp4-moderate` is at **19** failures.

### Quotas and the first NetworkPolicies (2026-10-19)

Through the `namespace-guardrails` values:

- **Quotas on all 25 non-platform namespaces.** Object counts and storage
  only, sized from what each namespace held: pods and services at twice the
  count (rounded up to 5; at least 10 and 5), 2 volumes and 20Gi where none
  were used, and no NodePort or LoadBalancer services. No quota was below
  current use, and running pods are not affected.
- **Default-deny NetworkPolicies on five small namespaces** whose traffic is
  fully known. `patch-operator` and `external-dns-operator` each serve only
  an API server webhook (9443) and call only the API server and DNS.
  `nfs-tls` runs only host-network pods, which policies do not affect.
  `node-labels` and `moc-metrics-collector` hold only service accounts.
  Neither Prometheus scrapes any of the five.

Checked after the sync: each webhook answered a dry-run request in about
0.35 s, and neither operator restarted.

`resource-requests-quota` passes; `nist-ocp4-moderate` is at **18**
failures. `configure-network-policies-namespaces` still fails, in CIS and
moderate: 13 namespaces have no policy yet. ACM, multicluster-engine,
HyperShift, Portworx and the others wait until a spoke exists, so their
traffic, including the spoke's, can be measured first. The policy must be
real: the check passes on any NetworkPolicy, including one that allows
everything.

## Stage C results (2026-10-19)

Node hardening, applied 21:25 to 22:28 EDT. The master pool was paused, so
the chart's 192 master MachineConfigs (191 `rhcos4-moderate` remediations
and `76-master-sshd-allowusers`) arrived as one rendered configuration. Each
node was then drained, updated and rebooted once, in turn: u13, u15, u17.
The worker pool has no machines, so its 189 MachineConfigs change nothing.

Checked on every node afterwards: the boot arguments (`audit=1`,
`audit_backlog_limit=8192`, `pti=on`, `vsyscall=none`, `page_poison=1`,
`nousb`), blocked kernel modules, and every NFS mount still on
`xprtsec=tls`.

| Scan | Fail, stage A | Fail, after stage C |
|---|---|---|
| `rhcos4-moderate` (masters) | 191 | **1** |
| `ocp4-moderate-node` (masters) | 4 | **1** |
| `ocp4-cis-node` (masters) | 0 | **0** |
| `nist-ocp4-moderate` (platform) | 25 | **18** |
| `nist-ocp4-cis` (platform) | 9 | **8** |

The two node failures left:

- `reject-unsigned-images-by-default`: closed by the registry allowlist,
  which stays off until the hub's images are inventoried.
- `service-usbguard-enabled`: USBGuard is installed and its MachineConfig is
  applied, but the service is disabled. Probably ordering: the package
  arrives as an RHCOS extension in the same update that enables the service.
  To verify. USB is off at boot (`nousb`) in any case.

### During the rollout: etcd crashes on the nodes taking the load

Each drain moved a node's pods, and their connections, to the other two
nodes. There, etcd and the kubelets stalled on TLS handshakes, and etcd
crashed:

- **First drain (u13):** etcd on u15 and u17 stopped answering from about
  21:28. etcd on u15 crashed at 21:33 and restarted. The API was unavailable
  from about 21:36 to 21:39, while u13 rebooted. Everything recovered without
  intervention.
- **Second and third drains (u15, u17):** shorter kubelet stalls. etcd on u13
  crashed at 22:15 and on u17 once, but quorum held and the API stayed up.
- **Afterwards:** u13, first back, held most of the drained pods. Its kubelet
  reached about 1,400 threads and a load average above 40, and HTTPS liveness
  probes (1 s timeout) failed. About a dozen ACM and multicluster-engine pods
  restarted repeatedly (63 restarts in all), then settled by about 22:40
  without intervention.

What the crash dumps show, for both etcd crashes:

- `pthread_create failed: Resource temporarily unavailable`, then `SIGABRT`.
  The kernel logged `fork rejected by pids controller` for the etcd pod: it
  reached the per-pod limit of 4,096 (`podPidsLimit`).
- About 4,650 goroutines, about 3,900 of them inside cgo calls to OpenSSL
  (`golang-fips`): about 3,400 in `EVP_PKEY_keygen` and about 350 in
  `RAND_bytes`. In FIPS mode, each TLS handshake's key generation is an
  OpenSSL call that holds an OS thread.

So, in FIPS mode, a burst of TLS reconnections can hold enough threads in
OpenSSL to exhaust the pod's thread limit. A drain causes such a burst.
Generating keys with the `openssl` command on the same nodes runs at normal
speed, so the slowdown appears only with many concurrent callers in one
process; contention inside OpenSSL is suspected, not shown.

**Why etcd had thousands of handshakes in flight** (dumps and logs
re-read, and connections counted, on 2026-10-20):

- The limit counts threads, not processes. etcd normally runs 35 to 223
  threads on this hub.
- In both dumps, about 3,900 threads each held one server-side TLS 1.3
  handshake on etcd's client port (2379), in key generation or
  `RAND_bytes`. Nearly all had been there less than a minute.
- The clients are the kube-apiservers. Each holds about one etcd
  connection per API resource type, to every etcd endpoint: 548 to 567
  per endpoint here (567 resource types), 329 to 348 on jetty (347). So
  each etcd member holds about 2,250 client connections at rest, against
  about 1,350 on jetty. The difference is ACM, multicluster-engine,
  HyperShift and Hive's CRDs.
- When a member or an API server restarts, those connections all
  handshake again at once.
- On the member that crashed first, handshakes were already slow before
  the client burst: its peers' TLS handshakes to it timed out from
  4 minutes before the crash. Then API server handshakes on 2379 began
  failing with `broken pipe` (the client gave up before etcd answered)
  and being retried, until the threads ran out.

So the thread count follows from two things: the number of connections,
which is set by the number of resource types; and how slow a handshake
is under concurrency, which is the open question. Raising `podPidsLimit`
would only let more stalled handshakes pile up before the same failure.

**Handshake bursts, measured (2026-10-20).** A test etcd (each cluster's
own image and TLS settings: RSA-2048, client certificates, the same
ciphers; FIPS OpenSSL confirmed loaded) took bursts of 3,000 simultaneous
TLS handshakes from a client on another node, three bursts per run.
[tls-handshake-test/](tls-handshake-test/) has the harness.

| Server node | CPUs | etcd build (OpenSSL) | GOMAXPROCS | Peak threads | CPU per handshake |
|---|---|---|---|---|---|
| nist-dev-infra | 176 | 4.22.14 (3.5.5) | default | 1,350; 1,841 | 21; 25 ms |
| nist-dev-infra | 176 | 4.22.14 (3.5.5) | 40 | 123; 110 | 13; 13 ms |
| nist-dev-infra | 176 | 4.22.16 (3.5.8) | default | 505 | 24 ms |
| jetty master | 40 | 4.22.16 (3.5.8) | default | 94 | 11 ms |
| jetty worker | 512 | 4.22.16 (3.5.8) | default | 534; 554 | 82; 94 ms |
| jetty worker | 512 | 4.22.14 (3.5.5) | default | 526; 519 | 276; 76 ms |

One handshake at a time cost 5 to 10 ms of server CPU everywhere. Every
burst completed, at about 2,000 to 2,400 handshakes a second in every
configuration.

What this shows:

- **Threads follow how many handshakes Go lets into OpenSSL at once,
  which follows `GOMAXPROCS` (by default, the node's CPU count).** On
  the same node and image, capping it at 40 cut peak threads by 11 to 17
  times, cut CPU per handshake by about 40%, and did not change
  throughput. The extra threads on large nodes buy nothing.
- **CPU per handshake grows with core count** (11 ms on 40 CPUs, about
  80 ms on 512), for the same work. The Go client, which does not use
  OpenSSL, showed the same growth. So that part is Go's runtime on large
  machines, not FIPS OpenSSL.
- **Bursts sometimes go badly.** One run took 276 ms of CPU per handshake,
  1,404 s of it in the kernel, and 7 s for one burst, on an idle node;
  the same run repeated was normal. The incident looked like such an
  episode, on a node already loaded by a drain.
- **Not shown:** that OpenSSL 3.5.8 (4.22.16) helps. Its one run on this
  hub peaked at 505 threads, against 1,350 and 1,841, but one run is not
  enough. Nor did a single burst reach 4,096 threads in isolation; the
  incident added client retries and a loaded node.

What would reduce the thread count, instead of raising the limit:
etcd with a lower `GOMAXPROCS` (the static pod is the etcd operator's, so
this is a question for Red Hat), fewer etcd connections (fewer resource
types), and smaller nodes for the control plane (the standard layout).

**Where the CPU goes (profiled the same day).** Same harness, with `perf`
attached to the test server from a node debug pod during the bursts
(`PERF=1`), and a control server that does the same handshakes with Go's
own crypto and no OpenSSL (`NATIVE=1`, [server/](tls-handshake-test/server/)).

| Server | Peak threads | Kernel | Real crypto | OpenSSL's read-write locks | Kernel mutex spinning (`osq_lock`) |
|---|---|---|---|---|---|
| FIPS etcd, this hub (176 CPUs) | 874 | 35.6% | 27.5% (OpenSSL FIPS module) | 8.3% | 13.7% |
| FIPS etcd, jetty master (40 CPUs) | 86 | 15.3% | 55.8% | 2.5% | not in the top symbols |
| Go-native control, this hub | 186 | 24.6% | 75% (Go) | none | 2.5% |

1. **FIPS is what turns concurrent handshakes into threads.** The native
   control peaks at about `GOMAXPROCS` (176) threads; FIPS etcd peaks well
   above it. Each OpenSSL call holds a thread while it runs.
2. **On this hub a third of FIPS etcd's CPU is kernel lock spinning, not
   crypto.** Kernel stacks show the spinning in `mprotect`, waiting for
   the process's memory-map lock. Tracing the syscalls: 13,600 to 33,500
   `mprotect` calls per 9,000 handshakes, against about 180 thread
   creations. About 98% come from OpenSSL's allocations
   (`CRYPTO_malloc` → glibc `malloc` → `sysmalloc` growing a heap): glibc
   gives each thread its own heap, and a new one grows in small steps,
   each step an `mprotect` under a lock the whole process shares.
3. **Making heaps grow in larger steps removes that, but the time moves
   to OpenSSL's locks.** With `GLIBC_TUNABLES=glibc.malloc.top_pad=67108864`
   (64 MiB) the test server made 350 `mprotect` calls and `osq_lock`
   disappeared from the profile. CPU per handshake did not improve,
   though (about 23 ms): OpenSSL's read-write lock calls rose from 8% to
   17%. Sampled stacks show those locks taken at the start of nearly every
   OpenSSL operation the Go FIPS bridge calls (`EVP_DigestInit_ex`,
   `EVP_DigestFinal`, `EVP_PKEY_sign`, `EVP_PKEY_derive_init`,
   `EVP_PKEY_generate`, `EVP_MAC_init`, `EVP_CipherInit_ex`). The frame
   that takes the lock is inside stripped code; the pattern fits
   OpenSSL 3 looking up the algorithm's provider on each call, but that is
   inferred, not shown. `glibc.malloc.arena_max=8` made things worse.

So, on a large FIPS node, concurrent handshakes in one process contend
first on the kernel's memory-map lock (through glibc's heaps) and then on
OpenSSL's own locks. Cores beyond about 40 add contention, not throughput.
For a Red Hat case: these profiles, the crash dumps, and the question of
whether golang-fips can avoid a lock on each OpenSSL operation (for
example by looking algorithms up once and reusing them).

jetty, also FIPS, did not show this. The differences:

| | jetty | nist-dev-infra |
|---|---|---|
| Layout | 3 control-plane nodes and 2 workers | Compact: 3 nodes run everything |
| CPUs per control-plane node | 40 | 176 |
| ACM, multicluster-engine, HyperShift, Hive | None | All |
| OpenShift, kernel | 4.22.16, `687.50` | 4.22.14, `687.46` |

On a compact hub, a drain moves every workload onto the nodes that run etcd
and the API servers, and ACM's many controllers all reconnect at once. With
176 CPUs, Go runs far more of those handshakes in parallel.

**Why it matters beyond stage C:** upgrades drain every node the same way.
To decide:

- a Red Hat support case, with the crash dumps (kept outside the repo);
- why TLS handshakes in etcd slow down under concurrency on this hub,
  before any change to `podPidsLimit` (see above: raising it alone does
  not address the cause);
- whether compliant hubs should use a standard layout (separate control
  plane) rather than a compact one;
- whether the next upgrade of this hub reproduces it.

## Stage D: the first hosted cluster (in preparation)

Unlike A to C, stage D runs through `CCI-MOC/oac-apps` and `moc-aws`
themselves: the hub's `hosted-clusters` and `hub-components`
ApplicationSets read `main`.

### What is written (2026-10-20)

| Where | What |
|---|---|
| oac-apps `hosted-cluster-nodepool-config` | The chart: NodePool config from the hub, API server audit, image config. A pool's own `config` entries may be names or `{name: ...}` |
| oac-apps, `values/nist-dev-infra/local-cluster/` | `acm.yaml` (agent discovery; the hub's ECDSA key, since sshd on a FIPS node refuses ed25519), `hcp-config.yaml`, `metallb.yaml`, `cert-manager.yaml`, `external-dns-operator.yaml` |
| oac-apps, `hosted-clusters/nist-dev-infra/` | Hub-wide defaults (FIPS, node hardening, audit profile, registry allowlist) and `nist-dev-workload0/values.yaml` |
| moc-aws `nist-dev-infra-hcp` | The zones `hcp.nist.int.massopen.cloud` and `hcp-int.nist.int.massopen.cloud`, delegated from `nist.int`; an external-dns user for them, whose key the hub reads where the iam-user module stores it; the hub may write `cluster/nist-dev-infra/hostedcluster/` (kubeconfig, etcd encryption key) |

Every values file renders. The cluster's HostedCluster and NodePool, with
test addresses in place of the placeholders, pass a server-side dry run
on the hub.

### Still needed

- **Hardware:** at least two bare-metal workers, new or wiped, that can
  reach the hub. Their resource class goes in the NodePool's selector.
- **Addresses from ops:** a MetalLB range for hosted API servers, one
  address for the hosted-cluster router, one for the cluster's ingress.
  Then a wildcard record `*.hcp-int.nist.int.massopen.cloud` for the
  router, in moc-aws.
- **A second moc-aws change, after the zones exist:** add both zones to
  the hub's cert-manager policy (`additional_zone_names`). The module looks
  zones up by name, so it cannot plan in the same change that creates them.
- **A default StorageClass** (oac-apps #148): the agent service's volumes
  name no class.
- **Hosted etcd storage, to decide:** the hub has no LVM storage (each
  node's second disk holds its own etcd), and Red Hat does not support
  etcd on NFS. The values use `pure-fb-nfsv4` for now.
- **On the test branch,** once the `clusters` namespace exists:
  `compliance-node-hardening` `nodePool.enabled: true`, so the NodePool's
  ConfigMap exists. Then an ApplicationSet for the cluster's own
  compliance components (BUILD.md Part 2, step 3).
- **The etcd crashes understood first:** a hosted control plane adds about
  75 pods, many of them TLS clients, to the nodes whose etcd crashed
  during stage C. Its own etcd is separate, but it runs on the same nodes.
- **Not yet:** an identity provider for the cluster (`oauth.mocsso` needs
  a Keycloak client); external-dns with a web-identity role in place of a
  stored key.
