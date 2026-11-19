# Compliance work by control

My compliance work (MOC-issues), grouped by NIST 800-171 control in the order of
the NIST Gap Analysis (2026-11-05). An issue can appear under more than one
control. Each issue links its PRs. Which automated check gives evidence for
each control is in [TEST-MAP.md](TEST-MAP.md).

Not covered by this work: Awareness and Training (3.2), Incident Response (3.6),
Personnel Security (3.9) and Physical Protection (3.10), which the gap analysis
assigns to BU Information Security, HR and the data centres.

## Access Control (AC)

**3.1.1, 3.1.2 Authorized users and functions**

- [#753](https://github.com/CCI-MOC/MOC-issues/issues/753) Named logins with timeouts on compliant clusters (MOC SSO) (done)
- [#602](https://github.com/CCI-MOC/MOC-issues/issues/602) IDP on Jetty (done)
- [#400](https://github.com/CCI-MOC/MOC-issues/issues/400) What should authentication look like for early tenants? (done)
- [#755](https://github.com/CCI-MOC/MOC-issues/issues/755) Retire the shared kubeadmin login (open)
- [#776](https://github.com/CCI-MOC/MOC-issues/issues/776) Break-glass procedure for compliant clusters (open)

**3.1.3 Control the flow of CUI**

- [#756](https://github.com/CCI-MOC/MOC-issues/issues/756) NetworkPolicies for a compliant hub's own namespaces (open)
- [#764](https://github.com/CCI-MOC/MOC-issues/issues/764) Route IP allowlist for cluster routes (open)
- [#771](https://github.com/CCI-MOC/MOC-issues/issues/771) Cluster-wide egress proxy (open)
- [#752](https://github.com/CCI-MOC/MOC-issues/issues/752) Hub admission policies: refuse non-compliant clusters and cleartext storage (done)

**3.1.5, 3.1.6 Least privilege**

- [#769](https://github.com/CCI-MOC/MOC-issues/issues/769) Least-privilege RBAC for the Portworx operator (open)
- [#749](https://github.com/CCI-MOC/MOC-issues/issues/749) group-sync-operator is not needed on compliant hubs (done)
- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)
- [#738](https://github.com/CCI-MOC/MOC-issues/issues/738) Stop pods getting GPUs they did not request (done)

**3.1.7 Log privileged functions**

- [#751](https://github.com/CCI-MOC/MOC-issues/issues/751) API server audit: request bodies, and the volume that came with them (done)
- [#735](https://github.com/CCI-MOC/MOC-issues/issues/735) Audit logging to Loki on FlashBlade object storage (done)

**3.1.11 Session termination**

- [#753](https://github.com/CCI-MOC/MOC-issues/issues/753) Named logins with timeouts on compliant clusters (MOC SSO) (done)

**3.1.12 Monitor remote access**

- [#735](https://github.com/CCI-MOC/MOC-issues/issues/735) Audit logging to Loki on FlashBlade object storage (done)
- [#751](https://github.com/CCI-MOC/MOC-issues/issues/751) API server audit: request bodies, and the volume that came with them (done)

## Audit and Accountability (AU)

**3.3.1, 3.3.2 Audit logs tied to identities**

- [#735](https://github.com/CCI-MOC/MOC-issues/issues/735) Audit logging to Loki on FlashBlade object storage (done)
- [#734](https://github.com/CCI-MOC/MOC-issues/issues/734) Object storage for hubs: pure-cosi and the object storage proxy (done)
- [#751](https://github.com/CCI-MOC/MOC-issues/issues/751) API server audit: request bodies, and the volume that came with them (done)
- [#753](https://github.com/CCI-MOC/MOC-issues/issues/753) Named logins with timeouts on compliant clusters (MOC SSO) (done)
- [#745](https://github.com/CCI-MOC/MOC-issues/issues/745) Measure the overhead of the RHCOS audit rules (open)
- [#770](https://github.com/CCI-MOC/MOC-issues/issues/770) Re-enable the audit-log-path rule after OCPBUGS-126610 (open)

**3.3.4, 3.3.5, 3.3.6 Alerting, correlation, reporting**

- [#775](https://github.com/CCI-MOC/MOC-issues/issues/775) Scan results from every cluster in one place (open)
- [#784](https://github.com/CCI-MOC/MOC-issues/issues/784) Metrics persistence on compliant clusters (open)

## Configuration Management (CM)

**3.4.1, 3.4.2 Baselines and security settings**

- [#722](https://github.com/CCI-MOC/MOC-issues/issues/722) Harden jetty to NIST 800-171 with the Compliance Operator (done)
- [#731](https://github.com/CCI-MOC/MOC-issues/issues/731) Build nist-dev-infra, a FIPS test hub, and bring it to compliance (done)
- [#732](https://github.com/CCI-MOC/MOC-issues/issues/732) Build nist-dev-workload0, a compliant hosted workload cluster (done)
- [#754](https://github.com/CCI-MOC/MOC-issues/issues/754) Build compliant-dev-infra, the compliant hub, on the R440s (open)
- [#730](https://github.com/CCI-MOC/MOC-issues/issues/730) Design: compliant hubs and hosted workload clusters (done)
- [#750](https://github.com/CCI-MOC/MOC-issues/issues/750) Standards mapping and scope for compliant OAC clusters (done)
- [#786](https://github.com/CCI-MOC/MOC-issues/issues/786) Publish the hardening playbook (open)
- [#752](https://github.com/CCI-MOC/MOC-issues/issues/752) Hub admission policies: refuse non-compliant clusters and cleartext storage (done)

**3.4.3, 3.4.4, 3.4.5 Change control, security review, who may change prod**

- [#803](https://github.com/CCI-MOC/MOC-issues/issues/803) How do we ensure non-compliant changes don't sneak into compliant clusters? (open)
- [#774](https://github.com/CCI-MOC/MOC-issues/issues/774) Remediation PRs from scan results (open)
- [#736](https://github.com/CCI-MOC/MOC-issues/issues/736) Upstream the compliance charts to oac-apps (open)

**3.4.6, 3.4.7 Least functionality**

- [#722](https://github.com/CCI-MOC/MOC-issues/issues/722) Harden jetty to NIST 800-171 with the Compliance Operator (done)
- [#749](https://github.com/CCI-MOC/MOC-issues/issues/749) group-sync-operator is not needed on compliant hubs (done)
- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)

**3.4.8, 3.4.9 Allowed software, user-installed software**

- [#765](https://github.com/CCI-MOC/MOC-issues/issues/765) Sign the images we build and verify signatures at runtime (open)
- [#780](https://github.com/CCI-MOC/MOC-issues/issues/780) Private registry for images we build (open)
- [#744](https://github.com/CCI-MOC/MOC-issues/issues/744) RHADS on the compliance clusters: findings and plan (open)
- [#740](https://github.com/CCI-MOC/MOC-issues/issues/740) Inventory operators' FIPS claims and scan their images (done)

## Identification and Authentication (IA)

**3.5.1, 3.5.2 Identify and authenticate users and devices**

- [#753](https://github.com/CCI-MOC/MOC-issues/issues/753) Named logins with timeouts on compliant clusters (MOC SSO) (done)
- [#602](https://github.com/CCI-MOC/MOC-issues/issues/602) IDP on Jetty (done)
- [#400](https://github.com/CCI-MOC/MOC-issues/issues/400) What should authentication look like for early tenants? (done)
- [#755](https://github.com/CCI-MOC/MOC-issues/issues/755) Retire the shared kubeadmin login (open)

## Maintenance (MA)

**3.7.1, 3.7.2 Controlled maintenance**

- [#757](https://github.com/CCI-MOC/MOC-issues/issues/757) Day-to-day operation of a compliant hub (open)
- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)
- [#779](https://github.com/CCI-MOC/MOC-issues/issues/779) Agree patch cadences (open)

## Media Protection (MP)

**3.8.3 Sanitization (GPU memory between tenants)**

- [#737](https://github.com/CCI-MOC/MOC-issues/issues/737) GPU passthrough to VMs and tenant isolation (done)
- [#739](https://github.com/CCI-MOC/MOC-issues/issues/739) GPU KubeVirt hosted clusters: jetty as hypervisor, andalusia (done)
- [#759](https://github.com/CCI-MOC/MOC-issues/issues/759) GPUs in containers and VMs on one hardened cluster (done)

**3.8.7 Removable media (USBGuard, `nousb`)**

- [#754](https://github.com/CCI-MOC/MOC-issues/issues/754) Build compliant-dev-infra, the compliant hub, on the R440s (open)
- [#722](https://github.com/CCI-MOC/MOC-issues/issues/722) Harden jetty to NIST 800-171 with the Compliance Operator (done)

**3.8.9 Backups**

- [#728](https://github.com/CCI-MOC/MOC-issues/issues/728) Nightly etcd backups for hubs (open)
- [#782](https://github.com/CCI-MOC/MOC-issues/issues/782) Backups off the FlashBlade (open)

## Risk Assessment (RA)

**3.11.2 Vulnerability scanning**

- [#725](https://github.com/CCI-MOC/MOC-issues/issues/725) Vulnerability scanning with ACS, including the HIPAA standard (done)
- [#740](https://github.com/CCI-MOC/MOC-issues/issues/740) Inventory operators' FIPS claims and scan their images (done)
- [#783](https://github.com/CCI-MOC/MOC-issues/issues/783) COSI on the rebuilt hub: S3 tests and image scans (open)
- [#775](https://github.com/CCI-MOC/MOC-issues/issues/775) Scan results from every cluster in one place (open)
- oac-infra [#33](https://github.com/CCI-MOC/oac-infra/pull/33) (draft): FIPS image builder; scans built images

**3.11.3 Remediation**

- [#774](https://github.com/CCI-MOC/MOC-issues/issues/774) Remediation PRs from scan results (open)
- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)
- [#779](https://github.com/CCI-MOC/MOC-issues/issues/779) Agree patch cadences (open)
- [#748](https://github.com/CCI-MOC/MOC-issues/issues/748) Replace patch-operator with ACM ConfigurationPolicies (open)

## Security Assessment (SA)

**3.12.1 Continuous monitoring, assessment**

- [#729](https://github.com/CCI-MOC/MOC-issues/issues/729) Compliance verification and cluster acceptance tests (done)
- [#777](https://github.com/CCI-MOC/MOC-issues/issues/777) verify.sh for a hub (open)
- [#675](https://github.com/CCI-MOC/MOC-issues/issues/675) Compliance testing (open): tests lined up in TEST-MAP.md
- [#775](https://github.com/CCI-MOC/MOC-issues/issues/775) Scan results from every cluster in one place (open)

**3.12.2 Plans of action (POA&M)**

- [#778](https://github.com/CCI-MOC/MOC-issues/issues/778) One register of exceptions and POA&M items (open)
- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)

**3.12.4 System security plan inputs**

- [#463](https://github.com/CCI-MOC/MOC-issues/issues/463) Gap analysis for NIST/HIPAA requirements compared to full OAC build (done)
- [#750](https://github.com/CCI-MOC/MOC-issues/issues/750) Standards mapping and scope for compliant OAC clusters (done)
- [#785](https://github.com/CCI-MOC/MOC-issues/issues/785) Non-technical controls for an authorization package (open)
- [#760](https://github.com/CCI-MOC/MOC-issues/issues/760) Lessons from the FIPS test hub (done)
- [#786](https://github.com/CCI-MOC/MOC-issues/issues/786) Publish the hardening playbook (open)

## System and Communications Protection (SC)

**3.13.1, 3.13.5, 3.13.6 Boundaries, segmentation, deny by default**

- [#730](https://github.com/CCI-MOC/MOC-issues/issues/730) Design: compliant hubs and hosted workload clusters (done)
- [#789](https://github.com/CCI-MOC/MOC-issues/issues/789) FlashBlade realms for compliant-dev-infra and compliant-dev-workload0 (done)
- [#756](https://github.com/CCI-MOC/MOC-issues/issues/756) NetworkPolicies for a compliant hub's own namespaces (open)
- [#764](https://github.com/CCI-MOC/MOC-issues/issues/764) Route IP allowlist for cluster routes (open)
- [#771](https://github.com/CCI-MOC/MOC-issues/issues/771) Cluster-wide egress proxy (open)

**3.13.4 No information transfer through shared resources**

- [#737](https://github.com/CCI-MOC/MOC-issues/issues/737) GPU passthrough to VMs and tenant isolation (done)
- [#738](https://github.com/CCI-MOC/MOC-issues/issues/738) Stop pods getting GPUs they did not request (done)
- [#759](https://github.com/CCI-MOC/MOC-issues/issues/759) GPUs in containers and VMs on one hardened cluster (done)
- [#766](https://github.com/CCI-MOC/MOC-issues/issues/766) GPU claim prevention for billing (open)
- [#784](https://github.com/CCI-MOC/MOC-issues/issues/784) Metrics persistence on compliant clusters (open)

**3.13.8, 3.13.15 Encryption in transit, session authenticity**

- [#723](https://github.com/CCI-MOC/MOC-issues/issues/723) Encrypt NFS traffic to the FlashBlade (NFS over TLS) (done)
- [#85](https://github.com/CCI-MOC/MOC-issues/issues/85) Pure Storage: Encryption in transit (done)
- [#789](https://github.com/CCI-MOC/MOC-issues/issues/789) FlashBlade realms for compliant-dev-infra and compliant-dev-workload0 (done)
- [#346](https://github.com/CCI-MOC/MOC-issues/issues/346) Evaluate performance cost of NFS-over-TLS vs unencrypted NFS (open)
- [#743](https://github.com/CCI-MOC/MOC-issues/issues/743) FlashBlade crypto in transit and PX-CSI FIPS: Pure's answers (open)
- [#761](https://github.com/CCI-MOC/MOC-issues/issues/761) Connectivity Link on OAC: chart, and gateway TLS under FIPS (done)
- [#767](https://github.com/CCI-MOC/MOC-issues/issues/767) Ingress certificate and CA from the organisation (open)
- [#768](https://github.com/CCI-MOC/MOC-issues/issues/768) FlashBlade management certificate from MOC's CA (open)
- [#752](https://github.com/CCI-MOC/MOC-issues/issues/752) Hub admission policies: refuse non-compliant clusters and cleartext storage (done)

**3.13.10 Key management**

- [#672](https://github.com/CCI-MOC/MOC-issues/issues/672) Determine whether to use NBDE for data-at-rest encryption in MOC 2.0 (done)
- [#810](https://github.com/CCI-MOC/MOC-issues/issues/810) A reliable home for the Tang server (open)
- [#767](https://github.com/CCI-MOC/MOC-issues/issues/767) Ingress certificate and CA from the organisation (open)
- [#768](https://github.com/CCI-MOC/MOC-issues/issues/768) FlashBlade management certificate from MOC's CA (open)

**3.13.11 FIPS-validated cryptography**

- [#724](https://github.com/CCI-MOC/MOC-issues/issues/724) Record FIPS 140-3 module status for OpenShift 4.22 nodes (done)
- [#740](https://github.com/CCI-MOC/MOC-issues/issues/740) Inventory operators' FIPS claims and scan their images (done)
- [#741](https://github.com/CCI-MOC/MOC-issues/issues/741) FIPS builds of pure-cosi (done)
- [#742](https://github.com/CCI-MOC/MOC-issues/issues/742) Replace the Grafana operator (no FIPS build) (done)
- [#746](https://github.com/CCI-MOC/MOC-issues/issues/746) Cluster Observability Operator: images are FIPS, the CSV flag says not (open)
- [#747](https://github.com/CCI-MOC/MOC-issues/issues/747) NVIDIA GPU Operator on FIPS clusters (open)
- [#781](https://github.com/CCI-MOC/MOC-issues/issues/781) Confirm the OpenSSL FIPS provider build with the RHEL crypto team (open)
- [#792](https://github.com/CCI-MOC/MOC-issues/issues/792) FIPS build host for hub boot media (open)
- [#733](https://github.com/CCI-MOC/MOC-issues/issues/733) Investigate etcd instability on a compact FIPS hub (done)
- [#668](https://github.com/CCI-MOC/MOC-issues/issues/668) Verify FIPS compatibility of connectivity link api manager on cluster (done)
- [#527](https://github.com/CCI-MOC/MOC-issues/issues/527) RH HW Request - Mini 3 node cluster request with FIPS enabled (done)
- [#629](https://github.com/CCI-MOC/MOC-issues/issues/629) RH HW Request - NIST/HIPPA trial build (done)
- [#743](https://github.com/CCI-MOC/MOC-issues/issues/743) FlashBlade crypto in transit and PX-CSI FIPS: Pure's answers (open)

**3.13.16 Encryption at rest**

- [#672](https://github.com/CCI-MOC/MOC-issues/issues/672) Determine whether to use NBDE for data-at-rest encryption in MOC 2.0 (done)
- [#811](https://github.com/CCI-MOC/MOC-issues/issues/811) Encrypt the compliant-dev-infra workers' LVM Storage disks (done)
- [#754](https://github.com/CCI-MOC/MOC-issues/issues/754) Build compliant-dev-infra, the compliant hub, on the R440s (open)

## System and Information Integrity (SI)

**3.14.1, 3.14.3 Flaw remediation, alerts**

- [#726](https://github.com/CCI-MOC/MOC-issues/issues/726) Patch cadence and privileged-workload exception register (done)
- [#779](https://github.com/CCI-MOC/MOC-issues/issues/779) Agree patch cadences (open)
- [#748](https://github.com/CCI-MOC/MOC-issues/issues/748) Replace patch-operator with ACM ConfigurationPolicies (open)
- [#774](https://github.com/CCI-MOC/MOC-issues/issues/774) Remediation PRs from scan results (open)

**3.14.2, 3.14.6, 3.14.7 Monitoring for attacks and unauthorized use**

- [#727](https://github.com/CCI-MOC/MOC-issues/issues/727) File integrity monitoring (AIDE) on every node (done)
- [#773](https://github.com/CCI-MOC/MOC-issues/issues/773) File integrity on hosted workers (RFE-8168) (open)
- [#725](https://github.com/CCI-MOC/MOC-issues/issues/725) Vulnerability scanning with ACS, including the HIPAA standard (done)
