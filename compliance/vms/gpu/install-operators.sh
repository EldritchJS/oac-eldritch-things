#!/usr/bin/env bash
set -euo pipefail

# Bootstraps a cluster that has GPU hardware but none of the software needed to
# use it, which is the state `preflight.sh` reports as:
#
#   - Install OpenShift Virtualization. Nothing else in this directory applies.
#   - Install NFD and the NVIDIA GPU Operator, then re-run this preflight.
#
# Installs three operators and their operand CRs:
#
#   Node Feature Discovery   labels nodes by hardware. Without it nothing knows
#                            the H100s exist, and the GPU operator has no
#                            feature.node.kubernetes.io/pci-10de.present=true
#                            to select on.
#   NVIDIA GPU Operator      driver, container toolkit, device plugin; and for
#                            this directory's purposes, vfio-manager and the
#                            sandbox device plugin that back VM passthrough.
#   OpenShift Virtualization KubeVirt. Without it there are no VMs to give a
#                            GPU to.
#
# ADMIN, and cluster-scoped. It is additive — it creates namespaces,
# subscriptions and CRs and deletes nothing — but installing an operator means
# handing a controller broad rights over the cluster, and the GPU operator in
# particular loads a kernel module on every GPU node. Report-only until APPLY=1.
#
# Idempotent: re-running after a partial install resumes rather than conflicts.

APPLY="${APPLY:-0}"
CSV_TIMEOUT="${CSV_TIMEOUT:-600}"
OPERAND_TIMEOUT="${OPERAND_TIMEOUT:-1200}"

# Which of the three to install. Set any to 0 to skip, e.g. to add the GPU
# operator to a cluster that already has virtualization.
WANT_NFD="${WANT_NFD:-1}"
WANT_GPU="${WANT_GPU:-1}"
WANT_CNV="${WANT_CNV:-1}"

# Turn on sandbox workloads as the ClusterPolicy is created rather than
# patching it afterwards. defaultWorkload=container means every node keeps the
# ordinary container GPU stack until something explicitly labels it otherwise,
# so this is a no-op for behaviour and only makes the per-node label
# nvidia.com/gpu.workload.config meaningful. Enabling it later costs a second
# full reconcile of the GPU stack on every node.
SANDBOX_WORKLOADS="${SANDBOX_WORKLOADS:-1}"

NFD_NS="openshift-nfd"
GPU_NS="nvidia-gpu-operator"
CNV_NS="openshift-cnv"

# Pinned to what the cluster's catalogs actually offer; re-check with
#   oc get packagemanifest <pkg> -n openshift-marketplace \
#     -o jsonpath='{.status.defaultChannel}{"\n"}'
# before moving a cluster to a different OpenShift minor.
NFD_CHANNEL="${NFD_CHANNEL:-stable}"
NFD_SOURCE="${NFD_SOURCE:-redhat-operators}"
GPU_CHANNEL="${GPU_CHANNEL:-v26.7}"
GPU_SOURCE="${GPU_SOURCE:-certified-operators}"
CNV_CHANNEL="${CNV_CHANNEL:-stable}"
CNV_SOURCE="${CNV_SOURCE:-redhat-operators}"

PASSED=0
FAILED=0

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  ⚠️  $1"; }
info() { echo "     $1"; }
step() { echo ""; echo "--- $1"; }

echo "========================================="
echo "  Operator bootstrap for GPU VM testing"
echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo '<not logged in>')"
echo "  User:    $(oc whoami 2>/dev/null || echo '?')"
echo "  Mode:    $([ "${APPLY}" = "1" ] && echo "APPLY (will install)" || echo "report only (APPLY=1 to install)")"
echo "========================================="

for bin in oc python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ Required binary '${bin}' not found."; exit 1; }
done
oc whoami >/dev/null 2>&1 || { echo "❌ Not logged in to a cluster."; exit 1; }

# ---------------------------------------------------------------- helpers ---

installed() { # installed <ns>  -> prints the Succeeded CSV name, if any
  oc get csv -n "$1" -o jsonpath='{range .items[?(@.status.phase=="Succeeded")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1
}

# Waits for any CSV in the namespace to reach Succeeded. Watching the
# subscription's .status.installedCSV is not enough on its own: it is set as
# soon as the InstallPlan resolves, well before the operator is actually up.
wait_csv() { # wait_csv <ns> <label>
  local ns="$1" label="$2"
  local deadline=$(( $(date +%s) + CSV_TIMEOUT )) csv=""
  echo "     waiting up to ${CSV_TIMEOUT}s for the ${label} CSV to reach Succeeded..."
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    csv="$(installed "${ns}")"
    if [ -n "${csv}" ]; then
      pass "${label}: ${csv} Succeeded"
      return 0
    fi
    local phase
    phase="$(oc get csv -n "${ns}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    echo "       ${label}: ${phase:-no CSV yet}"
    sleep 15
  done
  fail "${label} CSV did not reach Succeeded within ${CSV_TIMEOUT}s"
  info "Check: oc get csv,ip,sub -n ${ns}"
  return 1
}

# Operand CRs differ in shape by version, and hardcoding one risks setting a
# field the installed version does not have. Every operator ships a working
# example in the CSV's alm-examples annotation — that is the version-correct
# default, so start from it and override only what matters.
alm_example() { # alm_example <ns> <csv> <kind>
  oc get csv "$2" -n "$1" -o jsonpath='{.metadata.annotations.alm-examples}' 2>/dev/null \
    | KIND="$3" python3 -c '
import json, os, sys
try:
    examples = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in examples:
    if e.get("kind") == os.environ["KIND"]:
        print(json.dumps(e))
        sys.exit(0)
sys.exit(1)
'
}

ensure_namespace() { # ensure_namespace <ns>
  if oc get namespace "$1" >/dev/null 2>&1; then
    info "namespace/$1 already exists"
  else
    oc create namespace "$1"
  fi
}

# OLM rejects a second OperatorGroup in a namespace, so creating one blindly
# turns a re-run into an error.
ensure_operatorgroup() { # ensure_operatorgroup <ns> <name>
  if [ -n "$(oc get operatorgroup -n "$1" -o name 2>/dev/null)" ]; then
    info "operatorgroup already present in $1"
    return 0
  fi
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $2
  namespace: $1
spec:
  targetNamespaces:
    - $1
EOF
}

ensure_subscription() { # ensure_subscription <ns> <name> <pkg> <channel> <source>
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $2
  namespace: $1
spec:
  name: $3
  channel: $4
  source: $5
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
}

# ------------------------------------------------------------- report mode --

echo ""
echo "=== Current state ==="

for pair in "${NFD_NS}:Node Feature Discovery" "${GPU_NS}:NVIDIA GPU Operator" "${CNV_NS}:OpenShift Virtualization"; do
  ns="${pair%%:*}"; label="${pair#*:}"
  if oc get namespace "${ns}" >/dev/null 2>&1; then
    csv="$(installed "${ns}")"
    printf '     %-26s %s\n' "${label}" "${csv:-namespace exists, no Succeeded CSV}"
  else
    printf '     %-26s %s\n' "${label}" "not installed"
  fi
done

if [ "${APPLY}" != "1" ]; then
  echo ""
  echo "========================================="
  echo "  Report only — nothing was changed"
  echo "========================================="
  echo ""
  echo "APPLY=1 would, for each operator not already present:"
  [ "${WANT_NFD}" = "1" ] && echo "  - ${NFD_NS}:  subscribe to 'nfd' (${NFD_CHANNEL}/${NFD_SOURCE}), create a NodeFeatureDiscovery"
  [ "${WANT_GPU}" = "1" ] && echo "  - ${GPU_NS}:  subscribe to 'gpu-operator-certified' (${GPU_CHANNEL}/${GPU_SOURCE}), create a ClusterPolicy"
  [ "${WANT_CNV}" = "1" ] && echo "  - ${CNV_NS}:  subscribe to 'kubevirt-hyperconverged' (${CNV_CHANNEL}/${CNV_SOURCE}), create a HyperConverged"
  [ "${SANDBOX_WORKLOADS}" = "1" ] && echo "  - ClusterPolicy gets sandboxWorkloads.enabled=true, defaultWorkload=container"
  echo ""
  echo "The GPU operator loads the NVIDIA kernel module on every GPU node and"
  echo "OpenShift Virtualization runs virt-handler on every schedulable node."
  echo "Neither is confined to one namespace in effect, whatever the scope says."
  exit 0
fi

# --------------------------------------------------------------------- NFD --

if [ "${WANT_NFD}" = "1" ]; then
  step "1. Node Feature Discovery"
  if [ -n "$(installed "${NFD_NS}")" ]; then
    pass "already installed: $(installed "${NFD_NS}")"
  else
    ensure_namespace "${NFD_NS}"
    ensure_operatorgroup "${NFD_NS}" "openshift-nfd-group"
    ensure_subscription "${NFD_NS}" "nfd" "nfd" "${NFD_CHANNEL}" "${NFD_SOURCE}"
    wait_csv "${NFD_NS}" "NFD"
  fi

  NFD_CSV="$(installed "${NFD_NS}")"
  if [ -n "${NFD_CSV}" ]; then
    if oc get nodefeaturediscovery -n "${NFD_NS}" -o name 2>/dev/null | grep -q .; then
      pass "NodeFeatureDiscovery instance already exists"
    elif NFD_CR="$(alm_example "${NFD_NS}" "${NFD_CSV}" NodeFeatureDiscovery)"; then
      printf '%s' "${NFD_CR}" | oc apply -n "${NFD_NS}" -f -
      pass "NodeFeatureDiscovery created from the CSV's own example"
    else
      fail "Could not find a NodeFeatureDiscovery example in ${NFD_CSV}"
      info "Create one by hand from the console, then re-run."
    fi
  fi
fi

# ------------------------------------------------------------ GPU operator --

if [ "${WANT_GPU}" = "1" ]; then
  step "2. NVIDIA GPU Operator"
  if [ -n "$(installed "${GPU_NS}")" ]; then
    pass "already installed: $(installed "${GPU_NS}")"
  else
    ensure_namespace "${GPU_NS}"
    ensure_operatorgroup "${GPU_NS}" "nvidia-gpu-operator-group"
    ensure_subscription "${GPU_NS}" "gpu-operator-certified" "gpu-operator-certified" "${GPU_CHANNEL}" "${GPU_SOURCE}"
    wait_csv "${GPU_NS}" "GPU operator"
  fi

  GPU_CSV="$(installed "${GPU_NS}")"
  if [ -n "${GPU_CSV}" ]; then
    if oc get clusterpolicies.nvidia.com -o name 2>/dev/null | grep -q .; then
      pass "ClusterPolicy already exists: $(oc get clusterpolicies.nvidia.com -o name | head -1)"
    elif CP="$(alm_example "${GPU_NS}" "${GPU_CSV}" ClusterPolicy)"; then
      # Only touch sandboxWorkloads; everything else stays at the version's
      # own defaults, including the driver version, which must match what the
      # operator was built and certified against.
      CP="$(printf '%s' "${CP}" | SANDBOX="${SANDBOX_WORKLOADS}" python3 -c '
import json, os, sys
cp = json.load(sys.stdin)
if os.environ["SANDBOX"] == "1":
    sw = cp.setdefault("spec", {}).setdefault("sandboxWorkloads", {})
    sw["enabled"] = True
    # Nodes without an explicit nvidia.com/gpu.workload.config label keep the
    # container stack, so enabling this changes nothing until a node is
    # deliberately flipped.
    sw["defaultWorkload"] = "container"
print(json.dumps(cp))
')"
      printf '%s' "${CP}" | oc apply -f -
      pass "ClusterPolicy created$([ "${SANDBOX_WORKLOADS}" = "1" ] && echo " with sandboxWorkloads enabled")"
    else
      fail "Could not find a ClusterPolicy example in ${GPU_CSV}"
    fi
  fi
fi

# ----------------------------------------------------------------- CNV -----

if [ "${WANT_CNV}" = "1" ]; then
  step "3. OpenShift Virtualization"
  if [ -n "$(installed "${CNV_NS}")" ]; then
    pass "already installed: $(installed "${CNV_NS}")"
  else
    ensure_namespace "${CNV_NS}"
    ensure_operatorgroup "${CNV_NS}" "kubevirt-hyperconverged-group"
    ensure_subscription "${CNV_NS}" "hco-operatorhub" "kubevirt-hyperconverged" "${CNV_CHANNEL}" "${CNV_SOURCE}"
    wait_csv "${CNV_NS}" "OpenShift Virtualization"
  fi

  CNV_CSV="$(installed "${CNV_NS}")"
  if [ -n "${CNV_CSV}" ]; then
    if oc get hyperconverged -n "${CNV_NS}" -o name 2>/dev/null | grep -q .; then
      pass "HyperConverged already exists"
    elif HCO="$(alm_example "${CNV_NS}" "${CNV_CSV}" HyperConverged)"; then
      printf '%s' "${HCO}" | oc apply -n "${CNV_NS}" -f -
      pass "HyperConverged created from the CSV's own example"
    else
      fail "Could not find a HyperConverged example in ${CNV_CSV}"
    fi
  fi
fi

# ------------------------------------------------------------ settle/report --

step "4. Waiting for operands"

# The CSV going Succeeded only means the operator is running. The work that
# matters — NFD labelling nodes, the driver daemonset building and loading a
# kernel module, virt-handler rolling out — happens afterwards and takes much
# longer. Driver load is the slow one: first time on a node it may compile.
DEADLINE=$(( $(date +%s) + OPERAND_TIMEOUT ))
CP_STATE=""
HCO_STATE=""
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  GPU_NODES="$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  CP_STATE="$(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "-")"
  HCO_STATE="$(oc get hyperconverged -n "${CNV_NS}" -o jsonpath='{range .items[0].status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null || echo "-")"
  ALLOC="$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}' 2>/dev/null | tr -s ' ')"

  echo "     gpu.present nodes=${GPU_NODES}  clusterpolicy=${CP_STATE:--}  hco-available=${HCO_STATE:--}  allocatable gpus=[${ALLOC}]"

  READY=1
  [ "${WANT_GPU}" = "1" ] && [ "${CP_STATE}" != "ready" ] && READY=0
  [ "${WANT_CNV}" = "1" ] && [ "${HCO_STATE}" != "True" ] && READY=0
  [ "${READY}" = "1" ] && break
  sleep 20
done

if [ "${WANT_GPU}" = "1" ]; then
  if [ "${CP_STATE}" = "ready" ]; then
    pass "ClusterPolicy state=ready"
  else
    fail "ClusterPolicy state=${CP_STATE:-<none>} after ${OPERAND_TIMEOUT}s"
    info "Check: oc get pods -n ${GPU_NS}   (the driver daemonset is the usual holdout)"
  fi
fi
if [ "${WANT_CNV}" = "1" ]; then
  if [ "${HCO_STATE}" = "True" ]; then
    pass "HyperConverged Available=True"
  else
    fail "HyperConverged Available=${HCO_STATE:-<none>} after ${OPERAND_TIMEOUT}s"
    info "Check: oc get hyperconverged -n ${CNV_NS} -o yaml | grep -A5 conditions"
  fi
fi

echo ""
echo "========================================="
echo "  ${PASSED} passed, ${FAILED} failed"
echo "========================================="
echo ""
echo "Now re-run the preflight — it is the real acceptance test for this script:"
echo "  ./preflight.sh"
exit $([ "${FAILED}" -gt 0 ] && echo 1 || echo 0)
