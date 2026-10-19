#!/usr/bin/env bash
# Rate-limit every route outside openshift-*/kube-* (800-53 SC-5; closes
# ocp4-moderate-routes-rate-limit). Same limits and approach as jetty's
# manifests/23-acs-route-rate-limits.sh, extended to every such route,
# because a hub carries ACM and multicluster-engine routes as well as ACS.
#
# A script, not Route manifests: operators own these routes (ACS Central,
# MultiClusterEngine), and a declarative Route would fight them. On jetty
# the ACS operator kept added annotations across a forced reconcile. If an
# operator upgrade drops them, the nightly scan fails routes-rate-limit
# again, which is the signal to re-run this. Idempotent.
#
# Limits are per source IP: 100 concurrent TCP connections, 100 new
# connections per 3 s. They are TCP limits, so they also work on
# passthrough routes, where HAProxy never sees HTTP.
#
# Three routes carry traffic from managed clusters, not people:
# agent-registration, cluster-proxy-addon-anp and cluster-proxy-addon-user.
# 100 per source IP is generous for a hub with few hosted clusters. On a
# busy hub, check the router's connection counts before relying on it.
#
# route-ip-whitelist is NOT done here: it needs the source ranges people
# reach the hub from, and a wrong range locks everyone out.
#
# Usage:
#   KUBECONFIG=... ./route-rate-limits.sh            # report only
#   KUBECONFIG=... APPLY=1 ./route-rate-limits.sh    # annotate
set -euo pipefail

APPLY="${APPLY:-0}"
CONCURRENT="${CONCURRENT:-100}"
RATE="${RATE:-100}"

routes=$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.annotations.haproxy\.router\.openshift\.io/rate-limit-connections}{"\n"}{end}' \
  | awk '$1 !~ /^(openshift|kube)(-|$)/')

[ -z "$routes" ] && { echo "no routes outside openshift-*/kube-*"; exit 0; }

echo "$routes" | while read -r ns name current; do
  if [ "$current" = true ]; then
    echo "ok       $ns/$name"
  elif [ "$APPLY" = 1 ]; then
    oc annotate route "$name" -n "$ns" --overwrite \
      haproxy.router.openshift.io/rate-limit-connections=true \
      haproxy.router.openshift.io/rate-limit-connections.concurrent-tcp="$CONCURRENT" \
      haproxy.router.openshift.io/rate-limit-connections.rate-tcp="$RATE" >/dev/null
    echo "set      $ns/$name"
  else
    echo "missing  $ns/$name (APPLY=1 to annotate)"
  fi
done
