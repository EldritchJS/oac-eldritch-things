# Example: a compliant hub

How a hub is made compliant with the charts on the fork's
`compliance-charts` branch. Compliance is a property of the **hub**: a
compliant hub carries only compliant hosted clusters, and a non-compliant
hub carries none (their control planes, etcd and audit logs would live on
it). So nothing here is switched per cluster, and a non-compliant hub needs
no files at all.

| File | Goes to | Does |
|---|---|---|
| `apps-compliance.yaml` | `apps/<hub>/compliance.yaml` | Two ApplicationSets: the compliance charts on the hub, and the in-cluster ones on **every** cluster the hub manages |
| `hosted-clusters-values.yaml` | merged into `hosted-clusters/<hub>/values.yaml` | FIPS, node hardening, audit and registry settings, inherited by every hosted cluster on the hub |
| `values.yaml` | split into `values/<hub>/...` | Chart values for the hub and for its hosted clusters |

The hub refuses a hosted cluster that drops any of it: `compliance-hub-policy`
rejects a HostedCluster without FIPS, the audit profile or secret
encryption, and a NodePool without the node-hardening ConfigMap, whatever
git or a person asks for.

Names use `oac-dev-infra` as the hub; substitute the real one.
