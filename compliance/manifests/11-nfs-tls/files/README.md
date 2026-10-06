# Certificate drop point

`kustomize build` of the parent directory **will fail** until `pure-ca.crt`
exists here. That is intentional — a missing or wrong trust anchor means
`tlshd` fails every handshake, and failing at build time beats discovering it
when mounts break.

## Why it isn't in the repo

`pure-ca.crt` is **deliberately gitignored.** Not because it is secret — an
X.509 certificate is public key material whose purpose is distribution — but
because the FlashBlade's certificate carries the **NFS data VIP in its
subject**, and this repo redacts internal addresses (top-level README
§ Conventions). You cannot redact a certificate without breaking it, so it
stays out of version control.

Consequence: a clean clone needs this one manual step before `oc apply -k`.

## Obtaining it

Get it from the Purity//FB UI or API, or from whoever administers the array.

> `openssl s_client -connect <data-vip>:2049` will **not** work. RPC-with-TLS
> (RFC 9289) upgrades an already-established RPC connection rather than
> starting with a TLS handshake, so there is nothing for `s_client` to talk
> to on that port.

## What it must satisfy

The **CN or a SAN must match the NFS data VIP**. Mounts target the array by IP
and send that address as the TLS SNI, so a certificate naming only a hostname
fails validation even when everything else is correct.

If the array uses a self-signed certificate, this is that certificate. If it
is issued by an internal CA, this is the CA certificate.

## Verify before deploying

```sh
openssl x509 -in pure-ca.crt -noout -subject -issuer -dates
openssl x509 -in pure-ca.crt -noout -ext subjectAltName -ext basicConstraints
grep -c "PRIVATE KEY" pure-ca.crt    # must be 0
```

Check the subject or SAN covers the data VIP, and that `notAfter` is far
enough out that an expiry will not take storage down unannounced. **Put that
expiry date somewhere you will actually see it** — a silently expired storage
certificate is a cluster-wide outage with a confusing error message.

### Known quirks of the cert currently in use (verified 2026-10-06)

Both also present in the reference implementation that is known to work in
this environment, so neither is expected to block — but if the TLS handshake
fails verification, look here first rather than at the daemon:

- **No SAN.** The subject carries the VIP as CN only. Strict verifiers
  normally require an `iPAddress` SAN when the target is an IP.
- **`CA:FALSE`.** It is a self-signed *leaf* installed directly as a trust
  anchor, not a CA certificate.

Asking Pure to reissue with an `iPAddress` SAN would remove both doubts.
