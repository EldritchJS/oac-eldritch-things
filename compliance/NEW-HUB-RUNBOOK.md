# Building a compliant hub and its workload clusters

*The procedure. Last run 2026-11-18 to 24, building compliant-dev-infra,
compliant-dev-workload0 and andalusia; every step below is one that
worked on that build. Open items are marked **TODO**.*

This is the single procedure for standing up a compliant (FIPS, NIST
800-171, HIPAA) OAC hub and the clusters it carries, including the
long-lived pieces a rebuild keeps: DNS zones, the FlashBlade realm, AWS
roles, the Keycloak client and the oac-apps values.

Compliance itself is no longer a procedure. Since 2026-11-24 every
compliance component is on CCI-MOC/oac-apps main, switched on by one
marker file per hub (4.10). The steps below are about everything else.

Related:

- [BUILD.md](BUILD.md): why each step is there, and the general rules.
- [HUB-SPOKE.md](HUB-SPOKE.md): the design this builds.
- [PLAYBOOK.md](PLAYBOOK.md): the hardening method behind the charts.
- [OPERATIONS.md](OPERATIONS.md): keeping a cluster compliant afterwards.

Records of the builds themselves, which this procedure came from:

- [compliant-dev-infra/RUNBOOK.md](compliant-dev-infra/RUNBOOK.md): the
  current hub, its workload cluster and andalusia (2026-11-18 on).
- [nist-dev-infra/](nist-dev-infra/): the first FIPS hub, retired
  2026-10-28.
- [JETTY.md](JETTY.md): the by-hand proof of concept, before any chart.

Names below: `<hub>`, `<cluster>`, and `<zone>` for the hub's internal DNS
zone (compliant-dev-infra: `nist.int.massopen.cloud`). Times are UTC.

---

## 0. Before you start

**Access you need:**

| For | Access |
|---|---|
| The kubeadmin kubeconfig, ACS secrets, the preflight | AWS SSO, `SecretsManagerOperatorAccess` permission set |
| Uploading OIDC signing keys (4.5, 6.4) | AWS SSO, `ClusterOperatorAccess` (membership in `moc-aws-cluster-operators`) |
| The nodes | The MOC VPN, with the hub's subnet in your WireGuard `AllowedIPs`, and the BMCs, in case a node does not come back |
| The install | CCI-MOC/oac-infra `hub-images`: a pull secret and SSH key in Secrets Manager. The pull secret's account needs ACM and ACS entitlements, not only OpenShift's (4.11) |
| PRs | Write to forks of CCI-MOC/oac-apps; reviewers by topic in §10 |

**Tools:** `oc`, `helm`, `aws`, `jq`, `gh`, `ansible` with
`ansible.utils`. Building boot media needs none of them locally: the FIPS
build host does it (4.2).

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
export HUB=$HOME/kubeadmin-<hub>
export RB=~/oat/oac-eldritch-things/compliance/nist-dev-infra   # shared scripts and MachineConfigs
aws sso login --profile $SM
```

**Health check before any change that restarts something on the hub:**

```
KUBECONFIG=$HUB oc get nodes                                   # all Ready
KUBECONFIG=$HUB oc -n openshift-etcd get pods -l app=etcd      # 3 Running, 5/5
```

If a node is NotReady, wait. On compliant-dev-infra's FC830 predecessors,
spells lasted from a minute to three hours; etcd kept quorum in all of
them.

---

## 1. Decide first

These block the build (BUILD.md, "Before either"):

- Which workloads hold CUI or ePHI, and so whether this hub is needed (P4).
- The system-use notice text (P5).
- The registry allowlist (P6).
- An audit and alert destination, or keep audit on the hub's Loki for
  now (P9).
- Hardware: see 4.1. The wrong shape costs weeks.
- Which Tang server the nodes unlock against, and whether it will still
  be there in a year (MOC-issues #810). Every node needs it at every
  boot. Not TPM: see 4.2.

---

## 2. Day one: request in parallel

Open one tracking issue that links every PR below. Each has a different
owner, and most take days. Ask a named reviewer on each.

| # | What | Repo | Owner | Example | Done when |
|---|---|---|---|---|---|
| 2.1 | The hub's DNS zone in Route 53 | `moc-aws` | moc-aws maintainers | [#54](https://github.com/CCI-MOC/moc-aws/pull/54) | The zone exists |
| 2.2 | Delegate `<zone>` to it from internal DNS | `moc-dns` | DNS admins | [#33](https://github.com/CCI-MOC/moc-dns/pull/33) | `dig NS <zone>` answers with Route 53 |
| 2.3 | Hub records: `api`, `api-int`, `*.apps` | `moc-aws` (in the zone) | moc-aws maintainers | [#77](https://github.com/CCI-MOC/moc-aws/pull/77) | They resolve on the VPN |
| 2.4 | A FlashBlade realm per cluster, named after it | `everpure-moc` `realms.yaml` | FlashBlade admins | [#38](https://github.com/CCI-MOC/everpure-moc/pull/38) | Merged |
| 2.5 | Run the realm playbook | `everpure-moc` | FlashBlade admins | (by hand) | `cluster/<hub>/portworx` in Secrets Manager |
| 2.6 | A realm certificate **marked as a CA** | on the FlashBlade | FlashBlade admins and hub owner | (by hand) | `<realm>::realm-cert` imported; the `.crt` in `cluster/<hub>/nfs-tls-ca` |
| 2.7 | Membership in `moc-aws-cluster-operators` for the hub owner | `moc-aws` `sso-users.tf` | moc-aws maintainers | [#60](https://github.com/CCI-MOC/moc-aws/pull/60) | `ClusterOperatorAccess` profile logs in |
| 2.8 | Cluster and storage VLANs on each node's ports, storage untagged, **no default route on the storage VLAN's DHCP** | switches | network admins | ansible-switches [#148](https://github.com/CCI-MOC/ansible-switches/pull/148) | DHCP leases on both; one default route, via the cluster network |
| 2.9 | Nodes on the management network, VPN only, inventory entries | `oac-infra` | infra admins | [#32](https://github.com/CCI-MOC/oac-infra/pull/32) | Nodes PXE or ISO boot |
| 2.10 | A Keycloak client for the hub, redirect `https://oauth-openshift.apps.<hub domain>/oauth2callback/mocsso` | `moc-keycloak` `main.tf` | Keycloak maintainers | [#68](https://github.com/CCI-MOC/moc-keycloak/pull/68) | Secret in `cluster/<hub>/keycloak-oidc` |

The realm playbook gives a realm the FlashBlade's own self-signed
certificate, which is `CA:FALSE`. Storage over TLS needs a CA-marked one
(2.6): generate it with BUILD.md I8's `openssl` command, with the key
made where it is imported, and import it through the FlashBlade API with
an admin token. Without it every S3 request returns 503 and NFS mounts
refuse the handshake.

---

## 3. Before install: the AWS identity, in two halves

The hub's external-secrets and cert-manager authenticate to AWS through
the hub's OIDC issuer. AWS checks the issuer's documents when the
provider is created, so the order is fixed:

1. Open the moc-aws PR now: an `openshift_oidc_clusters` entry and
   `eso-<hub>`, `cert-manager-<hub>` roles, with cert-manager allowed in
   `<zone>`. **Do not merge yet.**
2. After install (4.5), upload the hub's OIDC documents.
3. Then merge and apply. Merging first fails with "Please check
   .well-known/openid-configuration", and the apply has to be re-run.

The issuer URL contains the cluster's name, so a renamed or rebuilt hub
needs new entries; it cannot reuse the old ones.

---

## 4. The hub

Upstream: oac-apps `docs/infra-cluster-deployment.md`. Why each step:
[BUILD.md](BUILD.md) Part 1.

### 4.1 Layout and hardware

**Three dedicated control-plane nodes and three workers, installed
together,** as oac-prod-infra has. Not compact: a compliant hub is on its
way to production, and compact under FIPS is the one combination that
failed. nist-dev-infra's three compact FC830s (176 threads each) crashed
etcd under FIPS TLS load, while oac-dev-infra runs compact on the same
hardware without FIPS.

- **About 40 cores per control-plane node.** If they have much more than
  about 40 threads, boot them with `nr_cpus=40` (4.4).
- **Nodes new, or wiped since their last use** (800-171 3.8.3), every
  disk, **with the record kept**. The procedure and what to save are in
  6.2; it applies to a hub's own nodes just as much as to a workload
  cluster's.
- **A second disk on each master** for etcd, and **on each worker** for
  LVM Storage (the hosted clusters' etcd, 4.13).
- **Secure Boot off.** Dell R440s with it on would not boot the agent
  ISO, and one refused a PCIe SSD's option ROM at POST
  (`UEFI0072`). Nothing in the scans or in ACS requires Secure Boot.
- **Check the boot mode.** An FC430 sled in UEFI mode with no hard disk
  in its boot order dropped its discovery ISO to GRUB; in legacy BIOS
  mode it installed. If a sled will not power on from its BMC, reset the
  iDRAC first (`racadm racreset`).
- **Name disks by serial or WWN, never `sdX`:** the names change between
  boots. On compliant-dev-infra's workers the install disk was `sda` in
  discovery and `sdb` once installed.
- **BMC passwords differ between hardware types.** The boot playbook has
  `any_errors_fatal`, so boot each group in its own run.

**Networks.** Every node gets DHCP on both ports: the cluster network on
port 1, the storage VLAN untagged on port 2. **The storage VLAN must not
hand out a gateway.** When it did, its default route sometimes won in
early boot, the node could not reach Tang, and it stayed at the disk
unlock prompt.

**Node details.** Boot each node from the bastion's discovery ISO
(`http://10.2.0.82/boot/discovery.iso`, or `discovery-r440.iso` for
R440s, which the generic one does not boot) and read
`http://<node-ip-on-cluster-network>/index.txt`. Record each node's MAC
on the cluster network, the install disk's serial, the second disk's WWN,
and the thread count.

**Inventory.** Add a group for the hub under the right parent in
oac-infra `infra/inventory/00hosts.yaml`, with controllers and computes,
their `node_name`, `bmc_addr` and the `boot_image_url` each needs. Remove
any commented block that claims the same BMCs, so no node is claimed
twice.

### 4.2 Install vars and boot media

**oac-infra `hub-images/group_vars/<hub>/vars.yml`, in one PR,** with an
entry for `<hub>` in `hub-images/inventory.yml`:

- `master1` to `master3`: hostnames, IPs, MACs, `install_drive_serial`
  and `etcd_drive_wwn` from 4.1. **Quote the WWNs:** YAML reads an
  unquoted `0x...` as a number, and Jinja writes it back in decimal.
- A `workers:` list: hostname, ip, mac, `install_drive_serial`, and
  `lvms_drive_wwn` for the LVM Storage disk. See
  `group_vars/examples/vars.yaml.example`.
- `diskencryption_mode: tang`, with `tang_servers` (url, thumbprint).
  Take the thumbprint from the server itself (`tang-show-keys`), not from
  its `/adv`. Every node's root disk, the masters' etcd disks and the
  workers' LVM Storage disks are then LUKS2, unlocked only through Tang.
  **Not `tpmv2`:** on hardware with no working TPM it installs
  unencrypted without saying so.
- `cluster_domain_name: <hub>`, `base_domain`, the networks,
  `rendezvous_ip` (one of the control-plane IPs), `api_ip`, `ingress_ip`,
  `fips_enabled: true`.
- `ssh_public_key`: ECDSA or RSA. FIPS rejects Ed25519.

**Before building:** `cluster/<hub>/sshkey` and `hub-images/pull-secret`
in Secrets Manager, and the api, api-int and `*.apps` records (2.3).

**Build the boot media on the FIPS build host.**
`openshift-install-fips` will not make media for a FIPS cluster on a host
without FIPS mode, so this runs on `fips-builder` (10.2.0.99; oac-infra
[#33](https://github.com/CCI-MOC/oac-infra/pull/33), MOC-issues #792),
which is FIPS-enabled, registered, and has the bastion key for the
upload:

```
ssh builder@10.2.0.99
cd hub-images
aws sso login --use-device-code --profile <profile>   # the host stores no AWS keys
AWS_PROFILE=<profile> ./build.sh <hub>
```

It fetches the SSH key and pull secret from Secrets Manager, builds the
ISO, stores the new cluster's kubeadmin kubeconfig in Secrets Manager,
and copies the ISO to the bastion's
`/srv/boot/<hub>-agent.x86_64.iso`. **Expect:** `ISO generated
successfully`, then the rsync line.

For a dry run that changes nothing, add `NO_STORE=1` (keeps a live hub's
kubeadmin secret) and `NO_UPLOAD=1` (keeps the bastion's ISO). An ISO
built with `NO_STORE=1` has credentials nobody kept: do not install from
it, build a fresh one.

### 4.3 Boot, and the first checks

Point the hub's groups in `00hosts.yaml` at
`http://10.2.0.82/boot/<hub>-agent.x86_64.iso` and boot all six
(`docs/hardware-inventory-and-configuration.md`, "Boot configuration"),
each BMC password group in its own run. Then wait. `wait-for` does not
need FIPS, so the plain `openshift-install` of the same version works
from a laptop on the VPN:

```
openshift-install agent wait-for install-complete --dir output/<hub>/work
```

**Expect:** `Install complete!` in about an hour. If a node stalls, see
§9: the disk unlock rows.

Fetch the kubeconfig the build stored, and keep it out of every repo:

```
(umask 077; aws --profile $SM secretsmanager get-secret-value --secret-id cluster/<hub>/kubeadmin \
  --query SecretBinary --output text | base64 -d > $HUB)
```

**Check FIPS on every node.** If any check fails, reinstall:

```
export KUBECONFIG=$HUB
oc get nodes                                                    # 6 Ready: 3 control-plane, 3 worker
oc get cm cluster-config-v1 -n kube-system -o yaml | grep fips  # fips: true
for n in $(oc get nodes -o name); do
  oc debug $n -q -- chroot /host cat /proc/sys/crypto/fips_enabled   # 1
done
```

**And Tang on every data disk:** `root` on all six, `etcd` on the
masters, `lvms` on the workers, each with one keyslot, a clevis token and
no passphrase:

```
for n in $(oc get nodes -o name); do
  oc debug $n -q -- chroot /host sh -c 'for m in root etcd lvms; do
    [ -e /dev/mapper/$m ] || continue
    d=$(cryptsetup status $m | awk "/device:/{print \$2}")
    echo "$(hostname) $m keyslots=$(cryptsetup luksDump $d | grep -cE "^  [0-9]+: luks2") $(clevis luks list -d $d)"
  done'
done
```

**Turn on etcd encryption now, while etcd is empty.** Re-encrypting a
busy hub stalled nist-dev-infra's masters and became a POA&M item there;
on a new hub it costs nothing:

```
oc patch apiserver cluster --type merge -p '{"spec":{"encryption":{"type":"aesgcm"}}}'
oc get openshiftapiserver -o=jsonpath='{range .items[0].status.conditions[?(@.type=="Encrypted")]}{.reason}{"\n"}{end}'
# EncryptionCompleted, within about 20 minutes
```

### 4.4 USBGuard, and 40 CPUs if the masters need it

Do this while the hub is empty: each master reboots once, and drains are
cheap with nothing running. The USBGuard MachineConfig is always applied.
Add `nr-cpus-machineconfig.yaml` only if 4.1 showed control-plane nodes
with much more than about 40 threads; otherwise leave it out and skip the
two CPU checks. Without it, etcd crashes under FIPS TLS handshake load
once the hub is busy.

```
export KUBECONFIG=$HUB
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
oc apply -f $RB/nr-cpus-machineconfig.yaml -f $RB/usbguard-enable-machineconfig.yaml
oc get mc $(oc get mcp master -o jsonpath='{.spec.configuration.name}') \
  -o jsonpath='{.spec.kernelArguments}{"\n"}'                   # includes nr_cpus=40
oc patch mcp master --type merge -p '{"spec":{"paused":false}}'
oc wait mcp/master --for=condition=Updated --timeout=90m
```

The rendered config name changes a minute or two after `apply`. If the
kernel arguments do not show `nr_cpus=40`, wait and look again before
unpausing.

The USBGuard unit waits for an extension that node hardening installs
later, so `systemctl is-enabled usbguard` reports no such unit until
then; that is expected. The masters' MachineConfig does not cover the
workers, whose scan then fails `service-usbguard-enabled`; the worker
copy is `$RB/usbguard-enable-worker-machineconfig.yaml` (one reboot each,
about 20 minutes).

### 4.5 The service account issuer and OIDC keys

Before anything on the hub needs AWS. The install templates cannot set
`serviceAccountIssuer`, so the script sets it; that restarts the API
servers and most pods, which is harmless on an empty hub. `-f` replaces
any keys a previous cluster of the same name left in S3; without it AWS
rejects every token.

```
aws sso login --profile $CO
cd ~/oat/oac-apps
KUBECONFIG=$HUB AWS_PROFILE=$CO CLUSTER_NAME=<hub> bootstrap/setup-oidc.sh -f
```

Answer yes when it asks to set the issuer. If an upload fails with "Token
has expired and refresh failed" right after `aws sso login`, the login
reused an expired portal session: `aws sso logout`, then log in again.

```
KUBECONFIG=$HUB oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/<hub>/.well-known/openid-configuration | jq .issuer
KUBECONFIG=$HUB oc get co kube-apiserver                     # Available, not Progressing (about 20 minutes)
```

Then merge and apply the moc-aws PR from §3.

### 4.6 The hub's values in oac-apps

One PR, in `values/<hub>/local-cluster/`:

| File | What |
|---|---|
| `external-secrets.yaml` | The `eso-<hub>` role |
| `portworx.yaml` | Nodes, storage ports and subnet, `tls: true` |
| `nfs-tls.yaml` | `tlshd` on every node, CA from `cluster/<hub>/nfs-tls-ca`, `storageClass.enabled: false` |
| `cert-manager.yaml`, `external-dns-operator.yaml` | The `cert-manager-<hub>` role, the zone |
| `openshift-gitops.yaml` | Argo controller at 8Gi, or it OOMs once clusters arrive |
| `acm.yaml`, `acm-placements.yaml`, `hcp-config.yaml`, `metallb.yaml` | ACM, the agent install service, the hosted-clusters router |
| `cluster-certificates.yaml` | A Let's Encrypt wildcard for the apps routes; the API certificate stays off, because agents and kubeconfigs trust the cluster's own CA |
| `keycloak-oauth.yaml`, and `apps/<hub>/keycloak-oauth.yaml` | Hub SSO through the 2.10 client, with `tokenConfig` (86400 s, 10m0s) |
| `lvmcluster.yaml` | The LVMCluster device selector at `/dev/mapper/lvms` (4.13) |

**Storage is TLS only from the first volume:** `portworx.yaml` and
`nfs-tls.yaml` go in together, or `nfs-tls` first (BUILD.md, "Storage is
TLS-only from its first volume").

The compliance values are a separate list, in 4.10.

### 4.7 Bootstrap Argo

Install the OpenShift GitOps operator and its ArgoCD instance first
(about 5 minutes); the bootstrap Application needs its CRDs.

```
cd ~/oat/oac-apps
KUBECONFIG=$HUB bootstrap/setup-gitops.sh
helm template bootstrap ./bootstrap --set hubName=<hub> | KUBECONFIG=$HUB oc apply -f -
KUBECONFIG=$HUB oc -n openshift-gitops get applications.argoproj.io      # all Synced, Healthy, after about 30 minutes
```

Use `applications.argoproj.io`: ACM adds another `Application` type, and
plain `oc get applications` lists that one, empty.

**If an app stays Degraded,** read its message
(`oc -n openshift-gitops get applications.argoproj.io <app> -o jsonpath='{.status.conditions}'`).
`hub-portworx` fails until 4.8 passes; re-sync it by hand then, because
Argo does not retry a failed commit.

### 4.8 Storage, TLS only, before any volume

```
cd ~/oat/oac-eldritch-things/compliance
KUBECONFIG=$HUB AWS_PROFILE=$SM tests/hub-preflight.sh <hub>   # every check PASS
KUBECONFIG=$HUB oc get sc                  # pure-fb-nfsv4 (default), TLS
KUBECONFIG=$HUB oc -n nfs-tls get pods     # tlshd Running on every node
```

If `pure-fb-nfsv4` is missing, re-sync `hub-portworx`.

Volumes that have waited since the install (Prometheus,
assisted-service, Perses) bind the moment the class exists, so **tlshd
has to be running first**. With several volumes arriving at once, tlshd
forks a process per handshake; its limit is 1Gi since oac-apps
[#258](https://github.com/CCI-MOC/oac-apps/pull/258), after it was
OOMKilled three times at 256Mi and every pending mount failed with
`mount.nfs: No such process`.

### 4.9 Object storage

`pure-cosi` and `object-storage-proxy` sync from main.

```
export KUBECONFIG=$HUB
oc get bucketclaims.objectstorage.k8s.io -A        # every claim Ready
dig +short s3.<hub domain>                         # the proxy's cluster IP, 172.30.x.x
oc -n portworx logs deploy/pure-cosi-driver --all-containers | grep -i -m5 realm   # no "Realm does not exist"
```

Wrong realm or endpoint values fail quietly: the only sign is pods
waiting for their bucket (BUILD.md I8). The `s3.<hub domain>` record
points at the proxy's ClusterIP, through a moc-aws PR.

### 4.10 Compliance: one marker and the hub's values

Every compliance component is on oac-apps main. One file switches them
all on for a hub, and the same marker covers its hosted clusters, because
a compliant hub carries only compliant clusters.

In one oac-apps PR:

1. `hosted-clusters/<hub>/compliance.yaml`, the marker. It may be empty;
   values in it apply to every hosted cluster.
2. `values/<hub>/local-cluster/<component>.yaml` for the hub's own
   components: `compliance-operator`, `compliance-node-hardening`,
   `platform-hardening`, `audit-logging`, `etcd-backup`, `rhacs`,
   `nfs-tls`, `namespace-guardrails-app`. Copy compliant-dev-infra's and
   change what the hub's name, networks and namespaces change.
3. `values/<hub>/hosted-clusters/<component>.yaml` for every hosted
   cluster (tailoring, guardrails, ACS, audit forwarding), and
   `values/<hub>/<cluster>/<component>.yaml` per cluster, as those
   clusters arrive (§6).

Three ApplicationSets then do the work, all gated on the marker:

| ApplicationSet | Deploys | Apps named |
|---|---|---|
| `hub-components-compliance` | the hub's own components, plus file integrity | `hub-<component>` |
| `compliance-clusters` | compliance-operator, file-integrity, platform-hardening, rhacs, audit-logging and namespace-guardrails-app to every managed cluster; nfs-tls to Portworx clusters | `<cluster>-<component>` |
| `compliance-gpu-clusters` | NFD and the GPU Operator to any cluster that has `values/<hub>/<cluster>/nvidia-gpu-operator.yaml` | `<cluster>-<component>` |

**Node hardening reboots every node.** It is about 380 MachineConfigs.
Agree a time, run the health check, pause the pools, let the PR merge,
then unpause:

```
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'
# merge, then:
oc get mc | grep -c '^75-'                                # about 380, once synced
oc patch mcp master --type merge -p '{"spec":{"paused":false}}'
oc patch mcp worker --type merge -p '{"spec":{"paused":false}}'
oc wait mcp/master --for=condition=Updated --timeout=180m
```

One node at a time, about 10 minutes each. To stop between nodes, pause
the pool again. A kubelet that stops reporting for more than 10 minutes
while its node answers can be restarted:
`oc debug node/<node> -- chroot /host systemctl restart kubelet`.

**After any MachineConfig roll, AIDE flags the machine-config daemon's
own files** (`/etc/machine-config-daemon/previous-logs/`) on the nodes
that rebooted. Re-initialise each, **one at a time**: the annotation
takes one node, and setting it again before the operator has acted
replaces the earlier one.

```
oc annotate fileintegrity all-nodes -n openshift-file-integrity \
  file-integrity.openshift.io/re-init=<node> --overwrite
oc get fileintegritynodestatuses -n openshift-file-integrity   # Succeeded on every node
```

### 4.11 ACS init bundle, by hand

The pull secret has to reach the add-on images, not only OpenShift's. The
install pulls OpenShift alone, so a pull secret from an account without
ACM and ACS entitlements installs fine and fails later, one image at a
time, as "denied: Token rejected by upstream registry". Check from any
node first:

```
oc debug node/<a worker> -- chroot /host bash -c '
  for i in rhacm2/thanos-rhel9:v2.17 advanced-cluster-security/rhacs-central-db-rhel9:5.0.0; do
    podman pull -q --authfile /var/lib/kubelet/config.json registry.redhat.io/$i >/dev/null && echo "ok   $i" || echo "FAIL $i"
  done'
```

Any FAIL: the account behind `hub-images/pull-secret` needs those
subscriptions, or use a pull secret from one that has them.

Then the hub's init bundle, once Central is up
(`oc -n stackrox rollout status deploy/central --timeout=30m`). It is a
credential: never commit it, and delete the file once applied.

```
umask 077; B=$(mktemp)
oc -n stackrox exec deploy/central -- roxctl central init-bundles generate <hub> \
  --insecure-skip-tls-verify \
  --password "$(oc -n stackrox get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}')" \
  --output-secrets - > $B
oc -n stackrox apply -f $B && rm -P $B
oc -n stackrox get securedcluster                         # Available within about 5 minutes
```

If the SecuredCluster is not Available after 5 minutes, the operator may
have given up just before the bundle arrived. Nudge it:
`oc -n stackrox annotate securedcluster stackrox-secured-cluster-services reconcile-nudge=$(date +%s) --overwrite`.

**A cluster registration secret instead, for clusters that do not exist
yet.** From ACS 5.0 the operator reads a Secret named
`cluster-registration-secret` (one key, `crs`) in the stackrox namespace,
runs a `crs` init container in the sensor pod, registers the cluster and
writes its own certificates. One CRS can onboard many clusters
(`--max-clusters 0`), so a hub could mint one, keep it in the secret
store, and let every new cluster register itself instead of someone
generating a per-cluster init bundle:

```
oc -n stackrox exec deploy/central -- roxctl central crs generate <name> \
  --insecure-skip-tls-verify --password "$(oc -n stackrox get secret central-htpasswd \
  -o go-template='{{index .data "password" | base64decode}}')" \
  --max-clusters 0 --valid-for 720h --output -
```

Two things to know before relying on it. **It only works for a cluster
Central has never seen:** on an already-registered cluster the handshake
is refused with "forbidden to use a Cluster Registration Certificate for
already-existing cluster" (tested on andalusia, 2026-11-25), so an
existing cluster that loses its certificates still needs an init bundle,
or must be deleted from Central first. And **it expires**: the default is
24 hours, so `--valid-for` has to cover the build window. Delivering it
through the secret store, as the rhacs chart's values ask, is not wired
up yet (MOC-issues #830).

### 4.12 Record the etcd backup volume outside the hub

So the backup is findable without the hub: patch its PV to `Retain`, look
up the volume's name on the FlashBlade, and record it in Secrets Manager
as `cluster/<hub>/etcd-backup-volume`. The commands are in the
etcd-backup chart's `values.yaml`. Repeat if the claim is ever recreated,
since the name changes with it. The compliance evidence PVs should be
`Retain` too.

### 4.13 LVM Storage on the workers

For the hosted clusters' etcd (MOC-issues #772): each worker's second
disk is encrypted against Tang at install and opened as
`/dev/mapper/lvms` before kubelet starts (4.2), and `lvmcluster.yaml`
points the device selector at it (4.6). `node-labels` marks every worker,
and the hosted-cluster chart's default `lvms-vg0` class is used, so the
hosted-clusters values set no etcd storage class. Hosted etcd on
FlashBlade NFS is test-only: it failed on a stale NFS lock (§9).

### 4.14 Scan, tailor, verify

Scans run nightly at 01:00. To scan now:

```
export KUBECONFIG=$HUB
for s in $(oc -n openshift-compliance get compliancescans -o name); do
  oc -n openshift-compliance annotate $s compliance.openshift.io/rescan= --overwrite
done
oc -n openshift-compliance get compliancescans                # all DONE, about 15 minutes
oc -n openshift-compliance get compliancecheckresults -l compliance.openshift.io/check-status=FAIL
```

**Archive the first results as the hub's baseline**, in
`tests/baseline-<hub>.txt`.

Then `verify.sh`, which checks what the steps above set up: FIPS, TLS,
the scans, ACS, the registry allowlist, SCCs, etcd backups, file
integrity, LUKS and Tang on every disk, OAuth token timeouts, chrony, the
API audit profile, USBGuard, default-deny NetworkPolicies, and the
admission policies on Deny.

```
cd ~/oat/oac-eldritch-things/compliance/tests
KUBECONFIG=$HUB ./verify.sh
```

BUILD.md Part 1 step 7 also has admission-policy dry runs, which create
nothing: a cleartext FlashBlade StorageClass and four non-compliant
HostedClusters and NodePools must each be denied, and the compliant ones
accepted.

**What a hub does not pass, and why.** compliant-dev-infra's baseline is
**3 distinct rules** (2026-11-24), all known:

| Rule | Status |
|---|---|
| `kubeadmin-removed` (also CIS) | **Known gap.** The kubeadmin login is a shared account, so the audit log cannot tell who used it (AC-2, IA-2). Removing it safely needs an SSO cluster-admin group first |
| `configure-network-policies-namespaces` (also CIS) | **TBD for production.** Policies for about 20 namespaces, many of them ACM, HyperShift and storage; each needs its traffic measured first, and a wrong policy cuts off a hub component. ACS's Network Graph records observed traffic and can generate them |
| `cluster-wide-proxy-set` | **POA&M.** None planned |

Rules that used to fail and are now fixed by the charts are listed in
[compliant-dev-infra/RUNBOOK.md](compliant-dev-infra/RUNBOOK.md); if one
reappears, that table says what closed it.

---

## 5. Hosted clusters: what the hub needs first

**The hub passes `verify.sh` first,** with every FAIL fixed or recorded
as known (4.14), and its ACS Central Available. The hub holds a hosted
cluster's control plane and data, so it is shown hardened before any
cluster goes on it. A cluster's PR can be written while that is being
done; it waits for two approvals anyway.

```
export KUBECONFIG=$HUB
oc -n openshift-gitops get applications.argoproj.io      # all Synced, Healthy
oc -n stackrox get central                               # Available
oc get validatingadmissionpolicybinding compliant-hosted-clusters \
  -o jsonpath='{.spec.validationActions}{"\n"}'           # ["Deny"]
```

| # | What | Repo |
|---|---|---|
| 5.1 | Agent install service and FIPS discovery image | `oac-apps` |
| 5.2 | Hub-wide values for every hosted cluster: FIPS, node hardening, audit profile, registry allowlist, import allowlist, token timeouts | `oac-apps` `hosted-clusters/<hub>/values.yaml` |
| 5.3 | Zones for hosted clusters (`hcp.<zone>`, `hcp-int.<zone>`), an external-dns user, ESO prefixes | `moc-aws` |
| 5.4 | cert-manager may answer DNS-01 in those zones | `moc-aws` |
| 5.5 | Wildcards to the hosted-clusters router, for Ignition, Konnectivity, OAuth and the agents' `api` checks | `moc-aws` |
| 5.6 | Compliance values for all hosted clusters (4.10 step 3), including `forwarder.remote.hubIngressCA: false` when the hub's apps certificate is publicly issued | `oac-apps` |

The hub's `router-hosted-clusters` Service must hold its pinned MetalLB
address. If the Service and the pinned pool are created in the same
second at bootstrap, the Service can take an address from the default
pool instead, and MetalLB never moves an assigned address; the agents
then cannot download their ignition. Delete the Service and let the
ingress operator recreate it.

---

## 6. A workload cluster

Upstream: oac-apps `docs/workload-cluster-deployment.md`. Why each step:
[BUILD.md](BUILD.md) Part 2.

### 6.1 Requests, in parallel

| # | What | Repo |
|---|---|---|
| 6.1.1 | The cluster's values: name, NodePools, agent selectors, network, release | `oac-apps` `hosted-clusters/<hub>/<cluster>/` |
| 6.1.2 | One storage NIC with `never-default`, or a reboot can put `br-ex` on the wrong NIC | same |
| 6.1.3 | `podPidsLimit` for the pool if its nodes have many cores (see §9, multus) | same |
| 6.1.4 | A Keycloak client, redirect URI from the HostedCluster's `oauthCallbackURLTemplate` with `mocsso` | `moc-keycloak` |
| 6.1.5 | A FlashBlade realm, if the cluster gets storage | `everpure-moc` |

Hold the cluster's `hosted-clusters` entry back until its workers are
ready: Argo starts the control plane as soon as the entry exists.

### 6.2 Workers

Boot them from **this hub's** discovery ISO:

```
export KUBECONFIG=$HUB
oc get infraenv -n hardware-inventory hardware-inventory -o jsonpath='{.status.isoDownloadURL}{"\n"}'
```

A BMC may refuse to mount that URL itself if it does not trust the hub's
Let's Encrypt certificate. What worked on Lenovo XCC: open the BMC's web
console, download the ISO, mount it with "Mount media from client" (keep
the tab open until the Agent registers), then a one-time CD boot over
Redfish.

**Wipe the disks before approving, and keep the record.** This is by hand
(decided 2026-11-25): ESI is being moved away from, and RHOSO18's Ironic,
which would bring automated cleaning back, is still an open evaluation
(MOC-issues #793). The discovery ISO runs from memory, so wiping the boot
disk is fine. On each (`ssh core@<ip>` with the cluster key):

```
{ hostname; date -u
  echo "== before"; lsblk -d -o NAME,SIZE,MODEL,SERIAL
  for d in $(lsblk -dn -o NAME -e 7,11); do
    sudo wipefs -a /dev/$d && sudo blkdiscard -f /dev/$d && echo "wiped and discarded /dev/$d"
  done
  echo "== after"; lsblk -d -o NAME,SIZE,MODEL,SERIAL
  for d in $(lsblk -dn -o NAME -e 7,11); do
    echo "/dev/$d signatures: $(sudo wipefs /dev/$d | tail -n +2 | wc -l | tr -d ' ') found"
  done
} | tee ~/wipe-<node>.txt
sudo systemctl restart agent.service      # re-read the empty disks; no reboot needed
```

**Keep every `wipe-<node>.txt`.** 800-171 3.8.3 wants the sanitization
record, not just the sanitization, and the record is the part that gets
forgotten: compliant-dev-infra's own six nodes have none, because the
wipe was described as a precondition rather than a step with an output
(the two SD665s that became workload0's workers do, in
`~/work/drafts/sd665-wipe/`). Note that `blkdiscard` is roughly SP 800-88
*Clear*; a drive's own sanitize or crypto-erase is *Purge*, which a
cluster holding CUI may need instead. **TODO:** confirm which level
applies with the authorizing official.

Approve and label them, picked by product name so no other node is
caught:

```
oc -n hardware-inventory get agents
for a in $(oc -n hardware-inventory get agents -o name); do
  p=$(oc -n hardware-inventory get $a -o jsonpath='{.status.inventory.systemVendor.productName}')
  case $p in *<model>*)
    oc -n hardware-inventory patch $a --type merge -p '{"spec":{"approved":true}}'
    oc -n hardware-inventory label $a --overwrite massopen.cloud/cluster=<cluster> openstack/resource-class=<class>
  esac
done
```

### 6.3 The cluster

Merge the `hosted-clusters` entry. The ApplicationSet creates the
HostedCluster and NodePool, and the hub's admission policy checks them.

```
oc -n clusters get hostedcluster <cluster> -o jsonpath='{.spec.fips} {.spec.configuration.apiServer.audit.profile}{"\n"}'
# true WriteRequestBodies
oc -n clusters get hostedcluster,nodepool                 # Available, all nodes (about an hour)
```

If the sync fails with a `compliant-hosted-clusters` message, fix the
values, not the policy.

Get its admin kubeconfig for the next steps. It is a credential: keep it
out of repos and delete it when done.

```
umask 077; W0=$(mktemp)
oc -n clusters extract secret/<cluster>-admin-kubeconfig --keys=kubeconfig --to=- > $W0
KUBECONFIG=$W0 oc get nodes
```

### 6.4 OIDC keys, SSO, certificates

1. **OIDC keys.** HyperShift sets the issuer; upload the keys before
   external-secrets and cert-manager need AWS, or cert-manager backs off
   and the ingress certificate is not issued:

   ```
   cd ~/oat/oac-apps
   KUBECONFIG=$W0 AWS_PROFILE=$CO CLUSTER_NAME=<cluster> bootstrap/setup-oidc.sh -f -n
   curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/<cluster>/.well-known/openid-configuration | jq .issuer
   ```

2. **SSO** needs nothing beyond the Keycloak client (6.1.4) and
   `oauth.mocsso.enabled: true` in the values. HyperShift removes
   kubeadmin once oauth-openshift is up. The OAuth route is internal: log
   in over the VPN.

3. **Certificates and secrets** sync from main.

   ```
   KUBECONFIG=$W0 oc get clustersecretstore,clusterissuer      # Valid, Ready
   KUBECONFIG=$W0 oc -n openshift-ingress get certificate      # Ready within a few minutes
   ```

### 6.5 Compliance

Automatic: the cluster is in the hub's `all-managed-clusters` placement,
the hub has the marker, so `compliance-clusters` (4.10) deploys its
components as soon as it joins. What is left is per cluster:

1. **Its values**, if it needs any beyond the hub-wide ones:
   `values/<hub>/<cluster>/<component>.yaml`. A new operator namespace
   brings `resource-requests-quota` and the limits rules with it until
   its guardrails are added.
2. **Its ACS init bundle**, generated on the hub's Central as in 4.11 but
   applied with the cluster's kubeconfig, and
   `securedCluster.clusterName` set in its rhacs values. This is the
   by-hand step that MOC-issues #830 is about replacing with delivery
   through the secret store. **A new cluster is the only place the
   automated path can be tested**, because a cluster registration secret
   is refused for a cluster Central already knows (4.11), so it is worth
   deciding which way to go before registering one rather than after.
3. **Audit forwarding:** add the cluster to the hub's audit-logging
   `auditWriters.clusters`, and to the hub's etcd-backup
   `hostedClusters`, which gives it a nightly snapshot CronJob on the
   hub.

```
KUBECONFIG=$W0 oc -n openshift-logging get clusterlogforwarder   # Ready
```

If an Argo app for the cluster goes Unknown after guardrails sync, a
NetworkPolicy may have cut the cluster off from the hub, and Argo cannot
reach it to fix it. Delete that policy with the cluster's own kubeconfig.

### 6.6 Scan and verify

```
for s in $(KUBECONFIG=$W0 oc -n openshift-compliance get compliancescans -o name); do
  KUBECONFIG=$W0 oc -n openshift-compliance annotate $s compliance.openshift.io/rescan= --overwrite
done
KUBECONFIG=$W0 oc -n openshift-compliance get compliancecheckresults -l compliance.openshift.io/check-status=FAIL
HUB_KUBECONFIG=$HUB KUBECONFIG=$W0 ./verify.sh
rm -P $W0
```

`HUB_KUBECONFIG` is needed: a hosted cluster's control-plane checks, its
Central and its etcd backups are all read from the hub.

**Expect** 2 distinct rules on a hosted cluster
(compliant-dev-workload0's baseline): `cluster-wide-proxy-set`, the same
POA&M as the hub, and `configure-network-policies-namespaces` for the
namespaces whose traffic has not been measured yet. Archive the first
results as that cluster's baseline.

---

## 7. A GPU hypervisor cluster

A workload cluster whose GPUs go to KubeVirt VMs rather than to pods.

1. **Values:** `values/<hub>/<cluster>/nvidia-gpu-operator.yaml` with
   `sandboxWorkloads` on and `defaultWorkload: vm-passthrough`, and
   `nfd-operator.yaml` with `enableTaints: false` (every node is a GPU
   node, so the taint would leave platform pods Pending). That file's
   existence is what puts the cluster in `compliance-gpu-clusters`
   (4.10). Not the `massopen.cloud/feature-gpu` label: that placement
   also installs RHOAI, serverless, service mesh and Kueue, and starts
   the operator in container mode, which claims the GPUs for pods.
2. **HyperConverged**, in the openshift-virtualization chart values:
   `permittedHostDevices` for the GPU's PCI id, and `maxHotplugRatio: 1`.
   At the default 4, QEMU refuses GPUs to VMs over 63 vCPUs.
3. **`vfio_iommu_type1` at boot**, a NodePool MachineConfig. The GPU
   Operator's VFIO manager loads `vfio-pci` but not this backend, so
   passthrough needs both: the binding from the operator and the module
   from git. Without it the node still advertises its GPUs and only a
   VM's start fails, which is why `verify.sh` T-07 checks
   `/sys/module/vfio_iommu_type1` on each passthrough node.
4. About a minute after the operator is Succeeded, each node advertises
   its GPU resource and every GPU is on `vfio-pci`.
5. `../vms/gpu/test-gpu-vm.sh` with `NAMESPACE=gpu-test GPU_COUNT=1`
   claims a billable GPU while it runs and deletes the VM on exit. Delete
   the namespace after.
6. **Scan fallout:** quotas for `nvidia-gpu-operator` and `openshift-nfd`;
   the operator's DaemonSets (no limits) and its nine `nvidia-*` SCCs
   (all capabilities) join the vendor exemptions. NFD creates
   `/etc/kubernetes/node-feature-discovery`, so re-initialise AIDE after.
7. **FIPS:** `gpu-operator-certified` is accepted in
   `../tests/operator-fips-accepted.txt` as a WARN. NVIDIA's FIPS builds
   need an NVIDIA AI Enterprise subscription, which MOC does not have.

**GPUs cost money.** Stop a VM that is holding GPUs when it is not in
use, and remember that stopping it needs the follow-up in §8.

## 8. A GPU VM cluster

A KubeVirt hosted cluster whose workers are VMs on a GPU hypervisor
cluster (§7), as andalusia runs on compliant-dev-workload0.

- **Hub `hcp-config`:** the hypervisor under `hypervisorClusters`. The
  hub writes `<hypervisor>-kubeconfig` in `clusters` from Secrets
  Manager, which the hypervisor's PushSecret keeps current.
- **On the hypervisor:** `hypervisor-cluster.yaml` lists the VM cluster
  and its namespace; `metallb.yaml` pins its ingress address for that
  namespace only. The hypervisor's own router keeps its pool.
- **The VM cluster:** its API on the hub's pool, FIPS from the hub
  default, the VM's vCPUs, memory, disk and GPUs. No disk encryption in
  the guest: the FlashBlade encrypts at rest (CMVP #5000).
- **Back the VM with 1Gi hugepages**, reserved on the hypervisor's nodes
  at boot and set on the VM through HyperShift's
  `kubevirt-vm-jsonpatch` NodePool annotation. Without them a large VM
  with passed-through GPUs takes about 19 s to start, outlasting
  virt-handler's SyncVMI timeout, and ends up a transient libvirt domain
  whose later hot-plugs all fail (§9). With them it starts in 5 to 7 s.
- **`evictionStrategy: None`**, so draining a hypervisor node shuts the
  VM down instead of waiting on CAPK (§9). Leave `autoRepair` off, or it
  fights a VM parked with `virtctl stop`. Tested on 2026-11-25: the drain
  finished in 54 s, the VM restarted itself on the other node in about
  40 s, and the CAPI Machine stayed `Running`, so neither the by-hand VMI
  delete nor the Machine-failure clear below was needed.
- **Inside the VM cluster:** the GPU Operator in container mode
  (`sandboxWorkloads` off, NFD taints off), from the same values file
  that puts it in `compliance-gpu-clusters`.
- **Its own compliance values:** the use notice, guardrails for its
  namespaces, `nvidia-gpu-operator`, `openshift-nfd` and
  `external-secrets`, or the scan's `banner-or-login-template-set`,
  `openshift-motd-exists` and `resource-requests-quota` fail. Scan
  results land on the infra storage class, not `pure-fb-nfsv4`. Leave
  nfs-tls out: it goes only to Portworx clusters.
- **On the hypervisor, after the VM cluster arrives:** its namespace is
  new there and needs a quota and NetworkPolicy, and HyperShift's
  `default-ingress-passthrough` route needs the route annotations, which
  the ACM policies (platform-hardening `routeAnnotations`) apply by
  themselves.
- **After every restart,** re-initialise AIDE in the VM cluster: the GPU
  driver rebuild changes files. Expect the GPUs back in about 10 minutes.
- **verify.sh on the hypervisor** would fail T-17 (billing) for the VM's
  GPUs; `GPU_CLAIM_ALLOW_NS` names the VM's namespace so they WARN
  instead.

---

## 9. Known failures, and what to do

| Symptom | Cause | Fix |
|---|---|---|
| A node sits at "Please enter passphrase for disk root", the console repeating "clevis-luks-askpass: Error communicating with server" | The storage network's DHCP gave a default route that won in early boot; Tang is reachable only from the cluster network | Remove the gateway from that VLAN's DHCP (2.8). If it recurs, check `ip route` on a running node shows one default route, via `br-ex`, then power-cycle the stuck node |
| A node is up and pings but never registers; no CSRs; `etcd-disk.service` or `lvms-disk.service` failed with "Error communicating with server" | On first boot the unit unlocked its disk while ovs-configuration was moving the address onto `br-ex` | Fixed in oac-infra [#38](https://github.com/CCI-MOC/oac-infra/pull/38). On an older ISO: `ssh core@<node>`, `sudo systemctl restart etcd-disk` (or `lvms-disk`), `sudo systemctl start kubelet` |
| A node never boots the agent ISO | Secure Boot on | Turn it off in the BIOS (4.1) |
| `agent create image` fails: "could not decode YAML for openshift/._98-...: control characters are not allowed" | macOS `tar` added AppleDouble files | Delete `._*` in `work`, rebuild; tar with `COPYFILE_DISABLE=1`. The FIPS build host avoids this |
| moc-aws apply fails: "Please check .well-known/openid-configuration" | The OIDC documents were not uploaded yet | Upload (4.5 or 6.4), re-run the apply |
| AWS rejects the cluster's tokens after a rebuild | `setup-oidc.sh` without `-f` kept the old cluster's keys in S3 | Run it again with `-f` |
| An Argo app keeps failing with an error your fix already removed | Argo retries a failed sync at the commit it started with (five times, about 15 minutes) | Wait for the retries to end, or terminate the operation |
| New volumes fail; tlshd logs "Certificate signer not found" | tlshd reads its CA only at startup | `oc -n nfs-tls rollout restart daemonset/tlshd` |
| Every S3 request returns 503, proxy health checks pass | HAProxy verified the FlashBlade's certificate against the client's Host header | Fixed in oac-apps [#174](https://github.com/CCI-MOC/oac-apps/pull/174). The realm certificate must also be a CA (2.6) |
| Loki discards hosted audit lines | The application tenant's line size and rate limits | `loki.tenantLimits` in the hub's audit-logging values (already set) |
| A hosted cluster's API returns 500, "failing health checks: etcd"; etcd logs "took too long" | etcd's WAL file creation blocked on a stale NFS lock on the FlashBlade | Delete the stale `member/wal/*.tmp` file in etcd-0, then delete the etcd-0 pod. Hosted etcd belongs on LVM Storage (4.13), not NFS |
| Masters go NotReady in turn, etcd restarts | FIPS TLS handshakes on large-core nodes | `nr_cpus=40` (4.4). Spells still happen a few times a day on affected hardware: wait them out |
| A kube-apiserver rollout stops: `installer-N` Pending on one master, the node `Unknown` | That master's kubelet froze at the moment its own API server switched revision; etcd on it stayed healthy | A graceful shutdown hangs on a node in this state. Check the other two masters' etcd members are healthy, then power-cycle it from its iDRAC (`racadm serveraction powercycle`). Back in about 9 minutes |
| A hosted cluster loses its compliance namespaces | An ApplicationSet deleted its Applications when the cluster left the placement | `preserveResourcesOnDeletion: true` (already set; BUILD.md Part 2 step 3) |
| A new hosted cluster's ACM add-ons crash-loop ("dial tcp 172.33.0.1:443: i/o timeout"), cluster-proxy down, every Argo app for it Unknown | An Egress NetworkPolicy isolated the namespace before the API and DNS rule arrived; the agents lost the API server and Argo could not finish | Fixed by the API and DNS egress rule in sync wave -1 (oac-apps [#282](https://github.com/CCI-MOC/oac-apps/pull/282)). To recover a cluster already in this state, render its policies and apply them with the cluster's own kubeconfig, then restart the add-on pods |
| `openshift-samples` Degraded: "global openshift image configuration prevents the creation of imagestreams" | The allowlist has no bare `quay.io`, which the samples operator wants when `samplesRegistry` is empty | `imageConfig.samplesRegistry: registry.redhat.io` (already set) |
| A hosted cluster's audit collectors log "certificate verify failed" | The hub's apps certificate changed, and the forwarder trusted only the hub's ingress CA: for a Let's Encrypt certificate, a chain without its root | `forwarder.remote.hubIngressCA: false` in the hosted-cluster values (already set) |
| multus crash-loops (`pthread_create failed`) on a many-core node, pods stuck in ContainerCreating | Each CNI plugin starts a thread per CPU inside multus's pod; about 70 pod network requests at once pass the pod limit of 4096 processes | `podPidsLimit` for the pool (6.1.3). kubelet resets the pod's `pids.max` at each container restart, so recovering a live node means rewriting it in a loop across multus's next restart |
| A node comes up with CRI-O failing after a reinstall | `nodeip-configuration` recorded the NIC's lease before `br-ex` took over and got another | On the node: remove `/run/nodeip-configuration/*`, restart `nodeip-configuration`, then `crio` and `kubelet`. A DHCP reservation per MAC prevents it |
| Scaling a NodePool to 0 hangs on the drain | Every node going at once, each holding the last copy of pods under a disruption budget, with `nodeDrainTimeout: 0` (wait forever) | Annotate the Machines with `machine.cluster.x-k8s.io/exclude-node-draining`. The Agents then reboot into discovery by themselves |
| A KubeVirt worker's new PVCs never attach: pods in ContainerCreating with FailedAttachVolume, the volumes at `MountedToPod` on the hypervisor, virt-handler logging "transient domains do not have any persistent config" | The VM's start outlasted virt-handler's SyncVMI timeout (VFIO pinning all its memory); on the retry virt-handler saw `Scheduled` + `Shutoff`, signalled deletion, and the launcher undefined the just-started domain. libvirt then refuses persistent hot-plug | 1Gi hugepages for the VM (§8). Until then, re-define the running domain from its live XML after each start; stop/start does not help |
| A hypervisor NodePool roll stalls: the node stays cordoned, CAPK logging "no matches for kind \"KubevirtMachine\"" | The VM is not live-migratable and its eviction strategy is `External`, so CAPK handles the eviction, and seems to send its update to the infra cluster, where the kind does not exist (MOC-issues #826, fixed) | `evictionStrategy: None` (§8), which is how a GPU VM cluster is built now. On a cluster still set to `External`, delete the VMI by hand, then clear the Machine's failure below |
| A KubeVirt cluster's console and apps unreachable after its VM was stopped: the LoadBalancer address not announced, its endpoint slice on the hypervisor `ready=false` | The stop left the CAPI Machine `Failed` ("VMI has reached a permanent finalized state"), which never clears; HCCO marks the endpoint not ready. Seen with `evictionStrategy: External`; with `None` the Machine stayed `Running` through a stop (2026-11-25) | Remove the Machine's `status.failureReason` and `failureMessage` on the hub. HCCO marks the endpoint ready within seconds; if the endpoint slice is missing, restart `hosted-cluster-config-operator` in that cluster's namespace |
| AIDE Failed after a roll, a reinstall or a new operator | Expected writes: the machine-config daemon's logs, `/etc/hosts` on a fresh node, LVM Storage's archive files, the GPU Operator's CRI-O drop-in, `policy.json` and `registries.conf` | Re-initialise the affected nodes, one at a time (4.10) |

```
oc patch machine.cluster.x-k8s.io -n clusters-<cluster> <machine> --subresource=status --type=json \
  -p '[{"op":"remove","path":"/status/failureReason"},{"op":"remove","path":"/status/failureMessage"}]'
```

---

## 10. How changes are made

- Every step above is a reviewed PR, except the by-hand items marked (the
  realm playbook, ACS init bundles, OIDC uploads, disk wipes).
- One commit per PR, whose message is the full description: why, and
  which clusters it changes and how. Open it with `gh pr create -f`.
- oac-apps needs two approvals. Name reviewers by topic: schwesig for
  observability, computate for Keycloak, OAuth and ACS, naved001 for the
  FlashBlade, memalhot for anything.
- A PR that rolls workers or reboots nodes says so, and is merged by hand
  at an agreed time, after the health check.
- **Hardware work on a hub node waits until any roll has finished,** and
  then goes one node at a time: pause the master pool, drain the node
  (`--force`, for the control-plane guard pods), do the work, uncordon,
  and wait for the hub's and the hosted clusters' etcd to be healthy
  before the next node. Two masters down at once takes the hub's API
  away, and the hosted clusters' etcd loses quorum with it.

---

## 11. Still open

- **TODO:** disk encryption on the hub is done with Tang, but a more
  reliable home for the Tang server, and a DNS name for it so a later
  move is only a key copy (MOC-issues #810). Every node needs Tang at
  every boot.
- **TODO:** a central audit and alert destination (P9).
- **TODO:** the ACS init bundle is still applied by hand for the hub and
  for every hosted cluster (4.11, 6.5); delivering it through the secret
  store is MOC-issues #830, and it can only be tested while onboarding a
  cluster Central has not seen before.
- **TODO:** NetworkPolicies for the hub's namespaces, for production
  (4.14).
- **TODO:** a decision on each operator without a FIPS claim; a hub runs
  several ([tests/operator-fips-inventory.md](tests/operator-fips-inventory.md)).
- **TODO:** a walk-through by someone who has not built a hub before, and
  fixes for whatever is unclear.
