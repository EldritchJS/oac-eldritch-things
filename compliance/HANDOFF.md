# Handoff: open work and next steps

*2026-11-06. Start here if you are picking this up. [README.md](README.md)
has the background and how it got here; this file is what is still open.*

Where it stands: jetty proved the stack can be made compliant, with GPUs
in containers and VMs. A FIPS test hub (nist-dev-infra) then built a
compliant workload cluster from oac-apps charts, and was retired on
2026-10-28. The compliance charts are going into CCI-MOC/oac-apps one PR at
a time. The next milestone is a replacement compliant hub, built from the
runbook by someone other than its author.

Older decision and prerequisite lists are still current and are not
repeated here: [BUILD.md](BUILD.md) P1 to P11 (what a compliant hub needs,
and from whom) and [PLAN.md](PLAN.md#open--what-remains-what-it-needs-and-from-whom)
(decisions, vendor questions, blocked items).

## Clusters today

| Cluster | What it is | State |
|---|---|---|
| jetty | Bare metal, FIPS on, OCP 4.22.14 | The test bed for everything below, and a KubeVirt hypervisor for oac-dev-infra (andalusia). Its internal registry is normally `Removed`; turn it on only to build a test image, then back off. No test leftovers as of 2026-11-06 |
| oac-dev-infra | OAC dev hub, FIPS **off** | Hosts andalusia. jetty is its hive spoke |
| andalusia | Hosted cluster on oac-dev-infra, one GPU VM worker on jetty | **Not FIPS** (the chart's default, and immutable). Fine for functional GPU tests; rebuild with `fips: true` before any compliance test |
| oac-dev-workload0 | Shared dev cluster, FIPS **off**, RHOAI 3.5 | Not ours; has the Service Mesh 3.5 operator for RHOAI |
| nist-dev-infra, nist-dev-workload0 | The FIPS test hub and its workload cluster | **Gone** (2026-10-28). Rebuild from [nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) |

Admin kubeconfigs are in AWS Secrets Manager. None is in this repo, and
none should be.

## Open pull requests

| PR | What | State (2026-11-06) | Next step |
|---|---|---|---|
| [oac-apps #197](https://github.com/CCI-MOC/oac-apps/pull/197) | Policy chart to keep a compliant hub compliant | Review required | Reviews |
| [oac-apps #198](https://github.com/CCI-MOC/oac-apps/pull/198) | File Integrity Operator chart | Review required | Reviews |
| [oac-apps #214](https://github.com/CCI-MOC/oac-apps/pull/214) | RHCOS hardening from git | Review required | Reviews |
| [oac-apps #216](https://github.com/CCI-MOC/oac-apps/pull/216) | Namespace NetworkPolicies and quotas | Changes requested; reworked as a library chart, as asked (2026-11-02) | Re-review; open question in the PR about namespaces no chart owns |
| [oac-apps #217](https://github.com/CCI-MOC/oac-apps/pull/217) | Nightly etcd backups of a hub | Review required | Reviews |
| [oac-apps #230](https://github.com/CCI-MOC/oac-apps/pull/230) | Project Grafana without the operator | Review required, checks pass | Reviews; then the follow-ups under Grafana below |
| [pure-cosi #13](https://github.com/CCI-MOC/pure-cosi/pull/13) | COSI driver on UBI, so TLS uses RHEL's FIPS OpenSSL | No reviews yet | Ask the pure-cosi maintainers |
| [pure-cosi #14](https://github.com/CCI-MOC/pure-cosi/pull/14) | FIPS builds of the COSI controller and sidecar | No reviews yet | As above |

Merged and in effect: #195 (the hub compliance marker), #196, #215, #218,
#208 (no GPUs for pods that did not ask), #212, #213, #219, #229 and the
others listed in [README.md](README.md). No ApplicationSet deploys the
compliance charts yet: once they merge, one PR wires them to #195's marker
(BUILD.md P1).

## Open work, by area

### 1. The replacement compliant hub

- **Next:** someone other than the author builds it on new nodes from
  [NEW-HUB-RUNBOOK.md](NEW-HUB-RUNBOOK.md), with etcd encryption from
  install. Neither runbook has been run end to end.
- **Needs first:** the charts merged and wired (above), and the
  prerequisites in BUILD.md P1 to P11.
- **Disk encryption (P10)** needs a tested method. TPM-based NBDE on the
  FC830s is [MOC-issues #672](https://github.com/CCI-MOC/MOC-issues/issues/672):
  estimated at 5 to 8 days for a test; **do not start until the issue's
  owner says to proceed** (it says to estimate only). The R440 workers
  have a TPM fault (#670). oac-infra supports only TPM (`tpmv2`); a Tang
  option is possible if TPM stays blocked.

### 2. Audit and alert destination (most urgent gap)

Audit records last hours on a node, and nothing alerts on a new scan
failure. Needs a destination from the security or SIEM owners. PLAN.md B1
and B2, BUILD.md P9.

### 3. Operators without a FIPS claim

[tests/operator-fips-inventory.md](tests/operator-fips-inventory.md) has the
full record, including check-payload scans of each one's images. `verify.sh
-t t18` fails on any new operator without the flag.

| Operator | Next step | With |
|---|---|---|
| Cluster Observability Operator | Its images are FIPS builds; the CSV flag is wrong. Get it corrected | COO team |
| Portworx | Images are not FIPS builds. Ask for FIPS builds of PX-CSI and the operator | Pure |
| NVIDIA GPU Operator | NVIDIA's FIPS driver images need NVIDIA AI Enterprise; a free NGC key cannot pull them | NVIDIA |
| Grafana operator | Replaced on compliant clusters by #230 (see Grafana below) | - |
| patch-operator | Check what it patches on a compliant cluster; likely replaceable by a chart | - |
| group-sync-operator | Controls access (800-171 3.1.1): a FIPS build or a replacement | - |

### 4. FIPS module validation

The nodes run OpenSSL FIPS provider `3.0.7-cda111b5812c30d4`, a security
build after the certified one (#4857). Confirm with the RHEL crypto team
that it is the submission in CMVP Comment Resolution. Re-review
[tests/fips-cmvp-certificates.md](tests/fips-cmvp-certificates.md) at every
upgrade.

### 5. Object storage (COSI)

All three parts now have FIPS builds, and on jetty (FIPS on) they ran a
full bucket lifecycle against the FlashBlade (inventory, "Object storage").

- Merge pure-cosi #13 and #14; then publish the images and point pure-cosi's
  manifests at the FIPS controller and sidecar.
- **The FlashBlade's identity is not checked**: its management certificate
  is the factory self-signed one. A FlashBlade admin installs one from MOC's
  CA with `10.3.11.50` in it; then pure-cosi verifies it (`verify_ssl`).
- Testing note: the FlashBlade management address is reachable only from
  pods on the storage network (NetworkAttachmentDefinition), not from the
  nodes or the default pod network.

### 6. Gateway TLS 1.3 (Connectivity Link)

OpenShift's built-in Gateway API istiod refuses TLS 1.3 under FIPS. A
second gateway from Service Mesh 3.5 (Istio 1.31, `fips-140-3`) does TLS 1.3
with FIPS ciphers only, and Connectivity Link policies work on it (tested
on jetty, inventory "Gateways").

- **Blocker:** its istiod does not start on FIPS nodes as shipped
  (`GODEBUG=fips140=only` conflicts with Red Hat Go's OpenSSL mode). The
  `GOLANG_FIPS=0` workaround uses Go's own FIPS module instead of RHEL's
  OpenSSL. Raise with the Service Mesh team, and ask whether running it
  beside the ingress operator's istiod is supported.
- It accepts only P-384 for key exchange; check the clients that will use
  it.
- Connectivity Link on jetty is deferred until the KubeVirt work settles.

### 7. Grafana without the operator

#230 adds `defaultGrafana.operator: false` to `user-projects`, tested on
jetty with RHEL's Grafana package
([GRAFANA-FIPS-IMAGE.md](GRAFANA-FIPS-IMAGE.md)). After it merges:

- Build the image once (the hub is suggested) and push it to a private
  registry. Which quay.io organization, and who holds its robot account,
  is undecided.
- Switch compliant clusters to the new mode, and stop deploying the
  `grafana-operator` chart there (today `all-managed-clusters` sends it to
  every cluster).
- Accept, or not, that editable projects start fresh: RHEL ships Grafana
  10.2, which cannot read an 11.x database.

### 8. GPUs and VMs

Passthrough, MIG and pod-in-VM are proven ([vms/gpu/README.md](vms/gpu/README.md)).
Pod-in-VM benchmarks used the AI UAT Harness (Ahmed Sanaullah).

- One tenant per GPU node until cross-tenant NVLink is answered.
- andalusia needs a FIPS rebuild before compliance testing (above).
- RDMA on jetty: not pursued for now (only 2 of 6 ConnectX ports linked, no
  SR-IOV or network operator).

### 9. Smaller recorded gaps

- The shared kubeadmin login: an SSO admin group first, then remove it.
- NetworkPolicies for the hub's own namespaces, for production: measure
  each namespace's traffic first ([nist-dev-infra/RUNBOOK.md](nist-dev-infra/RUNBOOK.md) §7).
- The cluster-wide proxy: a POA&M item, none planned.
- Hosted cluster etcd on FlashBlade NFS: accepted for the test only;
  production gets local disks.
- Storage for workload clusters (Portworx and NFS over TLS): on
  nist-dev-workload0 this needed a fix to the Portworx chart's NNCP (it
  would retake the default route), an opt-out of object-storage-proxy, and
  a pod address range from the network admins.

## Questions waiting on someone

New since PLAN.md's vendor table:

| Ask | Of |
|---|---|
| Correct COO's `fips-compliant` flag; is COO supported on FIPS clusters? | COO team |
| Is provider `3.0.7-cda111b5812c30d4` the CMVP submission in Comment Resolution? | RHEL crypto team |
| Fix istiod with `fips-140-3` on FIPS nodes; is a second Service Mesh beside the ingress operator's supported? | Service Mesh team |
| FIPS builds of PX-CSI and the Portworx operator | Pure |
| NVIDIA AI Enterprise access for the FIPS driver images | NVIDIA |
| A FlashBlade management certificate from MOC's CA | FlashBlade admins |
| A private quay.io organization for the Grafana image | Registry owner |
| Go-ahead for the NBDE test (#672) | The issue's owner |

## Recurring work

- Run `tests/verify.sh` before and after every change
  ([tests/README.md](tests/README.md)).
- At every upgrade: re-review the FIPS certificate record and
  [PRIVILEGED-WORKLOADS.md](PRIVILEGED-WORKLOADS.md); re-check disabled or
  exempted rules after operator upgrades.
- Rescan operator images with `tests/fips-image-scan.sh` when an operator
  changes. Run it on a cluster, never on a laptop.

## Things that will catch you

- **Building images on jetty:** the registry is `Removed`. Set it to
  `Managed` with `emptyDir`, wait for the openshift-apiserver rollout, and
  create image streams only after that (otherwise builds fail with
  `InvalidOutputReference`). Set it back to `Removed` afterwards.
- **Go builds on many-core nodes** hit the build pod's process limit; cap
  them with `GOFLAGS=-p=4` and `GOMAXPROCS=4`.
- **OLM reverts `oc rollout restart`** on operator-owned deployments; delete
  the pod instead.
- **Before importing a cluster to a hub,** check every placement that would
  select it, not just the intended one. jetty's first import pulled in
  12 components with prune.
- **Under FIPS:** sshd refuses ed25519 keys (use ECDSA); Grafana 10's
  default POST queries are refused by the monitoring tenancy port (use GET);
  PyPI's `cryptography` wheel bundles its own non-FIPS OpenSSL (build it
  from source on UBI).
- **COSI CRDs applied by hand** need the `api-approved.kubernetes.io`
  annotation that upstream's kustomization adds.
- **A Service Mesh test leaves CRDs behind:** removing the operator leaves
  its `sailoperator.io` CRDs, `trafficextensions.extensions.istio.io` and
  the `istio` and `istio-remote` GatewayClasses. The other 14 `istio.io`
  CRDs belong to the ingress operator; leave them.

## Who to ask

| Topic | Who |
|---|---|
| oac-apps generally | tzumainn |
| oac-apps repo layout, compliance chart upstreaming | larsks |
| Observability: Prometheus, COO, Loki, Grafana | schwesig |
| Keycloak, OIDC, MOC SSO | computate |
| FlashBlade, Portworx, pure-cosi | naved001, DanNiESh |
| AI UAT Harness | Ahmed Sanaullah |
| NBDE scope (#672) | hpdempsey |
