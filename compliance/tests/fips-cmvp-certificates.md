# FIPS 140-3 (CMVP) certificate record — jetty

Read by `verify.sh` T-02, which parses the two `KEY=value` lines below and
compares them with every node. **Re-review after every upgrade**: module
versions move with RHCOS, and T-02 WARNs when the running RHCOS differs from
the one reviewed here.

```
REVIEWED_RHCOS=Red Hat Enterprise Linux CoreOS 9.8.20260922-1 (Plow)
CERTIFIED_OPENSSL_PROVIDER_VERSION=3.0.7-395c1a240fbfffd8
```

Reviewed 2026-10-09 against OpenShift 4.22.16. Sources: Red Hat's FIPS
status page (access.redhat.com/compliance/fips), NIST CMVP certificate #4857,
and the NIST Modules In Process list (all read 2026-10-09).

---

## Verdict

**FIPS mode is on everywhere (T-01). FIPS *validation* is partial, and on
this exact build it is not established even for the one module that has a
certificate.** That is normal for a current minor release (validation lags
release by a year or more), but it has to be stated plainly in the SSP, not
implied by "FIPS mode enabled".

---

## Modules on the running nodes (all 5 identical, RHCOS 9.8.20260922-1)

| Module | Running on jetty | Red Hat status for RHEL 9.8 (OCP 4.22) | Certificate |
|---|---|---|---|
| **OpenSSL FIPS Provider** | `openssl-fips-provider-3.0.7-11.el9_8`, module version **`3.0.7-cda111b5812c30d4`** | Active — but for module version **`3.0.7-395c1a240fbfffd8`** (package `-6.el9`) | **#4857** (140-3 L1, Active, sunset 2029-10-28) |
| Kernel Cryptographic API | `kernel-5.14.0-687.50.1.el9_8`, `libkcapi-1.4.0-3.el9_8` | not listed for 9.8; "N/A" for 9.6 | none for 9.8 (9.4 had #5445; 9.2 #5034) |
| GnuTLS | host `gnutls-3.8.10-8.el9_8`; `tlshd` image `gnutls-3.8.10-9.el9_8` | not listed for 9.8; "N/A" for 9.6 | none for 9.8 (9.2 had #4846). A RHEL 9 gnutls submission is **in Review** at CMVP (2026-10-07) |
| Libgcrypt | `libgcrypt-1.10.0-13.el9_8` | not listed for 9.8; 9.6 "Scenario 3A revalidation" | #5366 covers `1.10.0-10.el9_x` builds, not this one |
| NSS | not installed on RHCOS | — | — |

The provider version is read at runtime (`openssl list -providers`), which
is how T-02 checks it on every node.

### 1. The OpenSSL provider on jetty is not the certified binary

Red Hat ships the FIPS provider separately from `openssl-libs` precisely so
the certified binary can stay fixed while the rest of OpenSSL moves (jetty's
`openssl-libs` is 3.5.8). Red Hat's page lists 9.8 as carrying the certified
module `3.0.7-395c1a240fbfffd8` in `openssl-fips-provider-3.0.7-6.el9`,
"repackaged for distribution but not modified".

The nodes run **`-11.el9_8`**, which reports **`3.0.7-cda111b5812c30d4`** — a
different module version, so a different binary. A later security update
to the provider (an equivalent `openssl-fips-provider-3.0.7-11` appears in a
rebuilder's security advisory) is the likely reason. Red Hat's page does
not list this version, and a newer **RHEL 9 OpenSSL FIPS Provider** is in
CMVP **Comment Resolution** (2026-09-03) — plausibly this build, unconfirmed.

**Ask Red Hat:** is module `3.0.7-cda111b5812c30d4`
(`openssl-fips-provider-3.0.7-11.el9_8`, RHCOS 9.8.20260922-1) covered by
#4857, or is it the submission in process? Until answered, the honest status
is "FIPS 140-3 module, validation of this version in process".

This is the standing trade-off: a CVE fix to a certified module produces an
unvalidated binary until revalidation completes. Running the patched,
unvalidated module is the normal and defensible choice; say so in the SSP.

### 2. Which jetty functions depend on which module

| Function | Module | Validated on 9.8? |
|---|---|---|
| OpenShift control plane and operators (Go, built with `golang-fips`) | OpenSSL FIPS provider **in each component's own container image**, not the host's | per image; same question as §1 |
| Host services using OpenSSL (`sshd`, `curl`; CRI-O and kubelet are Go linked to the host's OpenSSL) | host OpenSSL FIPS provider | §1 |
| **NFS-over-TLS handshake** (`tlshd`) | **GnuTLS** in the `tlshd` image | **No** — in Review |
| **NFS-over-TLS bulk encryption** (kTLS) | **Kernel Crypto API** | **No** — and no RHEL 9 kernel submission is in process |
| etcd encryption at rest (`aesgcm`) | Go → OpenSSL FIPS provider in the kube-apiserver image | §1 |
| AIDE hashing (sha512) | AIDE's crypto library in the File Integrity Operator image (RHEL's AIDE uses libgcrypt) | not for this build |

The storage-encryption path — the reason NFS-over-TLS exists (800-171
3.13.8 / 3.13.11) — rests on the two modules with **no 9.8 certificate**.
FIPS mode still restricts them to approved algorithms (T-15 shows the
effect), but "approved algorithms in FIPS mode" is not "validated module".

### 3. Operational environment

#4857's tested environments are RHEL 9 on an Intel Xeon Silver 4216, IBM
POWER10 and IBM z16. jetty runs Intel Xeon E5-2640 v4 (masters) and AMD
EPYC family 25 (workers), under RHCOS rather than RHEL. CMVP permits Level 1
software modules to run on unlisted environments, but the certificate then
makes no claim about them. Red Hat lists OpenShift 4.22 against RHEL 9.8,
which is the vendor's position that RHCOS carries the RHEL module.

---

## What to put in the SSP

1. FIPS mode is enforced on all nodes (evidence: T-01).
2. Cryptographic modules are the RHEL 9 modules shipped in RHCOS; the
   OpenSSL FIPS Provider is 140-3 certificate #4857, with the running build
   a post-certification security update whose validation is in process
   (cite Red Hat's answer once received). Kernel Crypto API and GnuTLS for
   this release are not yet validated (GnuTLS in CMVP review).
3. Re-reviewed at every platform upgrade (T-02 enforces the reminder).

## Re-review procedure (each upgrade)

1. `verify.sh -t t02` — lists each node's provider version and RHCOS.
2. Read Red Hat's FIPS page for the RHEL minor that OpenShift now maps to.
3. Check the CMVP Modules In Process list for Red Hat entries.
4. Update this file: the table, the two `KEY=value` lines, the date.
