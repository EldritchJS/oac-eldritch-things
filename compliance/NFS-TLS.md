# NFS over TLS — open gap, with a proven path

*Last updated 2026-10-06.*

> Angle-bracket values are redacted internal addresses. See the top-level
> README § Conventions.

## The gap

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
