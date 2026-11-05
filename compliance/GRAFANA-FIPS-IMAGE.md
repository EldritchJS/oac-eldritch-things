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
| Perses in the console (Cluster Observability Operator) | COO 1.5.4 is flagged `fips-compliant: false`; ask Red Hat when that changes |
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

- Set the image (and, if needed, the command) in the `user-projects` chart's
  Grafana deployment override, alongside the OAuth proxy it already sets.
- Check on a test cluster that the Grafana operator can still configure it:
  data source, dashboards, OAuth proxy. This is the main unknown.
- **Version:** RHEL ships 10.2; we run 11.3.0. Read-only projects store
  nothing and are unaffected. Editable projects keep a Grafana 11 database,
  which 10.2 cannot read, so they start fresh. Dashboards in git should be
  checked on 10.2.

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

## Still open

- Registry: which private quay.io organization, and who holds the robot account.
- Where the build runs (the hub is suggested).
- Whether editable projects starting fresh on 10.2 is acceptable.
- The Grafana operator itself is still the community build. Decide whether a
  component that only manages Grafana, and holds no tenant data, is in scope.
- Ask Red Hat about COO/Perses FIPS status; if it is close, Perses may be the
  better long-term route.
