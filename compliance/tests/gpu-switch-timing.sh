#!/usr/bin/env bash
# Measure how long it takes to switch a node between GPU modalities.
#
#   container      -> host NVIDIA driver owns the GPUs, advertised as nvidia.com/gpu
#   vm-passthrough -> vfio-pci owns them, advertised as nvidia.com/<DEVICE_RESOURCE>
#
# The switch is driven by one node label; the GPU Operator reconciles the rest.
# No reboot is involved on this hardware (AMD IOMMU is already active), so this
# measures operator reconcile time, not a boot cycle.
#
# MUTATING. It unloads and reloads the NVIDIA driver on the target node.
# Refuses to run if anything is actually using a GPU.
#
# Usage:
#   ./gpu-switch-timing.sh                      # default node, both directions
#   ./gpu-switch-timing.sh -n <node>            # pick the node
#   ./gpu-switch-timing.sh -n <node> -o         # one way only, leave it switched
#
set -uo pipefail

NODE="${NODE:-moc-r4pcc02u15}"
DEVICE_RESOURCE="${DEVICE_RESOURCE:-nvidia.com/GH100_H100_SXM5_80GB}"
GPU_NS="${GPU_NS:-nvidia-gpu-operator}"
TIMEOUT="${TIMEOUT:-1200}"      # seconds per direction
POLL="${POLL:-5}"
ONE_WAY=0

while getopts "n:r:t:oh" opt; do
  case $opt in
    n) NODE="$OPTARG" ;;
    r) DEVICE_RESOURCE="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) ONE_WAY=1 ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

# Progress goes to stderr: switch_to() is called inside $(...) to capture the
# elapsed seconds, so anything on stdout would be swallowed instead of shown.
say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found"
oc get node "$NODE" >/dev/null 2>&1 || die "node $NODE not found"

# ---------------------------------------------------------------- safety ----
say "Safety checks..."
gpu_pods=$(oc get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); n=0
for p in d['items']:
    for c in p['spec'].get('containers',[]):
        r={**c.get('resources',{}).get('limits',{}),**c.get('resources',{}).get('requests',{})}
        if any('nvidia.com' in k for k in r): n+=1
print(n)")
[ "$gpu_pods" != "0" ] && die "$gpu_pods pod(s) are requesting GPUs. Refusing to switch."

vmis=$(oc get vmi -A --no-headers 2>/dev/null | grep -cv '^No resources' || true)
[ "${vmis:-0}" != "0" ] && die "VirtualMachineInstances are running. Refusing to switch."
say "  no GPU workloads, no running VMs — safe"

# Warn (do not block) if the node carries something notable.
notable=$(oc get pods -n stackrox -o wide --no-headers 2>/dev/null \
          | awk -v n="$NODE" '$7==n {print $1}' | grep -E 'central' || true)
[ -n "$notable" ] && say "  NOTE: $NODE hosts RHACS: $(echo "$notable" | tr '\n' ' ')(label flip evicts nothing)"

# ------------------------------------------------------------- readiness ----
# container mode is serviceable when the node advertises nvidia.com/gpu and the
# driver + device-plugin pods on this node are Ready.
# NOTE: results are captured into variables, never piped into `grep -q`.
# Under `set -o pipefail`, grep -q exits on the first match, the upstream
# command gets SIGPIPE (141), and the pipeline reports failure despite the
# match. Here that would have meant "never ready" and a spurious timeout.
pod_ready_lines() {
  oc get pods -n "$GPU_NS" --field-selector spec.nodeName="$NODE" \
     -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null
}
match() { printf '%s\n' "$1" | grep -qE "$2"; }

ready_container() {
  local n lines
  n=$(oc get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "0" ] || return 1
  lines=$(pod_ready_lines)
  match "$lines" '^nvidia-driver-daemonset.* True'        || return 1
  match "$lines" '^nvidia-device-plugin-daemonset.* True' || return 1
  return 0
}

# passthrough is serviceable when the node advertises the device resource,
# vfio-manager is Ready, and the host driver is gone.
ready_passthrough() {
  local n lines all
  n=$(oc get node "$NODE" -o jsonpath="{.status.allocatable.$(echo "$DEVICE_RESOURCE" | sed 's/\./\\./g')}" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "0" ] || return 1
  lines=$(pod_ready_lines)
  match "$lines" '^nvidia-vfio-manager.* True' || return 1
  # The host driver must be gone, or it still owns the cards.
  all=$(oc get pods -n "$GPU_NS" --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null)
  match "$all" 'nvidia-driver-daemonset' && return 1
  return 0
}

switch_to() {
  local target="$1" checkfn="$2" t0 t1 elapsed
  say "---------------------------------------------------------------"
  say "Switching $NODE -> $target"
  t0=$(date +%s)
  oc label node "$NODE" "nvidia.com/gpu.workload.config=$target" --overwrite >/dev/null \
    || die "failed to label node"
  while :; do
    if $checkfn; then
      t1=$(date +%s); elapsed=$((t1-t0))
      say "READY in ${elapsed}s"
      echo "$elapsed"; return 0
    fi
    t1=$(date +%s)
    if [ $((t1-t0)) -ge "$TIMEOUT" ]; then
      say "TIMEOUT after ${TIMEOUT}s"; echo "-1"; return 1
    fi
    sleep "$POLL"
  done
}

# ------------------------------------------------------------------ run ----
orig=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}' 2>/dev/null)
orig="${orig:-container}"   # unset == container (ClusterPolicy defaultWorkload)
say "Node          : $NODE"
say "Starting mode : $orig"
say "Timeout       : ${TIMEOUT}s per direction"

if [ "$orig" = "container" ]; then first=vm-passthrough; firstfn=ready_passthrough
                                   second=container;     secondfn=ready_container
else                               first=container;      firstfn=ready_container
                                   second=vm-passthrough; secondfn=ready_passthrough
fi

A=$(switch_to "$first" "$firstfn" | tail -1)
if [ "$ONE_WAY" = "1" ]; then
  say "One-way requested; leaving $NODE in $first"
  B="(skipped)"
else
  B=$(switch_to "$second" "$secondfn" | tail -1)
fi

say "==============================================================="
say "RESULT  $NODE"
say "  $orig -> $first : ${A}s"
[ "$ONE_WAY" = "1" ] || say "  $first -> $second : ${B}s"
say "  final mode: $(oc get node "$NODE" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}')"
say "==============================================================="
