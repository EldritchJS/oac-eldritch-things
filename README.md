# oac-eldritch-things

Operational work on OpenShift clusters at the compute center — the things that
turn out to be stranger than expected once you look closely.

## What's here

| Directory | What |
|---|---|
| [`compliance/`](compliance/) | Building OAC hubs and workload clusters compliant with NIST 800-171, HIPAA and FIPS, through GitOps from `CCI-MOC/oac-apps`, with GPUs in containers and VMs. Start at [`compliance/README.md`](compliance/README.md). |

## Why it exists

The compute center will host clusters that have to pass a real assessment.
The work started on `jetty`, a sandbox hardened by hand, to learn whether
the stack could be made compliant at all. It moved on to the way OAC builds
clusters: a hub that creates hosted workload clusters, configured from
`oac-apps`, with `nist-dev-infra` as the first FIPS test hub.

The point is **transferable method**: measured numbers, reusable charts,
manifests and scripts, and a written record of the traps, so the clusters
that matter don't have to rediscover them. Experiments that would be
expensive on a production cluster are run on the test clusters first.

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
a test cluster.

## Before you run anything

No kubeconfig is in this repo, and none should be. See
[`compliance/README.md`](compliance/README.md) § Before you run anything.
