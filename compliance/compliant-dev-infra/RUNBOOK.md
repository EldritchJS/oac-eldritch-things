# Building compliant-dev-infra and its workload cluster

*Runbook, draft (2026-11-17). Not yet run. Open items are marked
**TODO**.*

compliant-dev-infra is a new compliant hub, with R440s as its control
plane and three pool FC430s as its workers, built from the
configuration and lessons of [nist-dev-infra](../nist-dev-infra/), the
first FIPS test hub (2026-10-15 to 2026-10-28). nist-dev-infra's documents
stay as they are: they are the record of that build and its results. This
runbook follows them step for step, changing what the new name, the
standard 3+3 layout and the new hardware change. The reasons behind each step
are in [BUILD.md](../BUILD.md); what happened on nist-dev-infra, stage by
stage, is in [nist-dev-infra/README.md](../nist-dev-infra/README.md).

The steps after section 2.2 are nist-dev-infra's, with the hub's name
changed; read each against the new layout as you go. Section 4 still
builds the workload cluster as nist-dev-workload0 was built; here it is
`compliant-dev-workload0`, the GPU hypervisor cluster on jetty's two
SD665-N V3s (MOC-issues #787), so its node and GPU steps still need
writing for that hardware.

Times are UTC unless they say EDT.

---

## Before you start

**Access you need:**

| For | Access |
|---|---|
| The kubeadmin kubeconfig, ACS secrets, the preflight | AWS SSO, `SecretsManagerOperatorAccess` permission set |
| Uploading OIDC signing keys (2.4, 4.3) | AWS SSO, `ClusterOperatorAccess` (membership in `moc-aws-cluster-operators`) |
| The hub's nodes | The MOC VPN, with the hub's subnet in your WireGuard `AllowedIPs`, and the BMCs, in case a node does not come back |
| The install | CCI-MOC/oac-infra `hub-images`: the pull secret and SSH key for `credentials/compliant-dev-infra/` (not in git). The pull secret's account needs ACM and ACS entitlements too (check in 2.8) |
| PRs | Write to forks of CCI-MOC/oac-apps; reviewers named in §6 |

**Tools:** `oc`, `helm`, `aws`, `jq`, `gh`, `ansible` with
`ansible.utils`, and `openshift-install-fips` for 4.22.

**Checkouts:**

```
git clone https://github.com/CCI-MOC/oac-apps.git ~/oat/oac-apps
git clone https://github.com/CCI-MOC/oac-infra.git ~/oat/oac-infra
git clone https://github.com/EldritchJS/oac-eldritch-things.git ~/oat/oac-eldritch-things
```

**Shell setup**, for every session (the profile names end in the MOC AWS
account number, shown here as `<account>`):

```
export SM=SecretsManagerOperatorAccess-<account>
export CO=ClusterOperatorAccess-<account>
export HUB=$HOME/kubeadmin-compliant-dev-infra
export RB=~/oat/oac-eldritch-things/compliance/nist-dev-infra   # scripts and MachineConfigs, shared with the first build
export CB=~/oat/oac-eldritch-things/compliance/compliant-dev-infra   # this hub's stage files
aws sso login --profile $SM
```

**Health check before any change that restarts something on the hub**
(the masters stall under load; see 5):

```
KUBECONFIG=$HUB oc get nodes                                   # all Ready
KUBECONFIG=$HUB oc -n openshift-etcd get pods -l app=etcd      # 3 Running
```

If a node is NotReady, wait. Spells have lasted from a minute to three
hours; etcd has kept quorum in all of them.

---

## 0. The name, and what comes from nist-dev-infra

The hub is **`compliant-dev-infra`** (decided 2026-11-17). The name is in
the install, the DNS names, the OIDC issuer, the Secrets
Manager paths and the oac-apps paths, so nist-dev-infra's configuration is
**copied under the new name**, not reused as it is. The steps below use
the new name.

**Decided:**

- **Workload cluster:** `compliant-dev-workload0`, an Agent hosted cluster
  on jetty's two GPU nodes, the hypervisor for andalusia (#787, #788).
- **Base domain:** `nist.int.massopen.cloud`, kept (agreed with tzumainn,
  2026-11-17). The hub is `api.compliant-dev-infra.nist.int.massopen.cloud`,
  and the zones and their delegation (moc-aws #54, moc-dns #33) stay.

- **Hardware:** R440s `MOC-R440-U14`, `U15` and `U16` (BMCs
  `10.3.10.114` to `.116`) for the control plane (tzumainn, 2026-11-17).
  oac-infra's inventory had them commented out as future oac-prod-infra
  computes.
- **Standard hub,** installed with all six nodes at once; jetty and
  andalusia go once its ISO is made: agreed with tzumainn, 2026-11-17.
- **Workers:** three pool FC430s, `MOC-R4PAC10U31-S1D`, `-S3A` and
  `-S3B` (BMCs `10.2.13.164` to `.166`); jetty's FC430s go back to the
  pool. Hosted etcd goes on LVM Storage on their second disks (2.11), not
  on the FlashBlade.
- **FlashBlade realms:** each realm is named after its cluster
  (everpure-moc `ansible/group_vars/all/realms.yaml`): `nist-dev-infra`
  (10.9.7.10, VLAN 2317) and `nist-dev-workload0` (10.9.12.10, VLAN 2318),
  with S3 endpoints built from the names. Either keep them, which breaks
  that convention, or add `compliant-dev-infra` and
  `compliant-dev-workload0` on the same VLANs and subnets: an everpure-moc
  PR, new CA-marked realm certificates from the FlashBlade admins, and new
  S3 endpoint records. Going with new realms: MOC-issues #789 (naved001).

**Kept, as they are:**

- Route 53 zones `nist.int.massopen.cloud` and `hcp.nist.int.massopen.cloud`.
- The `moc-aws-cluster-operators` memberships.
- The cluster and storage networks and their firewall rules.

**Copied under the new name** (one PR per repo; nist-dev-infra's entries
stay where they are):

| Repo or store | From | To |
|---|---|---|
| oac-apps | `hosted-clusters/nist-dev-infra/`, `values/nist-dev-infra/`, `apps/nist-dev-infra/`, the pure-cosi overlay | `compliant-dev-infra` paths, with the name and domain changed inside them |
| oac-infra | `hub-images/group_vars/nist-dev-infra/`, the `hub-images/inventory.yml` entry, `nist_dev_infra` in `infra/inventory/00hosts.yaml` | `compliant-dev-infra` (2.1, 2.2) |
| moc-aws | The OIDC provider and roles (`eso-*`, `cert-manager-*`), ESO secret prefixes, external-dns user, the `s3.nist-dev-infra` record | The same for `compliant-dev-infra` and `compliant-dev-workload0`, with a new external-dns key on the existing user. The issuer URL changes with the name, so these are new, not reused |
| moc-aws (DNS) | api, api-int, `*.apps` records for nist-dev-infra | The same names for `compliant-dev-infra`, same VIPs; nist-dev-infra's are removed. The `*.hcp` and `*.hcp-int` wildcards are shared |
| moc-keycloak | `nist-dev-infra` client (#55) | `compliant-dev-infra` and `compliant-dev-workload0` clients; their redirect URIs have the new domain |
| Secrets Manager | `cluster/nist-dev-infra/{sshkey,portworx,pure-cosi,nfs-tls-ca,keycloak-oidc}` | `cluster/compliant-dev-infra/...`; `keycloak-oidc` gets the new client's secret |

**Rebuilt:** the cluster, its kubeadmin kubeconfig, its OIDC signing keys,
the ACS init bundles, and the COSI buckets for Loki and ACM observability.

**Where each piece is** (2026-11-18):

| Piece | Where | State |
|---|---|---|
| Inventory and hardware doc | oac-infra [#32](https://github.com/CCI-MOC/oac-infra/pull/32) | Merged |
| Worker switch ports (VLANs 219, 2317) | ansible-switches [#148](https://github.com/CCI-MOC/ansible-switches/pull/148) | Merged and applied (naved001) |
| DNS, OIDC providers and roles, external-dns key | moc-aws [#77](https://github.com/CCI-MOC/moc-aws/pull/77) | Merged and applied; the OIDC documents are placeholders until 2.4 |
| Cleanup of nist-dev-infra's OIDC, IAM and cert-manager entries | moc-aws [#78](https://github.com/CCI-MOC/moc-aws/pull/78), moc-keycloak [#69](https://github.com/CCI-MOC/moc-keycloak/pull/69) | Merged and applied |
| Keycloak clients | moc-keycloak [#68](https://github.com/CCI-MOC/moc-keycloak/pull/68) | Merged; both `keycloak-oidc` secrets are in Secrets Manager |
| Hub values, compliant-dev-workload0 | oac-apps [#248](https://github.com/CCI-MOC/oac-apps/pull/248), [#254](https://github.com/CCI-MOC/oac-apps/pull/254), [#257](https://github.com/CCI-MOC/oac-apps/pull/257) | Merged; workload0's hosted-clusters entry held back until section 4 (#254) |
| Hub vars | oac-infra [#34](https://github.com/CCI-MOC/oac-infra/pull/34) | Merged |
| Boot the hub's nodes from its ISO | oac-infra [#35](https://github.com/CCI-MOC/oac-infra/pull/35) | Merged |
| Tang disk encryption: root, etcd, LVM Storage disks | oac-infra [#36](https://github.com/CCI-MOC/oac-infra/pull/36), [#37](https://github.com/CCI-MOC/oac-infra/pull/37), [#38](https://github.com/CCI-MOC/oac-infra/pull/38); MOC-issues #672, #811 | Merged; installed 2026-11-18 |
| Where the Tang server lives | MOC-issues #810 (naved001) | Open; today naved's server at `172.16.1.1` |
| FIPS build host | oac-infra [#33](https://github.com/CCI-MOC/oac-infra/pull/33), MOC-issues #792 | Draft, rebased, 4.22.22; asked hakasapl for an SD530 (#805); needs a RHEL activation key |
| SD665 switch ports to VLANs 220 and 2318 | ansible-switches [#151](https://github.com/CCI-MOC/ansible-switches/pull/151) | Merged and applied 2026-11-18; the SD665s are out of ESI |
| FlashBlade realms | MOC-issues #789, everpure-moc [#38](https://github.com/CCI-MOC/everpure-moc/pull/38) | Done 2026-11-19: both realms, CA-marked certificates, all three secrets |
| `cluster/compliant-dev-infra/sshkey`, `hub-images/pull-secret`, `cluster/compliant-dev-infra/kubeadmin` | Secrets Manager | Stored |
| File integrity, tlshd memory | oac-apps [#198](https://github.com/CCI-MOC/oac-apps/pull/198), [#258](https://github.com/CCI-MOC/oac-apps/pull/258) | Merged 2026-11-19; FIO on all six nodes |
| registry.redhat.io refuses `rhacm2/thanos-rhel9` and `rhacs-central-db-rhel9` | larsks (MOC's Red Hat account) | Open since 2026-11-19 12:30 ET, on oac-dev-infra too; holds ACS (2.8 stage B) and stage C |

---

## 1. Before the install: andalusia and jetty go

**When:** after compliant-dev-infra's ISO is made (2.2 step 2; jetty is
the FIPS node it is made on) and before section 4, which needs jetty's
GPU nodes. The hub's own install does not wait for this.

jetty and andalusia are only in use by this work. From here until andalusia is rebuilt on this hub (#788) there is no GPU
VM cluster.

**What is on them** (checked 2026-11-17): every PVC on jetty and
andalusia is on the FlashBlade (`pure-fb-nfsv4`; andalusia's through
`kubevirt-csi-infra-default`), not on node disks, and all have reclaim
policy `Delete`. The AI UAT Harness runs are already local
(`ai-uat-harness/runs`). Nothing on the nodes needs copying; the
FlashBlade volumes need deleting, or they outlive jetty.

1. **Remove andalusia first, while jetty still works,** so oac-dev-infra
   and jetty's KubeVirt clean up after it. On a branch of oac-apps:

   ```
   git rm -r hosted-clusters/oac-dev-infra/andalusia
   ```

   Merge it, then on oac-dev-infra:

   ```
   oc -n clusters get hostedcluster,nodepool | grep andalusia   # gone within about 15 minutes
   ```

   If it stays in `Deleting`: oac-apps `docs/hypershift-issues.md`.
   jetty's two GPU nodes were NotReady on 2026-11-17, so the VM's
   VirtualMachineInstance may not terminate by itself. If it hangs, on
   jetty: `oc -n clusters-andalusia delete vmi --all --force --grace-period=0`,
   then check that the `clusters-andalusia` PVCs are gone.

2. **Detach jetty from oac-dev-infra:** remove `values/oac-dev-infra/jetty`
   and anything else selecting it in oac-apps by PR. Then, on
   oac-dev-infra, set `spec.preserveOnDelete: true` on jetty's hive
   ClusterDeployment so deleting it does not try to deprovision, and
   delete the ManagedCluster and the ClusterDeployment.

3. **Delete jetty's own test volumes** while jetty still runs, so
   Portworx removes them from the FlashBlade:

   ```
   export KUBECONFIG=~/kubeadmin-jetty
   oc delete project uat-runner uat-project gpu-bench mm-test
   oc get pvc -A | grep -v '^openshift-'      # nothing left but the cluster's own
   ```

   andalusia's volumes (`clusters-andalusia`) go with step 1.

4. **Power off jetty's five nodes** and wipe them (800-171 3.8.3), every
   disk. The three FC430s go back to the pool; the SD665s go on to
   section 4. Move the SD665s' switch ports from jetty's VLANs (218, 2316)
   to workload0's (220, 2318): open the PR from the ansible-switches branch
   `compliant-dev-workload0-ports` now, and ask naved001 or hakasapl to run
   the playbook.

5. **Afterwards, by PR:** jetty's roles in moc-aws (#66) and its records in
   moc-dns's `int.massopen.cloud` zone. `oac-infra/infra/jetty-net.tf` is
   the network; leave it until the SD665s have moved.

---

## 2. The hub

Upstream: oac-apps `docs/infra-cluster-deployment.md`. Why each step:
[BUILD.md](../BUILD.md) Part 1.

### Layout

**oac-prod-infra's: three dedicated control-plane nodes and three
workers,** installed together. oac-prod-infra is the only standard hub;
the dev hubs (oac-dev-infra, dizzy-infra, bu-ist-demo-infra) are compact.
A compliant hub is on the way to production, so it follows prod. Compact
under FIPS is also the one combination that failed: nist-dev-infra's etcd
crashed under TLS load (BUILD.md Part 1 step 1), while oac-dev-infra runs
compact on the same FC830s without FIPS.

Order: the hub is built on the R440s and three workers (2.1 to 2.11);
jetty and andalusia go once the hub's ISO is made (section 1); then
compliant-dev-workload0 on jetty's GPU nodes (3, 4; MOC-issues #787) and
andalusia on it (#788).

### 2.1 Hardware and networks

Three R440s as control plane and three workers (oac-apps
`docs/infra-cluster-deployment.md`, "Infrastructure Configuration").
nist-dev-infra ran on three compact FC830s at 176 threads each, whose
etcd crashed under FIPS TLS load (BUILD.md Part 1 step 1). No R440 is
used as compute. There are eight R440s, `MOC-R6PCC06U14` to `U21`;
this hub takes `MOC-R440-U14` to `U16` (tzumainn, 2026-11-17).

**The workers are three FC430s** from the pool: `MOC-R4PAC10U31-S1D`,
`-S3A` and `-S3B` (BMCs `10.2.13.164` to `.166`; tzumainn, 2026-11-17).
jetty's own FC430s go back to the pool. Each worker's second disk is for
LVM Storage (the hosted clusters' etcd, 2.11). Port 1 (`eth0`) is on the
cluster network (VLAN 219) and port 2 (`eth1`) on storage (2317),
ansible-switches #148. **All three boot in legacy BIOS mode:** S1D was
in UEFI mode with no hard disk in its boot order, so its discovery ISO
dropped to GRUB; tzumainn switched it to BIOS on 2026-11-18. If a sled
will not power on from its BMC, reset the iDRAC first (`racadm racreset`).

**Secure Boot must be off on the R440s.** U15 and U16 had it on and would
not boot the agent ISO (tzumainn turned it off, 2026-11-18). The R440s'
iDRACs (`10.3.10.114` to `.116`) use a different root password from the
FC430s', and are on `10.3.10.0/24`, which has to be in your WireGuard
`AllowedIPs`.

**The storage network must not hand out a gateway.** Every node gets
DHCP on both ports. When VLAN 2317's DHCP also gave a default route (via
`10.9.7.1`), it sometimes won in early boot, and the node could not reach
Tang and stayed at the disk unlock prompt. naved removed the gateway from
2317's DHCP on 2026-11-18; Tang is only reachable from the cluster network.

**Name disks by serial or WWN, never `sdX`:** the names change between
boots (on the workers, the install disk was `sda` in discovery and `sdb`
once installed).

**The R440s** (from their discovery ISO): two 447 GiB SSDs each, `sda`
for the install and `sdb` for etcd, plus four 5.8 TiB NVMe left unused.
The cluster network is on the NIC discovery calls `eth2`.

Each step below follows tzumainn's doc, with what nist-dev-infra already
has and what is new for compliant-dev-infra.

1. **Networks.** nist-dev-infra's cluster network (`10.20.18.0/23`), its
   storage network and their firewall rules exist. **Attach the three
   R440s and the three workers** to both
   (`docs/hardware-inventory-and-configuration.md`,
   "Network configuration"), each with its storage port untagged, with
   DHCP, unless they are already on them. Addresses on `10.20.18.0/23`:
   each node's, as its discovery boot shows on the console (DHCP): the
   R440s got `.23` to `.25`. The VIPs are `10.20.19.11` and `.12`.
   Switch ports: the R440s were already on VLANs 219 and 2317; the FC430s
   by ansible-switches #148, applied by naved or hakasapl running the
   playbook.

2. **oac-infra `infra/inventory/00hosts.yaml`.** Add a
   `compliant_dev_infra` group under `nist_clusters`, beside
   `nist_dev_infra` (leave that as it is), with the R440s as controllers
   and the workers. iDRAC, like nist-dev-infra:

   ```yaml
        compliant_dev_infra:
          vars:
            cluster: compliant-dev-infra
            bm_management: bmc
            bmc_type: idrac
          children:
            compliant_dev_infra_controller:
              vars:
                boot_image_url: "http://10.2.0.82/boot/discovery-r440.iso"
              hosts:
                compliant-dev-infra-control-0:
                  node_name: MOC-R440-U14
                  bmc_addr: 10.3.10.114
                compliant-dev-infra-control-1:
                  node_name: MOC-R440-U15
                  bmc_addr: 10.3.10.115
                compliant-dev-infra-control-2:
                  node_name: MOC-R440-U16
                  bmc_addr: 10.3.10.116
            compliant_dev_infra_compute:
              vars:
                boot_image_url: "http://10.2.0.82/boot/discovery.iso"
              hosts:
                compliant-dev-infra-compute-0:
                  node_name: MOC-R4PAC10U31-S1D
                  bmc_addr: 10.2.13.164
                compliant-dev-infra-compute-1:
                  node_name: MOC-R4PAC10U31-S3A
                  bmc_addr: 10.2.13.165
                compliant-dev-infra-compute-2:
                  node_name: MOC-R4PAC10U31-S3B
                  bmc_addr: 10.2.13.166
   ```

   In the same PR: remove the commented `oac_prod_infra_compute` block
   that names the same three R440 BMCs, so no node is claimed twice.
   jetty's entry stays until jetty goes (section 1).

3. **Node details.** Boot each R440 from
   `http://10.2.0.82/boot/discovery-r440.iso`, not the generic
   `discovery.iso` in tzumainn's doc, which does not work on R440s; boot
   the FC430s from `discovery.iso`. Read
   `http://<node-ip-on-cluster-network>/index.txt`. Record each node's MAC
   on the cluster network and the install disk's serial; for the R440s, a
   second disk's WWN for etcd; for the workers, the second disk, for LVM
   Storage (2.11).

   **Also note the thread count.** If the control-plane nodes have much
   more than about 40 threads, 2.3 applies.

4. **Wipe all six** if they have been used before (800-171 3.8.3). The
   install rewrites the install disk, and with Tang (2.2) the etcd and
   LVM Storage disks are wiped and re-encrypted once per install.

### 2.2 Install

1. **oac-infra `hub-images/group_vars/compliant-dev-infra/vars.yml`, in one
   PR,** copied from nist-dev-infra's, with an entry for `compliant-dev-infra`
   in `hub-images/inventory.yml`:
   - `master1` to `master3`: the R440s' hostnames, IPs, MACs,
     `install_drive_serial` and `etcd_drive_wwn` from 2.1. **Quote the
     WWNs:** YAML reads an unquoted `0x...` as a number, and Jinja writes
     it back in decimal.
   - Add a `workers:` list for the three workers (hostname, ip, mac,
     install_drive_serial, and `lvms_drive_wwn` for the LVM Storage disk),
     as in `group_vars/examples/vars.yaml.example` and oac-prod-infra's vars.
   - `diskencryption_mode: tang`, with `tang_servers` (url, thumbprint).
     Get the thumbprint from the server itself (`tang-show-keys`), not
     from its `/adv`. Every node's root disk, the masters' etcd disks and
     the workers' LVM Storage disks are LUKS2, unlocked only through Tang
     (MOC-issues #672, #811). Not `tpmv2`: the R440s' TPMs are faulty
     (#670), and on the FC830s `tpmv2` with no working TPM installed
     unencrypted without saying so.
   - `cluster_domain_name: compliant-dev-infra`.
   - Keep: `base_domain`, the networks,
     `rendezvous_ip` (make it one of the new control-plane IPs), `api_ip`,
     `ingress_ip`, `fips_enabled: true`. Check `ssh_public_key` is ECDSA
     or RSA (FIPS rejects Ed25519).

   **Before the install** (section 0): `cluster/compliant-dev-infra/sshkey`
   and `hub-images/pull-secret` in Secrets Manager (both stored
   2026-11-17); the api, api-int and `*.apps` records for
   `compliant-dev-infra` in `nist.int.massopen.cloud`, on the same VIPs
   (moc-aws #77). For a manual build, put the SSH key in
   `credentials/compliant-dev-infra/` and the pull secret in
   `group_vars/compliant-dev-infra/secrets.yml` (neither in git); the FIPS
   build host fetches both from Secrets Manager itself.

2. **Make the boot media, on a FIPS-enabled RHEL host:**
   `openshift-install-fips` will not make media for a FIPS cluster on a
   host without FIPS mode. The FIPS build host (oac-infra #33, MOC-issues
   #792) does this in one command, `hub-images/build.sh compliant-dev-infra`,
   once it exists. Until then, do as tzumainn does: run the playbook on the bastion,
   let its last step (the `openshift-install-fips` image creation) fail,
   copy `output/compliant-dev-infra/work` to a FIPS node, run that command
   there, and copy the result back. jetty's nodes have been that FIPS
   node, so **make this ISO before jetty goes** (section 1).

   **How it was done, 2026-11-18** (OpenShift 4.22.22, latest
   stable-4.22). The playbook ran on a laptop in a copy of `hub-images`:
   it deletes `output/<cluster>` when it starts, so never run it while
   that holds a live install's `auth/`. It fails at the manifests step,
   as expected. The rendered `work` went to jetty node
   `a0-88-c2-27-c2-d4` (`10.20.16.25`, FIPS mode) through a debug pod
   (`oc debug` passes no stdin: keep a pod running and use `oc exec -i`),
   tarred with `COPYFILE_DISABLE=1` (macOS otherwise adds `._*` files,
   which the installer fails to parse). There:
   `openshift-install-fips agent create cluster-manifests`, then the
   playbook's Tang `diskEncryption` block added to
   `cluster-manifests/agent-cluster-install.yaml` by hand, a copy of
   `work` to `work-backup`, then `agent create image`. The final ISO
   (all disks on Tang) has sha256
   `bb85301bd3f21f3bb3f8a8fc6e68cef2cecb070a9c21656b29879812acbddbf3`;
   its `work` is on the builder's laptop. tzumainn copied it to the
   bastion. Afterwards, delete the node's `/var/tmp/cdi-build` (it holds
   the pull secret) and the debug pod.

   ```
   cd ~/oat/oac-infra/hub-images
   ansible-playbook -i inventory.yml create_agent_install_media.yaml -e cluster_name=compliant-dev-infra
   ```

   **Expect:** `ISO generated successfully at: output/compliant-dev-infra/work/agent.x86_64.iso`,
   and the kubeadmin password printed.

3. **Boot the nodes from it.** Copy the ISO to the bastion as
   `/srv/boot/compliant-dev-infra-agent.x86_64.iso`, point both groups
   in `00hosts.yaml` at `http://10.2.0.82/boot/compliant-dev-infra-agent.x86_64.iso`
   (oac-infra #35), and boot all six (`docs/hardware-inventory-and-configuration.md`, "Boot
   configuration"; boot the R440s and FC430s as separate runs, since
   their BMC passwords differ and the playbook stops every host when one
   fails). Then wait. `wait-for` does not need FIPS, so the plain
   `openshift-install` of the same version works from a laptop on the
   VPN; jetty's nodes cannot reach the rendezvous host's port 8090:

   ```
   openshift-install agent wait-for install-complete --dir output/compliant-dev-infra/work
   ```

   **Expect:** `Install complete!` in about an hour. If a node stalls,
   see section 5: the disk unlock rows.

4. **Store the kubeconfig** in a new secret, then copy it to `$HUB`.
   Never in a repo:

   ```
   aws --profile $SM secretsmanager create-secret --name cluster/compliant-dev-infra/kubeadmin \
     --secret-binary fileb://output/compliant-dev-infra/work/auth/kubeconfig
   (umask 077; aws --profile $SM secretsmanager get-secret-value --secret-id cluster/compliant-dev-infra/kubeadmin \
     --query SecretBinary --output text | base64 -d > $HUB)
   ```

5. **Check FIPS on every node.** If any check fails, reinstall:

   ```
   export KUBECONFIG=$HUB
   oc get nodes                                                  # 6 Ready: 3 control-plane, 3 worker
   oc get cm cluster-config-v1 -n kube-system -o yaml | grep fips  # fips: true
   for n in $(oc get nodes -o name); do
     oc debug $n -q -- chroot /host cat /proc/sys/crypto/fips_enabled   # 1
   done
   ```

   **And Tang on every data disk:** `root` on all six, `etcd` on the
   masters, `lvms` on the workers, each with one keyslot, a clevis
   token, and no passphrase:

   ```
   for n in $(oc get nodes -o name); do
     oc debug $n -q -- chroot /host sh -c 'for m in root etcd lvms; do
       [ -e /dev/mapper/$m ] || continue
       d=$(cryptsetup status $m | awk "/device:/{print \$2}")
       echo "$(hostname) $m keyslots=$(cryptsetup luksDump $d | grep -cE "^  [0-9]+: luks2") $(clevis luks list -d $d)"
     done'
   done
   ```

6. **Turn on etcd encryption now, while etcd is empty.** The first build
   left it off, because re-encrypting a busy hub stalled its masters (2.9,
   POA&M); on a new hub it costs nothing:

   ```
   oc patch apiserver cluster --type merge -p '{"spec":{"encryption":{"type":"aesgcm"}}}'
   oc get openshiftapiserver -o=jsonpath='{range .items[0].status.conditions[?(@.type=="Encrypted")]}{.reason}{"\n"}{end}'
   # EncryptionCompleted, within about 20 minutes
   ```

### 2.3 40 CPUs on the masters (if they have more)

The USBGuard MachineConfig is always applied here. `nr_cpus=40` only if 2.1
showed the control-plane R440s with much more than about 40 threads;
otherwise leave `nr-cpus-machineconfig.yaml` out of the `apply` and skip
the two CPU checks. Do this now, while the hub is empty: each master reboots once, and drains
are cheap with nothing running. Without it, etcd crashes under FIPS TLS
handshake load once the hub is busy (README, "Stage C results" and "40
CPUs on the masters"). The USBGuard unit waits for the extension that
stage C installs, so it is safe to add now.

```
export KUBECONFIG=$HUB
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
oc apply -f $RB/nr-cpus-machineconfig.yaml -f $RB/usbguard-enable-machineconfig.yaml
oc get mc $(oc get mcp master -o jsonpath='{.spec.configuration.name}') \
  -o jsonpath='{.spec.kernelArguments}{"\n"}'                   # includes nr_cpus=40
oc patch mcp master --type merge -p '{"spec":{"paused":false}}'
oc wait mcp/master --for=condition=Updated --timeout=90m
for n in $(oc get nodes -l node-role.kubernetes.io/master -o name); do oc get $n -o jsonpath='{.status.capacity.cpu}{"\n"}'; done   # 40, three times
```

The rendered config name changes a minute or two after `apply`. If the
kernel arguments do not show `nr_cpus=40`, wait and look again before
unpausing.

**On this hub (2026-11-18):** the R440 masters have 48 threads, so only
USBGuard was applied (each master rebooted once, about 30 minutes).
`systemctl is-enabled usbguard` reports no such unit until stage C
installs the extension; that is expected.

### 2.4 The service account issuer and OIDC keys, before anything uses AWS

The install templates cannot set `serviceAccountIssuer`, so the script
sets it. That restarts the API servers and most pods, which is harmless
on an empty hub. `-f` replaces the old cluster's keys, which are still in
S3: without it the script keeps them and AWS rejects every token.

```
aws sso login --profile $CO
cd ~/oat/oac-apps
KUBECONFIG=$HUB AWS_PROFILE=$CO CLUSTER_NAME=compliant-dev-infra bootstrap/setup-oidc.sh -f
```

Answer yes when it asks to set the issuer. If an upload fails with
"Token has expired and refresh failed" right after `aws sso login`, the
login reused an expired portal session: `aws sso logout`, then log in
again. **Check:**

```
KUBECONFIG=$HUB oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
# https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/compliant-dev-infra
curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/compliant-dev-infra/.well-known/openid-configuration | jq .issuer
# the same URL
KUBECONFIG=$HUB oc get co kube-apiserver                     # Available, not Progressing (about 20 minutes)
```

### 2.5 Bootstrap ArgoCD

First install the OpenShift GitOps operator and its ArgoCD instance
(`setup-gitops.sh`, about 5 minutes); the bootstrap Application needs its
CRDs. Then the bootstrap:

```
cd ~/oat/oac-apps
KUBECONFIG=$HUB bootstrap/setup-gitops.sh
helm template bootstrap ./bootstrap --set hubName=compliant-dev-infra | KUBECONFIG=$HUB oc apply -f -
```

Everything for the hub on CCI-MOC/oac-apps `main` now syncs:
storage, external-secrets, cert-manager and the Let's Encrypt ingress
certificate, ACM and HyperShift, Keycloak SSO and the token timeouts.
**Check,** after about 30 minutes:

```
KUBECONFIG=$HUB oc -n openshift-gitops get applications.argoproj.io      # all Synced, Healthy
```

Use `applications.argoproj.io`: ACM adds another `Application` type, and
plain `oc get applications` lists that one, empty.

**If an app stays Degraded:** read its message
(`oc -n openshift-gitops get applications.argoproj.io <app> -o jsonpath='{.status.conditions}'`).
`hub-portworx` fails until 2.6 passes; re-sync it by hand then, because
Argo does not retry a failed commit.

### 2.6 Storage, TLS only, before any volume

```
cd ~/oat/oac-eldritch-things/compliance
KUBECONFIG=$HUB AWS_PROFILE=$SM tests/hub-preflight.sh compliant-dev-infra   # every check PASS
KUBECONFIG=$HUB oc get sc                       # pure-fb-nfsv4 (default) and nfs-over-tls, both TLS
KUBECONFIG=$HUB oc -n nfs-tls get pods          # tlshd Running on all three nodes (after stage B, 2.8)
```

If `pure-fb-nfsv4` is missing, re-sync `hub-portworx` (2.5).

**What it took on 2026-11-19:**

- **The realm certificate.** The realm playbook gives the realm the
  FlashBlade's self-signed certificate (`CA:FALSE`). Replace it first with
  a CA-marked one (BUILD.md I8's `openssl` command, key generated where it
  is imported), through the FlashBlade API with an admin token, then put
  the `.crt` in `cluster/compliant-dev-infra/nfs-tls-ca` and in the proxy
  values (oac-apps #257). workload0's realm got its certificate the same
  day.
- **tlshd before the StorageClass.** Volumes that waited since the install
  (Prometheus, assisted-service, Perses) bind the moment `pure-fb-nfsv4`
  exists. nfs-tls went on first, with stage A (2.8): stage A's file plus
  `- component: nfs-tls`, so stage B keeps it.
- **A stuck sync.** `hub-portworx`'s sync from before #257 waited forever
  on nist-dev-infra's NNCPs (`NoMatchingNode`). End it and sync main:
  ```
  oc -n openshift-gitops patch applications.argoproj.io hub-portworx --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
  oc -n openshift-gitops patch applications.argoproj.io hub-portworx --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true,"revision":"main"}}}'
  ```
- **tlshd OOMKilled.** On s1d, with four volumes waiting, tlshd hit its
  256Mi limit three times (`mount.nfs: No such process` on every pending
  mount) before the backlog drained. The limit is 1Gi since oac-apps
  #258 (on the test branch at once).

`nfs-over-tls` comes from the fork's nfs-tls values, kept for the volumes
created on it on 2026-10-19 (ACS's databases, the etcd backups, COO's
Perses). A new hub sets `storageClass.enabled: false` there instead.

### 2.7 Object storage

`pure-cosi` and `object-storage-proxy` sync from main. **Check:**

```
export KUBECONFIG=$HUB
oc get bucketclaims.objectstorage.k8s.io -A        # every claim Ready (ACM observability's first)
dig +short s3.compliant-dev-infra.nist.int.massopen.cloud           # the proxy's cluster IP, 172.30.x.x
oc -n portworx logs deploy/pure-cosi-driver --all-containers | grep -i -m5 realm   # no "Realm does not exist"
```

Wrong realm or endpoint values fail quietly: the only sign is pods
waiting for their bucket (BUILD.md I8).

On 2026-11-19 the bucket was Ready at once, but ACM observability's ten
Thanos pods could not pull `registry.redhat.io/rhacm2/thanos-rhel9`:
"denied: Token rejected by upstream registry". The same pull failed from
oac-dev-infra, with another pull secret, and other `rhacm2` images pulled
fine, so it was Red Hat's registry, not this hub. Nothing in 2.8 needs
Thanos.

### 2.8 The compliance stages, from the fork

Each stage file updates the same ApplicationSet, `nist-compliance-test`,
which reads the fork's `compliant-dev-infra-test` branch: upstream oac-apps
main plus the compliance charts not yet upstream (audit-logging,
compliance-node-hardening, etcd-backup), a stopgap
`namespace-guardrails-app` (upstream's namespace-guardrails is now a
library, #756), and this hub's values under `values/compliant-dev-infra/`.
The upstreamed charts (compliance-operator, compliance-hub-policy,
platform-hardening, rhacs, nfs-tls) are upstream's. File integrity is not
in the stages: since oac-apps #198 (2026-11-19) main deploys it to every
compliant hub (`hub-file-integrity`), and a second Application for it
would fight the first. nfs-tls is tlshd only:
the TLS StorageClass is `pure-fb-nfsv4` with `portworx.tls: true`.
`nist-dev-infra-test` stays as the first build's record. Apply them in order,
waiting for each to settle:

```
export KUBECONFIG=$HUB
oc apply -f $CB/stage-a.yaml
oc -n openshift-gitops get applications.argoproj.io | grep nist-test     # all Synced, Healthy
```

**Stage A**, the Compliance Operator. Wait for the first scans (about 30
minutes), then go on:

```
oc -n openshift-compliance get compliancesuite            # every suite DONE
```

**Stage B**, everything except node hardening. Needs the default
StorageClass (2.6).

```
oc apply -f $CB/stage-b.yaml
oc -n stackrox rollout status deploy/central --timeout=30m
```

**On 2026-11-19:** stage A went on with `nfs-tls` added (2.6), and both
suites were DONE (NON-COMPLIANT, as expected) within 30 minutes. Stage B:
every app Synced except two.

- `nist-test-namespace-guardrails-app` stays OutOfSync: its values name
  `compliant-dev-workload0` and `klusterlet-compliant-dev-workload0`, which
  do not exist while workload0 is held back (#254). It clears in section 4.
- ACS Central's database could not pull its image (the registry row in the
  status table), so the init bundle waits.

**The pull secret has to reach the add-on images, not just OpenShift's.**
The install only pulls OpenShift itself, so a pull secret from an account
without ACM and ACS entitlements installs fine and fails later, one image
at a time, as "denied: Token rejected by upstream registry". Check before
stage B, from any node (the images are the ones that failed on 2026-11-19):

```
oc debug node/<a worker> -- chroot /host bash -c '
  for i in rhacm2/thanos-rhel9:v2.17 advanced-cluster-security/rhacs-central-db-rhel9:5.0.0; do
    podman pull -q --authfile /var/lib/kubelet/config.json registry.redhat.io/$i >/dev/null && echo "ok   $i" || echo "FAIL $i"
  done'
```

Any FAIL: the account behind `hub-images/pull-secret` needs those
subscriptions (MOC's Red Hat account: larsks), or a pull secret from one
that has them.

Then the hub's ACS init bundle. It is a credential: never commit it, and
delete the file once applied.

```
umask 077; B=$(mktemp)
oc -n stackrox exec deploy/central -- roxctl central init-bundles generate compliant-dev-infra \
  --insecure-skip-tls-verify \
  --password "$(oc -n stackrox get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}')" \
  --output-secrets - > $B
oc -n stackrox apply -f $B && rm -P $B
oc -n stackrox get securedcluster                         # Available within about 5 minutes
```

If the SecuredCluster is not Available after 5 minutes, the operator may
have given up just before the bundle arrived. Nudge it:
`oc -n stackrox annotate securedcluster stackrox-secured-cluster-services reconcile-nudge=$(date +%s) --overwrite`.

**Stage C**, node hardening: about 380 MachineConfigs. **Every master
reboots.** Agree a time, run the health check, and allow three hours.

```
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
oc apply -f $CB/stage-c.yaml
oc get mc | grep -c '^75-'                                # about 380, once synced
oc patch mcp master --type merge -p '{"spec":{"paused":false}}'
KUBECONFIG=$HUB $RB/watch-etcd-threads.sh                 # in another terminal, during the rollout; Ctrl-C after
oc wait mcp/master --for=condition=Updated --timeout=180m
```

During the rollout, etcd on the other two masters may restart as each one
drains (stage C took the API away for 10 minutes the first time, before
`nr_cpus=40`). To stop between nodes, pause the pool again. A kubelet that
stops reporting for more than 10 minutes while its node answers can be
restarted: `oc debug node/<node> -- chroot /host systemctl restart kubelet`.

**Stage E**, audit logging: Loki on a COSI bucket, and the forwarder.
Needs 2.7.

```
oc apply -f $CB/stage-e.yaml
oc -n openshift-logging get lokistack,clusterlogforwarder     # Ready
```

### 2.9 What the hub does not pass yet

Scan first. Scans run every night at 01:00; to scan now:

```
export KUBECONFIG=$HUB
for s in $(oc -n openshift-compliance get compliancescans -o name); do
  oc -n openshift-compliance annotate $s compliance.openshift.io/rescan= --overwrite
done
oc -n openshift-compliance get compliancescans                # all DONE, about 15 minutes
oc -n openshift-compliance get compliancecheckresults -l compliance.openshift.io/check-status=FAIL
```

Archive the first results as the hub's baseline.

Then the route rate limits, which the scan asks for on every route
outside `openshift-*`. Report first, then apply:

```
$RB/route-rate-limits.sh            # lists each route "missing" a limit
APPLY=1 $RB/route-rate-limits.sh    # annotates them
```

Re-run it after any operator upgrade: an operator can drop the
annotations.

**4 distinct rules still fail** (rescan, 2026-10-27): 4 in moderate, 3
of them also in CIS, none in the three node scans. Remove
rows as fixes land.
With everything in the Status column done, only the two POA&M items
remain.

Fixed so far, from 19 (moderate) and 7 (CIS):

| Rule | Fix |
|---|---|
| `resource-requests-quota` | Quotas for seven namespaces (fork `325ad26`) |
| `audit-log-forwarding-uses-tls` | A scanner false positive: a `lokiStack` output has no url. Tailored (`325ad26`) |
| `resource-requests-limits-in-daemonset`, `-statefulset` | Operator-owned namespaces exempted, rationale `vendorLimits` (`8490e2c`) |
| `ocp-allowed-registries`*, `-for-import`*, and the node scan's `reject-unsigned-images-by-default` | A registry allowlist from an inventory of every image reference on the hub (`1c277e3`). All 248 running images matched it; the change reloaded CRI-O on each master, without reboots. The COSI controller comes from a staging registry at a release-candidate tag: a supply-chain gap to record. Confirmed passing 2026-10-25. The allowlist left `openshift-samples` Degraded (it wants a bare `quay.io` when `samplesRegistry` is empty); `imageConfig.samplesRegistry: registry.redhat.io` fixed it (fork `75773f6`, 2026-10-26) |
| `routes-rate-limit` | `route-rate-limits.sh`, above. Confirmed passing 2026-10-25 |
| `ingress-controller-certificate` | A Let's Encrypt wildcard apps certificate from `cluster-certificates` (oac-apps [#184](https://github.com/CCI-MOC/oac-apps/pull/184), 2026-10-26). The API certificate stays off: agents and kubeconfigs trust the current CA. workload0's audit forwarder pinned the hub's old ingress CA and stopped verifying; it now uses system trust (`forwarder.remote.hubIngressCA: false`, fork `9c2cbca`) |
| `default-ingress-ca-replaced` | Tailored, rationale `ingressCert` (fork `329a866`): the rule wants a custom CA in `proxy/cluster`, and a publicly issued certificate needs none |
| `idp-is-configured`*, `oauth-or-oauthclient-inactivity-timeout`, `-token-maxage` | MOC SSO (`mocsso`) with 24-hour tokens and a 10-minute inactivity timeout: moc-keycloak [#55](https://github.com/CCI-MOC/moc-keycloak/pull/55), then oac-apps [#188](https://github.com/CCI-MOC/oac-apps/pull/188) (2026-10-26). An `oc` login through OAuth, kubeadmin's too, now expires after 10 idle minutes; the admin kubeconfig does not |
| `resource-requests-limits-in-deployment` | pure-cosi v0.1.2 sets requests and limits on the COSI controller and driver for every cluster (CCI-MOC/pure-cosi#11, oac-apps [#185](https://github.com/CCI-MOC/oac-apps/pull/185), 2026-10-26) |
| `audit-profile-set`* | `platform-hardening` `apiServerAudit`: WriteRequestBodies, server-side applied (fork `eadf121`, 2026-10-26). Argo's server-side apply takes the field over from the cluster-version-operator, which created the APIServer. The policy logs every write with its body, except Secrets, service account tokens, token reviews, OAuth clients, routes and MachineConfigs, which stay at Metadata. The kube-apiserver rollout took three hours: u15's and u17's kubelets froze at their API server switch, and each needed a power cycle (section 5) |
| `route-ip-whitelist` | Tailored, rationale `routeNetwork` (fork `d9a1935`, 2026-10-27): the hub's names resolve to private addresses, also through public DNS, so the ingress is not reachable from the internet. **Assumed, not verified:** that only the VPN and the hub's own clusters can route to it inside MOC. If others can, re-enable the rule and add per-route allowlists (the VPN, workload0's egress, the hub's network) with `route-rate-limits.sh` |

Still failing (* also CIS):

| Rule | Fix | Status |
|---|---|---|
| `kubeadmin-removed`* | Grant cluster-admin to an SSO group, then delete the `kubeadmin` secret in `kube-system`. The admin kubeconfig stays as break-glass | **Known gap** (decided 2026-10-26). The kubeadmin login is a shared account, so the audit log cannot tell who used it (AC-2, IA-2). Removing it safely needs an SSO cluster-admin group first; a draft (a moc-keycloak group and an oac-apps `cluster-admins` chart) exists but is not opened |
| `configure-network-policies-namespaces`* | Policies for 20 namespaces, many of them ACM, HyperShift and storage. Each needs its traffic measured first; a wrong policy cuts off a hub component. ACS's Network Graph, already on the hub, records observed traffic and can generate policies from it | **TBD for the production setup.** Expect policies for the namespaces oac-apps owns (object-storage-proxy, COSI, cert-manager, hardware-inventory, portworx) and an exception register for the operator-managed ACM, MCE and HyperShift namespaces |
| `api-server-encryption-provider-cipher`* | etcd encryption (`aesgcm`). On the first build it would have re-encrypted every Secret and ConfigMap on masters that stall under load | **POA&M** (decided 2026-10-24) on the first build. On the rebuild it is on from 2.2 step 6, so this rule should pass |
| `cluster-wide-proxy-set` | None planned | **POA&M**, as on workload0 |

### 2.10 Verify the admission policies

BUILD.md Part 1 step 7 has the dry runs, which create nothing: a
cleartext FlashBlade StorageClass and four non-compliant HostedClusters
and NodePools must each be denied, and the compliant ones accepted. On
this hub (2026-10-19 and 20) all were.

---

### 2.11 LVM Storage on the workers

For the hosted clusters' etcd (MOC-issues #772): each worker's second disk
is encrypted against Tang at install and opened as `/dev/mapper/lvms`
before kubelet starts (2.2). In oac-apps #248,
`values/compliant-dev-infra/local-cluster/lvmcluster.yaml` points the
LVMCluster's device selector at `/dev/mapper/lvms`. Tested on S3B
(2026-11-18): the volume group came back after a reboot with its data
(MOC-issues #811). `node-labels` marks every worker for it, and
the hosted-cluster chart's default `lvms-vg0` class is used, so the
hosted-clusters values set no etcd storage class.

---

## 3. What has to be true before workload0

```
export KUBECONFIG=$HUB
oc -n openshift-gitops get applications.argoproj.io | grep nist-test   # stages A to E Synced, Healthy
oc -n stackrox get central                                             # Central Available
oc get validatingadmissionpolicybinding compliant-hosted-clusters -o jsonpath='{.spec.validationActions}{"\n"}'   # ["Deny"]
```

The hub's own scans are not clean yet (2.9); the workload cluster does not
depend on them. `auditWriters.clusters` in the hub's audit-logging values
needs `compliant-dev-workload0` (nist-dev-infra's lists
`nist-dev-workload0` on the test branch).

---

## 4. workload0

Upstream: oac-apps `docs/workload-cluster-deployment.md`. Why each step:
[BUILD.md](../BUILD.md) Part 2.

### 4.1 Workers

jetty's two Lenovo SD665-N V3s, `MOC-R4PCC02U15` and `U16` (4 x H100
each), on workload0's VLANs (ansible-switches #151) and out of ESI, booted from
**this hub's** discovery ISO:

```
export KUBECONFIG=$HUB
oc get infraenv -n hardware-inventory hardware-inventory -o jsonpath='{.status.isoDownloadURL}{"\n"}'
```

**Before anything else**, restore workload0's hosted-clusters entry in
oac-apps (`hosted-clusters/compliant-dev-infra/compliant-dev-workload0/values.yaml`,
from the parent of oac-apps #254). #254 removed it because Argo started
workload0's control plane as soon as the hub was bootstrapped.

**Wipe the disks first.** ESI's cleaning failed on both SD665s (2026-11-18:
#151 moved their ports mid-clean) and they left ESI, so their disks still
hold jetty's data. Boot the discovery ISO, and before approving, on each
(`ssh core@<ip>` with the cluster key):

```
lsblk -d -o NAME,SIZE,MODEL,SERIAL        # every disk, including the boot one
for d in $(lsblk -dn -o NAME -e 7,11); do
  sudo wipefs -a /dev/$d && sudo blkdiscard -f /dev/$d
done
```

Keep the `lsblk` output for the compliance record. The discovery ISO runs
from memory, so wiping the boot disk is fine. Then reboot into the ISO
again so the agent re-reads the empty disks.

When they appear, approve and label them:

```
oc -n hardware-inventory get agents                        # both listed
for a in $(oc -n hardware-inventory get agents -o name); do
  h=$(oc -n hardware-inventory get $a -o jsonpath='{.spec.hostname}')
  case $h in <the two SD665s' hostnames>)   # TODO: read them from the agents
    oc -n hardware-inventory patch $a --type merge -p '{"spec":{"approved":true}}'
    oc -n hardware-inventory label $a --overwrite massopen.cloud/cluster=compliant-dev-workload0 openstack/resource-class=lenovo-sd665nv3-h100
  esac
done
```

The storage NIC's `never-default` setting (`enp163s0np0`) is in the
`hypervisor` NodePool's values (oac-apps #248), as for nist-dev-workload0
([#166](https://github.com/CCI-MOC/oac-apps/pull/166)): without it a
reboot can put `br-ex` on the wrong NIC. Portworx and GPU passthrough
are follow-ups, listed at the end of those values.

### 4.2 The cluster

The HostedCluster comes from oac-apps #248
(`hosted-clusters/compliant-dev-infra/compliant-dev-workload0/values.yaml`).
The `hosted-clusters` ApplicationSet creates the HostedCluster and
NodePool, and the hub's admission policy checks them. **Check:**

```
oc -n clusters get hostedcluster compliant-dev-workload0 -o jsonpath='{.spec.fips} {.spec.configuration.apiServer.audit.profile}{"\n"}'
# true WriteRequestBodies
oc -n clusters get hostedcluster,nodepool                 # Available, 2 of 2 nodes (about an hour)
```

If the sync fails with a `compliant-hosted-clusters` message, fix the
values, not the policy.

Get its admin kubeconfig for the next steps. It is a credential: keep it
out of repos and delete it when done.

```
umask 077; W0=$(mktemp)
oc -n clusters extract secret/compliant-dev-workload0-admin-kubeconfig --keys=kubeconfig --to=- > $W0
KUBECONFIG=$W0 oc get nodes                               # 2 Ready
```

### 4.3 OIDC keys, then the rest

1. **OIDC keys.** HyperShift sets the issuer; upload the new keys before
   external-secrets and cert-manager need AWS:

   ```
   cd ~/oat/oac-apps
   KUBECONFIG=$W0 AWS_PROFILE=$CO CLUSTER_NAME=compliant-dev-workload0 bootstrap/setup-oidc.sh -f -n
   curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/compliant-dev-workload0/.well-known/openid-configuration | jq .issuer
   ```

2. **SSO** needs nothing: the Keycloak client and its secret come from
   moc-keycloak #68, and
   `oauth.mocsso.enabled: true` is in the values. HyperShift removes
   kubeadmin once oauth-openshift is up. The OAuth route is internal: log
   in over the VPN.

3. **Certificates and secrets** sync from main (oac-apps
   [#175](https://github.com/CCI-MOC/oac-apps/pull/175)). **Check:**

   ```
   KUBECONFIG=$W0 oc get clustersecretstore,clusterissuer          # Valid, Ready
   KUBECONFIG=$W0 oc -n openshift-ingress get certificate          # Ready within a few minutes
   ```

   A router pod created before the secret exists waits in
   ContainerCreating, then starts.

### 4.4 The compliance stages, from the fork

These update the ApplicationSet `nist-compliance-test-managed` on the
hub, which deploys to every managed cluster. Apply in order:

```
export KUBECONFIG=$HUB
oc apply -f $CB/workload-stage-a.yaml        # Compliance Operator (hosted tailoring), FIO, the notice
oc -n openshift-gitops get applications.argoproj.io | grep compliant-dev-workload0-nist-test   # Synced, Healthy
```

**Stage B**, the ACS SecuredCluster. Its init bundle comes from the
hub's Central and goes to the cluster:

```
oc apply -f $CB/workload-stage-b.yaml
umask 077; B=$(mktemp)
oc -n stackrox exec deploy/central -- roxctl central init-bundles generate compliant-dev-workload0 \
  --insecure-skip-tls-verify \
  --password "$(oc -n stackrox get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}')" \
  --output-secrets - > $B
KUBECONFIG=$W0 oc -n stackrox apply -f $B && rm -P $B
KUBECONFIG=$W0 oc -n stackrox get securedcluster          # Available within about 5 minutes
```

The same nudge as 2.8 applies, with `KUBECONFIG=$W0`.

**Stage C**, NetworkPolicies and quotas:

```
oc apply -f $CB/workload-stage-c.yaml
oc -n openshift-gitops get applications.argoproj.io | grep compliant-dev-workload0   # all still Synced
```

If an app goes Unknown, a policy may have cut the cluster off from the
hub. Argo cannot reach it to fix it, so delete that policy with
`KUBECONFIG=$W0`.

**Stage D**, audit forwarding to the hub's Loki:

```
oc apply -f $CB/workload-stage-d.yaml
KUBECONFIG=$W0 oc -n openshift-logging get clusterlogforwarder   # Ready
```

### 4.5 Scan and verify

```
for s in $(KUBECONFIG=$W0 oc -n openshift-compliance get compliancescans -o name); do
  KUBECONFIG=$W0 oc -n openshift-compliance annotate $s compliance.openshift.io/rescan= --overwrite
done
KUBECONFIG=$W0 oc -n openshift-compliance get compliancescans
KUBECONFIG=$W0 oc -n openshift-compliance get compliancecheckresults -l compliance.openshift.io/check-status=FAIL
for n in $(KUBECONFIG=$W0 oc get nodes -o name); do
  KUBECONFIG=$W0 oc debug $n -q -- chroot /host cat /proc/sys/crypto/fips_enabled   # 1
done
rm -P $W0
```

**Expect** (workload0, 2026-10-23): `hosted-ocp4-moderate` **1 FAIL**
(`cluster-wide-proxy-set`), `hosted-ocp4-cis` **0 FAIL**, and the worker
node profiles compliant. The last failures and what closed them:

| Was failing | Closed by |
|---|---|
| `ocp-allowed-registries-for-import` (also CIS) | [#172](https://github.com/CCI-MOC/oac-apps/pull/172) |
| `oauth-or-oauthclient-inactivity-timeout`, `-token-maxage` | [#172](https://github.com/CCI-MOC/oac-apps/pull/172) sets them on the HostedCluster; tailored (`oauthTokens`), because HyperShift does not copy them to the guest |
| `default-ingress-ca-replaced` | [#175](https://github.com/CCI-MOC/oac-apps/pull/175)'s Let's Encrypt certificate; tailored (`ingressCert`), because the rule only reads `proxy/cluster` `trustedCA` |
| `resource-requests-limits-in-deployment`, `resource-requests-quota` | Appeared with External Secrets (#175): `external-secrets` added to the exempt regex, and given a quota |
| `cluster-wide-proxy-set` | Still fails: a POA&M gap, recorded in the SSP |

A new operator namespace on a hosted cluster brings the quota and limits
failures with it, until its guardrails are added.

Archive the first results as the cluster's baseline.

---

## 5. Known failures, and what to do

| Symptom | Cause | Fix |
|---|---|---|
| moc-aws apply fails: "Please check .well-known/openid-configuration" | The OIDC documents were not uploaded yet | Upload (2.4 or 4.3), re-run the apply |
| AWS rejects the cluster's tokens after a rebuild | `setup-oidc.sh` without `-f` kept the old cluster's keys in S3 | Run it again with `-f` |
| An Argo app keeps failing with an error your fix already removed | Argo retries a failed sync at the commit it started with (five times, about 15 minutes) | Wait for the retries to end, or terminate the operation |
| New volumes fail; tlshd logs "Certificate signer not found" | tlshd reads its CA only at startup | `oc -n nfs-tls rollout restart daemonset/tlshd` |
| Every S3 request returns 503, proxy health checks pass | HAProxy verified the FlashBlade's certificate against the client's Host header | Fixed in oac-apps [#174](https://github.com/CCI-MOC/oac-apps/pull/174). The realm certificate must also be a CA (BUILD.md, storage notes) |
| Loki discards hosted audit lines | The application tenant's line size and rate limits | `loki.tenantLimits` in the hub's audit-logging values (already set) |
| COO never installs: Perses CRD missing | The dashboard needed a CRD the operator installs | Fixed in oac-apps [#170](https://github.com/CCI-MOC/oac-apps/pull/170) |
| A hosted cluster's API returns 500, "failing health checks: etcd"; etcd logs "took too long" | etcd's WAL file creation blocked on a stale NFS lock on the FlashBlade (2026-10-23, 17:05 to 18:30) | Delete the stale `member/wal/*.tmp` file in etcd-0, then delete the etcd-0 pod. Hosted etcd on NFS is not supported: a POA&M item |
| Masters go NotReady in turn, etcd restarts | FIPS TLS handshakes on large-core nodes | `nr_cpus=40` (2.3). Spells still happen a few times a day: wait them out |
| A hosted cluster loses its compliance namespaces | An ApplicationSet deleted its Applications when the cluster left the placement | `preserveResourcesOnDeletion: true` (already set; BUILD.md Part 2 step 3) |
| `openshift-samples` Degraded: "global openshift image configuration prevents the creation of imagestreams" | The allowlist has no bare `quay.io`, which the samples operator wants when `samplesRegistry` is empty | `imageConfig.samplesRegistry: registry.redhat.io` (fork `75773f6`, already set) |
| workload0's audit collectors log "certificate verify failed" | The hub's apps certificate changed, and the forwarder trusted only the hub's ingress CA, copied by the audit-writers policy: for a Let's Encrypt certificate, a chain without its root | `forwarder.remote.hubIngressCA: false` in the hosted-cluster values (fork `9c2cbca`, already set) |
| A node sits at "Please enter passphrase for disk root", the console repeating "clevis-luks-askpass: Error communicating with server http://172.16.1.1:80" | The storage network's DHCP gave a default route that won in early boot; Tang is reachable only from the cluster network | Fixed on VLAN 2317's DHCP (no gateway, 2026-11-18). If it recurs, check `ip route` on a running node shows one default route, via `br-ex`, then power-cycle the stuck node |
| A node is up and pings but never registers; no CSRs; `etcd-disk.service` or `lvms-disk.service` failed with "Error communicating with server" | On first boot the unit unlocked its disk while ovs-configuration was moving the address onto `br-ex` | Fixed in oac-infra [#38](https://github.com/CCI-MOC/oac-infra/pull/38). On an ISO made before it: `ssh core@<node>` (key in `cluster/compliant-dev-infra/sshkey`), `sudo systemctl restart etcd-disk` (or `lvms-disk`), `sudo systemctl start kubelet` |
| An R440 never boots the agent ISO | Secure Boot on | Turn it off in the BIOS (2.1) |
| `agent create image` fails: "could not decode YAML for openshift/._98-...: control characters are not allowed" | macOS `tar` added AppleDouble files | Delete `._*` in `work`, rebuild; tar with `COPYFILE_DISABLE=1` |
| A kube-apiserver rollout stops: `installer-N` Pending on one master, the node `Unknown` | That master's kubelet froze, on 2026-10-26 at the moment its own API server switched revision (u13 for 5 minutes, u15 and u17 until power-cycled); etcd on it stayed healthy | A graceful shutdown hangs on a node in this state. Power-cycle it from its iDRAC: `ssh root@<bmc_addr>` (oac-infra `infra/inventory/00hosts.yaml`; older iDRACs need `-o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa`), then `racadm serveraction powercycle`. Check first that the other two masters' etcd members are healthy. The node is back in about 9 minutes and the rollout resumes |

---

## 6. Changes during the build

Every fix goes through a PR, as during the build:

- One commit per PR, whose message is the full description: why, and
  which clusters it changes and how. Open the PR with `gh pr create -f`.
- oac-apps needs two approvals. Name reviewers by topic: schwesig for
  observability, computate for Keycloak, OAuth and ACS, naved001 for the
  FlashBlade, memalhot for anything.
- A PR that rolls workers or reboots nodes says so, and is merged by hand
  at an agreed time, after the health check.

---

## 7. Still open

- The ACS chart is on main ([#181](https://github.com/CCI-MOC/oac-apps/pull/181)), but no ApplicationSet uses it
  yet; stage B still installs ACS from the fork.
- **TODO:** the stages come from the fork's `compliant-dev-infra-test` branch.
  Moving the compliance charts to CCI-MOC/oac-apps main is a separate
  piece of work; until then the fork is part of the build.
- Hosted etcd is on LVM Storage on the workers (2.11), no longer on NFS.
- **TODO:** a more reliable home for the Tang server, and a DNS name for
  it so a later move is only a key copy (MOC-issues #810). Every node
  needs Tang at every boot.
- **TODO:** have someone other than the original builder walk through
  this on the hub's replacement masters, and fix what is unclear. The
  current masters stall under FIPS (2.3, section 5), and an API server
  rollout froze two of them on 2026-10-26.
- **TODO:** NetworkPolicies for the hub's namespaces, for the production
  setup (2.9).
- **TODO:** ACS's scanner hits its memory limit about every 35 minutes on
  the masters (2026-10-26, iDRAC console of u15); raise the limit or run
  fewer replicas.
- **TODO:** u17's iDRAC log has "Correctable memory error rate exceeded
  for DIMM_B5" (2026-10-17); report it to the hardware owners. The
  kernel logged no corrected errors from 2026-10-22 on.
