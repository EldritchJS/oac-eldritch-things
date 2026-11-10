# FIPS Grafana from RHEL's package, in a UBI image

How to run Grafana on compliant (FIPS) clusters without building Grafana
ourselves: install Red Hat's own Grafana RPM into a UBI 9 image. Red Hat builds
and patches Grafana; we only maintain the image around it. Tested on jetty
(OpenShift 4.22.14, FIPS on) on 2026-11-05. See also
[GRAFANA.md](GRAFANA.md).

## Why

The per-project Grafana in oac-apps' `user-projects` chart uses the upstream
image from Docker Hub (`docker.io/grafana/grafana`), which is not a FIPS build.
Users' TLS already goes through FIPS code (the router and Red Hat's OAuth proxy),
but Grafana's own connection to the monitoring stack uses Grafana's own crypto.
A hardened cluster would also refuse Docker Hub images once its allowed
registries are set (`platform-hardening` chart, `ocp4-moderate`).

Alternatives considered:

| Option | Status |
|---|---|
| Grafana Labs FIPS build | None found for self-hosted Grafana; their FedRAMP authorization covers Grafana Cloud only |
| Perses in the console (Cluster Observability Operator) | COO 1.5.4 is flagged `fips-compliant: false`; check with the COO team when that changes |
| Build Grafana with Go's FIPS module (CMVP #5247) | Works, but we would maintain the whole Grafana build |
| Chainguard `grafana-fips` and `grafana-operator-fips` | Paid, private registry; FIPS module not named on their pages |
| **RHEL's Grafana RPM in a UBI image** | **Tested, works; this document** |

## Where Grafana comes from

- **Package:** `grafana-10.2.6-23.el9_8.7.x86_64`, vendor Red Hat, Inc., built
  on `konflux.redhat.com`.
- **Repository:** RHEL 9 AppStream (`rhel-9-for-x86_64-appstream-rpms`) on
  Red Hat's CDN. It is not in the free UBI repositories, so the build needs
  Red Hat entitlement certificates.
- **Entitlement:** every OpenShift cluster has them, in secret
  `etc-pki-entitlement` in `openshift-config-managed`. Mounted at
  `/etc/pki/entitlement` during the build, with `/etc/rhsm-host` removed,
  `dnf` sees the RHEL repositories. Nothing new to buy.
- **Base image:** `registry.access.redhat.com/ubi9/ubi`.

## What the test showed

| Check | Result |
|---|---|
| Installs in UBI 9 with the entitlement mounted | Yes |
| Starts on a FIPS node | Yes; `/api/health` returned `database: ok`, no errors logged |
| Uses FIPS crypto | Yes; the running process had RHEL's OpenSSL (`libcrypto.so.3.5.8`) and the OpenSSL FIPS provider (`fips.so`) loaded, provider status `active` |
| Layout | `/usr/sbin/grafana`, `/etc/grafana/grafana.ini`, `/etc/grafana/provisioning/`, `/usr/share/grafana`, `/var/lib/grafana` |

Red Hat's Go toolchain sends Go's crypto to OpenSSL and turns FIPS mode on
when the node is in FIPS mode, so no flag is needed.

## The image

```
FROM registry.access.redhat.com/ubi9/ubi
RUN rm -f /etc/rhsm-host \
 && dnf -y install --setopt=install_weak_deps=False grafana \
 && dnf clean all \
 && chgrp -R 0 /etc/grafana /var/lib/grafana /var/log/grafana \
 && chmod -R g=u /etc/grafana /var/lib/grafana /var/log/grafana
WORKDIR /usr/share/grafana
ENTRYPOINT ["/usr/sbin/grafana", "server", "--homepath=/usr/share/grafana", "--config=/etc/grafana/grafana.ini"]
```

- The entitlement certificates are mounted only while building and are not in
  the image.
- `chgrp`/`chmod` let OpenShift run it as an arbitrary non-root user under the
  default restricted SCC.

## Building and distributing

- **Built once**, in one place, for every cluster. An OpenShift BuildConfig on
  the hub (Docker strategy, `etc-pki-entitlement` mounted at
  `/etc/pki/entitlement`) is the simplest; GitHub Actions would need a Red Hat
  activation key instead.
- **Pushed to a private registry**, for example a private quay.io
  organization. It must be private: the image contains RHEL packages, which our
  subscription lets us run but not redistribute.
- **Per cluster:** only a pull secret (External Secrets from AWS Secrets
  Manager), the registry in the cluster's allowed-registries list when
  `platform-hardening` is on, and the image name in `user-projects`.

## Fitting it to oac-apps

**Decision (2026-11-05): no Grafana operator on compliant clusters.** The
operator is a community build, not flagged FIPS-compliant, and it pushes each
project's data source, including its token, into Grafana's admin API over
plain HTTP (confirmed on oac-dev-workload0: `adminUrl`
`http://grafana-service.<project>.svc:3000`, token from `valuesFrom` into
`secureJsonData.httpHeaderValue1`). Grafana can load data sources and
dashboards from files at startup instead (provisioning), so the operator is
not needed there.

This is for compliant clusters only, not an oac-apps-wide change: the
operator and today's Grafana stay as they are on every other cluster.
On a compliant cluster:

- The `user-projects` chart deploys Grafana itself (Deployment, Service,
  Route), with the image above and the OAuth proxy it already sets.
- The data source goes in a provisioning file whose token comes from the
  project's existing secret through an environment variable, so no
  credential crosses the network.
- Dashboards go in ConfigMaps from git, mounted as dashboard provisioning
  files, which also fits "dashboards belong in git".
- The `grafana-operator` chart is not deployed to that cluster, and the
  `restrict-tenant-networks` rule that lets the operator reach port 3000 is
  not needed there.
- **Version:** RHEL ships 10.2; we run 11.3.0. Read-only projects store
  nothing and are unaffected. Editable projects keep a Grafana 11 database,
  which 10.2 cannot read, so they start fresh. Dashboards in git should be
  checked on 10.2.

### Built: oac-apps #230 (2026-11-06)

[oac-apps #230](https://github.com/CCI-MOC/oac-apps/pull/230) adds
`defaultGrafana.operator: false` to `user-projects`, with the image in
`defaultGrafana.image`. The default stays `true`, and with it every cluster
renders exactly as before. With it off, each project gets a Deployment
(Grafana and the oauth-proxy), a Service with only the proxy port, a Route,
and ConfigMaps for `grafana.ini`, the provisioning files and the dashboard.
Grafana listens on `127.0.0.1`, so nothing outside its pod reaches port
3000.

Tested on jetty (FIPS on) with RHEL's `grafana-10.2.6` in UBI 9, the chart
applied as rendered:

| Check | Result |
|---|---|
| Startup | Datasource and dashboard provisioned, no errors logged |
| FIPS | RHEL's OpenSSL and its FIPS provider loaded in the Grafana process |
| No login; a token with no access to the project | 403 at the route |
| A project member's token | Dashboard listed; both panels return data |
| Tenancy | A query across all namespaces returned only the project's; one naming another namespace was rejected by prom-label-proxy |
| Port 3000 from another pod | Unreachable |
| Secrets in ConfigMaps | None; token and CA come from the environment |

Two things only the run showed, both fixed in the chart:

- Grafana 10 sends Prometheus queries as POST, and the tenancy port
  (9092) checks a POST as `create` on pod metrics, which `view` does not
  give. Every query was refused until the datasource used GET.
- Grafana logs an error for each provisioning folder that is missing, so
  all five are mounted (three empty).

## Keeping it current

- A scheduled rebuild (weekly) that pushes only when the `grafana` package or
  UBI changed. Red Hat publishes fixed Grafana packages several times a year.
- Someone notices if the build fails (for example after the entitlement
  certificates rotate).
- When a RHEL minor release moves Grafana to a new major version, check the
  dashboards before rolling out.
- Not ours to maintain: Grafana's code, its security fixes, or its FIPS
  crypto.

## Effect on compliance

- **Compliance Operator:** no effect on its rules, which scan node and cluster
  settings. The image runs non-root under the restricted SCC. The allowed
  registries rule needs our registry listed, and it would block today's Docker
  Hub image.
- **HIPAA:** data handling is unchanged (per-project access, OAuth proxy, read
  only). Grafana's connections now use validated crypto, and fixes arrive
  through Red Hat advisories.

## After #230 merges: removing the operator

The team chose to drop the operator (2026-11-10). #230 runs every project
Grafana without it and removes `grafana-operator` from
`all-managed-clusters`. Two things Argo does not do by itself:

- `all-managed-clusters` has `preserveResourcesOnDeletion: true`, so
  removing the entry deletes each cluster's `grafana-operator` Application
  but leaves the operator installed and running, no longer managed. It has
  to be removed by hand on every managed cluster: oac-dev-workload0,
  oac-dev-workload1, oac-prod-workload0, andalusia and jetty.
- The new Grafana objects have the names the operator gave its own
  (`grafana-deployment`, `grafana-service`, `grafana-sa`). The switch in
  place was not tested: if Argo applies the new Deployment before it prunes
  the old `Grafana` resource, garbage collection may delete the new one, or
  the apply may fail on the Deployment's immutable selector. Argo's retries
  and self-heal should settle it; check below.

Only oac-dev-workload0 has project Grafana (`gavin-test`, `buit`), neither
editable, so nothing saved is lost. The route changes from `grafana-route`
to `grafana`: the URLs become `grafana-project-<name>.apps.<domain>`. Tell
the `buit` requester (hdempsey) the new URL.

Change nothing on a cluster without the owner's go-ahead.

### 1. oac-dev-workload0: check the switch

With the cluster's kubeconfig, after `user-projects` has synced:

```sh
# No operator resources left in any project: expect "No resources found".
oc get grafanas.grafana.integreatly.org,grafanadatasources.grafana.integreatly.org,grafanadashboards.grafana.integreatly.org -A

for p in gavin-test buit; do
  oc get deploy,svc,route -n project-$p | grep -i grafana
  # Expect no ownerReferences (none means Argo's, not the operator's).
  oc get deploy grafana-deployment -n project-$p -o jsonpath='{.metadata.ownerReferences}{"\n"}'
  oc get pods -n project-$p -l app=grafana
done
```

If `grafana-deployment` is missing, or the Application shows a sync error
naming the selector as immutable, delete it and let Argo recreate it:

```sh
oc delete deploy grafana-deployment -n project-<name>
```

Then the login page should answer on the new URL:

```sh
curl -sk -o /dev/null -w '%{http_code}\n' https://grafana-project-buit.apps.<domain>/   # expect 302 or 403
```

### 2. Every managed cluster: remove the operator

First confirm that no Grafana resources are left anywhere. The operator
clears its own finalizers, so removing it first would leave any remaining
ones stuck in deletion. If this lists anything, stop and find out whose it
is:

```sh
oc get grafanas.grafana.integreatly.org,grafanadatasources.grafana.integreatly.org,grafanadashboards.grafana.integreatly.org,grafanafolders.grafana.integreatly.org -A
```

Then:

```sh
oc delete subscription grafana-operator -n grafana-operator
oc delete csv -n grafana-operator -l operators.coreos.com/grafana-operator.grafana-operator
oc delete operatorgroup grafana-operator -n grafana-operator
oc delete namespace grafana-operator
```

Check that nothing is left:

```sh
oc get csv -A | grep -i grafana-operator      # expect nothing
oc get crd -o name | grep grafana.integreatly.org
```

The CRDs stay after the operator is removed. Delete them only once the
first command in this step shows no resources (deleting a CRD deletes every
resource of that kind):

```sh
oc get crd -o name | grep grafana.integreatly.org | xargs oc delete
```

Afterwards, `tests/operator-fips-inventory.md`'s count drops from six
unflagged operators to five on these clusters.

## Still open

- Registry: which private quay.io organization, and who holds the robot account.
- Where the build runs (the hub is suggested).
- Whether editable projects starting fresh on 10.2 is acceptable.
- Setting the UBI image on compliant clusters (the default stays
  `docker.io/grafana/grafana:11.3.0`).
- Check COO/Perses FIPS status with the COO team; if it is close, Perses may be the
  better long-term route.
