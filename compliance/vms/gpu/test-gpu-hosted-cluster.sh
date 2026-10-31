#!/usr/bin/env bash
# Is a KubeVirt hosted cluster's GPU NodePool set up the way GPU VMs on jetty
# need (oac-apps #212)? Pods in a GPU VM matched bare metal only with
# dedicated CPUs, and small all-reduces only with SMT off in the guest
# (README: "Do pods in a GPU VM get bare-metal NVLink performance?").
#
#   1. Hub: the HostedCluster is available and the NodePool has all its nodes.
#   2. Hypervisor: each of the pool's VMs runs, holds its GPUs, and has the
#      dedicated CPUs and threads the NodePool's VM patch asked for.
#   3. Guest: every node is Ready; each GPU node sees its GPUs on the PCI bus,
#      and has SMT off if the pool boots it with nosmt.
#   4. Guest ingress: the canary route answers through the hypervisor's
#      router (ingress.type NodePortService), not a LoadBalancer.
#
# Read-only on the hub and the hypervisor. In the guest, step 3 starts one
# debug pod per GPU node (oc debug), which is removed when it ends. The guest
# kubeconfig is read from the hub into a temporary file that is deleted on
# exit.
#
# Does not measure performance: run ai-uat-harness against the guest for that.
#
# Exit: 0 all checks passed, 1 one failed, 2 could not run.
#
# Usage: HUB_KUBECONFIG=... KUBECONFIG=<hypervisor> CLUSTER=<name> ./test-gpu-hosted-cluster.sh
#   CLUSTER    hosted cluster name (required)
#   POOL       NodePool name, without the cluster prefix (default gpu)
#   HUB_NS     namespace of HostedClusters on the hub (default clusters)
set -uo pipefail

: "${HUB_KUBECONFIG:?set HUB_KUBECONFIG to the hub (management cluster)}"
: "${CLUSTER:?set CLUSTER to the hosted cluster name}"
POOL="${POOL:-gpu}"
HUB_NS="${HUB_NS:-clusters}"
NODEPOOL="$CLUSTER-$POOL"
CP_NS="$HUB_NS-$CLUSTER"        # control plane namespace on the hub, and the
                                # VMs' namespace on the hypervisor
hub() { KUBECONFIG="$HUB_KUBECONFIG" oc "$@"; }
FAILED=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILED=1; }
warn() { echo "  WARN $*"; }

GUEST_KC="$(umask 077; mktemp)"
trap 'rm -P "$GUEST_KC" 2>/dev/null || rm -f "$GUEST_KC"' EXIT
guest() { KUBECONFIG="$GUEST_KC" oc "$@"; }

echo "=== 1. hub: $HUB_NS/$CLUSTER and NodePool $NODEPOOL ==="
hub get hostedcluster "$CLUSTER" -n "$HUB_NS" >/dev/null 2>&1 || { echo "no HostedCluster $HUB_NS/$CLUSTER on the hub" >&2; exit 2; }
NP_JSON="$(hub get nodepool "$NODEPOOL" -n "$HUB_NS" -o json 2>/dev/null)" || { echo "no NodePool $HUB_NS/$NODEPOOL on the hub" >&2; exit 2; }
avail="$(hub get hostedcluster "$CLUSTER" -n "$HUB_NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
[ "$avail" = True ] && pass "HostedCluster available" || fail "HostedCluster Available=$avail"

# What the pool asks for: replicas, GPUs per VM, and the VM patch's settings.
read -r WANT HAVE GPUS DEDICATED THREADS <<EOF
$(printf '%s' "$NP_JSON" | python3 -I -c '
import json,sys
p=json.load(sys.stdin)
kv=p["spec"].get("platform",{}).get("kubevirt",{})
gpus=sum(d.get("count",1) for d in kv.get("hostDevices",[]))
patch=json.loads(p["metadata"].get("annotations",{}).get("hypershift.openshift.io/kubevirt-vm-jsonpatch","[]"))
ops={o["path"].rsplit("/",1)[1]: o.get("value") for o in patch}
print(p["spec"].get("replicas",0), p.get("status",{}).get("replicas",0), gpus,
      "true" if ops.get("dedicatedCpuPlacement") else "false", ops.get("threads",1))')
EOF
[ "$HAVE" = "$WANT" ] && pass "NodePool has $HAVE of $WANT nodes" || fail "NodePool has $HAVE of $WANT nodes"
[ "$GPUS" -gt 0 ] || warn "NodePool passes no hostDevices: not a GPU pool"
echo "  asks for: $GPUS GPU(s) per VM, dedicated CPUs $DEDICATED, $THREADS thread(s) per core"

echo "=== 2. hypervisor: VMs in $CP_NS ==="
VMIS="$(oc get vmi -n "$CP_NS" -o json 2>/dev/null)" || { echo "cannot list VMIs in $CP_NS: is KUBECONFIG the hypervisor?" >&2; exit 2; }
VM_NAMES="$(printf '%s' "$VMIS" | python3 -I -c '
import json,sys
pool=sys.argv[1]; want=dict(gpus=int(sys.argv[2]), ded=sys.argv[3]=="true", thr=int(sys.argv[4]))
for v in json.load(sys.stdin)["items"]:
    n=v["metadata"]["name"]
    if not n.startswith(pool+"-"): continue
    d=v["spec"]["domain"]; cpu=d.get("cpu",{})
    gpus=len(d.get("devices",{}).get("hostDevices",[]))
    bad=[]
    if v.get("status",{}).get("phase")!="Running": bad.append("phase "+str(v.get("status",{}).get("phase")))
    if gpus!=want["gpus"]: bad.append("%d GPU(s), want %d" % (gpus,want["gpus"]))
    if bool(cpu.get("dedicatedCpuPlacement"))!=want["ded"]: bad.append("dedicatedCpuPlacement %s" % cpu.get("dedicatedCpuPlacement"))
    if cpu.get("threads",1)!=want["thr"]: bad.append("threads %s, want %d" % (cpu.get("threads",1),want["thr"]))
    print(n, v.get("status",{}).get("nodeName","-"), "ok" if not bad else "; ".join(bad).replace(" ","_"))
' "$NODEPOOL" "$GPUS" "$DEDICATED" "$THREADS")"
[ -n "$VM_NAMES" ] || fail "no VMs named $NODEPOOL-* in $CP_NS"
while read -r vm node status; do
  [ -n "$vm" ] || continue
  if [ "$status" = ok ]; then
    pass "$vm on $node: running, $GPUS GPU(s), CPUs as asked"
  else
    fail "$vm on $node: $(printf '%s' "$status" | tr _ ' ')"
  fi
  if [ "$DEDICATED" = true ]; then
    qos="$(oc get pod -n "$CP_NS" -l "vm.kubevirt.io/name=$vm" -o jsonpath='{.items[0].status.qosClass}' 2>/dev/null)"
    [ "$qos" = Guaranteed ] && pass "$vm's launcher pod is Guaranteed" || fail "$vm's launcher pod QoS is ${qos:-unknown}, not Guaranteed"
  fi
done <<EOF
$VM_NAMES
EOF

echo "=== 3. guest: nodes, GPUs and SMT ==="
hub get secret "$CLUSTER-admin-kubeconfig" -n "$HUB_NS" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$GUEST_KC"
[ -s "$GUEST_KC" ] || { echo "no $HUB_NS/$CLUSTER-admin-kubeconfig on the hub" >&2; exit 2; }
guest get nodes >/dev/null 2>&1 || { echo "cannot reach the guest API with its admin kubeconfig" >&2; exit 2; }
notready="$(guest get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1}')"
[ -z "$notready" ] && pass "all guest nodes Ready" || fail "guest nodes not Ready: $notready"

while read -r vm _ _; do
  [ -n "$vm" ] || continue
  # The guest node is named after its VM. Count NVIDIA 3D controllers in sysfs
  # (lspci is not in RHCOS), and read the SMT state and the boot arguments.
  out="$(guest debug "node/$vm" -q -- chroot /host sh -c '
    n=0; for d in /sys/bus/pci/devices/*; do
      [ "$(cat $d/vendor)" = 0x10de ] && case "$(cat $d/class)" in 0x0302*|0x0300*) n=$((n+1));; esac
    done
    echo "gpus=$n smt=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null) cpus=$(nproc) nosmt=$(grep -c -w nosmt /proc/cmdline)"' 2>/dev/null | tail -1)"
  [ -n "$out" ] || { fail "$vm: oc debug in the guest gave nothing"; continue; }
  gpus= smt= cpus= nosmt=
  eval "$(printf '%s' "$out" | tr ' ' '\n' | grep -E '^(gpus|smt|cpus|nosmt)=[A-Za-z0-9-]*$')"
  [ "${gpus:-0}" = "$GPUS" ] && pass "$vm sees $gpus GPU(s)" || fail "$vm sees ${gpus:-0} GPU(s), want $GPUS"
  if [ "${nosmt:-0}" -gt 0 ]; then
    case "$smt" in off|forceoff) pass "$vm boots with nosmt; SMT $smt, $cpus CPUs online" ;;
                   *) fail "$vm boots with nosmt but SMT is ${smt:-unknown}" ;; esac
  elif [ "$THREADS" -gt 1 ]; then
    warn "$vm has $THREADS threads per core but SMT is ${smt:-unknown}: small all-reduces may be slow (add kernelArguments: [nosmt])"
  fi
  if allocatable="$(guest get node "$vm" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)" && [ -n "$allocatable" ]; then
    [ "$allocatable" = "$GPUS" ] && pass "$vm advertises nvidia.com/gpu=$allocatable" || fail "$vm advertises nvidia.com/gpu=$allocatable, want $GPUS"
  else
    warn "$vm advertises no nvidia.com/gpu: is the GPU Operator installed in the guest?"
  fi
done <<EOF
$VM_NAMES
EOF

echo "=== 4. guest ingress through the hypervisor's router ==="
type="$(hub get hostedcluster "$CLUSTER" -n "$HUB_NS" -o jsonpath='{.spec.operatorConfiguration.ingressOperator.endpointPublishingStrategy.type}' 2>/dev/null)"
[ "$type" = NodePortService ] && pass "guest router published as NodePortService" || warn "guest router published as ${type:-the default}, not NodePortService: it needs a LoadBalancer on the hypervisor"
# The canary route sets spec.subdomain, not spec.host; the router fills in
# the host it admitted it under.
canary="$(guest get route canary -n openshift-ingress-canary -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)"
if [ -z "$canary" ]; then
  fail "no canary route in the guest"
else
  code="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://$canary/" 2>/dev/null)"
  [ "$code" = 200 ] && pass "https://$canary/ answers 200" || fail "https://$canary/ answered ${code:-nothing}"
fi
wild="$(oc get route -n "$CP_NS" -o jsonpath='{range .items[?(@.spec.wildcardPolicy=="Subdomain")]}{.spec.host}{" "}{.spec.tls.termination}{"\n"}{end}' 2>/dev/null | head -1)"
[ -n "$wild" ] && pass "hypervisor has the wildcard route: $wild" || warn "no wildcard route in $CP_NS on the hypervisor"

[ "$FAILED" = 0 ] && { echo "PASS $CLUSTER's $POOL pool is set up for GPU VMs"; exit 0; }
echo "FAIL see the FAIL lines above"; exit 1
