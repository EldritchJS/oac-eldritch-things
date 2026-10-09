#!/usr/bin/env bash
# Rate-limit the routes outside openshift-*/kube-* (800-53 SC-5; closes
# jetty-ocp4-moderate-routes-rate-limit). On jetty the only such routes are
# ACS Central's two, both TLS passthrough, so only the TCP limits apply
# (HTTP request-rate limits need HAProxy to see HTTP).
#
# A script, not a Route manifest: the routes are owned by the ACS Central CR
# and reconciled by its operator, so a declarative Route would fight it.
# Measured 2026-10-09: the operator KEEPS added annotations -- restarting it
# forced a full reconcile and both routes kept them (generation unchanged).
# An ACS operator upgrade could still re-render the routes; the nightly
# compliance scan would then fail routes-rate-limit again, which is the
# signal to re-run this. Idempotent.
#
# Limits are per source IP: 100 concurrent TCP connections, 100 new
# connections per 3 s. The UI multiplexes over HTTP/2, so a browser holds a
# handful of connections; users behind one NAT share the budget.
# Verified in the router's haproxy.config (be_tcp:stackrox:central*):
#   tcp-request content reject if { src_conn_cur ge 100 }
#   tcp-request content reject if { src_conn_rate ge 100 }
#
# route-ip-whitelist (F5) is NOT done here: it needs the source ranges people
# reach the cluster from, and a wrong range locks everyone out of ACS.
set -euo pipefail
for r in central central-mtls; do
  oc annotate route "$r" -n stackrox --overwrite \
    haproxy.router.openshift.io/rate-limit-connections=true \
    haproxy.router.openshift.io/rate-limit-connections.concurrent-tcp=100 \
    haproxy.router.openshift.io/rate-limit-connections.rate-tcp=100
done
