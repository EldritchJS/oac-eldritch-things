#!/usr/bin/env bash
# Scan container images for FIPS-capable binaries with Red Hat's check-payload,
# in a throwaway pod on a cluster (never on a laptop).
#
# Usage:
#   KUBECONFIG=... ./fips-image-scan.sh IMAGE [IMAGE...]
#   KUBECONFIG=... ./fips-image-scan.sh --control
#
# The pod runs under restricted-v2 in its own project, builds check-payload
# and crane from source, unpacks each image with crane (no podman, no root),
# runs `check-payload scan local`, prints the report, and the project is
# deleted at the end. Only public images: no pull secret is mounted.
#
# --control builds one small Go program three ways and scans each, to show
# the scanner tells them apart: Red Hat's Go (pass), upstream Go (fail),
# upstream Go with GOFIPS140=v1.0.0 (pass).
#
# Mutates the cluster only by creating and deleting the project.
set -uo pipefail

NS="${FIPS_SCAN_NS:-fips-scan}"
command -v oc >/dev/null || { echo "oc not found" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }
[ $# -gt 0 ] || { sed -n '2,17p' "$0"; exit 2; }

MODE=images
if [ "$1" = "--control" ]; then MODE=control; shift; fi
IMAGES="$*"

read -r -d "" SCRIPT <<'EOF'
set -u
# The node has many CPUs; without -p the Go build hits the pod's process limit.
export HOME=/work GOTOOLCHAIN=auto GOPATH=/work/go GOCACHE=/work/cache \
  GOFLAGS="-mod=mod -p=2" GOMAXPROCS=2 PATH=/work/go/bin:$PATH
go install github.com/openshift/check-payload@latest >/work/build.log 2>&1 || { tail -5 /work/build.log; exit 1; }
report() {
  grep -v -E '^\s*$|^\+[-+]+\+$|^\| EXECUTABLE NAME|using embedded config|"scan" version|can.t find rpmdb|scanning failed|command failed|/etc/redhat-release .*could not find distribution' /work/out.txt | tail -n 40
}
if [ "$MODE" = control ]; then
  mkdir -p /work/src && cd /work/src
  printf 'package main\nimport ("crypto/sha256";"fmt")\nfunc main(){ fmt.Println(sha256.Sum256([]byte("x"))) }\n' > main.go
  go mod init control >/dev/null 2>&1; go mod edit -go=1.26.0
  for kind in redhat upstream upstream-fips140; do
    R=/work/root-$kind; mkdir -p $R/usr/bin $R/etc; cp /etc/redhat-release $R/etc/
    case $kind in
      redhat)           CGO_ENABLED=0 go build -o $R/usr/bin/control . ;;
      upstream)         CGO_ENABLED=0 GOTOOLCHAIN=go1.26.0 go build -o $R/usr/bin/control . ;;
      upstream-fips140) CGO_ENABLED=0 GOTOOLCHAIN=go1.26.0 GOFIPS140=v1.0.0 go build -o $R/usr/bin/control . ;;
    esac || { echo "build $kind failed"; continue; }
    echo "################ control-$kind"
    check-payload scan local --path $R > /work/out.txt 2>&1; echo "exit=$?"; report
  done
else
  go install github.com/google/go-containerregistry/cmd/crane@latest >>/work/build.log 2>&1 || { tail -5 /work/build.log; exit 1; }
  n=0
  for img in $IMAGES; do
    n=$((n+1)); IMG=/work/img$n; mkdir -p $IMG
    echo "################ $img"
    crane export --platform linux/amd64 "$img" - 2>/work/crane.err \
      | tar --no-same-owner --no-same-permissions --warning=no-unknown-keyword -x -C $IMG 2>/dev/null
    if [ -z "$(ls -A $IMG)" ]; then echo "could not pull: $(tail -1 /work/crane.err)"; continue; fi
    check-payload scan local --path $IMG > /work/out.txt 2>&1; echo "exit=$?"; report
    chmod -R u+w $IMG 2>/dev/null; rm -rf $IMG
  done
fi
echo "== done"
EOF

export SCRIPT
oc get ns "$NS" >/dev/null 2>&1 && { echo "project $NS already exists; set FIPS_SCAN_NS" >&2; exit 2; }
oc new-project "$NS" >/dev/null || exit 2
trap 'oc delete project "$NS" --wait=false >/dev/null 2>&1' EXIT

python3 -I - "$NS" "$MODE" "$IMAGES" <<'PY' | oc create -f - >/dev/null || exit 2
import json, os, sys
ns, mode, images = sys.argv[1:4]
script = os.environ["SCRIPT"]
print(json.dumps({"apiVersion": "v1", "kind": "Pod",
  # Pin the SCC: as cluster-admin, a pod otherwise gets the highest-priority
  # SCC that admits it, which on a Portworx cluster is Portworx's.
  "metadata": {"name": "fips-scan", "namespace": ns,
               "annotations": {"openshift.io/required-scc": "restricted-v2"}},
  "spec": {"restartPolicy": "Never", "containers": [{
    "name": "scan", "image": "registry.access.redhat.com/ubi9/go-toolset:latest",
    "command": ["/bin/bash", "-c", script],
    "env": [{"name": "IMAGES", "value": images}, {"name": "MODE", "value": mode}],
    "resources": {"requests": {"cpu": "2", "memory": "4Gi"}, "limits": {"memory": "8Gi"}},
    "volumeMounts": [{"name": "work", "mountPath": "/work"}],
    "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]},
                        "runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}}}],
    "volumes": [{"name": "work", "emptyDir": {"sizeLimit": "40Gi"}}]}}))
PY

echo "scanning in $NS on $(oc whoami --show-server) ..." >&2
for _ in $(seq 360); do
  ph=$(oc get pod fips-scan -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$ph" in Succeeded|Failed) break ;; esac
  sleep 5
done
oc logs fips-scan -n "$NS"
[ "$ph" = Succeeded ]
