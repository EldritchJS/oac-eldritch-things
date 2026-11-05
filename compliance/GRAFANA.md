# Grafana on compliant clusters (FIPS, NIST 800-171, HIPAA)

## In short

None of FIPS, NIST 800-171 or HIPAA forbids dashboards. They ask who can see
the data, how it travels, what is logged, and what crypto protects it. Grafana
fits if it is a **window onto data that already lives in the cluster**, scoped
to one project and behind the cluster's own login, rather than a second copy of
the data with its own users.

## What each one actually asks

| | What it cares about | What that means for Grafana |
|---|---|---|
| **FIPS 140** | Cryptography uses validated modules | TLS and login go through FIPS-validated code |
| **NIST 800-171** | Access control (3.1.1, 3.1.2, 3.1.5), audit (3.3.1), encryption in transit (3.13.8), FIPS crypto for CUI (3.13.11) | Only a project's own people see its dashboards; access is logged; traffic is encrypted |
| **HIPAA Security Rule** | Access control (164.312(a)), audit controls (164.312(b)), transmission security (164.312(e)), minimum necessary (164.502(b)) | The same, plus: show the least data a user needs |

Usage metrics (CPU, GPU, memory, request counts) are usually not CUI or PHI
themselves. They become sensitive when labels or names carry tenant data, for
example a pod, model or dataset named after a patient study. So they should be
handled as if they could be.

## The design that meets them

This is how the `user-projects` chart in oac-apps already deploys Grafana, as
an opt-in per project (on today for two projects on oac-dev-workload0):

1. **One Grafana per project, not one for the cluster.** A tenant's Grafana
   lives in that tenant's namespace and shows only that tenant's data. No shared
   dashboard can leak one tenant's usage to another.
2. **Log in with the cluster's identity, not Grafana's own users.** Red Hat's
   OpenShift OAuth proxy sits in front of each Grafana, and Grafana's own login
   form is off. Who may see a project's dashboards is the same as who may see
   the project. Removing someone from the project removes their dashboard access
   too, and logins are in the cluster's audit trail. Grafana's alerting is off;
   alerts stay with the platform.
3. **Read, don't copy.** Grafana queries the cluster's monitoring stack through
   the Thanos querier's tenancy port, which only answers for the namespace the
   caller is allowed to read. The data stays where it is, under its existing
   retention, and Grafana holds no store of its own.
4. **Encrypt in transit with the platform's crypto.** Users reach Grafana
   through the cluster's router, which terminates TLS with RHEL's FIPS-validated
   OpenSSL; the router re-encrypts to Grafana.
5. **Keep sensitive data out of labels.** Project guidance: no identifiers or
   study names in pod, model or metric labels.

## Open items

- **FIPS: Grafana and its operator are upstream builds.** The operator comes
  from `community-operators` and Grafana from Docker Hub
  (`docker.io/grafana/grafana`), neither flagged FIPS-compliant. Users' TLS
  is handled by the router and Red Hat's OAuth proxy, but Grafana's own
  connection to the monitoring stack uses Grafana's Go crypto. Red Hat ships
  no Grafana operator, and its own dashboard operator (the Cluster
  Observability Operator, with Perses) is not flagged FIPS-compliant either
  (1.5.4). Options: a FIPS build of Grafana, or the OpenShift console's
  built-in dashboards, which are covered by OpenShift's FIPS support but are
  far less flexible. Red Hat's own Grafana package in a UBI image was tested
  on jetty and runs with FIPS-mode OpenSSL; see
  [GRAFANA-FIPS-IMAGE.md](GRAFANA-FIPS-IMAGE.md).
- **Exports** (image rendering, sharing links) send data outside the cluster
  and need the same review as any other outbound path.
