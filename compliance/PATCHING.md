# Patch cadence — draft SSP text and how jetty meets it

> **DRAFT, 2026-10-08.** The day counts below are proposals, marked
> **[decide]**. They are the organisation's commitment to make, not ours;
> pick numbers you will actually keep, because an assessor checks the
> record against them.

Why this exists: ACS `HIPAA_164` fails 164.306(e) and 164.308(a)(6)(ii)
because running images carry CVEs with fixes available. That count never
reaches zero on a cluster running vendor images: ACS calls a CVE fixable when
*any* newer component version exists, and vendors rebuild on their own
schedule (STANDARDS.md §5, measured across the 4.22.16 upgrade). What
satisfies the control is a written cadence plus evidence of following it.

Controls this supports: NIST 800-171 **3.14.1** (flaw remediation, SI-2),
**3.11.2 / 3.11.3** (vulnerability scanning and remediation, RA-5); HIPAA
**164.308(a)(1)(ii)(B)** (risk management), and the two ACS-evaluated
sections above.

---

## 1. Draft SSP text

> **Flaw remediation and patch cadence.**
>
> *Scope.* All software running on the jetty cluster, in three classes:
> (a) the OpenShift platform (release payload and RHCOS),
> (b) operators installed through OLM,
> (c) container images built by [organisation] (currently the `tlshd`
> storage-encryption image).
>
> *Identification.* Red Hat Advanced Cluster Security scans every running
> image continuously and re-scans on new vulnerability data; images are
> pulled only from an allowlisted set of registries, each with a scanner
> integration. The OpenShift update service reports available platform
> updates on the `stable` channel.
>
> *Remediation timelines,* measured from the date a fix is available to us:
>
> | Class | Routine | Critical, or listed in CISA KEV |
> |---|---|---|
> | (a) Platform z-stream | within **30 days [decide]** of reaching the `stable` channel | within **7 days [decide]** |
> | (a) Platform minor version | within **90 days [decide]** of reaching `stable`; before the running minor leaves support | — |
> | (b) Operators | applied automatically within their channel (`installPlanApproval: Automatic`); channel moves follow the platform minor | same, plus a channel move if the fix is only in a newer channel |
> | (c) Our images | rebuilt at least **monthly [decide]** and on any fixable Important/Critical finding, within **14 days [decide]** | within **7 days [decide]** |
>
> Vendor images in classes (a) and (b) are remediated by applying the
> vendor's update, not by rebuilding them ourselves. A fixable CVE in a
> vendor image with no vendor update available is tracked, not a breach of
> this policy.
>
> *Verification.* Every platform update follows the documented procedure:
> pre-update etcd backup; the verification suite (`tests/verify.sh`) before
> and after, with identical results required; compliance rescans compared
> with the baseline; the ACS `HIPAA_164` standard re-run. Results are kept
> as evidence.
>
> *Exceptions.* A finding that does not apply is recorded as an ACS
> vulnerability exception with the reasoning; findings are not deleted.
> A **false positive** (the scanner is wrong about the version or
> component) is recorded as such and needs no expiry. A **deferral** (the
> finding is real but accepted for now) expires in at most **90 days
> [decide]** and is reviewed before it lapses. Requester and approver are
> different people (enforceable once the cluster has an identity provider).
>
> *Review.* Fixable Important/Critical findings in class (c) are reviewed
> **weekly [decide]**; the whole policy annually.

---

## 2. What jetty does today, against that text

| Requirement | State 2026-10-08 | Evidence |
|---|---|---|
| Platform on `stable` | ✅ `stable-4.22`, at 4.22.16; no update available | `oc adm upgrade` |
| z-stream applied, verified | ✅ 4.22.14 → 4.22.16 on 2026-10-08, full procedure | PLAN.md §7; verify 49/0/2 before and after |
| Operators automatic | ✅ all 7 subscriptions `Automatic`, each at its channel's latest CSV | `oc get sub -A` |
| Every registry scanned | ✅ since 2026-10-08 (`nvcr.io` had no integration before) | STANDARDS.md §5 |
| Scan freshness | ✅ ACS `30-Day Scan Age`: 0 violations | ACS |
| **Our images current** | ✅ `tlshd` rebuilt and rolled out 2026-10-09 (found 2026-10-08 14:51Z, fixed 01:56Z) — see §3 | `rpm -q` in every pod |
| Exceptions recorded | ✅ `mig-parted` false positive: ACS exceptions `AA-261009-1`, `-2` | ACS |
| Written cadence | ❌ this draft | — |

The patch-cadence control is evidenced by the record, so start the record
now: each future z-stream gets a dated PLAN.md entry like 4.22.16's.

---

## 3. Our images: `tlshd` — the first class (c) finding

ACS (`Fixable Severity at least Important`, active since 2026-10-08 14:51Z):

| CVE | Component | Have | Fixed in |
|---|---|---|---|
| CVE-2026-84782 (Important, CVSS 7.4) | `openssl`, `openssl-libs` | `3.5.8-1.el9_8` | `3.5.8-2.el9_8` |

The image was built 2026-10-06 (build `tlshd-4`). `tlshd` itself uses
GnuTLS, not OpenSSL, so reachability is doubtful — but this is our own image
and the fix is a rebuild, so rebuild rather than argue it.

**Remediated 2026-10-09 — the first run of the class (c) procedure.**
It took three builds, and each failure is a lesson:

1. **`tlshd-5` hung** in its first container: `SYN_SENT` to the API service.
   The default-deny egress added to `nfs-tls` that day (`manifests/18-*`)
   blocks build pods; validation had missed it because no build ran in the
   window. Fixed with `allow-egress-builds` in `manifests/18-*` — API, DNS
   and HTTPS for pods labelled `openshift.io/build.name` only. `tlshd`
   itself stays deny-all.
2. **`tlshd-6` built and pushed, but did not fix the CVE.** A rebuild only
   patches what the build updates: the Dockerfile installed `ktls-utils`
   on `ubi9:latest`, which still ships `openssl 3.5.8-1`. Caught by
   scanning before rollout. The Dockerfile now runs `dnf upgrade -y
   --refresh` first (`manifests/11-nfs-tls/buildconfig.yaml`).
3. **`tlshd-7`** upgraded `openssl`/`openssl-libs` to `3.5.8-2.el9_8` (plus
   glibc and tzdata errata). Digest `sha256:f8bcab63…`, pinned in
   `manifests/11-nfs-tls/daemonset.yaml`, applied with `oc apply -k`
   (the DaemonSet references a kustomize-generated ConfigMap; `-f` would
   have pointed it at a ConfigMap that does not exist).

Rollout 01:51–01:56Z, one node at a time. Verified:
- `rpm -q openssl-libs` = `3.5.8-2.el9_8` in all 5 running pods;
- T-13 4/4; the established kernel-TLS session on u15 survived the restart
  (no new handshake, no decrypt errors);
- a fresh PVC on u16 (no session there) handshook through the new `tlshd`,
  mounted with `xprtsec=tls`, wrote and read back, then deleted.

**Not yet confirmed by ACS.** Central could not scan the new image: three
attempts since 01:10Z stall at "Getting metadata" from ghcr.io, with an
established connection to GitHub and no network block — the same no-cause
pattern as the 2026-10-08 image-API hang (STANDARDS.md §5). The fixable-CVE
alerts on `nfs-tls` stay active until Central scans the new digest. The
previous build's image (`tlshd-6`) scanned fine on a second try, so this is
intermittent rather than ghcr being unreachable.

**Resolved without intervention:** Central completed the scan at 04:15Z
(~3 h after the first attempt, no restart) and both fixable-CVE alerts on
`nfs-tls` cleared. Class (c) cycle closed: found 2026-10-08 14:51Z, fixed
in production 01:56Z, confirmed by ACS 04:15Z.

Note: the ACS image *list* endpoint reported `fixableCves: 0` for this image
while the image detail and the alert both show two fixable rows. Read the
detail or the alerts, not the list summary.

---

## 4. ACS policies — what exists, and the proposal

Already enabled (ACS defaults, inform-only at deploy, **no notifier**):

| Policy | Active violations | Ours |
|---|---|---|
| `Fixable Severity at least Important` | 187 (164 platform) | `nfs-tls` 1, `etcd-backup` 1 (Red Hat `cli` image) |
| `Privileged Containers with Important and Critical Fixable CVEs` | 34 (24 platform) | same two |
| `30-Day Scan Age` | 0 | — |

The cluster-wide policy is mostly vendor images we cannot rebuild, so as an
alert source it is noise. Items 1 and 4 **applied 2026-10-09**; 2 waits on a
destination:

1. **New policy `jetty: our images — fixable Important+`**: same criteria as
   the default (`Fixed By` any, `Severity >= IMPORTANT`), scoped to the
   namespaces where we build the image (today `nfs-tls`; add others as
   images are added), stages BUILD + DEPLOY, inform-only. This is the one
   whose alerts mean "act within the class (c) timeline". **Applied** as
   policy-as-code, `manifests/19-acs-policy-own-images.yaml` (a
   `SecurityPolicy` CR synced by ACS's config-controller; Central accepted
   it). It fired on the old `tlshd` image as intended.
2. **Attach the notifier to it** once the audit/alert destination exists —
   the same open decision as audit forwarding (PLAN.md B1/B2). Notifiers
   on this policy plus the runtime policies are what close HIPAA
   308(a)(6)(ii) / 314(a)(2)(i)(C).
3. **Keep the default policy enabled** as the inventory of vendor exposure;
   no notifier on it.
4. **Record the `mig-parted` false positive** (CVE-2025-23266/-23267) as an
   ACS vulnerability exception with the pseudo-version reasoning.
   **Applied:** `AA-261009-1` (mig-manager), `AA-261009-2`
   (vgpu-device-manager), type FALSE_POSITIVE (no expiry), via
   `POST /v2/vulnerability-exceptions/false-positive` then `/approve`. ACS
   let the same admin account request and approve them — separation of
   duties needs real user accounts (IdP).

Optional later: a `verify.sh` check that fails when a fixable Important+
finding in our namespaces is older than the class (c) timeline.
