#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims every passthrough GPU on NODE_A, and briefly one on
# NODE_B, for about 10 minutes.
# ---------------------------------------------------------------------------
# Can a project node selector keep each tenant on its own GPU node? The
# NVLink and side-channel results rest on one tenant per GPU node; this is
# the mechanism that would enforce it. The platform admin annotates each
# tenant's project with openshift.io/node-selector; OpenShift merges that
# into every pod the project creates, VM launcher pods included, and
# rejects pods that ask for a different node.
#
# Projects: PREFIX-a pinned to NODE_A, PREFIX-b pinned to NODE_B, PREFIX-c
# not pinned. Each tenant is a service account with admin in its own
# project, acting through --as.
#   1. Tenant A cannot change its project's node selector.
#   2. A's VM holding all of NODE_A's GPUs runs on NODE_A.
#   3. A's next GPU VM waits, though NODE_B has free GPUs.
#   4. B's pod with nodeSelector NODE_A is rejected.
#   5. B's pod with required node affinity for NODE_A never runs there.
#   6. B's pod tolerating every taint still runs on NODE_B.
#   7. B's GPU VM with nodeSelector NODE_A never runs there.
#   8. Reported, not judged: C's pod asking for NODE_A runs there, next to
#      A's VM. Unpinned projects are the gap a cluster-wide default node
#      selector, or a project template, has to close.
# VMs boot from a small containerDisk: only where their launcher pods run,
# and with what GPUs, matters here, not the guest.
#
# Usage: KUBECONFIG=... NODE_A=<node> NODE_B=<node> ./test-gpu-tenant-pinning.sh
#   NODE_A, NODE_B  two vm-passthrough GPU nodes (required)
#   PREFIX          projects to create (default gpu-pin; must not exist)
#   IMAGE           pod image (default registry.access.redhat.com/ubi9/ubi-minimal)
#   DISK_IMAGE      VM containerDisk (default quay.io/kubevirt/cirros-container-disk-demo)
# Exit: 0 checks 1-7 held, 1 one did not, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")"

NODE_A="${NODE_A:-}"; NODE_B="${NODE_B:-}"
PREFIX="${PREFIX:-gpu-pin}"
IMAGE="${IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal}"
DISK_IMAGE="${DISK_IMAGE:-quay.io/kubevirt/cirros-container-disk-demo}"
WAIT=300

[ -n "$NODE_A" ] && [ -n "$NODE_B" ] && [ "$NODE_A" != "$NODE_B" ] || { echo "NODE_A and NODE_B are required and must differ" >&2; exit 2; }
for n in "$NODE_A" "$NODE_B"; do
  [ "$(oc get node "$n" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}' 2>/dev/null)" = vm-passthrough ] ||
    { echo "$n is not a vm-passthrough node" >&2; exit 2; }
done
RES=$(oc get node "$NODE_A" -o json | python3 -I -c '
import json,sys
a=json.load(sys.stdin)["status"]["allocatable"]
print(next((k for k in a if k.startswith("nvidia.com/") and k != "nvidia.com/gpu" and a[k] not in ("0",)), ""))')
[ -n "$RES" ] || { echo "$NODE_A advertises no passthrough GPUs" >&2; exit 2; }
COUNT_A=$(oc get node "$NODE_A" -o jsonpath="{.status.allocatable.${RES//./\\.}}")
echo "GPU resource $RES: $COUNT_A on $NODE_A, $(oc get node "$NODE_B" -o jsonpath="{.status.allocatable.${RES//./\\.}}") on $NODE_B"

for t in a b c; do oc get ns "$PREFIX-$t" >/dev/null 2>&1 && { echo "project $PREFIX-$t already exists" >&2; exit 2; }; done
cleanup() {
  for t in a b c; do oc delete ns "$PREFIX-$t" --wait=false >/dev/null 2>&1; done
  for t in a b c; do oc wait --for=delete "ns/$PREFIX-$t" --timeout=300s >/dev/null 2>&1; done
}
trap cleanup EXIT
for t in a b c; do
  oc create ns "$PREFIX-$t" >/dev/null || exit 2
  oc create sa tenant -n "$PREFIX-$t" >/dev/null
  oc create rolebinding tenant-admin -n "$PREFIX-$t" --clusterrole=admin --serviceaccount="$PREFIX-$t:tenant" >/dev/null
done
oc annotate ns "$PREFIX-a" openshift.io/node-selector="kubernetes.io/hostname=$NODE_A" >/dev/null
oc annotate ns "$PREFIX-b" openshift.io/node-selector="kubernetes.io/hostname=$NODE_B" >/dev/null
as() { local t=$1; shift; oc --as="system:serviceaccount:$PREFIX-$t:tenant" -n "$PREFIX-$t" "$@"; }

FAILED=0
ok() { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAILED=1; }

pod() { # pod <tenant> <name> <plain|selector|affinity|tolerate>
  local extra=""
  case "$3" in
    selector) extra="  nodeSelector: {kubernetes.io/hostname: $NODE_A}" ;;
    affinity) extra="  affinity: {nodeAffinity: {requiredDuringSchedulingIgnoredDuringExecution: {nodeSelectorTerms: [{matchExpressions: [{key: kubernetes.io/hostname, operator: In, values: [$NODE_A]}]}]}}}" ;;
    tolerate) extra="  tolerations: [{operator: Exists}]" ;;
  esac
  cat <<EOF | as "$1" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata: {name: $2}
spec:
$extra
  containers:
    - name: c
      image: $IMAGE
      command: ["sleep", "600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
EOF
}
vm() { # vm <tenant> <name> <gpus> [nodeSelector node]
  local devs="" i
  for i in $(seq "$3"); do devs="$devs{name: gpu$i, deviceName: $RES}, "; done
  cat <<EOF | as "$1" apply -f - 2>&1
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: {name: $2}
spec:
  runStrategy: Always
  template:
    spec:
      ${4:+nodeSelector: {kubernetes.io/hostname: $4\}}
      domain:
        devices:
          disks: [{name: root, disk: {bus: virtio}}]
          hostDevices: [${devs%, }]
        resources: {requests: {memory: 512Mi}}
      volumes: [{name: root, containerDisk: {image: $DISK_IMAGE}}]
EOF
}
node_of() { oc get pod "$2" -n "$PREFIX-$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
phase_of() { oc get pod "$2" -n "$PREFIX-$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
launcher() { oc get pods -n "$PREFIX-$1" -l "vm.kubevirt.io/name=$2" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
wait_running() { # wait_running <tenant> <pod>; prints the node it runs on, or nothing
  local _
  for _ in $(seq $((WAIT / 5))); do [ "$(phase_of "$1" "$2")" = Running ] && { node_of "$1" "$2"; return; }; sleep 5; done
}
wait_launcher_running() { # wait_launcher_running <tenant> <vm>
  local _ p
  for _ in $(seq $((WAIT / 5))); do
    p=$(launcher "$1" "$2"); [ -n "$p" ] && [ "$(phase_of "$1" "$p")" = Running ] && { node_of "$1" "$p"; return; }; sleep 5
  done
}

echo "=== 1. tenant A cannot move its own project ==="
OUT=$(oc annotate ns "$PREFIX-a" openshift.io/node-selector="kubernetes.io/hostname=$NODE_B" --overwrite \
  --as="system:serviceaccount:$PREFIX-a:tenant" 2>&1)
case "$OUT" in *[Ff]orbidden*) ok "changing the node selector is forbidden" ;; *) bad "tenant A changed its node selector: $OUT" ;; esac
echo "  (a real user, unlike this service account, may create new projects: projectrequests=$(oc auth can-i create projectrequests \
  --as=pin-check-user --as-group=system:authenticated --as-group=system:authenticated:oauth 2>/dev/null))"

echo "=== 2. tenant A's VM with all ${COUNT_A} of ${NODE_A}'s GPUs ==="
vm a full "$COUNT_A" >/dev/null
ON=$(wait_launcher_running a full)
[ "$ON" = "$NODE_A" ] && ok "runs on $NODE_A" || bad "launcher on '${ON:-nothing, not running}', expected $NODE_A"

echo "=== 3. tenant A's next GPU VM, with $NODE_A full ==="
vm a extra 1 >/dev/null
sleep 60
P=$(launcher a extra); ON=$(node_of a "$P")
if [ -z "$ON" ]; then
  ok "waits unscheduled ($(oc get pod "$P" -n "$PREFIX-a" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null | cut -c1-120))"
else
  bad "scheduled on $ON"
fi
oc delete vm extra -n "$PREFIX-a" --wait=false >/dev/null 2>&1

echo "=== 4.-6. tenant B's pods asking for $NODE_A ==="
OUT=$(pod b by-selector selector)
case "$OUT" in *created*) bad "a pod with nodeSelector $NODE_A was admitted (now on '$(wait_running b by-selector)')" ;;
  *) ok "nodeSelector $NODE_A rejected: $(printf '%s' "$OUT" | sed 's/.*: //' | cut -c1-120)" ;; esac
pod b by-affinity affinity >/dev/null; pod b tolerating tolerate >/dev/null
sleep 45
ON=$(node_of b by-affinity)
[ "$ON" != "$NODE_A" ] && ok "required affinity for $NODE_A: never there (phase $(phase_of b by-affinity), node '${ON:-none}')" ||
  bad "required affinity put B's pod on $NODE_A"
ON=$(wait_running b tolerating)
[ "$ON" = "$NODE_B" ] && ok "tolerating every taint: runs on $NODE_B" || bad "tolerating pod on '${ON:-nothing, not running}', expected $NODE_B"

echo "=== 7. tenant B's GPU VM with nodeSelector $NODE_A ==="
vm b to-a 1 "$NODE_A" >/dev/null
sleep 60
P=$(launcher b to-a); ON=$(node_of b "$P")
if [ "$ON" = "$NODE_A" ]; then bad "B's VM launcher runs on $NODE_A"
else ok "never on $NODE_A ($(oc get vmi to-a -n "$PREFIX-b" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'no VMI'), launcher '${P:-none}'; $(oc get events -n "$PREFIX-b" --field-selector involvedObject.kind=VirtualMachineInstance -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-120))"; fi

echo "=== 8. the unpinned project C asking for $NODE_A ==="
pod c to-a selector >/dev/null
ON=$(wait_running c to-a)
echo "  ⚠️  C's pod runs on '${ON:-nothing}'$([ "$ON" = "$NODE_A" ] && echo ", next to tenant A's VM: unpinned projects need a cluster default")"

[ "$FAILED" = 0 ] && { echo "PASS a project node selector kept each pinned tenant on its own GPU node"; exit 0; }
echo "FAIL a pinned tenant reached the other tenant's node, or its own did not hold"; exit 1
