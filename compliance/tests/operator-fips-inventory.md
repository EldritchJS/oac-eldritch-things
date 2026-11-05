# Operator FIPS inventory

Which installed operators claim FIPS support, and what to do about the ones
that don't. Companion to [fips-cmvp-certificates.md](fips-cmvp-certificates.md),
which covers the crypto modules themselves.

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

Not flagged `true`:

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

Flagged `true`: ACM and multicluster engine, OpenShift GitOps, cert-manager,
External Secrets, external-dns, MetalLB, NMState, LVM Storage, Node Feature
Discovery, OpenShift Virtualization, and Connectivity Link (rhcl, Authorino,
Limitador, DNS operator).

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
| Cluster Observability Operator | Ask Red Hat for its FIPS status. Until then, leave it off compliant clusters, or keep it with a justification (dashboards, no tenant data store) |
| Grafana operator | Remove on compliant clusters; Grafana from provisioning files ([GRAFANA-FIPS-IMAGE.md](../GRAFANA-FIPS-IMAGE.md)) |
| Portworx operator | Ask the vendor. It is in the storage path, so it is the hardest to justify keeping and the hardest to remove |
| NVIDIA GPU Operator | Ask NVIDIA. GPUs are why the clusters exist, so this is a justification, not a removal |
| patch-operator | Check what it patches on a compliant cluster; it may be replaceable by Argo CD or a chart |
| group-sync-operator | Group sync controls access (800-171 3.1.1), so it needs either a FIPS answer or a replacement |

## To make it checkable

Add a test to the verification suite that lists every CSV without
`fips-compliant: true` and fails unless the operator is on an accepted list,
so a new unflagged operator is caught instead of slipping in.
