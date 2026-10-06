# 11 — NFS over TLS (`tlshd`)

**Status: DEPLOYED and running. Blocked on one thing — the FlashBlade
certificate has no `iPAddress` SAN, so every TLS handshake is rejected.**

As of 2026-10-06 everything on the cluster side works:

- Image built in-cluster from the cluster's own RHEL entitlement
  (`ktls-utils-0.11-3.el9_6`), pushed to `ghcr.io/eldritchjs/tlshd`, pinned by
  digest in `daemonset.yaml`.
- `tlshd` DaemonSet is 2/2 Ready on both workers, trust anchor installed.
- `nfs-over-tls` StorageClass provisions successfully — a PVC **Bound**.

The mount then fails, and `tlshd` says exactly why:

```
tlshd[24]: Certificate owner unexpected.
tlshd[24]: Handshake with '<fb-data-vip>' (<fb-data-vip>) failed
```

**The array is presenting its default Pure self-signed certificate, which has
no Subject Alternative Name.** GnuTLS requires an `iPAddress` SAN to verify a
peer addressed by IP; it does **not** fall back to the CN. Compare with the
cert from the reference deployment that works:

| | SAN |
|---|---|
| Reference array (works) | `X509v3 Subject Alternative Name: IP Address:<its-vip>` |
| jetty FlashBlade (fails) | `No extensions in certificate` |

Note the issuers differ too: the working one was issued by the site
(`OU = Mass Open Cloud`), ours is the vendor default (`O = Pure Storage, Inc.`).
Someone generated a proper certificate for that other array; the same needs to
happen here.

### The ask for the storage team

> Reissue the FlashBlade NFS certificate with
> `subjectAltName = IP:<nfs-data-vip>`.
> The current default self-signed certificate has no SAN, so clients that
> address the array by IP cannot verify it.

Nothing else is known to be missing. Drop the new cert in as
`files/pure-ca.crt`, `oc apply -k .`, and the mount should complete.

Closes the cleartext-storage gap described in [../../NFS-TLS.md](../../NFS-TLS.md)
(800-171 3.13.8 / SC-8). The kernel on this cluster already supports
RPC-over-TLS; the only missing piece is the `tlshd` userspace daemon, supplied
here by a DaemonSet.

Adapted for jetty from a colleague's working implementation in this
environment. That repo is the upstream reference and is **not** vendored here.

---

## Remaining prerequisites

| Item | Where | Status |
|---|---|---|
| TLS export policy | `storageclass.yaml` | ✅ `export-policy-tls` (2026-10-06) |
| TLS NFS server name | `storageclass.yaml` | ✅ `nfs-server` — unchanged from the cleartext class |
| FlashBlade certificate | `files/pure-ca.crt` | ⚠️ **gitignored, supply locally** — see [files/README.md](files/README.md) |
| Container image | `daemonset.yaml` | ❌ `REPLACE-ME-IMAGE` — set after Phase 1 |

`kustomize build` **fails loudly** until the certificate is in place.
Deliberate: a missing or wrong trust anchor is worse than not deploying.

The certificate is not committed because its subject carries the NFS data
VIP, and this repo redacts internal addresses (top-level README
§ Conventions). A clean clone therefore needs that one manual step.

---

## Order of operations

### Phase 1 — build the image into a registry you own

Do **not** deploy a privileged host-network DaemonSet from an unowned
registry. It would also force that registry into `allowedRegistries`, which
collides with the stage 3 work in FEASIBILITY.md §3.

This cluster already has the RHEL entitlement secret, so an in-cluster build
works without a personal activation key. Copy it into the build namespace:

```sh
oc apply -f namespace.yaml

# Copy the entitlement secret. Do NOT use `oc apply` -- it stores the whole
# object in the last-applied-configuration annotation, and entitlement.pem is
# ~325KB base64, over the 256KB annotation limit:
#   "metadata.annotations: Too long: may not be more than 262144 bytes"
# `oc create` adds no such annotation, but rejects server-side metadata, so
# strip it first.
oc get secret etc-pki-entitlement -n openshift-config-managed -o json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin); m=d['metadata']
for k in ('resourceVersion','uid','creationTimestamp','managedFields',
          'annotations','ownerReferences','selfLink','generation'):
    m.pop(k,None)
m['namespace']='nfs-tls'
print(json.dumps(d))" \
  | oc create -f -

oc apply -f imagestream.yaml -f buildconfig.yaml
oc start-build tlshd -n nfs-tls --follow
```

> **Unvalidated step.** `ktls-utils` is almost certainly not in the UBI repos,
> which is why the reference build registers a subscription. The entitlement
> volume here should make it resolvable, but this has not been run on this
> cluster. If `dnf` cannot find the package, add an explicit RHEL repo file to
> the inline Dockerfile pointing at `cdn.redhat.com` with
> `sslclientcert=/etc/pki/entitlement/*.pem`. Treat the first build as the
> test of this assumption.

If you would rather push to an org-owned quay repo, skip the ImageStream and
BuildConfig and set `REPLACE-ME-IMAGE` directly. `quay.io` is already in use
cluster-wide, so it needs no new allowlist entry. The internal registry is
currently `managementState: Removed`, and its only possible backing store here
is NFS, which Red Hat does not recommend for the registry — fine for a
sandbox, do not carry it to a cluster under assessment.

### Phase 2 — deploy

```sh
kustomize build . | oc apply -f -      # or: oc apply -k .
oc rollout status ds/tlshd -n nfs-tls
```

### Phase 3 — prove it, two ways

A successful mount proves the mount worked, **not** that it is encrypted.
Check both:

```sh
# 1. the mount actually carries xprtsec
oc debug node/<worker> -q -- chroot /host grep xprtsec /proc/mounts

# 2. the wire is actually TLS
oc debug node/<worker> -q -- chroot /host \
  timeout 20 tcpdump -i any -nn -c 50 'host <fb-data-vip> and port 2049'
# expect: TLS handshake, then Application Data -- not readable NFS ops
```

### Phase 4 — the part people skip

- **Existing PVCs stay cleartext.** `mountOptions` is immutable, so
  `pure-fb-nfsv4` cannot be upgraded in place. Every existing volume needs a
  new PVC on `nfs-over-tls` and a data copy. This is the bulk of the work.
- **Document the ACS exception** for the privileged DaemonSet rather than
  silencing the policy.
- **Add a `verify.sh` check** asserting `tlshd` is Running on every eligible
  node *and* that TLS-backed mounts carry `xprtsec`. Without it this
  regresses silently — which is exactly how the gap went unnoticed to begin
  with, since no scanner inspects CSI mount options.

---

## Deliberate differences from the reference implementation

| Change | Why |
|---|---|
| `nodeSelector: worker` | Masters carry the control-plane taint and mount **zero** NFS (measured). Running a privileged host-network pod there buys nothing and widens the blast radius. To extend later, drop the selector and add a control-plane toleration. |
| `priorityClassName: system-node-critical` | This sits in the storage data path. On reboot nothing can mount a TLS volume until `tlshd` is up, and `remediate.sh` stage 2 reboots every node serially. |
| liveness + readiness probes | The reference has neither. If `tlshd` dies, mounts fail with `ESRCH` and nothing notices. |
| resource requests/limits | Required for a predictable QoS class on a node-critical daemon. |
| `seccompProfile: RuntimeDefault` | Still `privileged: true` (unavoidable — it needs the host network namespace and the kernel handshake upcall), but no reason to also waive seccomp. |
| Built in-cluster from entitlement | Removes the personal-registry dependency and the activation-key handling. |
