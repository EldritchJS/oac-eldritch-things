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
| Starts on a FIPS node | Yes; `/api/health` returned `database: ok`, no errors logged. Re-confirmed 2026-11-25 on compliant-dev-workload0 from `ghcr.io/cci-moc/grafana-fips`, run the way the chart runs it: 1/1 Running, readiness probe passing, as UID 1000 in group 0 under the restricted SCC |
| Uses FIPS crypto | Yes; the running process had RHEL's OpenSSL (`libcrypto.so.3.5.8`) and the OpenSSL FIPS provider (`fips.so`) loaded, provider status `active` |
| Layout | `/usr/sbin/grafana`, `/etc/grafana/grafana.ini`, `/etc/grafana/provisioning/`, `/usr/share/grafana`, `/var/lib/grafana` |

Either way no flag is needed: FIPS follows the node. **How it follows the
node changed between builds**, so check it again whenever the package
moves.

| | jetty, 2026-11 (`grafana-10.2.6-23.el9_8.7`) | compliant-dev-workload0, 2026-11-25 (`grafana-10.2.6-24.el9_9.9`) |
|---|---|---|
| Mechanism | Red Hat's Go toolchain routed Go's crypto to OpenSSL | Go's own FIPS 140-3 Cryptographic Module |
| Evidence | `libcrypto.so.3.5.8` and `fips.so` loaded, provider `active` | Built with go1.27.3, `GOFIPS140=v1` and `fips140=auto` in the binary; **no** libcrypto or libssl mapped into the running process |
| Switches on because | the node is in FIPS mode | `fips140=auto` reads the node's FIPS mode (`/proc/sys/crypto/fips_enabled` is 1) |

Both are valid FIPS stories, but they rest on **different CMVP certificates**:
the RHEL OpenSSL module in the first case, Go's Cryptographic Module in the
second. **TODO:** record the Go module's certificate in
[tests/fips-cmvp-certificates.md](tests/fips-cmvp-certificates.md), which
today only covers RHEL's OpenSSL, and re-check after any package bump. The
`verify.sh` T-02 WARN about the OpenSSL provider version does not cover a
binary that no longer uses OpenSSL.

**One trap when testing it by hand.** The RPM's stock `/etc/grafana/grafana.ini`
leaves `paths.data` commented out, so Grafana falls back to
`<homepath>/data` = `/usr/share/grafana/data`, which is root-owned and not
group-writable: a bare `podman run` or `oc run` fails with
`failed to connect to database: mkdir /usr/share/grafana/data: permission denied`.
That is not a fault in the image. The RPM's systemd unit passes
`cfg:default.paths.*`, and the `user-projects` chart does the equivalent by
mounting its own `grafana.ini` with `data = /var/lib/grafana` and an emptyDir
there. Test it the way the chart runs it, or the result is misleading.

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

**Built and published since 2026-11-25** by
[CCI-MOC/grafana-fips](https://github.com/CCI-MOC/grafana-fips), in the same
shape as [CCI-MOC/tlshd](https://github.com/CCI-MOC/tlshd): a GitHub Actions
workflow registers with MOC's Red Hat subscription through BuildKit secret
mounts, installs the package from RHEL 9 AppStream, then unregisters and
cleans, so neither the credentials nor the entitlement certificates are in
any layer. The Containerfile there is this document's, moved off the
in-cluster BuildConfig form (no `/etc/pki/entitlement` mount) and running as
UID 1001.

It needs two repository secrets, `RHEL_ORG_ID` and `RHEL_ACTIVATION_KEY`.
An unset key still passes the Containerfile's `-s` guard, because the
workflow writes a one-byte file, and the build then fails at
"Must specify an activation key"; that is what it looks like when the
secret is missing.

- **Per cluster:** the image name in `user-projects` (`defaultGrafana.image`,
  pinned by digest) and the registry in the allowed-registries list.
  `ghcr.io/cci-moc` is already allowed on compliant-dev-infra and its
  clusters, so oac-apps #297 is only the values file.

**On the image being public.** It holds RHEL packages installed with MOC's
subscription, and the subscription covers running them, not redistributing
them, so requiring authentication to pull is the intended end state: make
the package private and give the clusters a pull secret through External
Secrets. That is **deferred and recorded as an accepted exception**
(MOC-issues #780, decided 2026-11-24), as it is for `ghcr.io/cci-moc/tlshd`
and for larsks' own public tlshd image before it.

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

### What happened (2026-11-10)

#230 merged as 44d85eb. Done on every dev cluster; oac-prod-workload0
followed on 2026-11-16 (below).

- On oac-dev-workload0 the sync failed as feared: patching the new
  Deployment over the operator's gave `readinessProbe.httpGet: Forbidden:
  may not specify more than 1 handler type`, five times, and stopped, so
  the old `Grafana` resources were never pruned. Fix: delete them by full
  name, `oc delete grafanas.grafana.integreatly.org grafana -n
  project-<name>` (plain `grafana` matches external-secrets' Grafana
  generator first), then start a new sync.
- Deleting them also removed the operator's `grafana-sa`, and with it the
  token secret Argo had made for it. The next sync then hung: the token
  secret was in sync wave 1 and the Deployment that needs it in wave 0,
  and Argo starts a wave only once the one before is healthy. That is a
  bug in #230's chart, missed because the jetty test applied it by hand;
  oac-apps #238 moves the secret into the Deployment's wave. Until it
  merges, the two secrets on oac-dev-workload0 were created by hand, as
  the chart defines them.
- To stop a hung sync: `oc patch applications.argoproj.io <app> -n
  openshift-gitops --type merge -p
  '{"status":{"operationState":{"phase":"Terminating"}}}'` (the
  Application has no status subresource), then start one with
  `-p '{"operation":{"initiatedBy":{"username":"<you>"},"sync":{"prune":true}}}'`.
- After that, both project Grafanas ran on the new URLs (403 without a
  login), and the operator was removed from oac-dev-workload0, 1, 2,
  andalusia and jetty with step 2 below, deleting the CSV by name,
  `grafana-operator.v5.25.0`.

### oac-prod-workload0 (2026-11-16)

Removed through the production change process:
[ops-docs #55](https://github.com/CCI-MOC/ops-docs/pull/55), approved by
larsks and memalhot. Run at about 12:30 Eastern, ahead of the scheduled
13:00 because of a conflict; noted on the PR. No Grafana resources were
on the cluster beforehand; afterwards no `grafana-operator` CSV, no
`grafana.integreatly.org` CRDs (13 deleted) and no `grafana-operator`
namespace.

On this cluster `oc delete subscription` resolved to ACM's
`subscriptions.apps.open-cluster-management.io` and found nothing;
deleting the namespace removed the OLM Subscription. Step 2 now names
`subscriptions.operators.coreos.com`.

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
oc delete subscriptions.operators.coreos.com grafana-operator -n grafana-operator
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
