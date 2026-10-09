#!/usr/bin/env python3
"""Probe what TLS a set of endpoints actually accepts.

Usage: tls-probe.py name=host:port [name=host:port ...]

Writes one tab-separated line per endpoint and probe:

    <name>  <probe>  ACCEPTED|REFUSED|ERROR  <detail>

REFUSED means the SERVER rejected the handshake with a TLS alert. Anything
else (connection failure, a local OpenSSL that cannot offer the protocol) is
ERROR, never REFUSED: a probe that could not be made must not read as a pass.

Probes:
  tls13        TLS 1.3, default suites               expect ACCEPTED
  tls12-gcm    TLS 1.2, ECDHE + AES-GCM              expect ACCEPTED
  tls10        TLS 1.0                               expect REFUSED
  tls11        TLS 1.1                               expect REFUSED
  tls12-cbc    TLS 1.2, ECDHE + AES-CBC              expect REFUSED
  tls12-chacha TLS 1.2, ECDHE + ChaCha20-Poly1305    expect REFUSED (not FIPS)
  tls12-rsakx  TLS 1.2, static RSA key exchange      expect REFUSED (no PFS)

No certificate verification: this measures what is offered, not who is
offering it. Read-only — handshakes only.
"""
import socket
import ssl
import sys
import warnings

warnings.simplefilter("ignore", DeprecationWarning)   # TLSv1/1.1 enum access
V = ssl.TLSVersion

PROBES = [
    ("tls13", V.TLSv1_3, None),
    ("tls12-gcm", V.TLSv1_2, "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:"
                             "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384"),
    ("tls10", V.TLSv1, "ALL:@SECLEVEL=0"),
    ("tls11", V.TLSv1_1, "ALL:@SECLEVEL=0"),
    ("tls12-cbc", V.TLSv1_2, "ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:"
                             "ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384"),
    ("tls12-chacha", V.TLSv1_2, "ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305"),
    ("tls12-rsakx", V.TLSv1_2, "AES128-GCM-SHA256:AES256-GCM-SHA384"),
]

# Server-sent alerts that mean "I will not negotiate this".
REFUSAL_REASONS = {
    "TLSV1_ALERT_PROTOCOL_VERSION",
    "SSLV3_ALERT_HANDSHAKE_FAILURE",
    "TLSV1_ALERT_INSUFFICIENT_SECURITY",
    "NO_SHARED_CIPHER",
}


def probe(host, port, version, ciphers):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.minimum_version = ctx.maximum_version = version
        if ciphers:
            ctx.set_ciphers(ciphers)
    except (ValueError, ssl.SSLError) as e:
        return "ERROR", f"local client cannot offer this: {e}"
    try:
        with socket.create_connection((host, port), timeout=5) as s, \
                ctx.wrap_socket(s, server_hostname=host) as t:
            return "ACCEPTED", f"{t.version()} {t.cipher()[0]}"
    except ssl.SSLError as e:
        if e.reason in REFUSAL_REASONS:
            return "REFUSED", e.reason
        return "ERROR", e.reason or str(e)
    except OSError as e:
        return "ERROR", type(e).__name__


def main(argv):
    for arg in argv:
        name, hostport = arg.split("=", 1)
        host, port = hostport.rsplit(":", 1)
        for pname, version, ciphers in PROBES:
            result, detail = probe(host, int(port), version, ciphers)
            print(f"{name}\t{pname}\t{result}\t{detail}")


if __name__ == "__main__":
    main(sys.argv[1:])
