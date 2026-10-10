# NFS over TLS — working

*Last updated 2026-10-07.*

> Angle-bracket values are redacted internal addresses. See the top-level
> README § Conventions.

## The gap (closed 2026-10-07)

> This section and the next record the state **before** the fix, as measured.
> All NFS traffic is now encrypted — see *Migration progress* below.

**All NFS traffic between the nodes and the FlashBlade was cleartext.** Live
mount options on a worker:

```
nfs4 rw,relatime,vers=4.1,rsize=524288,wsize=524288,hard,proto=tcp,
     timeo=600,retrans=2,sec=sys,local_lock=none,addr=<fb-data-vip>
```

`sec=sys`, and no `xprtsec=`. Everything crossing the storage VLAN — including
data pulled from Pure to train models — was unencrypted on the wire.

This is a **control gap, not a feature request**: NIST 800-171 **3.13.8**
(cryptographic mechanisms to prevent unauthorised disclosure of CUI in
transit) and 800-53 **SC-8**. It is invisible to the Compliance Operator,
which does not inspect CSI mount options — so nothing in `tests/verify.sh` or
the scan results will ever flag it.

## What is and isn't in place

Measured on `moc-r4pcc02u15`, RHCOS 9.8, kernel `5.14.0-687.46.1.el9_8`.
"Before" is the state when the gap was found; "now" is after the fix.

| Layer | Before (2026-10-07) | Now |
|---|---|---|
| Kernel RPC-over-TLS | ✅ 42 `xprtsec`/`xs_tls` symbols; `tls.ko` present and loaded; handshake netlink symbols present | ✅ unchanged |
| `mount.nfs` passthrough | ✅ Passes `xprtsec=` to the kernel (the binary itself has no `xprtsec` string — it does not need one) | ✅ unchanged |
| FlashBlade server-side TLS | ✅ Supported (confirmed by the storage team; in use on another cluster) | ✅ in use |
| Portworx CSI `mountOptions` | ✅ Passes `xprtsec` through | ✅ `nfs-over-tls` StorageClass (default) carries `xprtsec=tls` |
| **`tlshd` userspace daemon** | ❌ **absent — the only missing piece** | ✅ **DaemonSet `nfs-tls/tlshd`, 5/5 nodes** ([manifests/11-nfs-tls/](manifests/11-nfs-tls/)) |

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

**[@larsks](https://github.com/larsks) has already built and proven option 1
in this environment**
(MOC, against a Pure appliance), including a packet capture showing the TLS
handshake and NFS traffic inside the TLS channel. That work is deliberately
**not vendored into this repo** — use it as the upstream reference:
[larsks/tlshd, branch `rhel9.6`](https://github.com/larsks/tlshd/tree/rhel9.6)
(`main` has nothing of use).

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
| `tlshd` DaemonSet on both workers | ✅ 2/2 Ready (since extended to every node — see below) |
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
| 2026-10-07 | CNV golden images fixed + migrated (6 PVCs) | 6 |
| 2026-10-07 | ACS central-db + scanner-v4-db migrated (3 PVCs) | **0** |

**Migration complete.** `tests/verify.sh` T-13 reports *"no cleartext NFS
mounts remain"*. All 18 PVCs in use are on `nfs-over-tls`.

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

One PVC remains *defined* on `pure-fb-nfsv4`: the original `stackrox/central-db`
(`scanner-v4-db`'s has since been deleted). Nothing mounts it; it is the
rollback path. Its PV is `Retain`, so deleting the claim preserves the data.
Delete once you are satisfied the migration held (PLAN.md D7).

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

### Migrating ACS: four operator behaviours that will stop you

Done 2026-10-07, Central offline ~40 minutes. The data was trivial —
central-db was **292MB** and scanner-v4-db **20GB**, against 350Gi
provisioned — but the ACS operator fought every step, each time with a
precise error worth knowing in advance:

1. **It reverts your scale-downs.** Scale
   `rhacs-operator-controller-manager` to 0 first, do the work, scale it back.
2. **It will not adopt a pre-created PVC if you also set `size` or
   `storageClassName`.** Those mean "create this for me". For an existing
   volume, set `claimName` only:
   > *Please remove the storageClassName and size properties from your spec,
   > or change the name to allow the operator to create a new one.*
3. **Renaming the DB claim orphans its backup volume.** The backup PVC name is
   derived from the DB claim, so it tries to create `<newname>-backup` and
   refuses while the old one exists:
   > *the operator can only manage 1 PVC for central-db-backup.*

   Delete the old backup PVC (PV on `Retain` first) and it creates the new one.
4. **Helm-managed PVCs need ownership metadata.** `scannerV4.db` is reconciled
   through Helm, so a hand-made PVC is rejected until it carries
   `app.kubernetes.io/managed-by: Helm` plus
   `meta.helm.sh/release-name` / `-namespace`. Add those and the operator
   adopts it and stamps the rest of its labels itself.

Copy mechanics: `tar`, not `cp -a`. The FlashBlade export carries a read-only
`.snapshot` directory and the mount root rejects `utime`, so `cp -a` exits
non-zero having copied fine. Assert on **file count**, not exit status —
`ubi-minimal` has no `tar` at all, and a job that silently copied 0 files
still reported success until the count check caught it.

Why a copy at all: `mountOptions` is immutable, so `pure-fb-nfsv4` cannot be
upgraded in place — each volume needs a new claim on `nfs-over-tls` and a data
move.

### Still to do

- ~~**Document the ACS exception** for the privileged DaemonSet.~~ Done:
  [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md) #1.
- **Delete the rollback PVC** `stackrox/central-db` (on `pure-fb-nfsv4`)
  once satisfied the migration held. Its PV is `Retain`. (`scanner-v4-db`'s
  is already gone.) PLAN.md D7.

## Manifests

Jetty-adapted manifests are in **[manifests/11-nfs-tls/](manifests/11-nfs-tls/)**,
deployed and live. `kustomize build` deliberately fails until the FlashBlade
certificate is supplied locally — it is not in the repo.

## What jetty needs that the reference does not supply

> Pre-deployment planning, kept as a checklist for the next cluster. On jetty
> every item below has been resolved.

| Item | Why |
|---|---|
| **The FlashBlade certificate for *this* appliance** | The reference ships its own appliance's self-signed cert. Ours must be the jetty FlashBlade's. |
| **Cert CN/SAN must match `<fb-data-vip>`** | Mounts target the data VIP by IP, and the client sends it as SNI. A cert naming a hostname we never use will fail validation. |
| **Pure-side TLS export policy + server name** | The reference StorageClass uses its own `pure_nfs_policy` / `pure_nfs_server`. Ours are currently `export-policy` / `nfs-server`, which are the **cleartext** ones. The storage team must create TLS-enabled equivalents. |
| **A migration plan for existing PVCs** | `mountOptions` are fixed at StorageClass level. Existing volumes on `pure-fb-nfsv4` do not transparently upgrade — they need a new class and a data move. |

## Risks to settle before deploying here

> Pre-deployment planning, kept for the next cluster. On jetty: the image is
> built in-cluster and pinned by digest (signing is PLAN.md D3); the DaemonSet
> runs `system-node-critical` with a liveness probe; the ACS exception is
> PRIVILEGED-WORKLOADS.md #1. The support-posture point still stands.

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
