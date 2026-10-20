#!/usr/bin/env bash
# Render the handshake test for the cluster in $KUBECONFIG.
# Usage: render.sh <server-node> <client-node>
set -euo pipefail
SERVER_NODE=$1 CLIENT_NODE=$2
EP=$(oc get pod -n openshift-etcd -l app=etcd -o name | head -1)
IMAGE=${IMAGE:-$(oc get -n openshift-etcd "$EP" -o jsonpath='{.spec.containers[?(@.name=="etcd")].image}')}
CIPHERS=$(oc get -n openshift-etcd "$EP" -o jsonpath='{.spec.containers[?(@.name=="etcd")].env[?(@.name=="ETCD_CIPHER_SUITES")].value}')
SEC='securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'
EXTRA=""
[ -n "${GOMAXPROCS:-}" ] && EXTRA="        - {name: GOMAXPROCS, value: \"$GOMAXPROCS\"}"
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: hs-test
---
apiVersion: v1
kind: Pod
metadata:
  name: etcd-test
  namespace: hs-test
  labels: {app: etcd-test}
spec:
  nodeName: $SERVER_NODE
  tolerations: [{operator: Exists}]
  restartPolicy: Never
  containers:
    - name: etcd
      image: $IMAGE
      command: [etcd]
      args:
        - --name=etcd-test
        - --data-dir=/data
        - --listen-client-urls=https://0.0.0.0:2379
        - --advertise-client-urls=https://etcd-test:2379
        - --cert-file=/certs/server.crt
        - --key-file=/certs/server.key
        - --trusted-ca-file=/certs/ca.crt
        - --client-cert-auth=true
      env:
        - {name: ETCD_CIPHER_SUITES, value: "$CIPHERS"}
        - {name: ETCD_TLS_MIN_VERSION, value: TLS1.2}
$EXTRA
      ports: [{containerPort: 2379}]
      $SEC
      volumeMounts:
        - {name: certs, mountPath: /certs}
        - {name: data, mountPath: /data}
  volumes:
    - {name: certs, secret: {secretName: hs-certs}}
    - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: hs-test
spec:
  nodeName: $CLIENT_NODE
  tolerations: [{operator: Exists}]
  restartPolicy: Never
  containers:
    - name: client
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: [sleep, "86400"]
      $SEC
      volumeMounts:
        - {name: certs, mountPath: /certs}
        - {name: work, mountPath: /work}
  volumes:
    - {name: certs, secret: {secretName: hs-certs}}
    - {name: work, emptyDir: {}}
EOF
