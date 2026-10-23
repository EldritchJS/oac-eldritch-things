# Hub storage: the steps, and ways to streamline them

On OAC hubs, the default StorageClass comes from Portworx on a Pure
FlashBlade. These are the steps it takes, as learned on nist-dev-infra.

## The steps

| # | Step | Repo or place | Owner (role) |
|---|---|---|---|
| 1 | A FlashBlade realm for the hub | `CCI-MOC/everpure-moc`, `realms.yaml` | FlashBlade admins |
| 2 | The realm playbook, which writes `cluster/<hub>/portworx` to AWS Secrets Manager | Run by hand; needs the FlashBlade admin token | FlashBlade admins |
| 3 | The hub's signing keys published to S3, and its `serviceAccountIssuer` set to match | `oac-apps/bootstrap/setup-oidc.sh`; needs S3 write | Hub owner |
| 4 | An AWS identity for the hub's external-secrets: an OIDC provider and the `eso-<hub>` role. AWS reads the hub's OIDC document (step 3) when it creates the provider | `CCI-MOC/moc-aws`, `openshift_oidc_clusters` | moc-aws maintainers |
| 5 | The storage VLAN (untagged) on each node's second port, reaching the DHCP server, the gateway and the FlashBlade | Switch configuration | Network admins |
| 6 | The hub's values: `external-secrets.yaml` (role) and `portworx.yaml` (nodes, ports, storage subnet, and `tls: true`, which also picks the TLS export policy since CCI-MOC/oac-apps#179) | `CCI-MOC/oac-apps` | Hub owner, oac-apps reviewers |
| 7 | NFS over TLS: the realm certificate in `cluster/<hub>/nfs-tls-ca`, and `nfs-tls.yaml` (`tlshd` on every node) with `storageClass.enabled: false` | AWS Secrets Manager; `CCI-MOC/oac-apps` | Hub owner; the certificate from the FlashBlade admins |

Steps 1, 3 and 5 can start on day one. Step 2 follows 1, and step 4
follows 3. Step 6 can merge at any point, but the Portworx sync only
succeeds once 2, 4 and 5 are done. Step 7 follows 2 (the certificate comes
from the realm), and merges with step 6 or before it.

Steps 6 and 7 go together because the first volume decides everything
after it. A node with a cleartext NFS mount to the FlashBlade reuses that
session for later TLS mounts, which then fail. If the cleartext class is
ever the default, the hub's components put their volumes on it, and they
have to be recreated on a TLS class (BUILD.md, "Storage is TLS-only
from its first volume").

## Ways to streamline

- **Request steps 1, 3 and 5 together,** when the hub is planned, from one
  tracking issue that links each PR. The checklist is in BUILD.md, "Hub
  infrastructure".
- **Check each step the same way,** with `tests/hub-preflight.sh <hub>`.
  It covers steps 2 to 7, read-only.
- **Set `serviceAccountIssuer` at install** (BUILD.md Part 1 step 2).
  Then `setup-oidc.sh` only uploads keys, and the hub does not need to
  restart its pods.
- **Share FlashBlade access** among more than one admin, each with their own
  account, with the playbook's token in a shared, audited store (BUILD.md
  P11).
- **Request a named reviewer** on each prerequisite PR.
- **Merge the values PRs (steps 6 and 7) last,** or re-sync `hub-portworx` once
  the preflight passes. ArgoCD does not retry a failed sync of the same
  commit.
- **Have the realm playbook store the certificate** in
  `cluster/<hub>/nfs-tls-ca`, as it already stores `cluster/<hub>/portworx`.
  Step 7 then needs no hand-off, and a re-run keeps the two in step.
