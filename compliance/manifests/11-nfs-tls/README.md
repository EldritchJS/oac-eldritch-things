# 11 — NFS over TLS (`tlshd`)

**Status: NOT DEPLOYED. Blocked on Phase 0 (storage team).**

Closes the cleartext-storage gap described in [../../NFS-TLS.md](../../NFS-TLS.md)
(800-171 3.13.8 / SC-8). The kernel on this cluster already supports
RPC-over-TLS; the only missing piece is the `tlshd` userspace daemon, supplied
here by a DaemonSet.

Adapted for jetty from a colleague's working implementation in this
environment. That repo is the upstream reference and is **not** vendored here.

---

## Placeholders — this will not apply until these are filled in

Four values must come from the storage team. Each is marked `REPLACE-ME` in
the manifests, and `kustomize build` **fails loudly** until the certificate
exists — deliberately, because a wrong trust anchor is worse than none.

| Placeholder | Where | What it is |
|---|---|---|
| `files/pure-ca.crt` | missing file | The jetty FlashBlade's CA / server cert. **CN or SAN must match the NFS data VIP** — mounts target it by IP and send that as SNI, so a hostname-only cert fails validation. |
| `REPLACE-ME-tls-export-policy` | `storageclass.yaml` | Pure export policy with TLS enabled. The current `export-policy` is the **cleartext** one. |
| `REPLACE-ME-tls-nfs-server` | `storageclass.yaml` | Pure NFS server name for the TLS endpoint. Current `nfs-server` is cleartext. |
| `REPLACE-ME-IMAGE` | `daemonset.yaml` | Set by the ImageStream once built (Phase 1), or an external registry ref. |

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
oc get secret etc-pki-entitlement -n openshift-config-managed -o yaml \
  | sed 's/namespace: openshift-config-managed/namespace: nfs-tls/' \
  | oc apply -f -
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
