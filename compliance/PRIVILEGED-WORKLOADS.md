# Privileged workloads — documented exceptions

*Measured 2026-10-09 on jetty (OpenShift 4.22.16). Written to be pasted into
the SSP as the exception register for 800-53 AC-6 / CM-7 (least privilege,
least functionality) and the HIPAA 164.308(a)(3)/(a)(4) findings ACS raises.*

Every workload below runs with privileges the hardening baseline would
otherwise forbid: a privileged container, a host namespace (network, PID,
IPC), a host filesystem mount, or cluster-wide RBAC. None can be removed
without removing the function. This document records **why each is needed,
what it touches, what compensates, and when to revisit** — so that the ACS
alerts they raise are understood, not silenced.

How the list was made: every pod outside `openshift-*`/`kube-*` (plus our
AIDE DaemonSet) was checked for `privileged`, `hostNetwork`/`hostPID`/
`hostIPC`, `runAsUser: 0`, added capabilities and `hostPath` volumes, with
its admitting SCC; every ClusterRoleBinding to a service account in these
namespaces was checked for wildcard or Secret-reading rules; and ACS's
active violations were counted per namespace. Re-run that measurement when
anything here changes.

---

## Summary

| # | Workload | Owner | Privileges | Why |
|---|---|---|---|---|
| 1 | `nfs-tls/tlshd` (DaemonSet) | us | privileged, hostNetwork | TLS handshakes for in-kernel NFS clients |
| 2 | `nfs-tls` image builds | us | privileged build pods (buildah) | Builds `tlshd` from entitled RHEL content |
| 3 | `etcd-backup` (CronJob) | us | privileged, hostNetwork, hostPID, root, host `/` | Runs the platform's `cluster-backup.sh` on a master |
| 4 | `openshift-file-integrity/aide-all-nodes` | us (Red Hat operator) | privileged, root, host `/` | AIDE must read every watched host file |
| 5 | `stackrox/collector` | Red Hat (ACS) | privileged, root, host `/`, `/proc`, `/etc`, `/dev` | eBPF runtime monitoring of every process and connection |
| 6 | NVIDIA GPU Operator (14 DaemonSets) | NVIDIA | privileged, root, host `/`; driver/toolkit/MIG also hostPID; MIG hostIPC | Kernel module build/load, device nodes, runtime hooks |
| 7 | `portworx/px-pure-csi-node` | Pure/Portworx | privileged, hostNetwork, hostPID, host `/`, `/dev`, `/etc/iscsi` | Mounting storage on the node for every pod |
| 8 | `portworx-operator` ServiceAccount | Pure/Portworx | **cluster-wide `*` on every resource** | Operator design |
| 9 | `rhacs-operator-controller-manager` ServiceAccount | Red Hat (ACS) | **cluster-wide `*` on every resource** | Operator design |

Rows 8 and 9 are effectively cluster-admin, Secrets included. Say so plainly.

---

## Compensating controls (shared)

These apply to every entry unless the entry says otherwise:

- **Placement and change control.** Each workload lives in its own namespace;
  only cluster-admins can modify it. Every manifest we own is in git and
  applied after `oc diff`.
- **Network.** Default-deny ingress on all our namespaces, and default-deny
  egress except where listed (`manifests/17-*`, `18-*`). **Exception to the
  exception:** hostNetwork pods (1, 3, 7) are outside NetworkPolicy
  entirely; no compensating network control exists for them on-cluster.
- **Images.** Pulls only from 8 allowlisted registries (`manifests/14-*`);
  every registry has an ACS scanner integration; our own images are scanned
  before rollout and covered by the scoped ACS policy (`manifests/19-*`).
- **Runtime detection.** ACS collector watches every process and connection
  on every node, including inside these pods. Proven during this work: every
  `oc exec` used for verification raised "Kubernetes Actions: Exec into Pod".
- **Host integrity.** AIDE watches `/boot`, `/root`, `/usr`, `/etc` on every
  node (`manifests/20-*`); a privileged workload that altered those paths
  would be reported within one scan interval (15 min; canary-tested).
- **Audit.** API server audit at `WriteRequestBodies` for all non-platform
  callers. **Limit:** retained ~6 h on the masters only until audit
  forwarding exists (PLAN.md B1).
- **Alerting.** **Not yet effective** — neither ACS nor Alertmanager has a
  receiver. Detection exists; notification does not.

---

## Entries

### 1. `nfs-tls/tlshd` — ours

- **Privileges:** privileged container, `hostNetwork`. SCC `privileged`.
- **Why:** the kernel's NFS client hands TLS handshakes to `tlshd` over a
  netlink socket in the host network namespace; the daemon must be in that
  namespace and able to install keys into kernel TLS. Required for
  NFS-over-TLS (800-171 3.13.8) on every node that can mount storage.
- **Touches:** netlink handshake socket; the array's certificate trust
  anchor (ConfigMap). No host filesystem mounts.
- **Additional controls:** image built by us from entitled RHEL content,
  pinned by digest, rebuilt per PATCHING.md class (c) (last 2026-10-09 for
  CVE-2026-84782); `verify.sh` T-13 checks every node; requests and limits
  set.
- **ACS alerts expected:** Privileged Container; Container with privilege
  escalation allowed; Docker CIS 5.9/5.20 (host network); Docker CIS 4.1
  (no non-root user); Red Hat Package Manager in Image.
- **Revisit:** if RHCOS ships `tlshd` (ktls-utils) natively, run it as a host
  service instead and delete the DaemonSet.

### 2. `nfs-tls` image builds — ours

- **Privileges:** Docker-strategy build pods run privileged as root with the
  node's container cache and kubelet pull credentials mounted.
- **Why:** that is how OpenShift's Docker build strategy runs buildah. Exists
  only while a build runs (~8 min per rebuild).
- **Additional controls:** egress limited to API, DNS and HTTPS for build
  pods only (`allow-egress-builds`, `manifests/18-*`); the BuildConfig is
  ours and in git.
- **Housekeeping:** completed build pods remain and keep appearing in ACS.
  `tlshd-7` produced the running digest; `oc delete build tlshd-4 tlshd-5
  tlshd-6 -n nfs-tls` removes the rest.
- **Revisit:** build off-cluster in CI and push signed images; then the
  BuildConfig, the entitlement Secret and this exception all go.

### 3. `etcd-backup` CronJob — ours

- **Privileges:** privileged, `hostNetwork`, `hostPID`, root, host `/`.
  SCC `privileged`. Runs nightly on a master for ~25 s.
- **Why:** runs the platform's own `/usr/local/bin/cluster-backup.sh`, which
  needs host podman and the node's etcd client certificates — the same
  access as `oc debug node`, which is the documented procedure.
- **Touches:** etcd (read, via the script); writes to a dedicated Retain PV.
  **The backups contain the etcd encryption key** and so can decrypt every
  Secret: the PV is Secret-grade.
- **Additional controls:** namespace contains nothing else; files 0600 /
  dirs 0700; T-14 checks freshness and the PV reclaim policy; restore
  rehearsed in an isolated pod.
- **ACS alerts expected:** Privileged Container; host network and PID
  namespace; privilege escalation; fixable CVEs in the release `cli` image
  (patched by platform upgrades, PATCHING.md class a).
- **Revisit:** when the built-in `AutomatedEtcdBackup` API is GA in the
  Default feature set, switch to it and delete this CronJob.

### 4. AIDE (`openshift-file-integrity/aide-all-nodes`) — ours, Red Hat operator

- **Privileges:** privileged, root, host `/` (read). SCC `privileged`.
- **Why:** file integrity monitoring must read every watched host file.
- **Touches:** reads `/boot`, `/root`, `/usr`, `/etc`; writes only its
  database under `/etc/kubernetes/aide.*` (excluded from its own scan).
- **Additional controls:** vendor operator on `Automatic` updates; T-16.
- **ACS alerts expected:** Privileged Container; privilege escalation;
  fixable CVEs (vendor image; class b).
- **Revisit:** none expected — this is the control's mechanism.

### 5. ACS collector — Red Hat

- **Privileges:** privileged, root, host `/`, `/proc`, `/sys`, `/etc`,
  `/dev`, `/usr/lib`, `/usr/share`.
- **Why:** eBPF probes for process, network and file activity on every node.
  It is the runtime-detection control that the other entries rely on.
- **Revisit:** none expected.

### 6. NVIDIA GPU Operator — NVIDIA

- **Privileges:** 14 DaemonSets, all privileged and root, most with host `/`.
  `driver`, `container-toolkit` and `mig-manager` also `hostPID`;
  `mig-manager` also `hostIPC`. Nine NVIDIA SCCs grant **every** capability
  (`allowedCapabilities: ['*']`) and are already a recorded tailoring
  exception (`manifests/13-*`, T-11).
- **Why:** builds and loads the NVIDIA kernel module against the running
  kernel, creates device nodes, installs the container-runtime hook
  (`/etc/crio/crio.conf.d/99-nvidia.conf`), binds GPUs to `vfio-pci` for VM
  passthrough, partitions MIG, and exports DCGM metrics.
- **Touches:** the kernel (module load), `/dev`, `/sys`, `/run/nvidia`, the
  CRI-O configuration, kubelet device-plugin sockets.
- **Additional controls:** modality switching is delegated and constrained
  (`manifests/08-*`, T-12 — Warn mode until an IdP exists); the CRI-O drop-in
  is watched by AIDE; requests/limits exemption recorded (`manifests/13-*`,
  E1).
- **Findings to record:**
  - **The GPU operator's ClusterRole may `use` any SCC** (no
    `resourceNames`), privileged included — so its service account can admit
    pods with any privilege. (NFD's operator role is the same.)
  - **SCC assignment crosses vendors.** `nvidia-node-status-exporter` is
    running under OpenShift Virtualization's `linux-bridge` SCC; a review
    today would assign `nvidia-sandbox-device-plugin`. SCC admission picks
    the most restrictive SCC the pod qualifies for among all it may use, so
    this is not an escalation (both are narrower than the exporter's own SCC),
    but the effective SCC is not the vendor's intent and changes with what
    else is installed.
- **ACS alerts expected (77 across 15 deployments):** Privileged Container;
  privilege escalation; no CPU request/memory limit; Mounting Sensitive Host
  Directories; host PID/IPC namespace; mount propagation; systemctl and
  compiler execution (the driver build); fixable CVEs (class b).
- **Revisit:** at each GPU operator upgrade (re-run the measurement; T-11
  fails on a new capability-granting SCC).

### 7. Portworx CSI node plugin — Pure/Portworx

- **Privileges:** privileged, `hostNetwork`, `hostPID`, host `/`, `/dev`,
  `/etc/iscsi`, `/var/lib/kubelet`. SCC `pure-csi-node-plugin-scc`.
- **Why:** performs the NFS mount on the node for every pod that uses a PV
  (CSI node plugins must mount into kubelet's tree with bidirectional
  propagation).
- **Revisit:** at Portworx upgrades.

### 8. `portworx-operator` RBAC — Pure/Portworx

- **Privileges:** ClusterRole with `*` verbs on `*` resources in all API
  groups. Equivalent to cluster-admin, including reading every Secret.
- **Why:** vendor operator design.
- **Compensating:** pod network egress limited to API and DNS — its internet
  manifest fetch is deliberately blocked (`manifests/18-*`); only
  cluster-admins can change its deployment.
- **Revisit:** ask Pure for a least-privilege ClusterRole; re-check at upgrades.

### 9. `rhacs-operator` RBAC — Red Hat

- **Privileges:** ClusterRole with `*` on `*` in all API groups.
- **Why:** the ACS operator installs and reconciles cluster-scoped objects
  (CRDs, webhooks, SCCs, cluster roles) for Central and SecuredCluster.
- **Compensating:** egress limited to API and DNS (`manifests/18-*`).
- **Revisit:** re-check at upgrades.

---

## ACS alerts on these workloads: accept, do not silence

On 2026-10-09: 77 active alerts in `nvidia-gpu-operator`, 23 in
`portworx`, 20 in `stackrox`, 11 each in `nfs-tls` and `etcd-backup`, 6 in
`openshift-file-integrity`, 3 in `rhacs-operator`. The configuration
violations (privileged, host namespaces, host mounts) are the exceptions
above. Two groups are **not** exceptions:

- **"Kubernetes Actions: Exec into Pod" / "Port Forward"** — our own
  verification during this work. Each should be traceable to a change in
  PLAN.md; once an IdP exists they will name a person rather than
  `kube:admin`.
- **Fixable CVEs** — handled by PATCHING.md, not here.

Recommendation: do **not** add ACS policy exclusions for these workloads.
When an alert destination exists, route only the runtime and our-images
policies to it; leave the configuration policies as the standing inventory
this document explains.

---

## Review

Re-measure and update this register at every platform or operator upgrade,
and whenever a workload is added to a non-platform namespace.
