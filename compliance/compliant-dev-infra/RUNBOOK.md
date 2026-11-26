# compliant-dev-infra: the build record

*What happened on this hub, its workload cluster and andalusia, from
2026-11-18 on. The procedure itself is
[../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md), which was written from
this build; read that to build a hub, and this to see what this one is
made of and what went wrong. Open items are marked **TODO**.*

**Where it stands (2026-11-25):** the hub, compliant-dev-workload0 and
andalusia are built, hardened and verified, every compliance component
comes from CCI-MOC/oac-apps main, and all three are at their scan
baselines (verify.sh 72/0, 50/0 and 33/0). andalusia's VM is stopped, to
leave its four H100s free.

compliant-dev-infra replaced [nist-dev-infra](../nist-dev-infra/), the
first FIPS test hub (2026-10-15 to 2026-10-28), built from its
configuration and lessons on new hardware and the standard 3+3 layout.
nist-dev-infra's documents stay as they are: they are the record of that
build. Times are UTC unless they say EDT.

---

## 1. What this hub is

| | |
|---|---|
| Name | `compliant-dev-infra` (decided 2026-11-17) |
| Base domain | `nist.int.massopen.cloud`, kept from nist-dev-infra (tzumainn). API `api.compliant-dev-infra.nist.int.massopen.cloud` |
| Control plane | Three R440s, `MOC-R440-U14` to `U16`, BMCs `10.3.10.114` to `.116`, 48 threads each. No R440 is used as compute |
| Workers | Three pool FC430s, `MOC-R4PAC10U31-S1D`, `-S3A`, `-S3B`, BMCs `10.2.13.164` to `.166`. Second disk for LVM Storage |
| Layout | Standard, not compact: all six installed at once. nist-dev-infra's compact FC830s crashed etcd under FIPS TLS load |
| Networks | Cluster `10.20.18.0/23` (VLAN 219), storage VLAN 2317, both from nist-dev-infra. VIPs `10.20.19.11` and `.12` |
| Disk encryption | Tang on every node's root disk, the masters' etcd disks and the workers' LVM Storage disks. Not TPM: the R440s' TPMs were faulty at the time (#670), and `tpmv2` with no working TPM installs unencrypted without saying so |
| Workload cluster | `compliant-dev-workload0`, an Agent cluster on jetty's two Lenovo SD665-N V3s, 4 H100s each (MOC-issues #787) |
| GPU VM cluster | `andalusia`, a KubeVirt cluster whose one worker VM runs on workload0 with four H100s (#788) |
| FlashBlade realms | `compliant-dev-infra` (10.9.7.10, VLAN 2317) and `compliant-dev-workload0` (10.9.12.10, VLAN 2318), new realms on the old VLANs, since each realm is named after its cluster (MOC-issues #789) |

**Kept from nist-dev-infra, as they were:** the Route 53 zones
`nist.int.massopen.cloud` and `hcp.nist.int.massopen.cloud`, the
`moc-aws-cluster-operators` memberships, the cluster and storage networks
and their firewall rules.

**Copied under the new name,** one PR per repo, because the name is in
the install, the DNS names, the OIDC issuer, the Secrets Manager paths
and the oac-apps paths: oac-apps (`hosted-clusters/`, `values/`, `apps/`,
the pure-cosi overlay), oac-infra (`hub-images/group_vars/`, the
inventory entries), moc-aws (the OIDC provider and roles, ESO prefixes,
the external-dns user, the `s3.` record, the api/api-int/`*.apps`
records), moc-keycloak (clients for both clusters), and Secrets Manager
(`cluster/compliant-dev-infra/{sshkey,portworx,pure-cosi,nfs-tls-ca,keycloak-oidc}`).

**Rebuilt:** the cluster, its kubeadmin kubeconfig, its OIDC signing
keys, the ACS init bundles, and the COSI buckets for Loki and ACM
observability.

### Where each piece came from

| Piece | Where | State |
|---|---|---|
| Inventory and hardware doc | oac-infra [#32](https://github.com/CCI-MOC/oac-infra/pull/32) | Merged |
| Worker switch ports (VLANs 219, 2317) | ansible-switches [#148](https://github.com/CCI-MOC/ansible-switches/pull/148) | Merged and applied (naved001) |
| DNS, OIDC providers and roles, external-dns key | moc-aws [#77](https://github.com/CCI-MOC/moc-aws/pull/77) | Merged and applied |
| Cleanup of nist-dev-infra's OIDC, IAM and cert-manager entries | moc-aws [#78](https://github.com/CCI-MOC/moc-aws/pull/78), moc-keycloak [#69](https://github.com/CCI-MOC/moc-keycloak/pull/69) | Merged and applied |
| Keycloak clients | moc-keycloak [#68](https://github.com/CCI-MOC/moc-keycloak/pull/68) | Merged; both `keycloak-oidc` secrets stored |
| Hub values, compliant-dev-workload0 | oac-apps [#248](https://github.com/CCI-MOC/oac-apps/pull/248), [#254](https://github.com/CCI-MOC/oac-apps/pull/254), [#257](https://github.com/CCI-MOC/oac-apps/pull/257) | Merged; workload0's hosted-clusters entry held back until its workers were ready (#254) |
| Hub vars, boot | oac-infra [#34](https://github.com/CCI-MOC/oac-infra/pull/34), [#35](https://github.com/CCI-MOC/oac-infra/pull/35) | Merged |
| Tang disk encryption: root, etcd, LVM Storage | oac-infra [#36](https://github.com/CCI-MOC/oac-infra/pull/36), [#37](https://github.com/CCI-MOC/oac-infra/pull/37), [#38](https://github.com/CCI-MOC/oac-infra/pull/38); MOC-issues #672, #811 | Merged; installed 2026-11-18 |
| Where the Tang server lives | MOC-issues #810 (naved001) | **Open**; today naved's server at `172.16.1.1` |
| FIPS build host | oac-infra [#33](https://github.com/CCI-MOC/oac-infra/pull/33), [#45](https://github.com/CCI-MOC/oac-infra/pull/45); MOC-issues #792 | Done. `fips-builder`, MOC-R4PCC06U01-N01, 10.2.0.99 (VLAN 911), RHEL 9.9, FIPS on, registered. First full build with upload to the bastion 2026-11-24; #792 closed |
| SD665 switch ports to VLANs 220 and 2318 | ansible-switches [#151](https://github.com/CCI-MOC/ansible-switches/pull/151) | Merged and applied 2026-11-18 |
| FlashBlade realms and CA-marked certificates | MOC-issues #789, everpure-moc [#38](https://github.com/CCI-MOC/everpure-moc/pull/38) | Done 2026-11-19 |
| File integrity, tlshd memory | oac-apps [#198](https://github.com/CCI-MOC/oac-apps/pull/198), [#258](https://github.com/CCI-MOC/oac-apps/pull/258) | Merged 2026-11-19; FIO on all six nodes |

### Access and kubeconfigs

`~/kubeadmin-compliant-dev-infra`, `~/kubeadmin-compliant-dev-workload0`
and `~/kubeadmin-andalusia`, all also in Secrets Manager; break-glass
only. Day to day, `oc login --web`. The R440s' iDRACs use a different
root password from the FC430s' and are on `10.3.10.0/24`, which has to be
in your WireGuard `AllowedIPs`.

---

## 2. Clearing the way: jetty and andalusia (2026-11-17 to 18)

jetty and the first andalusia were only in use by this work, and jetty's
GPU nodes were needed for workload0. Every PVC on both was on the
FlashBlade with reclaim policy `Delete`, and the AI UAT Harness runs were
already local, so nothing on the nodes needed copying.

Order: andalusia first, while jetty still worked, so oac-dev-infra and
jetty's KubeVirt cleaned up after it; then jetty detached from
oac-dev-infra (`preserveOnDelete: true` on its hive ClusterDeployment,
then the ManagedCluster and ClusterDeployment deleted); then jetty's own
test volumes deleted while it still ran, so Portworx removed them from
the FlashBlade; then all five nodes powered off and wiped (800-171
3.8.3). The three FC430s went back to the pool and the two SD665s on to
workload0, with their switch ports moved from jetty's VLANs (218, 2316)
to workload0's (220, 2318).

**The hub's ISO had to be made before jetty went,** because jetty was the
FIPS host it was built on. The FIPS build host has since replaced that.

Afterwards, by PR: jetty's roles in moc-aws (#66), its records in
moc-dns, and its network in oac-infra (MOC-issues #824, closed
2026-11-24).

---

## 3. The hub (2026-11-18 to 19)

Built as [../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) §4 describes.
What was particular to this build:

**Hardware.** The R440s: two 447 GiB SSDs each, `sda` for the install and
`sdb` for etcd, plus four 5.8 TiB NVMe left unused; the cluster network
on the NIC discovery calls `eth2`. The masters have 48 threads, so only
the USBGuard MachineConfig was applied, no `nr_cpus=40` (each master
rebooted once, about 30 minutes). Three things cost time:

- **Secure Boot** was on U15 and U16, and they would not boot the agent
  ISO. tzumainn turned it off (2026-11-18).
- **S1D was in UEFI mode** with no hard disk in its boot order, so its
  discovery ISO dropped to GRUB; switched to legacy BIOS.
- **VLAN 2317's DHCP handed out a default route** (via `10.9.7.1`),
  which sometimes won in early boot, so the node could not reach Tang and
  stayed at the disk unlock prompt. naved removed the gateway
  (2026-11-18).

**The ISO, 2026-11-18,** before the FIPS build host existed: OpenShift
4.22.22, the playbook run on a laptop, failing at the manifests step as
expected; the rendered `work` copied to jetty node `a0-88-c2-27-c2-d4`
(FIPS mode) through a debug pod, tarred with `COPYFILE_DISABLE=1` because
macOS otherwise adds `._*` files the installer cannot parse; there
`openshift-install-fips agent create cluster-manifests`, the Tang
`diskEncryption` block added to `agent-cluster-install.yaml` by hand,
then `agent create image`. The ISO's sha256 was
`bb85301bd3f21f3bb3f8a8fc6e68cef2cecb070a9c21656b29879812acbddbf3`.
Afterwards the node's `/var/tmp/cdi-build` (which holds the pull secret)
and the debug pod were deleted. **None of that is needed now:**
`build.sh <hub>` on the FIPS build host does all of it, including the
upload.

**etcd encryption** was turned on at 2.2 while etcd was empty, so
`api-server-encryption-provider-cipher` passes here. On nist-dev-infra it
was a POA&M item, because re-encrypting a busy hub stalled its masters.

**Storage (2026-11-19).** Three things:

- The realm playbook gave the realm the FlashBlade's self-signed
  certificate (`CA:FALSE`); it was replaced with a CA-marked one through
  the FlashBlade API, and the `.crt` stored and put in the proxy values
  (oac-apps #257). workload0's realm got its certificate the same day.
- tlshd went on before the StorageClass, so the volumes waiting since the
  install bound over TLS.
- `hub-portworx`'s sync from before #257 waited forever on
  nist-dev-infra's NNCPs (`NoMatchingNode`); it had to be terminated and
  re-synced at main. tlshd was then OOMKilled three times at its 256Mi
  limit with four volumes waiting (oac-apps #258 raised it to 1Gi).

`nfs-over-tls` still exists on this hub as a second StorageClass, kept
for volumes created on it on 2026-10-19 (ACS's databases, the etcd
backups, COO's Perses). A new hub sets `storageClass.enabled: false` and
has only `pure-fb-nfsv4`.

**Object storage (2026-11-19).** The bucket was Ready at once, but ACM
observability's ten Thanos pods could not pull
`registry.redhat.io/rhacm2/thanos-rhel9`: "denied: Token rejected by
upstream registry". The same pull failed from oac-dev-infra with another
pull secret, and other `rhacm2` images pulled fine, so it was Red Hat's
registry, not this hub. It cleared by itself about 19:30, after about six
hours.

**Node hardening (2026-11-19).** Both pools paused, 379 MachineConfigs
applied, both unpaused at 13:28: one master and one worker at a time,
about 10 minutes each, all done by 14:05. Every node came back unlocked
by Tang, with `fips=1 audit=1 nousb pti=on`; etcd stayed 3/3. USBGuard
then ran on the masters only, and the worker scan failed
`service-usbguard-enabled`, so the worker MachineConfig followed (22:09
to 23:12).

**Audit logging (2026-11-19).** At Loki's defaults (2 MB/s, 256 kB lines)
it refused about 110 pushes a minute and dropped lines holding whole
ConfigMaps; about 18 lines were lost before the hub's audit-logging
values gave the `audit` tenant the same limits as `application`.

**First verify: 2026-11-19, 23:40, 73 PASS, 0 FAIL, 5 WARN, 4 SKIP.**
The first run had 6 FAILs:

| Test | Failure | Fix |
|---|---|---|
| T-10 (4) | Each allowlisted registry reported as missing | A bug in the check: it compared hostnames with path-scoped allowlist entries. It now compares whole image references |
| T-14 | No backup yet; then the backup PV was `Delete` and the job's `cli` image was 4.22.14's | Ran a backup by hand; patched the PV to `Retain`; set the 4.22.22 `cli` digest |
| T-16 | AIDE flagged u16's `/etc/coredns/Corefile`, rewritten by its reboot | Re-initialised u16 |

The compliance evidence PVs were also `Delete`; all eight are now
`Retain`. The WARNs are known: the FIPS validation record needs
re-review for this RHCOS and its OpenSSL provider build (MOC-issues
#781), and three operators claim no FIPS support, each accepted with a
reason.

The storage network's DHCP also put its DNS server in every worker's
`resolv.conf`; oac-apps
[#261](https://github.com/CCI-MOC/oac-apps/pull/261) turns that and its
default route off on every cluster.

### The hub's scan baseline

**3 distinct rules**, in `../tests/baseline-compliant-dev-infra.txt`:
`kubeadmin-removed` and `configure-network-policies-namespaces` (both
scans) and `cluster-wide-proxy-set`. All eight node scans pass. What each
one is, and why it is accepted, is in
[../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) 4.14.

nist-dev-infra reached 4 distinct rules; the fourth,
`api-server-encryption-provider-cipher`, passes here because etcd
encryption was turned on at install. These closed during that build and
stay closed by the charts; if one reappears, this is what fixed it:

| Rule | Fix |
|---|---|
| `resource-requests-quota` | Quotas for every non-platform namespace, in the guardrails values |
| `audit-log-forwarding-uses-tls` | A scanner false positive: a `lokiStack` output has no url. Tailored |
| `resource-requests-limits-in-daemonset`, `-statefulset`, `-deployment` | Operator-owned namespaces exempted, rationale `vendorLimits`; pure-cosi v0.1.2 set requests and limits on its own controller and driver |
| `ocp-allowed-registries`, `-for-import`, `reject-unsigned-images-by-default` | A registry allowlist built from an inventory of every image reference on the hub. The allowlist left `openshift-samples` Degraded until `imageConfig.samplesRegistry: registry.redhat.io` |
| `routes-rate-limit`, `route-ip-whitelist` | First a script, then the platform-hardening `routeAnnotations` ACM policies (§6) |
| `ingress-controller-certificate` | A Let's Encrypt wildcard apps certificate (oac-apps [#184](https://github.com/CCI-MOC/oac-apps/pull/184)). The API certificate stays off |
| `default-ingress-ca-replaced` | Tailored, rationale `ingressCert`: the rule wants a custom CA in `proxy/cluster`, and a publicly issued certificate needs none |
| `idp-is-configured`, `oauth-or-oauthclient-inactivity-timeout`, `-token-maxage` | MOC SSO with 24-hour tokens and a 10-minute inactivity timeout (moc-keycloak [#55](https://github.com/CCI-MOC/moc-keycloak/pull/55), oac-apps [#188](https://github.com/CCI-MOC/oac-apps/pull/188)) |
| `audit-profile-set` | `platform-hardening` `apiServerAudit: WriteRequestBodies`, server-side applied so Argo takes the field from the cluster-version-operator |

---

## 4. compliant-dev-workload0 (2026-11-19 to 20)

Built as [../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) §6. oac-apps #260
merged at 23:43 on 2026-11-19; the control plane was available at 23:49
and both SD665s joined at 00:26 (4.22.22, FIPS on both).

**The workers.** Both SD665s left ESI uncleaned (ansible-switches #151
moved their ports mid-clean), so their disks still held jetty's data and
were wiped by hand from the discovery ISO; the `lsblk` records are in
`~/work/drafts/sd665-wipe/`. Their XCC would not mount the hub's ISO URL
itself, rejecting the Let's Encrypt certificate even with the chain
imported, so each was mounted from the BMC's web console and booted once
over Redfish. At POST, "Platform secure boot fuse is enabled but CPU 1, 2
are unfused" is informational; do not fuse, it cannot be undone. The node
sits at UEFI DXE INIT for several minutes before GRUB.

**What went wrong, and the fixes:**

| Problem | Cause | Fix |
|---|---|---|
| Agents stuck "insufficient": ignition not downloadable | The hub's `router-hosted-clusters` Service got 10.20.19.200 from MetalLB's default pool, not its pinned 10.20.19.10: the Service and the pinned pool were created in the same second at bootstrap, and MetalLB never moves an assigned address | Deleted the Service; the ingress operator recreated it with the right address. **TODO:** an `hcp-config` PR putting the pool in an earlier wave |
| Ingress certificate not issued | cert-manager tried its Route 53 role before the OIDC keys were uploaded, then backed off | Deleted the challenge; issued at once |
| Two apps Unknown | Helm release names over 53 characters | `releaseName: "{{component}}"`, now how every compliance ApplicationSet names releases |
| One ACS collector in CrashLoopBackOff (exit 137) | 1Gi limit; 512 CPUs per node, per-CPU eBPF buffers | 3Gi limit in workload0's rhacs values |
| AIDE failed on all three hub workers | LVM Storage wrote `/etc/lvm/archive/*` and `/etc/lvm/backup/vg0` when it made workload0's etcd volumes | Re-initialised; oac-apps [#264](https://github.com/CCI-MOC/oac-apps/pull/264) excludes those paths |
| The hub's `routes-rate-limit` failed | HyperShift adds `ignition-server`, `konnectivity-server` and `oauth` routes in `clusters-<cluster>` | The script was re-run then; the ACM policies cover new routes now (§6) |

**Disk encryption on the workers (2026-11-20).** oac-apps #263 (the
chart: a pool's machineConfigs may carry Ignition `luks` and
`filesystems`), #265 and #266. Both SD665s reinstalled 17:12 to 18:10.
Three things it took:

- **Scaling to 0 hung on the drain:** with both nodes going, each held
  the last copy of pods under a disruption budget, and the NodePool's
  `nodeDrainTimeout` is 0. Annotating both Machines with
  `machine.cluster.x-k8s.io/exclude-node-draining` released them, and the
  Agents rebooted into discovery by themselves.
- **One node came up with CRI-O failing:** `nodeip-configuration` had
  recorded the NIC's lease before `br-ex` took over.
- **On the other, multus crash-looped** (`pthread_create failed`): about
  70 pod network requests at once, each a Go CNI plugin starting a thread
  per CPU (512) inside multus's pod, passed the pod limit of 4096
  processes. Unblocked by raising that pod's cgroup `pids.max` to 65536
  on the node; kubelet resets it at each container restart, so it had to
  be rewritten in a loop across multus's next restart. The lasting fix is
  `podPidsLimit` for the pool: oac-apps #268 (chart) and **TODO** #276
  (the value). It recurred on 2026-11-23 and stalled a roll for an hour.

**Storage (2026-11-20).** oac-apps #269 (Portworx, object-storage-proxy
and the storage registries for hosted clusters, applied without a node
roll) and #270 (the ClusterSecretStore served only `openshift-config`;
portworx, object-storage-proxy and nfs-tls added). What it took: Argo
gave up on tlshd's DaemonSet while its secret could not sync, so the app
needed a re-sync; the six VM boot images were made as Block in the
minutes before CDI's StorageProfile applied, and Block mounts without
`xprtsec=tls`, so the DataVolumes were deleted and the DataImportCrons
remade them as Filesystem; and a changed ScanSetting only reaches
existing scans if the suites are remade (`oc delete compliancesuite --all`).

**etcd backups for hosted clusters (2026-11-20).** The etcd-backup chart
takes `hostedClusters`: per cluster, a CronJob in the hub's `etcd-backup`
namespace at 03:00 UTC runs `etcdctl snapshot save` in a ready etcd pod,
streams it to its own volume and checks the hash (136 MB, 14 kept). No
privileges beyond exec in `clusters-<cluster>`. A restore also needs the
cluster's Secret encryption key, which the hub's own backup holds.

**Baseline: 2 distinct rules**
(`../tests/baseline-compliant-dev-workload0.txt`):
`cluster-wide-proxy-set`, as on the hub, and
`configure-network-policies-namespaces` for portworx,
object-storage-proxy and the two reinstall namespaces. **TODO:** policies
from ACS's observed flows.

**TODO:** the tailoring rationales in the hosted-clusters compliance
values say "checked on the hub, 2026-10-22/23": that was nist-dev-infra,
and they have not been re-checked here. The hub now has HyperShift's
`auditlogpersistenceconfigs` CRD, which may end the audit-retention
exception.

---

## 5. GPU passthrough and andalusia (2026-11-20 to 24)

workload0's H100s go to KubeVirt VMs only. The generic steps are in
[../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) §7 and §8; the pieces are:

| Piece | Where |
|---|---|
| NFD and the GPU Operator, vm-passthrough on workload0 and container mode inside andalusia | `values/compliant-dev-infra/{compliant-dev-workload0,andalusia}/{nfd-operator,nvidia-gpu-operator}.yaml`, deployed by `compliance-gpu-clusters` (oac-apps #292, #294) |
| `defaultWorkload` as a chart value | oac-apps [#286](https://github.com/CCI-MOC/oac-apps/pull/286) |
| HyperConverged `permittedHostDevices` (`10DE:2330`) and `maxHotplugRatio: 1` | oac-apps #273 |
| `vfio_iommu_type1` at boot | oac-apps #272 |
| andalusia itself | oac-apps [#275](https://github.com/CCI-MOC/oac-apps/pull/275), merged 2026-11-23 |
| 1Gi hugepages | oac-apps [#287](https://github.com/CCI-MOC/oac-apps/pull/287) |
| `evictionStrategy: None` | oac-apps [#288](https://github.com/CCI-MOC/oac-apps/pull/288) |

Passthrough was proven on 2026-11-20: each node advertised
`nvidia.com/GH100_H100_SXM5_80GB: 4`, every H100 on `vfio-pci`, and
`../vms/gpu/test-gpu-vm.sh` tiers 1 to 3 passed at 15.52 GB/s
host-to-device, as on jetty.

**andalusia** is API 10.20.19.14 (the hub's pool), one VM with 64 vCPUs,
128Gi, a 300Gi `pure-fb-nfsv4` disk and 4 H100s, no pinned node, FIPS
from the hub default, ingress pinned at 10.20.20.11 on workload0. No disk
encryption in the guest: the FlashBlade encrypts at rest (CMVP #5000).
Still open for it:

- **TODO:** MOC SSO; it needs a moc-keycloak client, kubeadmin only until
  then.
- **TODO:** `qosClass: Guaranteed` (dedicated host CPUs), which needs the
  static CPU manager on workload0.
- **TODO:** 10.20.20.11 does not answer ping; not yet confirmed outside
  VLAN 220's DHCP range.

Its own first verify (2026-11-23) needed: its name in the hub's
etcd-backup `hostedClusters` and audit-logging `auditWriters.clusters`;
`securedCluster.clusterName` and an ACS init bundle; its scan results on
`kubevirt-csi-infra-default`, after which the Pending result PVCs had to
be deleted and the scans re-run; guardrails without `metallb-system` and,
until oac-apps #281, `external-secrets`; and nfs-tls left out. T-15
cannot reach the worker's kubelet (it is on workload0's pod network) and
WARNs; probed from a pod in `clusters-andalusia` it offers TLS 1.3 and
1.2 GCM and refuses CBC.

### The transient domain (2026-11-23)

andalusia's VM came up as a transient libvirt domain on every start, and
every later hot-plug failed with "transient domains do not have any
persistent config": its new PVCs stopped at `MountedToPod` on workload0
and their pods sat in ContainerCreating.

**Cause (CNV 4.22.16):** QEMU took about 19 s to start this VM, because
VFIO pins all 128Gi, longer than virt-handler's SyncVMI call waits. The
call timed out; on the retry virt-handler saw the VMI still `Scheduled`
with the domain `Shutoff`, treated it as shut down and signalled deletion
(vm.go:1711). The launcher ran that delete as soon as the start finished,
so its log shows "Domain started", "Domain undefined" and "Signaled vmi
deletion" in the same millisecond, while the guest kept running. Small or
1-GPU test VMs start in under a second and were never affected.
Stop/start did not help.

**Fix:** 1Gi hugepages (oac-apps #287). workload0's `91-hugepages-1g`
reserves 136 pages per node at boot, and andalusia's `hugepages: 1Gi`
patches the VM through HyperShift's `kubevirt-vm-jsonpatch` NodePool
annotation. The VM now starts in 5 to 7 s with a persistent domain.
Check: `virsh dominfo 1` in the launcher's compute container says
`Persistent: yes`; `no` (verify.sh T-07 FAILs) means it started without
hugepages, and the workaround is to re-define the running domain from its
live XML (`$W0` is workload0's kubeconfig):

```
L=$(KUBECONFIG=$W0 oc -n clusters-andalusia get pod -l kubevirt.io=virt-launcher -o name)
KUBECONFIG=$W0 oc -n clusters-andalusia exec $L -c compute -- sh -c '
V="virsh -c qemu+unix:///session?socket=/var/run/libvirt/virtqemud-sock"
$V dumpxml 1 > /var/run/kubevirt-private/live.xml && $V define /var/run/kubevirt-private/live.xml
$V dominfo 1 | grep Persistent'
```

### Rolls, drains and stopping the VM

#287's own roll stalled on the VM for 30 minutes: it is not
live-migratable and its eviction strategy was `External`, so CAPK on the
hub handled the eviction and failed every few seconds with "no matches
for kind \"KubevirtMachine\"", which exists on the hub but not on
workload0 (MOC-issues #826). `evictionStrategy: None` (#288) is the fix;
it has **not yet been tested with the VM running**, because in the
2026-11-24 roll the VM was already stopped.

**After stopping the VM, or deleting its VMI, clear the Machine's failure
on the hub.** `virtctl stop` makes CAPI record "VMI has reached a
permanent finalized state", which never clears; the Machine stays
`Failed`, HCCO marks andalusia's ingress endpoint on workload0 not ready,
MetalLB stops announcing 10.20.20.11, and the console and apps are
unreachable.

```
KUBECONFIG=$HUB oc patch machine.cluster.x-k8s.io -n clusters-andalusia <machine> \
  --subresource=status --type=json \
  -p '[{"op":"remove","path":"/status/failureReason"},{"op":"remove","path":"/status/failureMessage"}]'
```

HCCO's machine controller then marks the endpoint ready within seconds;
if the endpoint slice is missing, restart
`hosted-cluster-config-operator` in `clusters-andalusia` on the hub.
HCCO's "router-nodeport-default not found" errors are expected: andalusia
publishes its router as a LoadBalancer, not through HyperShift's NodePort
passthrough.

**GPU tests, 2026-11-24.** AI UAT Harness (Ahmed Sanaullah),
`-t component,chunked-prefill,llm-d-local -p`, run 20261124_024623, 43
minutes: 14 of 64 failed (19 the day before). chunked-prefill passed.
component's 5 are host-tuning checks a VM cannot meet (no cpufreq or
cpuidle in the guest, THP) with no expected values in the cluster file.
llm-d-local's 9 all follow from its `header-injector` image,
`docker.io/nginx:1.27-alpine`, which the registry policy rejects; behind
that it would fail anyway, because its image bundles an opencv that is
not FIPS-compatible, so llm-d-local is not expected to pass on a FIPS
cluster. The harness namespaces were then deleted and the VM stopped at
03:31, so it does not hold four H100s idle. To bring andalusia back:
`virtctl start`, then clear the Machine's failure above if it is
`Failed`, and re-initialise AIDE once the GPU driver has rebuilt.

---

## 6. Moving onto oac-apps main (2026-11-24)

The three hand-applied ApplicationSets on the fork's
`compliant-dev-infra-test` branch were replaced by main's (MOC-issues
#736):

| oac-apps PR | ApplicationSet | Deploys |
|---|---|---|
| [#284](https://github.com/CCI-MOC/oac-apps/pull/284) | (chart) | audit-logging |
| [#290](https://github.com/CCI-MOC/oac-apps/pull/290) | `hub-components-compliance` | the hub's nine components, with the route-annotation ACM policies in platform-hardening |
| [#291](https://github.com/CCI-MOC/oac-apps/pull/291) | `compliance-clusters` | six components to every hosted cluster, nfs-tls to Portworx clusters |
| [#292](https://github.com/CCI-MOC/oac-apps/pull/292), [#294](https://github.com/CCI-MOC/oac-apps/pull/294) | `compliance-gpu-clusters` | NFD and the GPU Operator, to clusters with GPU Operator values |
| [#288](https://github.com/CCI-MOC/oac-apps/pull/288) | (andalusia values) | `evictionStrategy: None` |
| [#296](https://github.com/CCI-MOC/oac-apps/pull/296) | (hub guardrails values) | quotas for andalusia's three namespaces on the hub |

tlshd moved from a personal registry to `ghcr.io/cci-moc/tlshd`, built by
CCI-MOC/tlshd's workflow with MOC's RHEL subscription (activation key
`tlshd-ci`), and `ghcr.io/eldritchjs` left both allowed-registry lists.
The image is public for now; requiring authentication to pull it is
deferred (MOC-issues #780).

**Cutover, per ApplicationSet:** remove the resources finalizer from its
Applications, delete the ApplicationSet with `--cascade=orphan`, delete
the Applications, then merge. Main's Applications adopted the objects in
place. #292 went first (16:18), then #288, #290 and #291 at 18:19.

**The roll.** Main's node hardening encodes its files as base64 where the
fork used URL encoding, so the hub's MachineConfigs and the NodePools'
ConfigMap changed although the file contents did not. Every hub node
rebooted once, workload0's two nodes updated in place, and andalusia's VM
was replaced, then stopped to free the GPUs. It finished at 19:19.

**The outage, 18:45 to 18:51.** A power cycle of u14 for the TPM work
below overlapped the MachineConfig reboot of u16, leaving the hub one
master, so the hub's API went away; the hosted etcd members on the hub's
workers lost their node heartbeats and workload0's etcd lost quorum. It
recovered by itself once the nodes were back. **The lesson is now in the
procedure** ([../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) §10):
hardware work on a hub node waits until a roll has finished, then goes
one node at a time.

**Route policy messages.** The hub's `route-rate-limits` policy listed
every route it matched in its compliance message (1866 characters), over
the 1024 an event allows, so its compliance events were rejected and left
no trail for SC-5 (found by schwesig on #290). #290 added
`customMessage`: a route count when compliant, the failing routes when
not. #295 added the fallback for a failure with no route at fault, such
as an API error, which uses ACM's default message cut to 900 characters.
ACM's separate "Policy status updated" event still uses the default
message and is still rejected on the hub; `customMessage` does not apply
to it.

**TPMs (hakasapl, same day),** one master at a time with the master pool
paused and the node drained:

| Node | Result |
|---|---|
| u14 | TPM 2.0 at `/dev/tpmrm0` after enabling it in the BIOS |
| u15 | Module replaced, but its **CMOS battery is dead**, so BIOS settings do not persist: still no TPM |
| u16 | TPM not enabled |

Secure Boot is off on all three. Nothing in our scans or in ACS requires
it, and with it on, u14's firmware refused the PCIe SSD's option ROM
(`UEFI0072`) and the node would not boot.

**Checks afterwards.** At 21:12, workload0 was at its scan baseline with
verify.sh 50/0, and the hub was at 70/2: `resource-requests-quota` for
andalusia's three namespaces on the hub, which had had no quota since
andalusia arrived on 11-23 (the hosted-cluster chart's `machine-limit`
quota is for agent clusters only, and andalusia is KubeVirt), and AIDE
Failed on four nodes for the machine-config daemon's logs. #296 fixed the
first and the AIDE re-inits the second: **the hub is back at 72/0, with
nist-ocp4-moderate at its 3 accepted rules.** andalusia is to be verified
when its VM next runs.

---

## 7. andalusia verified, and the eviction fix proven (2026-11-25)

The VM was started at 02:12 for the checks #788 was waiting on, and
stopped at 02:59; 47 minutes of GPU time.

**It came up clean.** The libvirt domain was **persistent** from a cold
start, so #287's hugepages hold without the re-define workaround; the
node was Ready and the HostedCluster Available two minutes after the
start, with no Machine failure to clear; all 19 Argo apps reached
Synced/Healthy. The GPU driver rebuilt in about nine minutes, after
which the node advertised its four H100s.

| Check | Result |
|---|---|
| Scans | At baseline: hosted-ocp4-cis 1, hosted-ocp4-moderate 2 |
| `verify.sh` (with `HUB_KUBECONFIG`) | **33 PASS, 0 FAIL**, 5 WARN, 8 SKIP |
| `cluster-acceptance.sh --gpu` | **9 PASS, 0 FAIL**: ClusterPolicy ready, 4 GPUs advertised, host driver running, CUDA runs in a pod, no GPU left claimed |

Two things needed a nudge, both expected and both in the procedure:
AIDE's first run flagged the GPU Operator's
`/etc/crio/crio.conf.d/99-nvidia.conf` and was re-initialised; and
`nvidia-dcgm-exporter` crash-looped four times losing a startup race with
`nvidia-dcgm` ("Failed to connect to remote hostengine"), which left the
ClusterPolicy `notReady` until it recovered by itself.

### The drain test (MOC-issues #826)

Draining `a0-88-c2-27-c2-d4` on workload0, the node holding the VM, with
`evictionStrategy: None` from #288:

| | `External` (2026-11-24) | `None` (2026-11-25) |
|---|---|---|
| Drain | Stalled 30 minutes, node cordoned indefinitely | **Finished in 54 s** |
| VM | Had to delete the VMI by hand | Shut down and restarted itself on the other node in about 40 s |
| CAPI Machine | Went `Failed`, needed clearing by hand | **Stayed `Running`** |

So #288 removes both by-hand steps, not only the stall. The Machine also
stayed `Running` through the later stop, which used to be the other way
the failure appeared. KubeVirt's hotplug-volume webhook refused to evict
a volume pod for a few seconds while the VMI was still alive; it cleared
by itself. **#826 is closed.**

### Cluster registration secrets, tested and not adopted

The ACS init bundle is applied by hand on every cluster, although the
rhacs chart's values say credentials should come from the secret store.
ACS 5.0 has cluster registration secrets, which looked like the way to
automate it: one reusable secret, and each new cluster registers itself.

Tested on andalusia (certificates backed up first). The operator
supports it with no prompting: a `crs` init container appeared in the
sensor pod as soon as `cluster-registration-secret` existed, and it
reached Central. Central then refused it:

```
PermissionDenied: not authorized: forbidden to use a Cluster Registration
Certificate for already-existing cluster "andalusia"
```

**A CRS onboards a cluster Central has never seen; it cannot re-issue
certificates for one that is already registered.** andalusia's
certificates were restored from the backup and it reached Central again
at 02:42. The approach is sound for new clusters and is written up in
[../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) 4.11; wiring it to the
secret store is MOC-issues #830, to be tried on the next new cluster
rather than by disturbing a working one.

---

### verify.sh T-25, added 2026-11-25

Running Ahmed Sanaullah's compliance branch of the AI UAT Harness on both
clusters turned up three namespaces with no default-deny NetworkPolicy
that our guardrails values already intend to close, which nothing of ours
was checking. `verify.sh` gained T-25 for it, with
`networkpolicy-default-deny-accepted.txt` holding the namespaces carried
under the broad `configure-network-policies-namespaces` gap, which WARN.

**T-25 reports 3 FAILs on each cluster: the hub 72/3, workload0 49/3.**
`stackrox` was closed the same day by oac-apps #299, which took it to 2,
and then two corrections to the check itself took it back to 3. Both are
worth recording, because the first repeated a mistake I had just found in
someone else's code:

- T-25 counted only a **zero-rule** policy as closing a direction. A pod
  selected by any Ingress policy is isolated and only what that policy
  allows gets through, so HyperShift's all-pods allow policies in a
  `clusters-*` namespace do close ingress. The check now counts any
  all-pods policy naming a direction, which is the same correction made
  to the harness's C-07 an hour earlier.
- `clusters-compliant-dev-workload0` had been accepted while the
  identical `clusters-andalusia` had not. Both are HyperShift control
  planes on the hub with the same four policies, so the acceptance was
  removed rather than extended: these namespaces hold the hosted etcd,
  and their egress is unrestricted.

What is open now:

| Namespace | Why it is open | Can it be closed now |
|---|---|---|
| `clusters-andalusia`, `clusters-compliant-dev-workload0` | HyperShift control planes on the hub: its four policies close ingress but nothing closes egress. On the hypervisor `clusters-andalusia` is the VM namespace instead, and is open both ways | **Not yet.** HyperShift owns those namespaces and ships the policies; ours could conflict on upgrade. Likely an exception to record rather than a policy to write, but the egress gap is real and these hold hosted etcd |
| `metallb-system` | its guardrails entry has a quota only | **No.** The webhook server and controller need ingress from the API server, which for a hosted cluster comes from the hub; closing it without that rule breaks MetalLB admission, and MetalLB publishes `router-default` and andalusia's ingress. The `speaker` pods are `hostNetwork`, so a policy neither affects nor protects them |
| `clusters-andalusia` | no guardrails entry on the hypervisor | **No.** On the hypervisor this is the VM itself and on the hub andalusia's control plane; needs KubeVirt, CSI and console traffic measured first |

The last two belong with the broad gap rather than apart from it: they
need ACS's Network Graph to measure the flows before a policy can be
written safely. All three are tracked in MOC-issues #832, and the counts
go back to 0 by fixing them rather than by listing them as accepted.

Two of the harness's own checks were wrong and were fixed back to it
(asanaullah/ai-uat-harness#16): it looked for ClusterLogForwarder in
`logging.openshift.io`, which Cluster Logging 6 moved to
`observability.openshift.io`, so it reported that audit logs were not
forwarded on a cluster that had been forwarding them for five days; and
it accepted a default-deny only as a single policy naming both
directions, not as the ingress and egress pair we render, which buried
the three real namespaces under thirty-two.

## 8. Monitoring that was not working (2026-11-26)

Three things closed out, and a pattern found by looking for a fourth.

**`metallb-system` closed (oac-apps #301).** MetalLB ships a NetworkPolicy
but it selects only the controller pods, leaving the operator's two
uncovered, which is why the namespace counted as open in both directions.
Measured with ACS's Network Graph over seven days: ingress 9443 for the
webhooks, 8080 and 7472 for metrics, egress to the API server and DNS and
nothing else. The same rule works on both clusters because the API server
reaches the webhook over host network on the hub and through the
konnectivity agent on a hosted cluster, and that agent is itself
hostNetwork. Tested before proposing: the webhook still accepted a good
IPAddressPool and still rejected a malformed one, and a six-minute soak
showed no restarts and every LoadBalancer address up. `speaker` is
hostNetwork, so none of this protects the speakers.

**The hypervisor's `clusters-andalusia` is a permanent exception.** It had
been recorded as "not measurable while the VM is stopped", which was
wrong. The VM was started for twenty minutes to settle it: ACS shows the
virt-launcher deployment and zero flows for it, while the same cluster
recorded 64 edges elsewhere in thirty minutes. The VM attaches with bridge
binding on the pod network and the guest is itself an OpenShift node
running its own OVN - `ovn-k8s-mp0`, `br-int` and nested veths are all
visible inside it - so one interface carries an entire nested cluster's
traffic. A default-deny there would have to allow everything a cluster
needs. No further measurement changes that. The VM holds four H100s while
it runs, so it was stopped again.

### Monitoring was failing silently in six namespaces

Found while checking that the new `metallb-system` policies would not break
a metrics scrape. There was no scrape to break.

Operators write **platform-intent** ServiceMonitors - a bearer token file
and the platform Prometheus's certificate paths - into namespaces that
carry no `openshift.io/cluster-monitoring` label. The platform Prometheus
reads only labelled namespaces, and user workload monitoring refuses any
ServiceMonitor that reads the filesystem, so the monitors are rejected and
the only sign is an `InvalidConfiguration` event. Everything looks right:
the ServiceMonitors exist, the Services have endpoints, the namespace looks
monitored. Only the absence of data gives it away.

| Namespace | What is lost | Status |
|---|---|---|
| `metallb-system` | both ServiceMonitors; no MetalLB metrics on any cluster, production included | fixed by oac-apps #302, which labels the namespace |
| `external-dns-operator` | operator metrics | recorded; we install the operator but do not own its namespace manifest |
| `openshift-storage` | LVM Storage operator metrics. An `openshift-*` namespace, so this is not only third-party charts | recorded |
| `openshift-nfd` | Node Feature Discovery operator metrics, on workload0 rather than the hub | recorded |
| `patch-operator` | operator metrics | moot, the operator is being removed (MOC-issues #831) |
| `openshift-cluster-observability-operator` | its **PrometheusRule** is loaded by no ruler at all, so the observability operator's own alerts never fire | recorded |

The last one is a different half of the same cause. That rule carries
`openshift.io/user-monitoring=false`, which deliberately keeps user
workload monitoring away, and its namespace is unlabelled, so the platform
Prometheus will not read it either. Checked against all three rulers on the
cluster.

Verified the fix end to end on the hub rather than reasoning about it: with
the label applied and all four of #301's policies in place, the platform
Prometheus brought up all seven MetalLB targets - the controller and six
speakers - inside two minutes, and `metallb_k8s_client_updates_total`
returned seven series. A prediction in MOC-issues #834 that this would need
a `monitoringPorts` allow was wrong and has been struck: MetalLB's own
policy already permits the named port `metricshttps`, which resolves to
kube-rbac-proxy's container port 9120 on the controller pod, and the
speakers are hostNetwork.

### Three checks added, and one corrected

- **T-26** alerts have a destination. The hub's Alertmanager has three
  receivers, `Default`, `Watchdog` and `Critical`, and all three are
  **empty**: every alert fires and notifies nobody. It warns until a
  receiver exists (P9).
- **T-27** no ServiceMonitor is being rejected. 162 on the hub, 5 rejected,
  each recorded in `tests/monitoring-accepted.txt`.
- **T-28** every PrometheusRule is loaded by a ruler and evaluating. 77 on
  the hub, one accepted in `tests/prometheusrule-accepted.txt`.
- **T-19 was reassuring us wrongly.** It counted the word "tang" in
  `clevis luks list`, which prints one `sss` line however many urls it
  holds, so it could not tell two servers from one server under two names.
  It now resolves each url: compliant-dev-infra's two pins,
  `tang.massopen.cloud` and `172.16.1.1`, are the same address at threshold
  1, so all six nodes now warn that there is no Tang redundancy
  (MOC-issues #810). That matters for the production build, which is
  planned on hardware with the same constraints.

### etcd backups

All three runs succeeded on the first attempt in 42 to 47 seconds, so
MOC-issues #833 did not recur the night after it was found. The truncation
is intermittent rather than a permanent break, which is the failure a retry
fixes; oac-apps #300 is still the right change.

---

## 9. Still open

- **TODO:** MOC SSO for andalusia, the last open item on MOC-issues
  #788. moc-keycloak [#71](https://github.com/CCI-MOC/moc-keycloak/pull/71)
  adds its OIDC client; once that is applied and the secret is in Secrets
  Manager, an oac-apps change sets `oauth.mocsso.enabled` and HyperShift
  drops kubeadmin.
- **TODO:** deliver the ACS secured-cluster credential from the secret
  store instead of by hand (MOC-issues #830), on the next new cluster.
- **TODO:** oac-apps [#234](https://github.com/CCI-MOC/oac-apps/pull/234)
  (node labels with ConfigurationPolicies), the last open upstreaming PR
  (MOC-issues #736).
- **TODO:** u15's CMOS battery, so its BIOS settings persist and its TPM
  can be enabled.
- **TODO:** a more reliable home for the Tang server, and a DNS name for
  it so a later move is only a key copy (MOC-issues #810).
- **TODO:** MOC-issues #832, now down to one item. `stackrox` was closed by
  oac-apps #299 and `metallb-system` by oac-apps #301; the hypervisor's
  `clusters-andalusia` is a permanent exception (§8). What is left is
  whether HyperShift should ship egress policies for its own
  control-plane namespaces, carried on MOC-issues #756. T-25 fails 0 on
  both clusters, with the remainder recorded as accepted exceptions.
- **TODO:** NetworkPolicies for the hub's namespaces, for the production
  setup (§3), and for workload0's remaining four (§4).
- **TODO:** `podPidsLimit` for workload0's pool, oac-apps #276.
- **TODO:** have someone other than the original builder walk through
  [../NEW-HUB-RUNBOOK.md](../NEW-HUB-RUNBOOK.md) and fix what is unclear.
- **TODO:** ACS's scanner hits its memory limit about every 35 minutes on
  the masters; raise the limit or run fewer replicas.
- **DONE 2026-11-25:** u17's iDRAC log has "Correctable memory error rate
  exceeded for DIMM_B5" (2026-10-17). Reported on oac-infra
  [#48](https://github.com/CCI-MOC/oac-infra/pull/48), where u17 was
  listed as a production control node; tzumainn replaced it with **u20**
  in that PR and in ansible-switches #159. The kernel
  logged no corrected errors from 2026-10-22 on. u17 is not part of this
  hub.
