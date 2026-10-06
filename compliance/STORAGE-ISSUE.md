# Pure FlashBlade storage — RESOLVED 2026-10-02

> Angle-bracket values like `<fb-data-vip>` are **redacted internal
> addresses**, not blanks to fill in. This repo is public; see the top-level
> README § Conventions.

> **Follow-on:** the data path works, but it is **unencrypted** (`sec=sys`,
> no `xprtsec`). That is a separate open gap — see [NFS-TLS.md](NFS-TLS.md).
> The cluster-side network config described here is now captured in
> `manifests/10-nncp-br-storage.yaml`; the switch-side VLAN trunking is the
> network team's and is not reproducible from this repo.

> **STATUS: FIXED.** The storage VLAN was trunked to the Pure appliance and
> everything works. ARP for `<fb-data-vip>` now resolves (`<fb-mac>`,
> state `REACHABLE`), NFS 2049 is open from masters and workers, and real
> workloads mount and run. No OpenShift-side change was needed, as predicted.
>
> Verified after the fix:
> - PostgreSQL canary **PASS** on FlashBlade NFS — initdb, server start,
>   1000-row write/read, and a forced `CHECKPOINT` (fsync to NFS) all OK.
> - ACS Central + Central DB (100Gi), Scanner V4 DB (50Gi) running on PVCs.
> - Compliance Operator back on archival storage; raw ARF written to PVC.
>
> Everything below is retained as the diagnostic record.

---

**Short version: Pure was not the problem. The config was incomplete.** Volume
*provisioning* worked end to end; the *data path* did not. One address was
unreachable, and that single fact explained every symptom.

Cluster: `jetty` (OCP 4.22.14) · StorageClass `pure-fb-nfsv4` · Portworx CSI 26.2.0

---

## Symptom

Every PVC binds successfully, and no pod can ever mount one. Pods sit in
`ContainerCreating` indefinitely.

Confirmed affected:

| Workload | State |
|---|---|
| CNV golden-image importers (`openshift-virtualization-os-images`, 6 DataVolumes) | `Init:0/1`, stuck **88+ minutes**, DataVolumes still `ImportScheduled` |
| Compliance Operator result servers | `ContainerCreating`, scans hung in `LAUNCHING` |
| Standalone test PVC + pod (our canary) | `ContainerCreating`, same failure |

The CNV importers matter most for diagnosis: they have been stuck since the
storage was first set up. **This never worked — it is not a regression.**

---

## Root cause

The FlashBlade **NFS data VIP `<fb-data-vip>` does not respond to ARP** on the
`<storage-subnet>/24` storage network, from any node in the cluster.

Driver error (`px-pure-csi-node`, `node-plugin` container):

```
NodeStageVolume failed: mount failed: exit status 32
Mounting arguments: -t nfs -o nfsvers=4.1,tcp \
  <fb-data-vip>:/px_fbfb2ac3-pvc-e98bd161-7f2f-4ae0-bd8b-c134b54e995e \
  /var/lib/kubelet/plugins/kubernetes.io/csi/pxd.portworx.com/.../globalmount
Output: mount.nfs: No route to host
```

### Evidence the cluster side is healthy

Tested from both a master and a worker:

| Check | `moc-r4pac08u31-s1a` (master) | `moc-r4pcc02u16` (worker) |
|---|---|---|
| `br-storage` interface | UP, `<master-storage-ip>/24` | UP, `<worker-storage-ip>/24` |
| Storage gateway `<storage-gw>` | **REACHABLE** | **REACHABLE** |
| FlashBlade data VIP `<fb-data-vip>` | **UNREACHABLE** | **UNREACHABLE** |
| ARP entry for `<fb-data-vip>` | `FAILED` | `INCOMPLETE` |
| Route to `<fb-data-vip>` | correct, via `br-storage` | correct, via `br-storage` |

The nodes have the right interface, the right subnet, the right route, and the
storage VLAN carries traffic — **the gateway on that exact subnet answers.**
Only the array's data VIP is silent.

`<fb-data-vip>` is on a directly-connected subnet, so reaching it requires only
ARP, not routing. **ARP is layer 2 and cannot be blocked by an IP firewall or
ICMP policy.** An `INCOMPLETE`/`FAILED` ARP entry therefore means nothing is
answering for that IP on that segment. This is not a filtering artifact.

### Why provisioning still works

Portworx reaches the FlashBlade **management** endpoint `10.3.11.50` to create
filesystems, and that path is fine — PVCs bind and FlashBlade filesystems are
created. Management plane OK, **NFS data plane broken**. That split is exactly
why this looked like working storage at a glance.

Config in `px-pure-secret`:
```
FlashBlades: MgmtEndPoint: 10.3.11.50 | NFSEndPoint: <fb-data-vip>
```

---

## CONFIRMED CAUSE (2026-10-02)

Admin: *"I am pretty sure the vlan isn't trunked to the Pure storage appliance."*

That is consistent with every observation, and it is the fix:

- **ARP `INCOMPLETE`/`FAILED`** — if the storage VLAN never reaches the array's
  ports, the FlashBlade never receives the ARP request, so nothing replies.
  Exactly what an untrunked VLAN looks like from the client side.
- **Gateway `<storage-gw>` reachable** — the switch carries the VLAN to the *node*
  ports and to the router, just not to the *array* ports. This is why the
  subnet looked healthy while the array stayed invisible.
- **Management `10.3.11.50` works** — the FlashBlade's management interface sits
  on a different, correctly connected network. Management plane up, data plane
  isolated. That is precisely the split we measured.

**Action: trunk the storage VLAN to the Pure appliance ports.** No OpenShift,
Portworx, or StorageClass change is needed — the cluster side is already correct.

### Verify after the change

```sh
# 1. ARP must resolve (this is the actual fix landing)
oc debug node/moc-r4pcc02u16 -- chroot /host /bin/bash -c \
  'ping -c2 -W2 <fb-data-vip>; ip neigh show <fb-data-vip>'

# 2. Then a real mount, end to end
oc apply -f manifests/canary-postgres-on-nfs.yaml
oc logs -n acs-storage-canary job/pg-canary
oc delete ns acs-storage-canary
```

**Next thing that could bite, once the VIP answers:** the export policy
`export-policy` must permit node IPs `<master-storage-ip>`–`<worker-storage-ip>`. We never got far
enough to be refused by it, so it is still unverified. Worth confirming in the
same maintenance window rather than discovering it on the next attempt.

### How they can reproduce in ~10 seconds

```sh
oc debug node/moc-r4pcc02u16 -- chroot /host /bin/bash -c \
  'ping -c2 -W2 <storage-gw>; ping -c2 -W2 <fb-data-vip>; ip neigh show <fb-data-vip>'
```
Gateway replies, VIP does not, ARP stays `INCOMPLETE`. When that VIP answers,
the storage works — no OpenShift-side change needed.

---

## Block storage: TABLED — do not raise with admins

FlashBlade is a file and object platform; it does not serve block. There is no
FlashArray in this environment, so **no block StorageClass is coming.** This is
settled — do not ask the admins for one.

Consequence: **NFS is the only option for ACS Central DB.** Red Hat's guidance
steers Postgres toward block (CephFS prohibited, EFS steered away from in
favour of EBS), so running `central-db` on FlashBlade NFS is a known deviation
from the recommended path. It is a supportability caution, not a documented
prohibition — NFS is never named as unsupported for `central-db`.

This raises the stakes on the canary. `manifests/canary-postgres-on-nfs.yaml`
is no longer a nice-to-have pre-check; it is **the test that decides the Central
DB strategy**, and it has still never actually run. Run it the moment mounts
work, before deploying Central.

If Postgres on FlashBlade NFS proves unhealthy, the remaining options are
`hostPath` on local disk (masters have unused `sdb`/`sdc` at 186G; workers have
a 7TB `nvme1n1`) or an external Postgres via `central.db.connectionString` —
**not** block storage.

Sources: [RHACS 4.8 default resource requirements](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.8/html/installing/acs-default-requirements),
[RHACS 4.8 installing on OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.8/html/installing/installing-rhacs-on-red-hat-openshift)

---

## Impact right now

- **Compliance Operator — unblocked.** Running with `rawResultStorage.enabled: false`
  (the CRD's documented option for "environments that don't have storage").
  Check results land in `ComplianceCheckResult` CRs. **Caveat: raw ARF/XCCDF XML
  is not archived**, so this is a working baseline, not durable audit evidence.
  Flip back to `true` and re-run once mounts work.
- **ACS — still blocked.** Central DB needs a real 100Gi PVC; there is no
  storage-less mode. Nothing to do until the VIP is fixed.
- **CNV golden images — blocked**, and will self-heal once mounts work.
