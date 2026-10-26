#!/usr/bin/env bash
# Is this cluster set up properly for containers, VMs and GPUs? For any OAC
# cluster: a standalone one like jetty, or a hosted spoke, compliant or not.
#
# What runs depends on what the cluster has, found from the cluster itself:
#   virtualization  a HyperConverged exists
#   GPUs            nodes labelled nvidia.com/gpu.present=true
#   compliant       a ScanSettingBinding exists in openshift-compliance
#                   (override with --compliant / --not-compliant)
#   hosted          infrastructure controlPlaneTopology=External
#
# Three levels, each opt-in beyond the first:
#   (default)     read-only checks. Free, a few minutes.
#   --functional  also boots test VMs: network, persistent disk, live
#                 migration (../vms/test-vm*.sh). Free; creates and deletes
#                 its own project.
#   --gpu         also claims GPUs: a CUDA pod (test-gpu-pod.sh) and a GPU VM
#                 (../vms/gpu/test-gpu-vm.sh). COSTS MONEY while claimed.
# The billing check (no GPU left claimed) always runs last.
#
# Usage: KUBECONFIG=... ./cluster-acceptance.sh [--functional] [--gpu]
#          [--compliant | --not-compliant]
# Exit: 0 nothing failed, 1 something failed, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

FUNCTIONAL=0 GPU=0 COMPLIANT=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --functional) FUNCTIONAL=1 ;;
    --gpu) GPU=1 ;;
    --compliant) COMPLIANT=1 ;;
    --not-compliant) COMPLIANT=0 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
PASS=0 FAIL=0 WARN=0 SKIP=0
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s %s\n' "$Y" "$N" "$*"; WARN=$((WARN+1)); }
skip() { printf '  SKIP %s\n' "$*"; SKIP=$((SKIP+1)); }
info() { printf '       %s\n' "$*"; }

# Runs verify.sh checks (generic ones only) and folds their counts into ours.
verify() {
  local out
  out=$(./verify.sh -t "$1" 2>&1)
  printf '%s\n' "$out" | sed -n '/^$/,/^-----/p' | grep -v '^-----'
  # Result lines only, not verify.sh's own totals line.
  PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^  PASS ')))
  FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^  FAIL ')))
  WARN=$((WARN + $(printf '%s\n' "$out" | grep -c '^  WARN ')))
  SKIP=$((SKIP + $(printf '%s\n' "$out" | grep -c '^  SKIP ')))
}

# Runs a functional script and records one PASS/FAIL line for it.
functional() { # functional <label> <command...>
  local label=$1 log; shift
  log=$(mktemp)
  if "$@" > "$log" 2>&1; then ok "$label"; else bad "$label (log: $log)"; return; fi
  rm -f "$log"
}

command -v oc >/dev/null || { echo "oc not found" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }

# ---------------------------------------------------------- what is here ---
TOPO=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null)
HOSTED=0; [ "$TOPO" = External ] && HOSTED=1
HAS_VIRT=0; [ -n "$(oc get hyperconverged -A -o name 2>/dev/null)" ] && HAS_VIRT=1
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
if [ "$COMPLIANT" = auto ]; then
  COMPLIANT=0
  [ -n "$(oc get scansettingbinding -n openshift-compliance -o name 2>/dev/null)" ] && COMPLIANT=1
fi

printf '%scluster acceptance%s  —  %s  —  %s\n' "$B" "$N" "$(oc whoami --show-server)" "$(date -u '+%Y-%m-%d %H:%M UTC')"
printf '  %s, virtualization %s, GPU nodes: %s, compliant: %s\n' \
  "$([ $HOSTED = 1 ] && echo "hosted spoke" || echo standalone)" \
  "$([ $HAS_VIRT = 1 ] && echo yes || echo no)" "${GPU_NODES:-none}" \
  "$([ $COMPLIANT = 1 ] && echo yes || echo no)"

# ------------------------------------------------------------- containers --
hdr "Nodes and storage"
notready=$(oc get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1"("$2")"}')
[ -z "$notready" ] && ok "every node Ready" || bad "nodes not Ready: $notready"
cordoned=$(oc get nodes --no-headers 2>/dev/null | awk '$2 ~ /SchedulingDisabled/ {print $1}')
[ -n "$cordoned" ] && warn "cordoned: $cordoned"
DEFAULT_SC=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)
case "$(echo $DEFAULT_SC | wc -w | tr -d ' ')" in
  1) ok "one default StorageClass: $DEFAULT_SC" ;;
  0) bad "no default StorageClass (VM disks and most PVCs need one)" ;;
  *) bad "more than one default StorageClass: $DEFAULT_SC" ;;
esac
DEFAULT_SC=$(echo $DEFAULT_SC | awk '{print $1}')

if [ "$COMPLIANT" = 1 ]; then
  hdr "Compliant cluster"
  verify t01
  if [ -n "$DEFAULT_SC" ]; then
    mo=$(oc get sc "$DEFAULT_SC" -o jsonpath='{.mountOptions}' 2>/dev/null)
    prov=$(oc get sc "$DEFAULT_SC" -o jsonpath='{.provisioner}' 2>/dev/null)
    case "$mo" in
      *xprtsec=tls*) ok "default StorageClass mounts NFS over TLS" ;;
      *) [ "$prov" = pxd.portworx.com ] \
           && bad "default StorageClass $DEFAULT_SC has no xprtsec=tls: storage traffic in cleartext" \
           || warn "default StorageClass $DEFAULT_SC ($prov) is not NFS; check its encryption by hand" ;;
    esac
  fi
fi

# --------------------------------------------------------- virtualization --
if [ "$HAS_VIRT" = 1 ]; then
  hdr "Virtualization"
  hco_ns=$(oc get hyperconverged -A -o jsonpath='{.items[0].metadata.namespace}')
  avail=$(oc get hyperconverged -n "$hco_ns" -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}')
  degr=$(oc get hyperconverged -n "$hco_ns" -o jsonpath='{.items[0].status.conditions[?(@.type=="Degraded")].status}')
  [ "$avail" = True ] && [ "$degr" != True ] && ok "HyperConverged Available, not Degraded" \
    || bad "HyperConverged Available=$avail Degraded=$degr"
  sched=$(oc get nodes -l kubevirt.io/schedulable=true -o name 2>/dev/null | wc -l | tr -d ' ')
  handlers=$(oc get pods -n "$hco_ns" -l kubevirt.io=virt-handler --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
  [ "$sched" -gt 0 ] && ok "$sched node(s) can run VMs" || bad "no node is kubevirt.io/schedulable"
  [ "$handlers" -ge "$sched" ] && ok "virt-handler running on $handlers node(s)" \
    || bad "virt-handler running on $handlers of $sched VM-capable nodes"
  [ "$sched" -lt 2 ] && warn "fewer than 2 VM-capable nodes: VMs cannot live migrate"
  if [ -n "$DEFAULT_SC" ]; then
    modes=$(oc get storageprofile "$DEFAULT_SC" -o jsonpath='{.status.claimPropertySets[*].accessModes}' 2>/dev/null)
    case "$modes" in
      *ReadWriteMany*) ok "default StorageClass offers ReadWriteMany (VM live migration)" ;;
      "") warn "no CDI StorageProfile for $DEFAULT_SC" ;;
      *) warn "default StorageClass has no ReadWriteMany: VMs on it cannot live migrate" ;;
    esac
  fi
else
  hdr "Virtualization"; skip "no HyperConverged on this cluster"
fi

# ------------------------------------------------------------------- GPUs --
hdr "GPUs"
if [ -z "$GPU_NODES" ]; then
  skip "no GPU nodes"
else
  cp_state=$(oc get clusterpolicy -o jsonpath='{.items[0].status.state}' 2>/dev/null)
  [ "$cp_state" = ready ] && ok "GPU Operator ClusterPolicy ready" || bad "ClusterPolicy state '${cp_state:-none}'"
  verify t06,t07
  # QEMU needs the vfio type1 backend for any passed-through GPU; the GPU
  # Operator does not load it (jetty, 2026-10-20). vfio-pci also needs the
  # IOMMU on, which an RDMA node turns off (amd_iommu=off): such a node
  # cannot serve GPU VMs (../vms/gpu/README.md). Needs a debug pod, which a
  # hosted spoke may not allow.
  for n in $(oc get nodes -l nvidia.com/gpu.workload.config=vm-passthrough -o jsonpath='{.items[*].metadata.name}'); do
    r=$(oc debug "node/$n" -n default --quiet -- chroot /host sh -c \
        'm=missing; [ -d /sys/module/vfio_iommu_type1 ] && m=loaded
         g=$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)
         o=$(grep -oE "(amd|intel)_iommu=off" /proc/cmdline | head -1)
         echo "$m $g ${o:-none}"' 2>/dev/null)
    read -r mod groups off <<< "$r"
    case "$mod" in
      loaded)  ok "$n vfio_iommu_type1 loaded" ;;
      missing) bad "$n vfio_iommu_type1 not loaded: GPU VMs fail with 'No available IOMMU models'" ;;
      *)       warn "$n could not check vfio_iommu_type1 or the IOMMU (no debug pod)"; continue ;;
    esac
    if [ "$off" != none ]; then
      bad "$n is in vm-passthrough mode with $off: an RDMA node cannot serve GPU VMs"
    elif [ "${groups:-0}" -gt 0 ]; then
      ok "$n IOMMU on ($groups groups)"
    else
      bad "$n has no IOMMU groups: vfio-pci cannot claim its GPUs"
    fi
  done
  # Placement and configuration of GPU VMs: one tenant per node, no
  # LiveMigrate, every passthrough resource permitted. Logic and fixtures:
  # ../lib/gpu-vm-checks.py, ./test-gpu-vm-checks.sh.
  if [ "$HAS_VIRT" = 1 ]; then
    d=$(mktemp -d)
    if oc get nodes -o json > "$d/nodes.json" 2>/dev/null \
       && oc get vm,vmi -A -o json > "$d/vms.json" 2>/dev/null \
       && oc get hyperconverged -A -o json > "$d/hco.json" 2>/dev/null \
       && oc get kubevirt -A -o json > "$d/kv.json" 2>/dev/null; then
      while IFS=$'\t' read -r lvl check detail; do
        case "$lvl" in
          PASS) ok "$check: $detail" ;;
          FAIL) bad "$check: $detail" ;;
          *)    warn "$check: $detail" ;;
        esac
      done < <(python3 ../lib/gpu-vm-checks.py "$d/nodes.json" "$d/vms.json" "$d/hco.json" "$d/kv.json")
    else
      bad "could not read nodes, VMs, HyperConverged or KubeVirt for the GPU VM checks"
    fi
    rm -rf "$d"
  fi
fi

# ------------------------------------------------------------- functional --
if [ "$FUNCTIONAL" = 1 ] && [ "$HAS_VIRT" = 1 ]; then
  hdr "Functional: VMs (free)"
  ns="acceptance-vm-$(date +%s)"
  if oc create ns "$ns" >/dev/null 2>&1; then
    functional "VM boots, has network"            env NAMESPACE="$ns" ../vms/test-vm.sh
    functional "VM keeps data on a persistent disk" env NAMESPACE="$ns" ../vms/test-vm-storage.sh
    if [ "${sched:-0}" -ge 2 ]; then
      functional "VM live migrates without rebooting" env NAMESPACE="$ns" ../vms/test-vm-migration.sh
    else
      skip "live migration: fewer than 2 VM-capable nodes"
    fi
    oc delete ns "$ns" --timeout=300s >/dev/null 2>&1   # billing below needs the GPU released
  else
    bad "could not create project $ns for the VM tests"
  fi
elif [ "$FUNCTIONAL" = 1 ]; then
  hdr "Functional: VMs (free)"; skip "no virtualization"
fi

if [ "$GPU" = 1 ] && [ -n "$GPU_NODES" ]; then
  hdr "Functional: GPUs (billable)"
  if [ -n "$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '$1 > 0')" ]; then
    functional "CUDA runs in a pod (container mode)" ./test-gpu-pod.sh
  else
    skip "GPU pod: no node in container mode"
  fi
  if [ "$HAS_VIRT" = 1 ] && [ -n "$(oc get nodes -l nvidia.com/gpu.workload.config=vm-passthrough -o name)" ]; then
    ns="acceptance-gpuvm-$(date +%s)"
    if oc create ns "$ns" >/dev/null 2>&1; then
      functional "CUDA runs in a VM (passthrough)" env NAMESPACE="$ns" ../vms/gpu/test-gpu-vm.sh
      oc delete ns "$ns" --timeout=300s >/dev/null 2>&1   # billing below needs the GPU released
    else
      bad "could not create project $ns for the GPU VM test"
    fi
  else
    skip "GPU VM: no node in vm-passthrough mode"
  fi
elif [ "$GPU" = 1 ]; then
  hdr "Functional: GPUs (billable)"; skip "no GPU nodes"
fi

# ---------------------------------------------------------------- billing --
[ -n "$GPU_NODES" ] && verify t17

printf '\n%s--------------------------------------------------%s\n' "$B" "$N"
printf '%sPASS %d%s   %sFAIL %d%s   %sWARN %d%s   SKIP %d\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$WARN" "$N" "$SKIP"
[ "$FUNCTIONAL" = 0 ] && printf 'Read-only run. --functional boots test VMs (free); --gpu claims GPUs (billable).\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
