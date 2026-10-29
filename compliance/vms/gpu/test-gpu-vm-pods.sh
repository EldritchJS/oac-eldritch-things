#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COSTS MONEY: claims GPU_COUNT passthrough GPUs for about 30 minutes.
# ---------------------------------------------------------------------------
# Can a tenant run pods on a passthrough GPU inside its own VM? That is the
# shape of a tenant's own Kubernetes (k3s here; a HyperShift KubeVirt
# NodePool would be the same inside the guest): the VM holds the whole GPU,
# and the tenant's cluster hands it to the tenant's pods.
#
#   1. test-gpu-vm.sh boots a VM holding GPU_COUNT GPUs and installs the
#      driver (MAX_TIER=2: no CUDA toolkit, the pod brings its own).
#   2. In the guest: NVIDIA's container toolkit, then k3s with nvidia as
#      the default runtime, then the NVIDIA device plugin.
#   3. The k3s node must advertise GPU_COUNT nvidia.com/gpu; a pod
#      requesting all of them lists them with nvidia-smi and runs the CUDA
#      vectorAdd sample.
#
# The guest needs to reach github.com, nvidia.github.io, get.k3s.io and
# nvcr.io.
#
# Usage: KUBECONFIG=... ./test-gpu-vm-pods.sh
#   NAMESPACE      project to create (default gpu-vm-pods; must not exist)
#   GPU_COUNT      GPUs for the VM (default 1)
#   NODE           passthrough node to put the VM on (default: any)
#   K3S_VERSION    k3s release, e.g. v1.33.5+k3s1 (default: the stable channel)
#   PLUGIN_VERSION NVIDIA device plugin release (default v0.17.1)
#   SAMPLE_IMAGE   CUDA test image (default nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04)
# Exit: 0 a pod in the VM ran CUDA on the GPUs, 1 it did not, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-gpu-vm-pods}"
GPU_COUNT="${GPU_COUNT:-1}"
NODE="${NODE:-}"
K3S_VERSION="${K3S_VERSION:-}"
PLUGIN_VERSION="${PLUGIN_VERSION:-v0.17.1}"
SAMPLE_IMAGE="${SAMPLE_IMAGE:-nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04}"
VM_NAME=gpu-vm-pods
GUEST_USER=ubuntu

oc get ns "$NAMESPACE" >/dev/null 2>&1 && { echo "project $NAMESPACE already exists" >&2; exit 2; }
oc create ns "$NAMESPACE" >/dev/null || exit 2
KEYDIR=""
cleanup() {
  oc delete ns "$NAMESPACE" --timeout=300s >/dev/null 2>&1
  [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"
}
trap cleanup EXIT

echo "=== 1. VM with ${GPU_COUNT} GPU(s) and the driver (test-gpu-vm.sh) ==="
OUT=$(NAMESPACE="$NAMESPACE" VM_NAME="$VM_NAME" GPU_COUNT="$GPU_COUNT" NODE="$NODE" MAX_TIER=2 KEEP_VM=1 ./test-gpu-vm.sh 2>&1)
printf '%s\n' "$OUT" | grep -E '✅|❌|Results:' | sed 's/^/  /'
KEYDIR=$(printf '%s\n' "$OUT" | sed -n 's/^SSH key kept in \(.*\) (delete.*/\1/p')
printf '%s' "$OUT" | grep -q 'VERIFICATION SUCCESS' && [ -n "$KEYDIR" ] || { echo "VM setup failed" >&2; exit 2; }

SSH_OPTS=(-i "$KEYDIR/id_ecdsa")
HELP="$(virtctl ssh --help 2>&1 || true)"
printf '%s' "$HELP" | grep -q -- '--local-ssh-opts' && SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
printf '%s' "$HELP" | grep -qE -- '--local-ssh([^-]|$)' && SSH_OPTS+=(--local-ssh=true)
TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
guest() { virtctl ssh "${SSH_OPTS[@]}" -c "$1" "$TARGET" </dev/null 2>/dev/null; }

cat > "$KEYDIR/k3s-gpu.sh" <<EOF
set -eu
k() { sudo k3s kubectl "\$@"; }

echo "STEP container toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
  sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' |
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y nvidia-container-toolkit >/dev/null

# k3s finds nvidia-container-runtime at start and adds it to containerd.
echo "STEP k3s"
curl -sfL https://get.k3s.io |
  sudo INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_EXEC="--default-runtime=nvidia" sh - >/dev/null
for _ in \$(seq 60); do k get node 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
echo "K3S \$(k version 2>/dev/null | sed -n 's/^Server Version: //p')"

echo "STEP device plugin ${PLUGIN_VERSION}"
k apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml >/dev/null
for _ in \$(seq 60); do
  n=\$(k get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')
  [ "\${n:-0}" -ge 1 ] && break; sleep 5
done
echo "ALLOCATABLE \${n:-0}"

echo "STEP pod"
cat <<POD | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: cuda}
spec:
  restartPolicy: Never
  containers:
    - name: cuda
      image: ${SAMPLE_IMAGE}
      command: ["sh", "-c", "nvidia-smi -L && /cuda-samples/vectorAdd"]
      env: [{name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}]
      resources: {limits: {nvidia.com/gpu: ${GPU_COUNT}}}
POD
for _ in \$(seq 120); do
  case "\$(k get pod cuda -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac; sleep 5
done
echo "PHASE \$(k get pod cuda -o jsonpath='{.status.phase}')"
k logs cuda 2>&1 | sed 's/^/POD /'
EOF

echo "=== 2. container toolkit, k3s and device plugin, in the guest ==="
virtctl scp "${SSH_OPTS[@]}" "$KEYDIR/k3s-gpu.sh" "$TARGET:k3s-gpu.sh" </dev/null >/dev/null 2>&1 || { echo "scp failed" >&2; exit 2; }
RUN=$(guest 'bash k3s-gpu.sh 2>&1'); printf '%s\n' "$RUN" | sed 's/^/  /'

echo "=== 3. result ==="
ALLOC=$(printf '%s\n' "$RUN" | sed -n 's/^ALLOCATABLE //p')
LISTED=$(printf '%s\n' "$RUN" | grep -c '^POD GPU [0-9]*:')
printf '%s\n' "$RUN" | grep -q '^PHASE' || { echo "INCONCLUSIVE: the guest setup stopped before the pod (see above)"; exit 2; }
echo "  k3s node advertises nvidia.com/gpu=${ALLOC:-0}; the pod saw ${LISTED} GPU(s)"
if [ "${ALLOC:-0}" = "$GPU_COUNT" ] && [ "$LISTED" = "$GPU_COUNT" ] &&
   printf '%s\n' "$RUN" | grep -q '^POD Test PASSED' && printf '%s\n' "$RUN" | grep -q '^PHASE Succeeded'; then
  echo "PASS a pod in the VM's own Kubernetes ran CUDA on the VM's ${GPU_COUNT} passthrough GPU(s)"; exit 0
fi
echo "FAIL no pod in the VM ran CUDA on all ${GPU_COUNT} GPU(s)"; exit 1
