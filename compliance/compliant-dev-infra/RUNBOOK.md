# Building compliant-dev-infra and its workload cluster

*Runbook, draft (2026-11-17). Not yet run. Open items are marked
**TODO**.*

compliant-dev-infra is a new compliant hub, with R440s as its control
plane and jetty's FC430s as its workers, built from the
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
| The install | CCI-MOC/oac-infra `hub-images`: the pull secret and SSH key for `credentials/compliant-dev-infra/` (not in git) |
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

**Still to decide before the PRs:**

- **Hardware:** whether three R440s are free for the control plane (2.1);
  tzumainn is asking in `moc_2_0`.
- **FlashBlade realms:** each realm is named after its cluster
  (everpure-moc `ansible/group_vars/all/realms.yaml`): `nist-dev-infra`
  (10.9.7.10, VLAN 2317) and `nist-dev-workload0` (10.9.12.10, VLAN 2318),
  with S3 endpoints built from the names. Either keep them, which breaks
  that convention, or add `compliant-dev-infra` and
  `compliant-dev-workload0` on the same VLANs and subnets: an everpure-moc
  PR, new CA-marked realm certificates from the FlashBlade admins, and new
  S3 endpoint records. Going with new realms: MOC-issues #789 (naved001).

**Kept, as they are:**

- The FlashBlade realm `nist-dev-infra`, its CA-marked certificate
  (`nist-dev-infra::realm-cert`) and its export policies.
- Route 53 zones `nist.int.massopen.cloud` and `hcp.nist.int.massopen.cloud`.
- The `moc-aws-cluster-operators` memberships.
- The cluster and storage networks and their firewall rules.

**Copied under the new name** (one PR per repo; nist-dev-infra's entries
stay where they are):

| Repo or store | From | To |
|---|---|---|
| oac-apps | `hosted-clusters/nist-dev-infra/`, `values/nist-dev-infra/`, `apps/nist-dev-infra/`, the pure-cosi overlay | `compliant-dev-infra` paths, with the name and domain changed inside them |
| oac-infra | `hub-images/group_vars/nist-dev-infra/`, the `hub-images/inventory.yml` entry, `nist_dev_infra` in `infra/inventory/00hosts.yaml` | `compliant-dev-infra` (2.1, 2.2) |
| moc-aws | The OIDC provider and roles (`eso-*`, `cert-manager-*`), ESO secret prefixes, external-dns user, the `s3.nist-dev-infra` record | The same for `compliant-dev-infra`. The issuer URL changes with the name, so these are new, not reused |
| moc-aws (DNS) | api, api-int, `*.apps` records for nist-dev-infra | The same names for `compliant-dev-infra`, same VIPs |
| moc-keycloak | `nist-dev-infra` client (#55) | A `compliant-dev-infra` client; its redirect URI has the new domain |
| Secrets Manager | `cluster/nist-dev-infra/{sshkey,portworx,pure-cosi,nfs-tls-ca,keycloak-oidc}` | `cluster/compliant-dev-infra/...`; `keycloak-oidc` gets the new client's secret |

**Rebuilt:** the cluster, its kubeadmin kubeconfig, its OIDC signing keys,
the ACS init bundles, and the COSI buckets for Loki and ACM observability.

**TODO:** confirm the kept list with the owners of each (moc-aws,
FlashBlade, Keycloak) before the PRs.

---

## 1. Before the install

Nothing to tear down: nist-dev-infra's nodes were released on 2026-10-28,
and compliant-dev-infra uses different hardware. jetty's two GPU nodes,
which later become the hypervisor cluster's workers, are wiped before
reuse (800-171 3.8.3).

---

## 2. The hub

Upstream: oac-apps `docs/infra-cluster-deployment.md`. Why each step:
[BUILD.md](../BUILD.md) Part 1.

### 2.1 Hardware and networks

**The standard layout, not nist-dev-infra's compact one:** three R440s as
control plane, and jetty's three Dell FC430s (2 x Xeon E5-2640 v4, 40
threads, 126 GiB, 2 x 186 GB SSD) as workers (oac-apps
`docs/infra-cluster-deployment.md`, "Infrastructure Configuration").
nist-dev-infra ran on three compact FC830s at 176 threads each, whose
etcd crashed under FIPS TLS load (BUILD.md Part 1 step 1). No R440 is
used as compute. There are eight R440s, `MOC-R6PCC06U14` to `U21`;
**whether three are free is not known yet** (2026-11-17): tzumainn is
asking in `moc_2_0`.

**The FC430s are jetty's control plane today,** so jetty (and andalusia,
whose VMs run on it) goes out of service when they are taken for this
hub, before the hub is installed, not only when the GPU nodes move (#787).
Each FC430's second SSD, jetty's etcd disk today, becomes the worker's LVM
Storage disk for the hosted clusters' etcd: small, but enough for the two
hosted clusters this hub carries.

Each step below follows tzumainn's doc, with what nist-dev-infra already
has and what is new for compliant-dev-infra.

1. **Networks.** nist-dev-infra's cluster network (`10.20.18.0/23`), its
   storage network and their firewall rules exist. **Attach the three
   R440s and the three FC430s** to both; the FC430s move off jetty's
   network (`docs/hardware-inventory-and-configuration.md`, "Network
   configuration"), each with its storage port untagged, with DHCP, unless
   they are already on them.

2. **oac-infra `infra/inventory/00hosts.yaml`.** Add a
   `compliant_dev_infra` group with the three R440s as controllers and the
   three FC430s as workers (copy the shape of `oac_prod_infra`). Leave
   `nist_dev_infra` as it is. Point the R440s at `discovery-r440.iso` and
   the FC430s at `discovery.iso` for now.

3. **Node details.** Boot each R440 from
   `http://10.2.0.82/boot/discovery-r440.iso`, not the generic
   `discovery.iso` in tzumainn's doc, which does not work on R440s; boot
   the FC430s from `discovery.iso`. Read
   `http://<node-ip-on-cluster-network>/index.txt`. Record each node's MAC
   on the cluster network and the install disk's serial; for the R440s, a
   second disk's WWN for etcd; for the FC430s, the second SSD, for LVM
   Storage.

   **Also note the thread count.** If the control-plane nodes have much
   more than about 40 threads, 2.3 applies.

4. **Wipe them** (800-171 3.8.3): the FC430s certainly, as jetty's
   former control plane, and the R440s if they have been used before. The
   install rewrites the install disk; the etcd disks and the FC430s'
   second SSDs need wiping too.

### 2.2 Install

1. **oac-infra `hub-images/group_vars/compliant-dev-infra/vars.yml`, in one
   PR,** copied from nist-dev-infra's, with an entry for `compliant-dev-infra`
   in `hub-images/inventory.yml`:
   - `master1` to `master3`: the R440s' hostnames, IPs, MACs,
     `install_drive_serial` and `etcd_drive_wwn` from 2.1. **Quote the
     WWNs:** YAML reads an unquoted `0x...` as a number, and Jinja writes
     it back in decimal.
   - Add a `workers:` list for the three FC430s (hostname, ip, mac,
     install_drive_serial), as in `group_vars/examples/vars.yaml.example`.
   - `diskencryption_mode: ""`, not `tpmv2`. The R440s' TPMs are faulty
     (MOC-issues #670), and on the FC830s `tpmv2` with no working TPM
     installed unencrypted without saying so. Disk encryption is a
     recorded exception on this hub (E6, MOC-issues #672).
   - `cluster_domain_name: compliant-dev-infra`.
   - Keep: `base_domain`, the networks,
     `rendezvous_ip` (make it one of the new control-plane IPs), `api_ip`,
     `ingress_ip`, `fips_enabled: true`. Check `ssh_public_key` is ECDSA
     or RSA (FIPS rejects Ed25519).

   **Before the install** (section 0): `cluster/compliant-dev-infra/sshkey`
   in Secrets Manager (copy nist-dev-infra's); the api, api-int and
   `*.apps` records for `compliant-dev-infra` in `nist.int.massopen.cloud`,
   on the same VIPs. Put the SSH key in `credentials/compliant-dev-infra/` and
   the pull secret in `group_vars/compliant-dev-infra/secrets.yml` (neither in
   git).

2. **Make the boot media:**

   ```
   cd ~/oat/oac-infra/hub-images
   ansible-playbook -i inventory.yml create_agent_install_media.yaml -e cluster_name=compliant-dev-infra
   ```

   **Expect:** `ISO generated successfully at: output/compliant-dev-infra/work/agent.x86_64.iso`,
   and the kubeadmin password printed.

3. **Boot the nodes from it.** Copy the ISO to the bastion as
   `/srv/boot/compliant-dev-infra-agent.x86_64.iso`, point both groups in
   `00hosts.yaml` at `http://10.2.0.82/boot/compliant-dev-infra-agent.x86_64.iso`,
   and boot all six (`docs/hardware-inventory-and-configuration.md`, "Boot
   configuration"). Then wait:

   ```
   openshift-install-fips agent wait-for install-complete --dir output/compliant-dev-infra/work
   ```

   **Expect:** `Install complete!` in about an hour.

4. **Store the kubeconfig**, overwriting the old one, then copy it to
   `$HUB`. Never in a repo:

   ```
   aws --profile $SM secretsmanager put-secret-value --secret-id cluster/compliant-dev-infra/kubeadmin \
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

Answer yes when it asks to set the issuer. **Check:**

```
KUBECONFIG=$HUB oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
# https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/compliant-dev-infra
curl -s https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/compliant-dev-infra/.well-known/openid-configuration | jq .issuer
# the same URL
KUBECONFIG=$HUB oc get co kube-apiserver                     # Available, not Progressing (about 20 minutes)
```

### 2.5 Bootstrap ArgoCD

```
cd ~/oat/oac-apps
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

### 2.8 The compliance stages, from the fork

Each stage file updates the same ApplicationSet, `nist-compliance-test`,
which reads the fork's `nist-dev-infra-test` branch. Apply them in order,
waiting for each to settle:

```
export KUBECONFIG=$HUB
oc apply -f $RB/stage-a.yaml
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
oc apply -f $RB/stage-b.yaml
oc -n stackrox rollout status deploy/central --timeout=30m
```

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
oc apply -f $RB/stage-c.yaml
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
oc apply -f $RB/stage-e.yaml
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

Two FC430s, `moc-r4pac10u37-s1b` and `-s1d`, booted from **this hub's**
discovery ISO:

```
export KUBECONFIG=$HUB
oc get infraenv -n hardware-inventory hardware-inventory -o jsonpath='{.status.isoDownloadURL}{"\n"}'
```

Boot each from that ISO (BMC virtual media). When they appear, approve
and label them:

```
oc -n hardware-inventory get agents                        # both listed
for a in $(oc -n hardware-inventory get agents -o name); do
  h=$(oc -n hardware-inventory get $a -o jsonpath='{.spec.hostname}')
  case $h in <the two SD665-N V3s' hostnames>)   # TODO: nist-dev-workload0 used two FC430s here
    oc -n hardware-inventory patch $a --type merge -p '{"spec":{"approved":true}}'
    oc -n hardware-inventory label $a --overwrite massopen.cloud/cluster=compliant-dev-workload0 openstack/resource-class=<TODO: SD665 class>
  esac
done
```

The storage NIC's `never-default` setting is already in the NodePool
values (oac-apps [#166](https://github.com/CCI-MOC/oac-apps/pull/166)):
without it a reboot can put `br-ex` on the wrong NIC.

### 4.2 The cluster

Put the cluster back by reverting the teardown PR (1.1) in a new PR:

```
git revert <merge commit from 1.1>
```

Merge it. The `hosted-clusters` ApplicationSet creates the HostedCluster
and NodePool, and the hub's admission policy checks them. **Check:**

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

2. **SSO** needs nothing: the Keycloak client and secret are kept, and
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
oc apply -f $RB/workload-stage-a.yaml        # Compliance Operator (hosted tailoring), FIO, the notice
oc -n openshift-gitops get applications.argoproj.io | grep compliant-dev-workload0-nist-test   # Synced, Healthy
```

**Stage B**, the ACS SecuredCluster. Its init bundle comes from the
hub's Central and goes to the cluster:

```
oc apply -f $RB/workload-stage-b.yaml
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
oc apply -f $RB/workload-stage-c.yaml
oc -n openshift-gitops get applications.argoproj.io | grep compliant-dev-workload0   # all still Synced
```

If an app goes Unknown, a policy may have cut the cluster off from the
hub. Argo cannot reach it to fix it, so delete that policy with
`KUBECONFIG=$W0`.

**Stage D**, audit forwarding to the hub's Loki:

```
oc apply -f $RB/workload-stage-d.yaml
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
- **TODO:** the stages come from the fork's `nist-dev-infra-test` branch.
  Moving the compliance charts to CCI-MOC/oac-apps main is a separate
  piece of work; until then the fork is part of the build.
- **TODO:** a home for hosted etcd that is not NFS.
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
