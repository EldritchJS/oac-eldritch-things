# jetty's compliance work as oac-apps charts: the proof

Step 2 of [HUB-SPOKE.md](../HUB-SPOKE.md) packaged jetty's manifests as Helm
charts for [CCI-MOC/oac-apps](https://github.com/CCI-MOC/oac-apps). **The
charts live in the fork**, not here:

| Where | What |
|---|---|
| [EldritchJS/oac-apps](https://github.com/EldritchJS/oac-apps), branch `compliance-charts` | Nine new charts and `scripts/export-remediations.py`. Adds files only; changes nothing existing. A proposal: to be discussed with the oac-apps maintainers before any PR |
| same fork, branch `hosted-cluster-nodepool-config` | `NodePool.spec.config`, API server audit and image config on the `hosted-cluster` chart. Renders identically for every existing cluster; a PR candidate on its own |
| this directory | The evidence that the charts reproduce jetty, and the pieces that are not in the fork (below) |

Both branches are based on oac-apps `62a149e`. As of 2026-10-13 they are
local only, not yet pushed.

jetty was built by hand, once; that approach will not be repeated. So the
charts are written for clusters built from oac-apps, not for adopting jetty.
jetty is used here only as a real cluster to check the charts against.

Compliance is switched per **hub**, never per workload cluster: a compliant
hub carries only compliant hosted clusters, and a non-compliant hub carries
none (HUB-SPOKE.md §2, "Compliant and non-compliant hubs"). The ninth chart,
`compliance-hub-policy`, makes a compliant hub refuse a non-compliant
HostedCluster or NodePool.

## What is here

| Path | What |
|---|---|
| `values/oac-dev-infra/jetty/` | Values that point each chart at jetty's settings. Kept out of the fork: jetty is not a managed cluster |
| `patches/0001-*.patch` | `cluster-certificates`: audit and encryption on the APIServer object. **On hold** until its owner is asked (see below) |
| `examples/compliant-hub/` | Everything a compliant hub adds: the `apps/<hub>/` drop-in (hub and every managed cluster), hub-wide hosted-cluster values, chart values. A non-compliant hub adds nothing |
| `scripts/validate.sh` | Renders the fork's charts with jetty's values and runs `oc diff` against jetty |

## The proof

`oc diff` sends each rendered object to the API server as a dry run and
shows what applying it would change. It changes nothing. An empty diff
means the chart produces what jetty already runs.

### Run 1: charts with adoption workarounds (2026-10-13)

The first version of the charts could take over jetty's existing objects.
Every chart matched jetty. The only differences were ArgoCD's sync
annotations, plus `autoApplyRemediations: false` and
`autoUpdateRemediations: false` written explicitly on the ScanSetting (the
default, made explicit). That covered:

| Chart | Objects | From |
|---|---|---|
| `compliance-node-hardening` | 382: 379 Compliance Operator MachineConfigs, 2 sshd `AllowUsers`, the MachineConfiguration disruption policy | the operator's applied remediations, `manifests/21-*` |
| `compliance-operator` | 8 | `01`, `03`, `06`, `13` |
| `etcd-backup` | 5 | `15` |
| `file-integrity` | 4 | `20` |
| `namespace-guardrails` | 34: 27 NetworkPolicies, 7 ResourceQuotas | `17`, `18`, `22` |
| `nfs-tls` | 5 | `11-nfs-tls/`, minus the image build |
| `platform-hardening` | 3 | `14`, `16` |
| `rhacs` | 7 | `02`, `04`, `05`, `19` |

### Run 2: the charts in the fork (2026-10-13)

The adoption workarounds were then removed, so the charts follow oac-apps'
own conventions (`operator-library` for OperatorGroups and, where no labels
are needed, Namespaces). Against jetty, `oc diff` now shows exactly those
removals and nothing else:

| Chart | Difference from jetty | Why |
|---|---|---|
| `compliance-operator` | A second OperatorGroup, `openshift-compliance` | `operator-library` names it after the namespace; jetty's is `compliance-operator`. On jetty, two OperatorGroups would stop OLM. On a cluster built from the charts there is only one |
| `file-integrity` | Same, `openshift-file-integrity` | Same |
| `rhacs` | `rhacs-operator` namespace loses its labels | `operator-library.namespace` writes none; jetty's came from a hand `oc apply` |
| `nfs-tls` | Two description annotations | They now link to this repo on GitHub |
| the other four | ArgoCD annotations only | — |

Alongside, with `patches/0001` applied: `helm-lint-all.sh` passes, and
`helm-unittest-all.sh` passes 363 tests across 24 charts.

To run it again (helm 3, the helm-unittest plugin for the tests, `oc`
logged in to jetty):

```
scripts/validate.sh ~/oat/oac-apps --diff-jetty
```

with the fork checked out on `compliance-charts`. Diffs land in `.render/`
(not tracked).

## What the jetty check caught

Found by diffing against a real cluster; all fixed in the fork:

- **ArgoCD fights over the APIServer object.** oac-apps' `cluster-certificates`
  chart hard-codes `audit.profile: Default`. With self-heal on, it would undo
  `WriteRequestBodies` within minutes, and a second chart cannot own the same
  object without the two Applications fighting. Hence `patches/0001`.
- **Helm's `with` skips an empty map.** `namespace-guardrails` silently
  dropped deny-only namespaces (`ingress: {}`). Four policies missing; caught
  by counting objects against the manifests.
- **ACS rewrites policy scopes.** Its config-controller fills in empty label
  selectors, which ArgoCD would show as a difference forever. The chart's
  values say to write them out.
- **Helm merges maps.** `nodeSelector: {}` does not clear a default
  selector; `null` does. Mattered for the hosted-cluster example, where a
  master selector would leave the scan result server unschedulable.

## Not in the fork, and why

- **jetty-only manifests:** `07` (CNV host devices), `08` (GPU-switch RBAC),
  `10` (storage NNCP, with addresses), `12` (CDI StorageProfile), `23` (ACS
  route rate limits), the canaries, and the tlshd BuildConfig (a fleet
  should pull one published, scanned image, not build on every cluster).
- **`patches/0001` (`cluster-certificates`):** changes what an existing
  oac-apps chart owns. Its defaults render what it renders today, but
  whether audit settings belong in that chart is the maintainers' call.
- **`examples/compliant-hub/`:** per-hub files, and which hub is compliant
  is a decision, not a default. The `cluster-certificates` part of
  `values.yaml` needs `patches/0001`. Rendered on 2026-10-13 against both
  fork branches plus `patches/0001`: `oac-dev-workload0` with the hub-wide
  values comes out with FIPS, `WriteRequestBodies`, secret encryption, an
  image allowlist and the hardening ConfigMap on both NodePools, which is
  what `compliance-hub-policy` checks.

## Not verified: needs a hub and a hosted cluster (HUB-SPOKE.md §7)

- `compliance-hub-policy` against real HyperShift objects. Its CEL was
  accepted by jetty's API server (a dry run; jetty has no HyperShift types,
  so field names were not type-checked). Start it with
  `validationActions: [Warn, Audit]`.
- **E1:** what the Compliance Operator reports inside a hosted cluster.
- **E2:** whether a NodePool accepts the merged node-hardening ConfigMap
  (188 rules, about 88 KB), and how `InPlace` upgrades roll it out.
- The API server port that egress NetworkPolicies must allow inside a
  hosted cluster (6443 on jetty).
- The chrony remediation points nodes at `pool.ntp.org`, the profile's
  default. MOC may want its own servers: tailor `var-multiple-time-servers`
  first.
