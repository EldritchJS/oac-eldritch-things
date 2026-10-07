# NFS over TLS — working

*Last updated 2026-10-07.*

> Angle-bracket values are redacted internal addresses. See the top-level
> README § Conventions.

## The gap (now closed for new volumes)

**All NFS traffic between the nodes and the FlashBlade is cleartext.** Live
mount options on a worker:

```
nfs4 rw,relatime,vers=4.1,rsize=524288,wsize=524288,hard,proto=tcp,
     timeo=600,retrans=2,sec=sys,local_lock=none,addr=<fb-data-vip>
```

`sec=sys`, and no `xprtsec=`. Everything crossing the storage VLAN — including
data pulled from Pure to train models — is unencrypted on the wire.

This is a **control gap, not a feature request**: NIST 800-171 **3.13.8**
(cryptographic mechanisms to prevent unauthorised disclosure of CUI in
transit) and 800-53 **SC-8**. It is invisible to the Compliance Operator,
which does not inspect CSI mount options — so nothing in `tests/verify.sh` or
the scan results will ever flag it.

## What is and isn't in place

Measured on `moc-r4pcc02u15`, RHCOS 9.8, kernel `5.14.0-687.46.1.el9_8`:

| Layer | State |
|---|---|
| Kernel RPC-over-TLS | ✅ 42 `xprtsec`/`xs_tls` symbols; `tls.ko` present and loaded; handshake netlink symbols present |
| `mount.nfs` passthrough | ✅ Passes `xprtsec=` to the kernel (the binary itself has no `xprtsec` string — it does not need one) |
| FlashBlade server-side TLS | ✅ Supported (confirmed by the storage team; in use on another cluster) |
| Portworx CSI `mountOptions` | ✅ Passes `xprtsec` through |
| **`tlshd` userspace daemon** | ❌ **absent — the only missing piece** |

### The decisive test

Mounting an existing export with `xprtsec=tls` against the real FlashBlade:

```
mount.nfs: No such process
```

`ESRCH` is the kernel's handshake upcall finding **no userspace listener**.
That is the precise signature of "kernel supports TLS, no `tlshd` running" —
and it proves every other layer already works. Production mounts were
undisturbed (18 still present afterwards).

> Red Hat backported NFS-over-TLS to RHEL 9. Upstream it landed in kernel 6.5,
> which is why the feature is easy to assume missing on a 5.14 kernel. It is
> not missing. **RHCOS 10 is not required**, and in any case the RHCOS version
> is pinned by the release payload — it is not an independent choice.

## The fix

`ktls-utils` (which provides `tlshd`) is not in RHCOS and cannot be `dnf
install`ed onto a node. Two ways to supply it:

1. **A privileged DaemonSet** running `tlshd` in a container, `hostNetwork:
   true`. No layered image, no MachineConfig, no reboot.
2. **On-cluster image layering** — `machineosconfigs`/`machineosbuilds` CRDs
   do exist on this cluster, so this is available. Heavier: a build pipeline,
   an entitled builder, and a node reboot per rollout.

**A colleague has already built and proven option 1 in this environment**
(MOC, against a Pure appliance), including a packet capture showing the TLS
handshake and NFS traffic inside the TLS channel. That work is deliberately
**not vendored into this repo** — use it as the upstream reference:

- Container: UBI9 + `ktls-utils`, `CMD ["/usr/sbin/tlshd", "-s"]`
- DaemonSet: privileged, `hostNetwork: true`, mounts the storage CA from a
  ConfigMap, runs `trust anchor` on each cert, then `exec tlshd -s`
- StorageClass: a separate class carrying `mountOptions: [xprtsec=tls]`

Running `tlshd` inside the container means `trust anchor` modifies the
*container's* trust store, which is correct — the daemon doing the handshake
is the one that needs the trust.

## Status (2026-10-07): WORKING, end to end

| Step | State |
|---|---|
| Image built from the cluster's own RHEL entitlement | ✅ `ktls-utils-0.11-3.el9_6` |
| Pushed to `ghcr.io/eldritchjs/tlshd`, pinned by digest | ✅ |
| `tlshd` DaemonSet on both workers | ✅ 2/2 Ready |
| `nfs-over-tls` StorageClass provisions | ✅ PVC Bound |
| TLS handshake | ✅ `Handshake with <fb-data-vip> was successful` |
| Mount carries `xprtsec=tls` | ✅ confirmed in `/proc/mounts` |
| **Traffic actually encrypted** | ✅ **proven by packet capture** |

### The proof

A mount succeeding proves the mount worked, not that it is encrypted. So:
300 lines of a unique canary string were written to a TLS-backed volume while
capturing port 2049 to the array.

| | |
|---|---|
| Canary lines written (control) | 300 |
| Packets captured during the window | 3,454 (1.49 MB) |
| **Occurrences of the canary in the capture** | **0** |

On a cleartext mount that string appears in the capture verbatim.

### What made it fail first time

The array's **default Pure self-signed certificate has no Subject Alternative
Name**, and GnuTLS requires an `iPAddress` SAN to verify a peer addressed by
IP — it does not fall back to the CN. The symptom was:

```
tlshd: Certificate owner unexpected.
tlshd: Handshake with <fb-data-vip> failed
```

Worth knowing *why* that error is diagnostic: `unexpected owner` means the
chain validated against a trusted anchor and only the **name** check failed.
A wrong or untrusted certificate gives an unknown-issuer error instead. So the
message localises the fault precisely.

Ruled out along the way, with evidence: the client permits TLS 1.3
(`enabled-version = TLS1.3` under the FIPS policy), and the certificate is
SHA-256/RSA-2048, both FIPS-acceptable — so neither a protocol-version
mismatch nor an algorithm rejection.

**Fix:** storage team reissued with `subjectAltName = IP:<nfs-data-vip>`.
Keep that requirement in mind for any other array.

### Node-reboot behaviour — measured, and it is a non-issue

The obvious worry with running `tlshd` as a pod is ordering: nothing can mount
a TLS volume until the daemon is up, so a reboot could strand workloads.
Measured on `moc-r4pcc02u16`, 2026-10-07, with a TLS-backed volume in use:

| Interval | Time |
|---|---|
| reboot issued → node Ready | 606s |
| node Ready → `tlshd` Ready | **0s** |
| node Ready → TLS mount usable | 6s |
| **`tlshd` Ready → TLS mount usable** | **6s** ← the ordering window |
| heartbeat gap on the TLS volume | 580s (vs 606s total reboot) |

`tlshd` is Ready *at the moment the node is* — a DaemonSet with
`priorityClassName: system-node-critical` comes up with the node rather than
after it. **TLS adds nothing measurable to recovery.**

The only `FailedMount` observed was `driver name pxd.portworx.com not found in
the list of registered CSI drivers` — CSI registration lag, which affects every
volume regardless of encryption and has nothing to do with `tlshd`.

Caveat: one node, lightly loaded, one TLS volume. Worth re-measuring after
migration if recovery time starts to matter.

### Migration progress

| Date | Change | Cleartext mounts |
|---|---|---|
| 2026-10-07 | baseline after tlshd deployed | 18 |
| 2026-10-07 | `nfs-over-tls` made the **default** StorageClass | 18 |
| 2026-10-07 | Compliance Operator raw results migrated (8 PVCs) | 8 |
| 2026-10-07 | CNV golden images fixed + migrated (6 PVCs) | **6** |

**Default StorageClass is now `nfs-over-tls`.** Anything provisioned from here
on is encrypted without anyone having to ask. Note the trade: `tlshd` is now a
dependency for every new volume cluster-wide. The reboot measurement above
says that is safe, but it is a real centralisation of risk.

**Compliance raw results.** `jetty-default` ScanSetting now sets
`rawResultStorage.storageClassName: nfs-over-tls`. The operator reuses PVCs by
name, so migrating meant deleting the old ones — the eight PVs were patched to
`persistentVolumeReclaimPolicy: Retain` first, so the archived ARF evidence
survives as `Released` volumes on the array rather than being deleted with the
claims. Recover one by creating a PVC bound to its `volumeName` if ever needed.

Still on `pure-fb-nfsv4`: only the three ACS stackrox volumes
(`central-db` 100Gi, `central-db-backup` 200Gi, `scanner-v4-db` 50Gi).

### The mistake worth not repeating: scoping tlshd to workers

The DaemonSet originally carried `nodeSelector: node-role.kubernetes.io/worker`,
justified as reducing the blast radius of a privileged host-network pod, on the
measured basis that masters carried the control-plane taint and mounted zero
NFS.

The measurement was accurate and the conclusion was still wrong. It described
*where pods happened to be sitting*, not where they can run. The Compliance
Operator schedules its result-server pods onto masters, and the moment the
compliance PVCs moved to `nfs-over-tls` every one of those mounts failed with
`exit status 32` — with no handshake reaching any `tlshd`, because there was
none on those nodes to reach.

Two lessons, both now encoded:

- **A daemon in the storage data path belongs on every node that can mount
  storage.** The reference implementation had no nodeSelector; narrowing it was
  not an improvement. `tolerations: [{operator: Exists}]` now.
- **T-13 was polling workers only**, mirroring the same bad assumption, so it
  could not have caught this. It now checks all nodes.

### Still to do

- **Migrate the ACS volumes** — the last three, 350Gi. Live Postgres, so it
  needs a maintenance window: scale Central down, copy, repoint. Or accept
  losing violation history and let it rebuild.
  `mountOptions` is immutable, so `pure-fb-nfsv4` cannot be upgraded in place:
  each volume needs a new claim on `nfs-over-tls` and a data copy. This is the
  bulk of the remaining work, and `tests/verify.sh` T-13 tracks the ratio.
- **Document the ACS exception** for the privileged DaemonSet.
- **Consider making `nfs-over-tls` the default StorageClass** once migration
  is done, so new volumes are encrypted without anyone having to remember.

## Manifests

Jetty-adapted manifests are in **[manifests/11-nfs-tls/](manifests/11-nfs-tls/)**,
with the four storage-team unknowns marked `REPLACE-ME`. All eight objects
validate against the live API under a server-side dry-run; `kustomize build`
deliberately fails until the FlashBlade certificate is supplied.

## What jetty needs that the reference does not supply

| Item | Why |
|---|---|
| **The FlashBlade certificate for *this* appliance** | The reference ships its own appliance's self-signed cert. Ours must be the jetty FlashBlade's. |
| **Cert CN/SAN must match `<fb-data-vip>`** | Mounts target the data VIP by IP, and the client sends it as SNI. A cert naming a hostname we never use will fail validation. |
| **Pure-side TLS export policy + server name** | The reference StorageClass uses its own `pure_nfs_policy` / `pure_nfs_server`. Ours are currently `export-policy` / `nfs-server`, which are the **cleartext** ones. The storage team must create TLS-enabled equivalents. |
| **A migration plan for existing PVCs** | `mountOptions` are fixed at StorageClass level. Existing volumes on `pure-fb-nfsv4` do not transparently upgrade — they need a new class and a data move. |

## Risks to settle before deploying here

- **Image provenance.** The reference image is published to a personal
  registry. A privileged, host-network DaemonSet in the storage data path is
  exactly the thing not to pull from an unowned namespace — and it would force
  that registry into the `allowedRegistries` allowlist, which collides with the
  stage 3 work in FEASIBILITY.md §3. **Build it ourselves and push to the
  internal registry or an org-owned quay repo.**
- **Boot ordering.** If `tlshd` is a pod, then on reboot nothing can mount a
  TLS-backed volume until that pod is running. Mounts retry, so it should
  converge, but it means slower node recovery and possible flapping. Set
  `priorityClassName: system-node-critical` and add a liveness probe — the
  reference DaemonSet has neither. **This interacts with compliance
  remediation**, which reboots every node serially (see `remediate.sh`
  stage 2).
- **ACS will alert.** A new privileged host-network DaemonSet will trip
  runtime policies. Legitimate — document it as an accepted exception rather
  than silencing the policy. It does not add a new SCC, so the "10 known SCCs"
  assertion in `tests/verify.sh` T-11 stays valid.
- **Support posture.** NFS-over-TLS on OpenShift is not an officially
  supported configuration. For a sandbox that is fine; record it as a known
  deviation before it propagates to a cluster under assessment.

## If this turns out to be too much

The storage network is a dedicated, non-routed VLAN. "Traffic confined to an
isolated storage segment" is a defensible compensating control for SC-8 and
costs nothing. Weigh that against a tech-preview dependency in the data path —
but **do not leave the gap undocumented either way**.
