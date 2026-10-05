#!/usr/bin/env bash
set -euo pipefail

# Automated proof that a VM on OpenShift Virtualization comes up, can reach the
# outside world, and can be reached (and written to) from outside.
#
# Results come back over `virtctl ssh` rather than an in-guest web server: the
# cirros image's busybox has no httpd applet, so there is nothing to serve with.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-self-test-vm}"
TIMEOUT="${TIMEOUT:-180s}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
SSH_TIMEOUT="${SSH_TIMEOUT:-45}"
KEEP_VM="${KEEP_VM:-0}"   # set to 1 to leave the VM running for debugging
GUEST_USER="${GUEST_USER:-cirros}"
WORKDIR=""

echo "=== 0. Preflight ==="

# Every resource below is addressed with an explicit -n, so there is no need to
# change the user's active project — doing so would leave their shell pointed
# somewhere else after the test exits.
for bin in oc virtctl ssh-keygen; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "❌ Required binary '${bin}' not found in PATH."
    if [ "${bin}" = "virtctl" ]; then
      echo "   Get the download URL with:"
      echo "   oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'"
    fi
    exit 1
  fi
done

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "❌ Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

# Fail before creating anything if a previous run left a VM behind. Silently
# reusing it would report on a guest this run never configured.
if oc get vm "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ Leftover vm/${VM_NAME} from a previous run exists in ${NAMESPACE}. Remove it first:"
  echo "   oc delete vm ${VM_NAME} -n ${NAMESPACE} --ignore-not-found"
  exit 1
fi
echo "no leftover objects from a previous run"

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_VM}" = "1" ]; then
    echo "KEEP_VM=1, leaving vm/${VM_NAME} running. Delete with:"
    echo "  oc delete vm ${VM_NAME} -n ${NAMESPACE}"
  else
    oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false
  fi
  [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  echo "Done!"
}
trap cleanup EXIT

# Portable timeout: macOS has no coreutils `timeout` by default.
run_with_timeout() {
  local secs="$1"; shift
  local rc=0 pid watcher
  "$@" & pid=$!
  ( sleep "${secs}"; kill -9 "${pid}" 2>/dev/null ) & watcher=$!
  wait "${pid}" 2>/dev/null || rc=$?
  kill "${watcher}" 2>/dev/null || true
  wait "${watcher}" 2>/dev/null || true
  return "${rc}"
}

# Ephemeral keypair, thrown away on exit. ECDSA rather than RSA to stay under
# KubeVirt's 2048-byte inline userdata cap (~170 bytes on the wire vs ~400), and
# rather than ed25519 because the cirros guest runs an older dropbear.
WORKDIR="$(mktemp -d "/tmp/${VM_NAME}-selftest.XXXXXX")"
SSH_KEY="${WORKDIR}/id_ecdsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "${SSH_KEY}" -C "selftest"
SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

# Nonce proves the file we read back is the one we pushed, not a leftover.
NONCE="inbound-$(date +%s)-${RANDOM}"
printf 'INBOUND_TRANSFER_TOKEN=%s\n' "${NONCE}" > "${WORKDIR}/upload.txt"

# The guest script is terse on purpose: this namespace allows neither secrets
# nor configmaps, so the payload must fit KubeVirt's 2048-byte inline
# cloudInitNoCloud limit. Explanation lives here rather than in the payload.
#
#   - authorized_keys is written by hand because cirros ships a cut-down
#     cloud-init with no ssh_authorized_keys support.
#   - dropbear rejects the key if .ssh or authorized_keys is group/world writable.
#   - The report is mv'd into place atomically so a poll never reads it half-written.
cat > "${WORKDIR}/user-data" <<EOF
#!/bin/sh
PATH=\$PATH:/sbin:/usr/sbin
H=\$(getent passwd ${GUEST_USER} 2>/dev/null|cut -d: -f6)
[ -n "\$H" ] || H=/home/${GUEST_USER}
mkdir -p \$H/.ssh
echo "${SSH_PUBKEY}" > \$H/.ssh/authorized_keys
chown -R ${GUEST_USER} \$H/.ssh 2>/dev/null
chmod 700 \$H/.ssh; chmod 600 \$H/.ssh/authorized_keys
R=/tmp/selftest-report
n=0
while [ \$n -lt 60 ]; do
ip route 2>/dev/null|grep -q ^default && break
n=\$((n+1)); sleep 1
done
{
echo "=== IN-VM TEST REPORT ==="
uname -a
ip -4 addr show 2>/dev/null || ifconfig 2>/dev/null
ip route 2>/dev/null
if ping -c 3 -w 20 8.8.8.8 2>&1; then echo PING_TEST_PASSED; else echo PING_TEST_FAILED; fi
if nslookup example.com 2>&1; then echo DNS_TEST_PASSED; else echo DNS_TEST_FAILED; fi
L=\$({ curl -sS -m 20 -I http://example.com 2>&1 || wget -S -O /dev/null -T 20 http://example.com 2>&1; }|grep -m1 HTTP/)
echo "\${L:-no-http-response}"
case "\$L" in *HTTP/*) echo HTTP_TEST_PASSED;; *) echo HTTP_TEST_FAILED;; esac
echo TESTS_COMPLETE
} > \$R.tmp 2>&1
chmod 644 \$R.tmp
mv \$R.tmp \$R
EOF

UD_BYTES=$(wc -c < "${WORKDIR}/user-data" | tr -d ' ')
echo ""
echo "=== 1. Deploying Self-Testing VM Manifest ==="
echo "cloud-init userdata: ${UD_BYTES} bytes (KubeVirt inline cap is 2048)"
if [ "${UD_BYTES}" -gt 2048 ]; then
  echo "❌ Error: userdata exceeds the inline limit and this namespace cannot create secrets."
  exit 1
fi

USERDATA_BLOCK="$(sed 's/^/            /' "${WORKDIR}/user-data")"

# NOTE: deliberately no `ports:` list on the masquerade interface. Listing ports
# makes KubeVirt forward *only* those, which silently blocks SSH on 22 and makes
# every virtctl ssh/scp fail with "connection refused".
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          interfaces:
          - name: default
            masquerade: {}
        resources:
          requests:
            memory: 128Mi
      networks:
      - name: default
        pod: {}
      volumes:
      - containerDisk:
          image: quay.io/kubevirt/cirros-container-disk-demo
        name: containerdisk
      - cloudInitNoCloud:
          userData: |
${USERDATA_BLOCK}
        name: cloudinitdisk
EOF

echo ""
echo "=== 2. Waiting for VMI Creation & Ready State ==="
for i in $(seq 1 15); do
  if oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for VMI object to spawn (attempt ${i}/15)..."
  sleep 2
done

oc wait --for=condition=Ready "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout="${TIMEOUT}"

# virtctl's SSH flags moved around between releases, so probe --help rather than
# assuming. The exact-match guard on --local-ssh matters: a plain substring test
# also matches --local-ssh-opts, and virtctl 1.9 has the latter but not the
# former, so a loose test passes an unknown flag and every call fails.
SSH_HELP="$(virtctl ssh --help 2>&1 || true)"
SSH_OPTS=(-i "${SSH_KEY}")
if printf '%s' "${SSH_HELP}" | grep -q -- '--local-ssh-opts'; then
  # Without these the local ssh binary aborts on the unknown host key. The VM is
  # new every run, so its key is never in known_hosts.
  SSH_OPTS+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
fi
if printf '%s' "${SSH_HELP}" | grep -q -- '--known-hosts'; then
  : > "${WORKDIR}/known_hosts"
  SSH_OPTS+=(--known-hosts "${WORKDIR}/known_hosts")
fi
if printf '%s' "${SSH_HELP}" | grep -qE -- '--local-ssh([^-]|$)'; then
  SSH_OPTS+=(--local-ssh=true)
fi

SSH_TARGET="${GUEST_USER}@vmi/${VM_NAME}/${NAMESPACE}"
SSH_LOG="${WORKDIR}/ssh.log"

guest_ssh() { # guest_ssh <remote command>
  run_with_timeout "${SSH_TIMEOUT}" virtctl ssh "${SSH_OPTS[@]}" -c "$1" "${SSH_TARGET}" \
    < /dev/null > "${SSH_LOG}" 2>&1
}

echo ""
echo "=== 3. Fetching Test Results from Guest VM (virtctl ssh) ==="
RESULT=""
for i in $(seq 1 "${POLL_ATTEMPTS}"); do
  if guest_ssh "cat /tmp/selftest-report 2>/dev/null"; then
    RESULT="$(grep -v 'different from the KubeVirt version\|^Client Version:\|^Server Version:\|Permanently added' "${SSH_LOG}" || true)"
    if printf '%s' "${RESULT}" | grep -q "TESTS_COMPLETE"; then
      echo "Guest reported TESTS_COMPLETE after ${i} attempt(s)."
      break
    fi
    echo "SSH is up, in-guest tests still running (attempt ${i}/${POLL_ATTEMPTS})..."
  else
    echo "Waiting for guest SSH to accept connections (attempt ${i}/${POLL_ATTEMPTS})..."
  fi
  RESULT=""
  sleep "${POLL_INTERVAL}"
done

echo ""
echo "--- IN-VM TEST OUTPUT ---"
echo "${RESULT:-<no report retrieved from guest>}"
echo "--------------------------"
echo ""

echo "=== 4. Transferring a File Into the Guest (virtctl scp) ==="
SCP_LOG="${WORKDIR}/scp.log"
FETCHED=""

SCP_OPTS=("${SSH_OPTS[@]}")
if printf '%s' "${SSH_HELP}" | grep -q -- '--local-ssh-opts'; then
  # -O forces the legacy scp protocol. Modern scp defaults to SFTP, and cirros
  # has no /usr/libexec/sftp-server, so the default fails with "Connection closed".
  SCP_OPTS+=(-t "-O")
fi

echo "Pushing upload.txt to ${SSH_TARGET}:/tmp/upload.txt ..."
if run_with_timeout "${SSH_TIMEOUT}" virtctl scp "${SCP_OPTS[@]}" \
     "${WORKDIR}/upload.txt" "${SSH_TARGET}:/tmp/upload.txt" \
     < /dev/null > "${SCP_LOG}" 2>&1; then
  echo "scp reported success; reading the file back out of the guest..."
  if guest_ssh "cat /tmp/upload.txt 2>/dev/null"; then
    FETCHED="$(cat "${SSH_LOG}")"
  fi
else
  echo "scp did not complete. Log:"
  cat "${SCP_LOG}" 2>/dev/null || true
fi

echo ""
echo "=== 5. Verdict ==="
FAILED=0

check() { # check <token> <human description>
  if printf '%s' "${RESULT}" | grep -q "$1"; then
    echo "  ✅ $2"
  else
    echo "  ❌ $2"
    FAILED=1
  fi
}

# Retrieving the report at all means we opened an authenticated SSH session into
# the guest, so inbound reachability is proven by the same fact.
if [ -n "${RESULT}" ]; then
  echo "  ✅ VM is up and reachable inbound (authenticated SSH into guest)"
else
  echo "  ❌ VM is up and reachable inbound (authenticated SSH into guest)"
  FAILED=1
fi

check "TESTS_COMPLETE"   "In-guest test suite ran to completion"
check "PING_TEST_PASSED" "Egress ICMP  — VM can ping out (8.8.8.8)"
check "DNS_TEST_PASSED"  "Egress DNS   — VM can resolve example.com"
check "HTTP_TEST_PASSED" "Egress HTTP  — VM can fetch http://example.com"

if printf '%s' "${FETCHED}" | grep -q "${NONCE}"; then
  echo "  ✅ Inbound file transfer — scp landed ${NONCE} on the guest filesystem"
else
  echo "  ❌ Inbound file transfer — scp of ${NONCE} not verifiable in guest"
  FAILED=1
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
  echo "✅ VERIFICATION SUCCESS: OpenShift VM compute and networking are fully operational!"
else
  echo "❌ VERIFICATION FAILED: see the ❌ lines above."
  if [ -s "${SSH_LOG}" ]; then
    echo ""
    echo "Last ssh output:"
    cat "${SSH_LOG}"
  fi
  if [ -s "${SCP_LOG}" ]; then
    echo ""
    echo "scp Log:"
    cat "${SCP_LOG}"
  fi
  echo ""
  echo "VMI status:"
  oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o wide || true
  echo ""
  echo "Re-run with KEEP_VM=1 to keep the VM for console access:"
  echo "  KEEP_VM=1 ./$(basename "$0")"
  echo "  virtctl console ${VM_NAME} -n ${NAMESPACE}   # login: cirros / gocubsgo"
  exit 1
fi
