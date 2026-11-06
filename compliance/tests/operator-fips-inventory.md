# Operator FIPS inventory

Which installed operators claim FIPS support, and what to do about the ones
that don't. Companion to [fips-cmvp-certificates.md](fips-cmvp-certificates.md),
which covers the crypto modules themselves.

**In short (2026-11-05):** 6 of the 21 operators installed on jetty and
oac-dev-infra are not flagged `fips-compliant: true`: Cluster Observability,
Grafana, Portworx, NVIDIA GPU, patch-operator and group-sync-operator ([the
table](#results-2026-11-05)). Only Cluster Observability's images pass
`check-payload` ([the scans](#what-the-images-contain-2026-11-05)). None has
a recorded decision yet ([the options](#deciding-each-one)).

## Why this exists

The hardening work covers node and platform settings: FIPS mode on the nodes
and the Compliance Operator's `ocp4-moderate` and `rhcos4-moderate` scans. Those
scans do not look at which operators are installed. Nothing in the process
checked add-on operators, so this inventory does.

## What the flag means

Operators declare `features.operators.openshift.io/fips-compliant` in their
CSV. `true` is the vendor's claim that the operator runs in FIPS mode using
validated crypto. `false` or no annotation means the vendor makes no claim. It
does not prove the operator uses unapproved crypto, but an assessor goes by the
claim, so every operator without `true` needs a recorded decision.

Check a cluster (read-only):

```
oc get csv -A -o json | jq -r '.items[]
  | select(.metadata.labels["olm.copiedFrom"] == null)
  | [(.metadata.annotations["features.operators.openshift.io/fips-compliant"] // "none"),
     .metadata.name, .spec.provider.name] | @tsv' | sort -u
```

## Results (2026-11-05)

Checked: jetty and the oac-dev-infra hub. Not checked: oac-prod-infra, the
hosted clusters (oac-dev-workload0/1/2, andalusia). nist-dev-infra is gone.

**15 of the 21 operators installed on the two clusters are flagged
`fips-compliant: true`**, all from Red Hat:

| Operator | Version | jetty | oac-dev-infra | What it does |
|---|---|---|---|---|
| Advanced Cluster Management | 2.17.3 | - | true | Manages the hub's clusters and policies |
| multicluster engine | 2.17.3 | - | true | Hosted clusters (HyperShift) |
| OpenShift GitOps | 1.22.3 | - | true | Argo CD, which applies oac-apps |
| OpenShift Virtualization | 4.22.12 | true | - | KubeVirt VMs, including GPU VMs |
| cert-manager | 1.20.1 | true | true | Certificates |
| External Secrets | 1.2.1 | true | true | Secrets from AWS Secrets Manager |
| external-dns | 1.3.12 | - | true | DNS records |
| MetalLB | 4.22.0 | - | true | Load balancer addresses |
| NMState | 4.22.0 | true | true | Node networking |
| LVM Storage | 4.21.1 | - | true | Local disks |
| Node Feature Discovery | 4.22.0 | true | - | Node labels, including GPUs |
| Connectivity Link (rhcl) | 1.4.3 | true | - | API gateway policies |
| Authorino | 1.4.3 | true | - | Gateway authentication |
| Limitador | 1.4.2 | true | - | Gateway rate limits |
| DNS operator (Connectivity Link) | 1.4.2 | true | - | Gateway DNS |

The compliance tooling itself is flagged too. These were not installed on
either cluster on 2026-11-05 (they ran on nist-dev-infra), so this is the
flag in jetty's catalog, not an installed CSV:

| Operator | Version | Flag |
|---|---|---|
| Compliance Operator | 1.10.0 | true |
| File Integrity Operator | 1.5.0 | true |
| Advanced Cluster Security | 4.11.7 | true |
| Logging (cluster-logging) | 6.7.0 | true |
| Loki Operator (Red Hat's) | 6.7.0 | true |

Not flagged `true` (6 of 21):

| Operator | Vendor | jetty | oac-dev-infra | Installed by | What it touches |
|---|---|---|---|---|---|
| Cluster Observability Operator 1.5.4 | Red Hat | false | false | oac-apps, every hub and managed cluster | Perses dashboards in the console; reads metrics |
| Grafana operator 5.25.0 | Grafana Labs (community) | none | - | oac-apps, every managed cluster | Per-project Grafana; pushes each project's data source token over plain HTTP ([GRAFANA-FIPS-IMAGE.md](../GRAFANA-FIPS-IMAGE.md)) |
| Portworx operator 26.4.0 | Portworx | false | false | oac-apps, hubs and Portworx clusters | Storage driver for FlashBlade volumes; holds the FlashBlade API token |
| NVIDIA GPU Operator 26.7.2 | NVIDIA | false | - | oac-apps, GPU clusters | GPU drivers and device plugins; privileged on GPU nodes |
| patch-operator 0.1.11 | Red Hat Community of Practice | none | none | oac-apps, hubs and hypervisor clusters | Patches cluster resources; broad API write access |
| group-sync-operator 0.1.2 | Red Hat Community of Practice | - | none | oac-apps (`github-group-sync`) | Syncs groups from GitHub, which decide who can access what |

`packageserver` also has no flag. It is part of OLM, shipped with OpenShift,
and covered by the platform.

Catalog matters: jetty's catalog also offers a community `loki-operator`
(v0.12.0, flag false) beside Red Hat's (6.5 to 6.7, flag true).

## Deciding each one

For each operator without `true`, one of:

1. **Remove it** from compliant clusters.
2. **Replace it** with a flagged equivalent.
3. **Keep it**, with a written justification answering two questions: does it
   handle CUI or PHI, and does its crypto protect that data? Kept operators
   become POA&M items.

Starting points, not yet decided:

| Operator | Likely route |
|---|---|
| Cluster Observability Operator | Its images pass check-payload, so keep it, citing the scan; get the CSV flag corrected with the COO team |
| Grafana operator | Remove on compliant clusters; Grafana from provisioning files, built and tested in oac-apps #230 ([GRAFANA-FIPS-IMAGE.md](../GRAFANA-FIPS-IMAGE.md)) |
| Portworx operator | Ask the vendor. It is in the storage path, so it is the hardest to justify keeping and the hardest to remove |
| NVIDIA GPU Operator | Ask NVIDIA. GPUs are why the clusters exist, so this is a justification, not a removal |
| patch-operator | Check what it patches on a compliant cluster; it may be replaceable by Argo CD or a chart |
| group-sync-operator | Group sync controls access (800-171 3.1.1), so it needs either a FIPS answer or a replacement |

## What the vendors say (2026-11-05)

From public documentation and the catalogs on jetty. Vendor answers, when they
come, replace this.

### Cluster Observability Operator (Red Hat)

- COO 1.5's release notes list a fix: the build "enables the strict FIPS
  runtime and CGO compilation across all Operator components". check-payload
  confirms it: the six COO 1.5.5 images running on jetty pass (see "What the
  images contain").
- The CSV still says `fips-compliant: false` on every channel (1.5.4 on
  `stable` and `fast`). Upstream's CSV (rhobs/observability-operator) has no
  FIPS annotation at all, so the `false` is set in Red Hat's build.
- Other Red Hat operators have switched the flag to `true` after the same
  build change, so it may lag. Unconfirmed.
- **Ask the COO team:** is COO supported on FIPS clusters, and when will
  the CSV say so? Related: MOC-issues #684 (observability components and FIPS).

### NVIDIA GPU Operator

- NVIDIA ships "government ready" STIG and FIPS builds of the GPU Operator's
  images, selected in the ClusterPolicy (for example the driver image
  `gpu-driver-stig-fips`, with an RHCOS variant). Validated on OpenShift 4.19
  in FIPS mode. The images use FIPS-enabled OpenSSL; NVIDIA calls them
  suitable for FedRAMP High.
- It is the same operator, so the CSV stays `fips-compliant: false` on every
  channel (v25.3 to v26.7).
- Needs an **NVIDIA AI Enterprise** subscription and an NGC API key. It is
  licensed per GPU: list price $4,500 per GPU per year, education rate $1,125.
  The same subscription is the only way to license compute vGPU (C-Series),
  which is licensed per vGPU. H100 PCIe and NVL cards include five years;
  our H100 SXM5 cards do not.
- Not every component has a government-ready image (NVIDIA names GDS,
  Confidential Computing Manager and GDRCopy as missing). No CMVP certificate
  is named.
- **Ask NVIDIA:** are the VM passthrough components (`vfio-manager`, sandbox
  device plugin) covered; which FIPS module and certificate the images use;
  does MOC have AI Enterprise, and how do GPU and vGPU licenses combine.

### Portworx (Pure Storage, Everpure)

- What we run is **PX-CSI 26.2.0**, installed by the Portworx operator
  26.4.0 (CSV `fips-compliant: false`). Images: the operator from
  `registry.connect.redhat.com`; driver and attacher from
  `docker.io/portworx`; CSI sidecars from `registry.k8s.io` (upstream builds,
  not FIPS).
- No public FIPS statement, image or certificate for PX-CSI or its operator.
- The FlashBlade has CMVP certificate **#5000**, "FlashBlade Data Encryption
  Module", FIPS 140-3, active, validated 2025-04-17, sunset 2027-04-16,
  level 1. It names hardware and firmware versions, so it most likely covers
  data at rest, not the network protocols. The 140-2 certificate #3345 is
  historical. FlashArray's module is #4937.
- **Also a registry problem:** with `platform-hardening`'s allowed registries
  on, the `docker.io` and `registry.k8s.io` images would be refused, so PX-CSI
  would not install on a compliant cluster as it stands.
- **Ask Pure:** are PX-CSI and its operator built with validated crypto and
  supported on FIPS OpenShift, and will the CSV say so; can it use Red Hat's
  FIPS-built CSI sidecars and pull everything from
  `registry.connect.redhat.com`; which module does the FlashBlade use for NFS
  over TLS and for its management API, and is that #5000. The NFS question
  is the FlashBlade's end of the encryption-in-transit path
  ([fips-cmvp-certificates.md](fips-cmvp-certificates.md) covers the nodes'
  end).

## What the images contain (2026-11-05)

The flag is a claim; Red Hat's [check-payload](https://github.com/openshift/check-payload)
checks the binaries themselves: whether each Go binary is built to use a FIPS
module, and whether the image's OpenSSL is the certified one. Red Hat runs it
on OpenShift's own release images.

Rerun with [fips-image-scan.sh](fips-image-scan.sh), which scans in a
throwaway pod (restricted-v2, no pull secret) and deletes its project after.

**Control first** (`./fips-image-scan.sh --control`): one small Go program
built three ways.

| Build | Result |
|---|---|
| Red Hat's Go | Pass |
| Upstream Go | Fail: not CGO_ENABLED |
| Upstream Go with Go's FIPS module on (`GOFIPS140=v1.0.0`) | Pass |

So the scanner tells the builds apart, and for an upstream Go project the fix
is one build setting.

**Results** for the public images of the unflagged operators, as running on
jetty and the hub. None passed:

| Scanner's reason | What it means | Images |
|---|---|---|
| Not CGO_ENABLED | Upstream Go, no FIPS crypto | Portworx `px-pure-csi-driver` and `px-pure-csi-attacher` 26.2.0; `registry.k8s.io` csi-provisioner and csi-node-driver-registrar; NVIDIA `gpu-operator` v26.7.2 (also its validator and tools); `grafana-operator` |
| Does not set `GODEBUG fips140` | Newer Go; the FIPS module is there but not turned on | NVIDIA `container-toolkit`, `k8s-device-plugin`, `dcgm-exporter`, `k8s-mig-manager`; `group-sync-operator` |
| Missing required symbols | Older Go, no FIPS support | Grafana 11.3.0; NVIDIA `kubevirt-gpu-device-plugin` (GPUs to VMs); `patch-operator` |
| No FIPS-certified OpenSSL in the image | The Go binary passes; the base image's OpenSSL is not the certified one | `ghcr.io/cci-moc/pure-cosi` v0.1.0 (MOC's own, on the hub) |

What follows:

- The unflagged operators are not FIPS builds (except COO, below):
  evidence, not only a missing flag.
- `pure-cosi` is ours to fix: build it on a UBI base image with RHEL's
  OpenSSL.
- For Pure, the question becomes concrete: build PX-CSI with Go's FIPS
  module (or Red Hat's Go), and use Red Hat's CSI sidecars.

**Second scan, with jetty's pull secret** (`FIPS_SCAN_PULL_SECRET=1`,
2026-11-05), of the images running on jetty:

| Image | Result |
|---|---|
| OpenShift platform image (the DNS operator from jetty's release), as a positive control | Pass |
| COO 1.5.5: `cluster-observability-rhel9-operator`, `obo-prometheus-rhel9-operator`, `obo-prometheus-operator-admission-webhook-rhel9`, `perses-rhel9-operator`, `perses-rhel9`, `monitoring-console-plugin-rhel9` | **All pass** |
| Portworx `openstorage-operator` 26.4.0 (`/operator`, `/dryrun`, `/preflight`) | Fail: not CGO_ENABLED |

So COO is a FIPS build, as its 1.5 release notes say, and the `false` flag
is wrong metadata: what is left is correcting the CSV. The
Portworx operator is upstream Go like the rest of Portworx.

Still not scanned: NVIDIA's government-ready images (for example
`nvcr.io/nvidia/gpu-driver-stig-fips`). A free NGC key is accepted by
nvcr.io but granted no pull on them (checked 2026-11-05 through the
registry's token service); they need an NGC organization with NVIDIA AI
Enterprise. `FIPS_SCAN_NGC_KEY_FILE` scans them once a key from such an
organization is available.

### Object storage (COSI), on the hub

COSI is three parts, each with its own crypto path. Scanned 2026-11-05:

| Part | Image | Talks to | check-payload |
|---|---|---|---|
| COSI controller | `gcr.io/k8s-staging-sig-storage/objectstorage-controller` (upstream pre-release) | Kubernetes API (TLS) | Fail: not CGO_ENABLED |
| Sidecar, in each driver pod | `registry.k8s.io/sig-storage/objectstorage-sidecar:v0.2.2` | Kubernetes API (TLS); writes the S3 keys to Secrets | Fail: not CGO_ENABLED |
| Driver (MOC's own) | `ghcr.io/cci-moc/pure-cosi:v0.1.0` | FlashBlade management API (TLS) | Fail: no FIPS-certified OpenSSL |
| Driver, rebuilt on UBI (branch `fips-ubi-base`) | built on jetty, not published | same | **Pass** |

The rebuilt driver passed an end-to-end test on jetty (FIPS mode on), with
the hub's driver config, from a pod on the storage network (the only path
to the FlashBlade's management address): bucket create, grant, revoke and
delete worked; Python's `ssl` and `cryptography` both ran RHEL's OpenSSL
3.5.8 with FIPS on; every connection used TLS 1.3 with AES-256-GCM, and
ChaCha20 was refused.

Still open:

- **The FlashBlade's identity is not checked.** py-pure-client defaults to
  `verify_ssl=False` and pure-cosi does not set it; the FlashBlade's
  management certificate is its factory self-signed one (CN Pure Storage, no
  SANs). The traffic is encrypted, but the API token would go to anyone who
  could impersonate the address. Fix: a management certificate from MOC's CA
  with `10.3.11.50` in it, then pure-cosi verifies against that CA. Applies
  to v0.1.0 too.
- **The controller and sidecar are upstream Go without FIPS.** Red Hat does
  not ship COSI, and the controller is a staging build from a registry that
  compliant clusters' `allowedRegistries` would block. We now build both
  from upstream v0.2.2 with Red Hat's Go (`CGO_ENABLED=1`,
  `strictfipsruntime`) in the pure-cosi repo (CCI-MOC/pure-cosi#14). Both
  pass check-payload. On 2026-11-05, on jetty, all three FIPS builds ran a
  full bucket lifecycle against the FlashBlade (BucketClaim, BucketAccess,
  key Secret, then revoke and bucket deletion), each with RHEL's OpenSSL
  FIPS provider loaded. Left: publish the images and point pure-cosi's
  manifests at them.

### Gateways: Service Mesh 3.5 beside the built-in Istio, on jetty

OpenShift's built-in Gateway API istiod (1.28.5, run by the ingress
operator, `COMPLIANCE_POLICY=fips-140-2`) refuses TLS 1.3, and its version
cannot be changed. Tested 2026-11-05 on jetty (FIPS mode on): Service Mesh
3.5 (`servicemeshoperator3`, flagged fips-compliant) running a second
istiod, Istio 1.31.1 with `fips-140-3`, in its own namespace and
GatewayClass (`istio`). Everything was removed afterwards.

TLS offered by a non-FIPS client (OpenSSL 3.5.9), so only the gateway's
policy decides:

| Client offered | Service Mesh 3.5 gateway (`fips-140-3`) | Built-in gateway (`fips-140-2`) |
|---|---|---|
| TLS 1.3, AES-256-GCM or AES-128-GCM | Accepted | **Refused** |
| TLS 1.2, ECDHE AES-128-GCM | Accepted | Accepted |
| ChaCha20 (1.3 or 1.2) | Refused | Refused |
| X25519 key exchange | Refused | Refused |
| P-256 key exchange (TLS 1.3) | Refused; only P-384 | n/a |
| TLS 1.1 | Refused | Refused |

- Both gateways' proxies (`istio-proxyv2-rhel9`) load RHEL's OpenSSL FIPS
  provider.
- Connectivity Link works on the new class: a RateLimitPolicy on the test
  Gateway was Accepted and Enforced (3 requests 200, then 429).
- The ingress operator, its istiod and Kuadrant stayed healthy; Gateway
  API v1.4.1 (owned by the ingress operator) caused no problems.

Open:

- **istiod crashes on FIPS nodes with `fips-140-3`** (to raise with the
  Service Mesh team).
  Service Mesh sets `GODEBUG=fips140=only`, and Red Hat's Go panics at
  start: "GOLANG_FIPS and GODEBUG=fips140 are mutually exclusive". The
  operator reapplies `GODEBUG` if overridden. Setting `GOLANG_FIPS=0` lets
  it start, but istiod then uses Go's own FIPS module instead of RHEL's
  OpenSSL (libcrypto not loaded); that module's CMVP status is not
  checked. istiod signs the mesh's certificates, so this matters.
- **P-384 only.** Clients that offer just X25519 and P-256 cannot connect.
  Browsers and curl offer P-384; check the clients that will use it.
- **Support.** No Red Hat statement found that Service Mesh 3 beside the
  ingress operator's istiod is supported; ask.

## Checked by T-18

`verify.sh -t t18` lists every operator without `fips-compliant: true`. An
operator listed in [operator-fips-accepted.txt](operator-fips-accepted.txt) is
a WARN; any other FAILs, so a new unflagged operator is caught instead of
slipping in. The six above are listed as "under review" until each has a
decision. On 2026-11-05 it gave 5 WARNs on jetty and 4 on the oac-dev-infra
hub, no FAILs; dropping Portworx from the list turned it into a FAIL.
