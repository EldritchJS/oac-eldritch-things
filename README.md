# oac-eldritch-things

Operational work on OpenShift clusters at the compute center — the things that
turn out to be stranger than expected once you look closely.

## What's here

| Directory | What |
|---|---|
| [`compliance/`](compliance/) | Hardening the `jetty` cluster to NIST 800-171 / HIPAA / FIPS while keeping dual-modality GPU (containers ⇄ VMs) working. Start at [`compliance/README.md`](compliance/README.md). |

## Why it exists

`jetty` is a sandbox, but it sits in a compute center that will host real
clusters needing to pass a real assessment. So the point of this repo is not a
compliant `jetty` — it is **transferable method**: measured numbers, reusable
manifests and scripts, and a written record of the traps, so the clusters that
matter don't have to rediscover them.

Experiments that are expensive on a production GPU cluster are cheaper here. We run
them here and note what happened.

## Conventions

**This repo is public.** Working in the open is the point, so the content has
to be safe to publish rather than hidden:

- **No credentials, ever.** No kubeconfigs, tokens, init bundles, or secrets.
  `.gitignore` enforces this, but the rule is the rule regardless.
- **Internal addresses are redacted** as `<descriptive-placeholder>` —
  e.g. `<fb-data-vip>`, `<storage-gw>`, `<cluster-api-fqdn>`. These are
  redactions, not blanks to fill in. Keep the surrounding technical detail:
  the diagnostic value is in the *reasoning*, not the octets.
- **Hostnames are kept.** Rack identifiers like `moc-r4pcc02u15` are opaque
  without network access and make the docs concrete.
- **Certificates are not committed when their subject names an internal
  address.** An X.509 cert is public key material, not a secret — but it
  cannot be redacted without breaking it, so one carrying an internal VIP
  stays out of the repo and is supplied locally instead. See
  `compliance/manifests/11-nfs-tls/files/README.md`.

When these notes are reused for a cluster that is actually under assessment,
re-read them with this in mind: a careful public account of which controls are
*not* yet in place is a different proposition for a production system than for
a sandbox.

## Before you run anything

No kubeconfig is in this repo, and none should be. See
[`compliance/README.md`](compliance/README.md) § Prerequisites.
