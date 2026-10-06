# Certificate drop point

`kustomize build` of the parent directory **will fail** until `pure-ca.crt`
exists here. That is intentional — a missing or wrong trust anchor means
`tlshd` fails every handshake, and failing at build time is better than
discovering it when mounts break.

## What to put here

`pure-ca.crt` — the certificate `tlshd` should trust when connecting to the
jetty FlashBlade.

**The CN or a SAN must match the NFS data VIP.** Mounts target the array by
IP address and send that address as the TLS SNI, so a certificate naming only
a hostname will fail validation even though everything else is correct.

If the array uses a self-signed certificate, this is that certificate. If it
is issued by an internal CA, this is the CA certificate.

## Do not commit the private key

Only the public certificate belongs here. A certificate is public by design
and safe in this public repo; the corresponding key never leaves the array.
The repo `.gitignore` already blocks `*credentials*`, `*.env`, and secret
files, but it cannot catch a `.key` you add deliberately — don't.

## Verify before deploying

```sh
openssl x509 -in pure-ca.crt -noout -subject -issuer -dates -ext subjectAltName
```

Check that the subject/SAN covers the data VIP and that `notAfter` is far
enough out that an expiry will not take storage down unannounced. Put the
expiry date somewhere you will actually see it.
