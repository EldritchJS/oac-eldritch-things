#!/usr/bin/env bash
# Verification harness — compliance + GPU + virtualisation. Written for
# jetty; runs on any standalone cluster or hub (compliant-dev-infra,
# MOC-issues #777). GPU tests skip on clusters without GPUs.
#
# READ-ONLY. Every check here inspects state; none mutates the cluster.
# The mutating test (GPU switch turnaround, T-08) is a separate script:
#   ./gpu-switch-timing.sh
#
# Purpose: a regression net to run BEFORE and AFTER cluster hardening.
# Remediating the 800-171 baseline is ~377 MachineConfigs and a rolling reboot
# of every node; this proves FIPS, compliance posture, ACS, and BOTH GPU
# modalities still work on the other side.
#
# Usage:
#   ./verify.sh                  # run everything
#   ./verify.sh -t t01,t06,t07   # run a subset
#   ./verify.sh -l               # list tests
#   ./verify.sh --save-baseline  # record current FAIL counts as the baseline
#
# The baseline is per cluster: baseline-<cluster>.txt (jetty's is
# baseline-fail-counts.txt), <cluster> from the API server's hostname.
#
# Exit: 0 all passed, 1 one or more FAILed. WARN/SKIP do not fail the run.
set -uo pipefail

cd "$(dirname "$0")" || exit 2
DEVICE_RESOURCE="${DEVICE_RESOURCE:-}"   # passthrough resource; read from each node when empty
export DEVICE_RESOURCE
GPU_NS=nvidia-gpu-operator
CO_NS=openshift-compliance
ACS_NS=stackrox
SCAN_MAX_AGE_HOURS="${SCAN_MAX_AGE_HOURS:-48}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-26}"   # nightly + slack for one retried night

PASS=0; FAIL=0; WARN=0; SKIP=0; ONLY=""; SAVE_BASELINE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -t) ONLY="$2"; shift 2 ;;
    -l) grep -oE '^run_t[0-9]+\(\)' "$0" | tr -d '()' | sed 's/run_//'; exit 0 ;;
    --save-baseline) SAVE_BASELINE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; R=""; Y=""; B=""; N=""; fi

hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s %s\n' "$Y" "$N" "$*"; WARN=$((WARN+1)); }
skip() { printf '  SKIP %s\n' "$*"; SKIP=$((SKIP+1)); }
info() { printf '       %s\n' "$*"; }

jp() { oc get "$1" "${2:-}" ${3:+-n "$3"} -o jsonpath="$4" 2>/dev/null; }

# Pods in a namespace on a given node, as text. Returned via a variable rather
# than piped, because `set -o pipefail` + `grep -q` is a trap: grep exits on
# the first match, oc gets SIGPIPE (141), and pipefail reports the whole
# pipeline as failed even though the match succeeded. That produced a false
# "no driver daemonset Running" here once already.
pods_on() { oc get pods -n "$1" --field-selector "spec.nodeName=$2" --no-headers 2>/dev/null; }
has_line() { printf '%s\n' "$1" | grep -qE "$2"; }

# --------------------------------------------------------------- T-01 ------
run_t01() {
  hdr "T-01  FIPS mode on every node"
  local nodes bad_nodes=0
  nodes=$(oc get nodes -o name 2>/dev/null | sed 's|node/||')
  [ -z "$nodes" ] && { bad "cannot list nodes"; return; }
  for n in $nodes; do
    local out fips cmdline policy attempt
    # `oc debug` schedules a pod and intermittently fails to start one. Retry
    # before reporting: a flaky FAIL in a regression suite is worse than a slow
    # one, because people stop believing it.
    out=""
    for attempt in 1 2 3; do
      out=$(oc debug "node/$n" -n default --quiet -- chroot /host /bin/bash -c \
        'printf "%s|%s|%s" "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" \
          "$(grep -o "fips=1" /proc/cmdline || echo MISSING)" \
          "$(update-crypto-policies --show 2>/dev/null)"' 2>/dev/null | tr -d '\r')
      case "$out" in *"|"*) break ;; esac   # got a usable reading
      [ "$attempt" -lt 3 ] && sleep 5
    done
    case "$out" in
      *"|"*) ;;
      *) # A hosted spoke may not allow debug pods: that is "unknown", not "off".
         if [ "$(jp infrastructure cluster "" '{.status.controlPlaneTopology}')" = External ]; then
           warn "$n  could not read FIPS state (no debug pod on this hosted cluster); check the HostedCluster's spec.fips on the hub"
         else
           bad "$n  could not read FIPS state after 3 attempts (oc debug failed)"; bad_nodes=$((bad_nodes+1))
         fi
         continue ;;
    esac
    fips="${out%%|*}"; policy="${out##*|}"; cmdline=$(echo "$out" | cut -d'|' -f2)
    if [ "$fips" = "1" ] && [ "$cmdline" = "fips=1" ] && [ "$policy" = "FIPS" ]; then
      ok "$n  fips_enabled=1 cmdline=fips=1 policy=FIPS"
    else
      bad "$n  fips_enabled='$fips' cmdline='$cmdline' policy='$policy'"
      bad_nodes=$((bad_nodes+1))
    fi
  done
  [ "$bad_nodes" -gt 0 ] && info "FIPS cannot be enabled post-install. A failure here means drift or a rebuilt node."
}

# --------------------------------------------------------------- T-02 ------
run_t02() {
  hdr "T-02  FIPS validation (CMVP 140-3)"
  info "FIPS *mode* (T-01) is not FIPS *validation*. Record: ./fips-cmvp-certificates.md"
  local rec=./fips-cmvp-certificates.md reviewed certified img p n v
  if [ ! -f "$rec" ]; then
    warn "No CMVP certificate record ($rec). Document the 140-3 status of the"
    info "RHEL modules (OpenSSL FIPS provider, kernel crypto API, GnuTLS, libgcrypt)."
    return
  fi
  ok "CMVP certificate record present"
  reviewed=$(sed -n 's/^REVIEWED_RHCOS=//p' "$rec")
  certified=$(sed -n 's/^CERTIFIED_OPENSSL_PROVIDER_VERSION=//p' "$rec")

  # Every node must run the RHCOS the record was reviewed against; module
  # versions move with RHCOS, so a new one means the record is stale.
  img=$(oc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' | sort -u)
  if [ "$img" = "$reviewed" ]; then
    ok "record reviewed against the running RHCOS ($img)"
  else
    warn "RHCOS changed since the record was reviewed — re-review it"
    info "reviewed: $reviewed"; info "running:  $(printf '%s' "$img" | tr '\n' ';')"
  fi

  # Running OpenSSL FIPS provider version, per node, read through the
  # machine-config-daemon pods (host / at /rootfs) so no debug pods are made.
  local mismatch="" seen=""
  for p in $(oc get pods -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -o name 2>/dev/null); do
    n=$(oc get "$p" -n openshift-machine-config-operator -o jsonpath='{.spec.nodeName}')
    v=$(oc exec -n openshift-machine-config-operator "$p" -c machine-config-daemon -- \
        chroot /rootfs sh -c 'openssl list -providers 2>/dev/null' 2>/dev/null \
        | awk '/fips/{f=1} f&&/version:/{print $2; exit}')
    seen="$seen $n=${v:-unknown}"
    [ "$v" = "$certified" ] || mismatch="$mismatch $n(${v:-unknown})"
  done
  if [ -z "$seen" ]; then
    warn "could not read the OpenSSL FIPS provider version from any node"
  elif [ -z "$mismatch" ]; then
    ok "OpenSSL FIPS provider is the certified version ($certified) on all nodes"
  else
    warn "OpenSSL FIPS provider is NOT the certified version $certified on:$mismatch"
    info "See fips-cmvp-certificates.md §1 — validation of the running build in process."
  fi
}

# --------------------------------------------------------------- T-03 ------
run_t03() {
  hdr "T-03  Compliance scans fresh and not regressed"
  local suites
  suites=$(oc get compliancesuite -n "$CO_NS" -o name 2>/dev/null | sed 's|.*/||')
  [ -z "$suites" ] && { bad "no ComplianceSuites found"; return; }
  for s in $suites; do
    local phase; phase=$(jp compliancesuite "$s" "$CO_NS" '{.status.phase}')
    [ "$phase" = "DONE" ] && ok "suite $s phase=DONE" || bad "suite $s phase=$phase"
  done

  # Freshness: newest ComplianceScan endTimestamp.
  #
  # NOT the newest ComplianceCheckResult creationTimestamp — a rescan UPDATES
  # existing CCRs in place rather than recreating them, so their
  # creationTimestamp is frozen at whenever the rule first appeared. Measured
  # directly: CCRs read 20:09:35Z while the scan that had just finished read
  # 22:10:40Z. Using the CCR timestamp makes freshness drift upward forever and
  # eventually false-WARN "scans may have stopped" on a perfectly healthy
  # nightly schedule. endTimestamp is the only field that tracks actual runs.
  local newest age_h
  newest=$(oc get compliancescan -n "$CO_NS" -o jsonpath='{range .items[*]}{.status.endTimestamp}{"\n"}{end}' 2>/dev/null | grep . | sort | tail -1)
  if [ -n "$newest" ]; then
    age_h=$(python3 -c "
import datetime,sys
t=datetime.datetime.strptime('$newest','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()//3600))")
    [ "$age_h" -le "$SCAN_MAX_AGE_HOURS" ] \
      && ok "results ${age_h}h old (<= ${SCAN_MAX_AGE_HOURS}h)" \
      || warn "results ${age_h}h old (> ${SCAN_MAX_AGE_HOURS}h) — scans may have stopped"

    # Absolute age is not enough. The documented workflow is "run this after
    # each remediation stage", and a scan can sit comfortably inside the 48h
    # window while still PREDATING the change you are trying to verify.
    #
    # That happened for real: stage 2 applied 377 MachineConfigs and rebooted
    # every node at 12:58-13:09Z, but the newest scan was the 01:02Z nightly.
    # T-03 reported "12h old" and "matches baseline" — a green result that
    # described the cluster as it was BEFORE the hardening. The baseline
    # comparison below is meaningless whenever this is true.
    local newest_mc
    newest_mc=$(oc get mc -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null \
      | grep . | sort | tail -1)
    if [ -n "$newest_mc" ] && [ "$newest_mc" \> "$newest" ]; then
      warn "STALE: newest MachineConfig ($newest_mc) is NEWER than the newest"
      info "     scan ($newest). These results predate the last cluster change,"
      info "     so the baseline comparison below does NOT reflect current state."
      info "     Rescan before trusting it:"
      info "       for s in \$(oc get compliancescan -n $CO_NS -o name | sed 's|.*/||'); do"
      info "         oc annotate compliancescan \$s -n $CO_NS compliance.openshift.io/rescan= --overwrite; done"
    fi
  fi

  # regression vs baseline
  local cur; cur=$(mktemp)
  for scan in $(oc get compliancescan -n "$CO_NS" -o name 2>/dev/null | sed 's|.*/||'); do
    local n; n=$(oc get ccr -n "$CO_NS" \
      -l "compliance.openshift.io/scan-name=$scan,compliance.openshift.io/check-status=FAIL" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "$scan $n" >> "$cur"
  done
  if [ "$SAVE_BASELINE" = "1" ]; then
    cp "$cur" "$BASELINE_FILE"; ok "baseline saved -> $BASELINE_FILE"; cat "$cur" | sed 's/^/       /'
  elif [ -f "$BASELINE_FILE" ]; then
    while read -r scan n; do
      local base; base=$(awk -v s="$scan" '$1==s{print $2}' "$BASELINE_FILE")
      if [ -z "$base" ]; then warn "$scan: $n FAIL (new scan, no baseline)"
      elif [ "$n" -gt "$base" ]; then bad "$scan: $n FAIL (baseline $base) — REGRESSED"
      elif [ "$n" -lt "$base" ]; then ok "$scan: $n FAIL (baseline $base) — improved"
      else ok "$scan: $n FAIL (matches baseline)"; fi
    done < "$cur"
  else
    warn "no baseline file; run --save-baseline to create one"
    cat "$cur" | sed 's/^/       /'
  fi
  rm -f "$cur"

  # Rules disabled in the jetty TailoredProfiles as SCANNER FALSE POSITIVES
  # are checked here directly, so disabling the rule does not stop testing
  # the control. ocp4-openshift-api-server-audit-log-path (OCPBUGS-126610):
  # the content reads the wrong ConfigMap; this reads the right one.
  local oas_path
  if is_hosted; then
    # HyperShift: the config is YAML in the hub's control plane namespace.
    if [ -z "${HUB_KUBECONFIG:-}" ]; then
      skip "hosted cluster: openshift-apiserver runs on the hub; set HUB_KUBECONFIG to check its audit-log-path"
      return
    fi
    oas_path=$(hub_oc get configmap openshift-apiserver -n "$HCP_NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
      | python3 -c 'import sys,yaml; print(((yaml.safe_load(sys.stdin) or {}).get("apiServerArguments",{}).get("audit-log-path") or [""])[0])' 2>/dev/null)
  else
    oas_path=$(oc get configmap config -n openshift-apiserver -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
      | python3 -c 'import json,sys; print((json.load(sys.stdin).get("apiServerArguments",{}).get("audit-log-path") or [""])[0])' 2>/dev/null)
  fi
  [ "$oas_path" = "/var/log/openshift-apiserver/audit.log" ] \
    && ok "openshift-apiserver audit-log-path set ($oas_path) — checked here; scanner rule disabled (OCPBUGS-126610)" \
    || bad "openshift-apiserver audit-log-path is '${oas_path:-unset}', expected /var/log/openshift-apiserver/audit.log"
}

# --------------------------------------------------------------- T-04 ------
run_t04() {
  hdr "T-04  Raw ARF evidence is archived"
  local enabled pvcs
  for ss in $(oc get scansetting -n "$CO_NS" -o name 2>/dev/null | sed 's|.*/||'); do
    enabled=$(jp scansetting "$ss" "$CO_NS" '{.rawResultStorage.enabled}')
    if [ "$enabled" = "false" ]; then
      warn "ScanSetting $ss has rawResultStorage.enabled=false — results are NOT durable audit evidence"
    fi
  done
  pvcs=$(oc get pvc -n "$CO_NS" --no-headers 2>/dev/null | grep -c Bound)
  [ "${pvcs:-0}" -gt 0 ] \
    && ok "$pvcs bound result PVC(s) in $CO_NS" \
    || bad "no bound result PVCs — raw ARF is not being archived"
}

# --------------------------------------------------------------- T-05 ------
run_t05() {
  hdr "T-05  RHACS healthy"
  local c s
  if is_hosted; then
    # Central is the hub's; this cluster runs only the SecuredCluster.
    c=$(hub_oc get central stackrox-central-services -n "$ACS_NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    [ -z "${HUB_KUBECONFIG:-}" ] && c="unknown (hosted: set HUB_KUBECONFIG to check the hub's Central)"
  else
    c=$(jp central stackrox-central-services "$ACS_NS" '{.status.conditions[?(@.type=="Available")].status}')
  fi
  s=$(jp securedcluster stackrox-secured-cluster-services "$ACS_NS" '{.status.conditions[?(@.type=="Available")].status}')
  [ "$c" = "True" ] && ok "Central Available" || bad "Central Available=$c"
  [ "$s" = "True" ] && ok "SecuredCluster Available" || bad "SecuredCluster Available=$s"
  # Count pods whose READY column is not n/n, excluding Completed.
  # Deliberately awk, not `grep -E '([0-9]+)/\1'` — ERE backreferences are not
  # portable (they work in BSD/GNU grep, fail in ugrep), and a grep that errors
  # returns empty, which can read as "nothing wrong".
  local notready
  notready=$(oc get pods -n "$ACS_NS" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if ($3!="Completed" && (a[1]!=a[2] || $3!="Running")) c++} END{print c+0}')
  [ "${notready:-}" = "0" ] && ok "all $ACS_NS pods ready" || bad "${notready:-?} pod(s) not ready in $ACS_NS"
  local coll exp
  coll=$(oc get pods -n "$ACS_NS" --no-headers 2>/dev/null | grep -c '^collector-')
  exp=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$coll" = "$exp" ] && ok "collector on all $exp nodes" || warn "collector on $coll of $exp nodes"
}

# --------------------------------------------------------------- T-06 ------
run_t06() {
  hdr "T-06  GPU container modality"
  local found=0
  for n in $(oc get nodes -o name 2>/dev/null | sed 's|node/||'); do
    local mode cap
    mode=$(jp node "$n" "" '{.metadata.labels.nvidia\.com/gpu\.workload\.config}')
    cap=$(jp node "$n" "" '{.status.capacity.nvidia\.com/gpu}')
    [ -z "$cap" ] && continue           # no GPUs on this node at all
    [ -n "$mode" ] && [ "$mode" != "container" ] && continue
    found=1
    local alloc; alloc=$(jp node "$n" "" '{.status.allocatable.nvidia\.com/gpu}')
    [ -n "$alloc" ] && [ "$alloc" != "0" ] \
      && ok "$n advertises nvidia.com/gpu=$alloc" \
      || bad "$n in container mode but advertises nvidia.com/gpu='$alloc'"
    local p; p=$(pods_on "$GPU_NS" "$n")
    if has_line "$p" 'nvidia-driver-daemonset.*Running'; then
      ok "$n host NVIDIA driver running"
    else
      bad "$n container mode but no driver daemonset Running"
    fi
  done
  [ "$found" = "0" ] && skip "no node currently in container modality"
}

# --------------------------------------------------------------- T-07 ------
run_t07() {
  hdr "T-07  GPU VM-passthrough modality"
  local found=0 seen=""
  for n in $(oc get nodes -o name 2>/dev/null | sed 's|node/||'); do
    local mode; mode=$(jp node "$n" "" '{.metadata.labels.nvidia\.com/gpu\.workload\.config}')
    [ "$mode" != "vm-passthrough" ] && continue
    found=1
    # The sandbox device plugin advertises the card under its model name
    # (nvidia.com/GH100_H100_SXM5_80GB on jetty). Read it from the node unless
    # DEVICE_RESOURCE pins one, so other GPU models do not fail falsely.
    local res
    res=$(oc get node "$n" -o json 2>/dev/null | python3 -c '
import json, os, sys
a = json.load(sys.stdin)["status"].get("allocatable", {})
want = os.environ.get("DEVICE_RESOURCE")
for k, v in a.items():
    if k.startswith("nvidia.com/") and k != "nvidia.com/gpu" and (not want or k == want):
        print(k + "=" + v)')
    if [ -z "$res" ]; then
      bad "$n in vm-passthrough but advertises no device resource${DEVICE_RESOURCE:+ $DEVICE_RESOURCE}"
    fi
    local r
    for r in $res; do
      [ "${r#*=}" != "0" ] && ok "$n advertises $r" || bad "$n in vm-passthrough but advertises $r"
      case " $seen " in *" ${r%%=*} "*) ;; *) seen="$seen ${r%%=*}" ;; esac
    done
    local p; p=$(pods_on "$GPU_NS" "$n")
    if has_line "$p" 'nvidia-vfio-manager.*Running'; then
      ok "$n vfio-manager running"
    else
      bad "$n no vfio-manager Running"
    fi
    if has_line "$p" 'nvidia-driver-daemonset'; then
      bad "$n host driver still present — it must NOT claim the GPU in passthrough mode"
    else
      ok "$n host driver absent (correct)"
    fi
  done
  [ "$found" = "0" ] && { skip "no node currently in vm-passthrough modality"; return; }

  # permittedHostDevices must be present on BOTH the manager and the managed CR.
  # PATH GOTCHA: on hco.kubevirt.io/v1 this lives under spec.virtualization.
  # The v1beta1 top-level path returns empty on a v1 object and makes a correct
  # config look missing. Check both so a version bump cannot silently fool us.
  local hco kv
  hco=$(jp hyperconverged kubevirt-hyperconverged openshift-cnv '{.spec.virtualization.permittedHostDevices.pciHostDevices[*].resourceName}')
  [ -z "$hco" ] && hco=$(jp hyperconverged kubevirt-hyperconverged openshift-cnv '{.spec.permittedHostDevices.pciHostDevices[*].resourceName}')
  kv=$(jp kubevirt kubevirt-kubevirt-hyperconverged openshift-cnv '{.spec.configuration.permittedHostDevices.pciHostDevices[*].resourceName}')
  for r in $seen; do
    case "$hco" in *"$r"*) ok "HCO permits $r" ;;
      *) bad "HCO does NOT permit $r (got '$hco')" ;; esac
    case "$kv" in *"$r"*) ok "KubeVirt CR permits $r" ;;
      *) bad "KubeVirt CR does NOT permit $r (got '$kv') — HCO propagation broken" ;; esac
  done
}

# --------------------------------------------------------------- T-10 ------
run_t10() {
  hdr "T-10  Registry allowlist sanity"
  local allowed
  allowed=$(jp image.config.openshift.io cluster "" '{.spec.registrySources.allowedRegistries[*]}')
  # Allowlist entries may be scoped by path (quay.io/openshift-release-dev,
  # docker.io/portworx), so compare whole image references, not hostnames.
  # docker.io/<name> is docker.io/library/<name>.
  local images inuse
  images=$(oc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
          | grep -v '^$' | sort -u)
  inuse=$(echo "$images" | sed 's|/.*||' | sort -u)
  info "registries in use: $(echo "$inuse" | tr '\n' ' ')"
  if [ -z "$allowed" ]; then
    warn "allowedRegistries is UNSET (compliance check ocp-allowed-registries FAILs)"
    info "Before setting it, every registry above must be included — a missing"
    info "entry causes cluster-wide ImagePullBackOff and reboots all nodes."
    return
  fi
  info "allowlist: $allowed"
  local bad_imgs
  bad_imgs=$(echo "$images" | python3 -c '
import sys
allowed = sys.argv[1].split()
for img in sys.stdin.read().split():
    ref = img
    parts = ref.split("/")
    if parts[0] == "docker.io" and len(parts) == 2:
        ref = "docker.io/library/" + parts[1]
    ok = any(ref == a or ref.startswith(a + "/") or ref.startswith(a + ":") or ref.startswith(a + "@") for a in allowed)
    if not ok: print(img)' "$allowed")
  if [ -z "$bad_imgs" ]; then
    ok "every image in use ($(echo "$images" | wc -l | tr -d ' ')) matches an allowlist entry"
  else
    while read -r i; do bad "IN USE BUT NOT ALLOWLISTED: $i"; done <<< "$bad_imgs"
  fi
}

# --------------------------------------------------------------- T-11 ------
run_t11() {
  hdr "T-11  SCC capability exceptions are known"
  # This check fails purely because of NVIDIA + KubeVirt. Track the set so a
  # NEW privileged SCC cannot appear unnoticed.
  local offenders
  offenders=$(oc get scc -o json 2>/dev/null | python3 -c "
import json,sys,re
d=json.load(sys.stdin)
rx=re.compile(r'^privileged\$|^hostnetwork-v2\$|^restricted-v2\$|^restricted-v3\$|^nonroot-v2\$|^insights-runtime-extractor-scc|^nested-container\$')
print('\n'.join(sorted(s['metadata']['name'] for s in d['items']
      if s.get('allowedCapabilities') and not rx.match(s['metadata']['name']))))")
  local n; n=$(echo "$offenders" | grep -c . )
  info "SCCs with allowedCapabilities outside the default allowlist: $n"
  local unexpected=0
  for s in $offenders; do
    case "$s" in
      nvidia-*|kubevirt-controller) ;;
      *) bad "unexpected privileged SCC: $s"; unexpected=$((unexpected+1)) ;;
    esac
  done
  [ "$unexpected" = "0" ] && ok "all $n are the known NVIDIA/KubeVirt set (expected, documented)"
}

# --------------------------------------------------------------- T-12 ------
run_t12() {
  hdr "T-12  GPU modality switch is a delegated, constrained permission"
  if ! oc get clusterrole gpu-modality-switcher >/dev/null 2>&1; then
    skip "gpu-modality-switcher ClusterRole not present (manifests/08 not applied)"
    return
  fi
  # SubjectAccessReview, not `oc auth can-i --as` — the latter returns
  # misleading "no" answers for impersonated group membership.
  _sar() {
    cat <<EOF | oc create -f - -o jsonpath='{.status.allowed}' 2>/dev/null
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: gpu-switch-probe
  groups: ["gpu-switchers", "system:authenticated"]
  resourceAttributes:
    verb: $1
    resource: nodes
    ${2:+name: $2}
EOF
  }
  local gpu_nodes master
  gpu_nodes=$(oc get clusterrole gpu-modality-switcher \
    -o jsonpath='{.rules[?(@.resourceNames)].resourceNames[*]}' 2>/dev/null)
  [ -n "$gpu_nodes" ] && ok "write scoped to: $gpu_nodes" || bad "no resourceNames scoping — role can patch ANY node"

  for n in $gpu_nodes; do
    [ "$(_sar patch "$n")" = "true" ] && ok "can patch $n" || bad "cannot patch $n (role broken)"
  done
  master=$(oc get nodes -l node-role.kubernetes.io/master -o name 2>/dev/null | head -1 | sed 's|node/||')
  if [ -n "$master" ]; then
    [ "$(_sar patch "$master")" = "true" ] \
      && bad "can patch master $master — scoping has leaked" \
      || ok "cannot patch master $master"
  fi
  [ "$(_sar delete)" = "true" ] && bad "can delete nodes" || ok "cannot delete nodes"

  # The admission policy is what stops a holder cordoning or relabelling.
  if oc get validatingadmissionpolicy gpu-modality-switch-guard >/dev/null 2>&1; then
    local mode
    mode=$(oc get validatingadmissionpolicybinding gpu-modality-switch-guard \
             -o jsonpath='{.spec.validationActions}' 2>/dev/null)
    case "$mode" in
      *Deny*) ok "admission policy ENFORCING ($mode)" ;;
      *)      warn "admission policy present but NOT enforcing ($mode)"
              info "Expected until an identity provider exists. Switch to [\"Deny\"] after that." ;;
    esac
  else
    bad "ValidatingAdmissionPolicy missing — RBAC alone cannot stop cordon/relabel"
  fi
}

# --------------------------------------------------------------- T-13 ------
run_t13() {
  hdr "T-13  Storage traffic is encrypted (NFS over TLS)"
  info "No scanner checks this: the Compliance Operator does not inspect CSI"
  info "mount options, so a regression here is invisible to ocp4-moderate."
  info "800-171 3.13.8 / SC-8. Detail: ../NFS-TLS.md"

  local ns=nfs-tls

  # 1. the daemon that answers the kernel's handshake upcall
  if ! oc get ds tlshd -n "$ns" >/dev/null 2>&1; then
    warn "tlshd DaemonSet absent in $ns — NFS over TLS is not deployed"
    info "Any mount with xprtsec=tls then fails: 'mount.nfs: No such process'"
    return
  fi
  local want have
  want=$(jp daemonset tlshd "$ns" '{.status.desiredNumberScheduled}')
  have=$(jp daemonset tlshd "$ns" '{.status.numberReady}')
  if [ -n "$want" ] && [ "${want:-0}" -gt 0 ] && [ "$want" = "$have" ]; then
    ok "tlshd Ready on $have/$want node(s)"
  else
    bad "tlshd not Ready: ${have:-0}/${want:-0} — TLS mounts will fail"
  fi

  # 2. every NFS StorageClass asks for it (jetty: nfs-over-tls; hubs:
  #    pure-fb-nfsv4). NFS here means nfsvers in mountOptions, or Portworx's
  #    pure_file backend. A cleartext class is FAIL: anything can use it.
  local scs line name mo nfs_scs=0
  scs=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}|{.mountOptions}|{.parameters.backend}{"\n"}{end}' 2>/dev/null)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=${line%%|*}; mo=$(echo "$line" | cut -d'|' -f2)
    case "$mo|${line##*|}" in *nfsvers*|*"|pure_file") ;; *) continue ;; esac
    nfs_scs=$((nfs_scs+1))
    case "$mo" in
      *xprtsec=tls*) ok "StorageClass $name requests xprtsec=tls" ;;
      *)             bad "StorageClass $name is NFS without xprtsec=tls (mountOptions: ${mo:-none})" ;;
    esac
  done <<< "$scs"
  [ "$nfs_scs" = 0 ] && bad "no NFS StorageClass found"

  # 3. what is actually mounted, per worker. Cleartext mounts are EXPECTED
  #    until existing PVCs are migrated -- mountOptions are immutable, so
  #    volumes on pure-fb-nfsv4 cannot be upgraded in place. Report the ratio
  #    rather than failing on it.
  # ALL nodes, not just workers. This originally polled workers only, matching
  # a tlshd DaemonSet that was scoped the same way -- and both were wrong. The
  # Compliance Operator's result-server pods schedule onto masters and mount
  # NFS there, so a worker-only check cannot see cleartext (or broken) mounts
  # on the control plane. That is precisely the failure it missed once.
  local nodes tot_tls=0 tot_clear=0
  nodes=$(oc get nodes -o name 2>/dev/null | sed 's|node/||')
  for n in $nodes; do
    local out
    out=$(oc debug "node/$n" -n default --quiet -- chroot /host /bin/bash -c \
      'printf "%s|%s" "$(grep -c "xprtsec=tls" /proc/mounts)" \
        "$(grep " nfs4\? " /proc/mounts | grep -vc xprtsec)"' 2>/dev/null | tr -d '\r')
    case "$out" in
      *"|"*) ;;
      *) warn "$n  could not read /proc/mounts"; continue ;;
    esac
    local tls="${out%%|*}" clear="${out##*|}"
    tot_tls=$((tot_tls + ${tls:-0})); tot_clear=$((tot_clear + ${clear:-0}))
    info "$n  tls=$tls cleartext=$clear"
  done
  if [ "$tot_tls" -gt 0 ]; then
    ok "$tot_tls NFS mount(s) carrying xprtsec=tls"
  else
    warn "no TLS-backed NFS mounts in use yet"
    info "tlshd is ready, but nothing is consuming nfs-over-tls."
  fi
  if [ "$tot_clear" -gt 0 ]; then
    warn "$tot_clear NFS mount(s) still CLEARTEXT (sec=sys, no xprtsec)"
    info "Expected until PVCs are migrated: mountOptions are immutable, so"
    info "volumes on pure-fb-nfsv4 need a new claim on nfs-over-tls and a copy."
  else
    ok "no cleartext NFS mounts remain"
  fi
}

# --------------------------------------------------------------- T-14 ------
# A backup job that silently stops working looks exactly like one that works,
# until the day you need it. No scanner checks for etcd backups at all.
run_t14() {
  hdr "T-14  etcd backups are running (CP-9)"
  local ns=etcd-backup
  if is_hosted; then
    # A hosted cluster's etcd runs on the hub, in $HCP_NS. Look there for
    # anything that backs it up: a CronJob in that namespace, or one in the
    # hub's etcd-backup namespace naming this cluster.
    if [ -z "${HUB_KUBECONFIG:-}" ]; then
      skip "hosted cluster: etcd runs on the hub; set HUB_KUBECONFIG to check its backups"; return
    fi
    local cj
    cj=$( { hub_oc get cronjob -n "$HCP_NS" -o name 2>/dev/null; hub_oc get cronjob -n "$ns" -o name 2>/dev/null | grep -i -- "$CLUSTER"; } | grep -i etcd | head -1)
    if [ -n "$cj" ]; then ok "hub has $cj for this cluster's etcd"
    else bad "no backup of this cluster's etcd on the hub (etcd in $HCP_NS; the hub's etcd-backup covers only its own)"; fi
    return
  fi
  if ! oc get cronjob etcd-backup -n "$ns" >/dev/null 2>&1; then
    bad "no etcd-backup CronJob in $ns — etcd is not being backed up"
    info "See ../manifests/15-etcd-backup.yaml"
    return
  fi
  [ "$(jp cronjob etcd-backup "$ns" '{.spec.suspend}')" = "true" ] \
    && warn "CronJob etcd-backup is SUSPENDED" || ok "CronJob etcd-backup active ($(jp cronjob etcd-backup "$ns" '{.spec.schedule}'))"

  # Newest SUCCESSFUL job of any origin. Not .status.lastSuccessfulTime: a
  # manual `oc create job --from=cronjob/...` run does not update it.
  local newest age_h
  newest=$(oc get jobs -n "$ns" -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.status.completionTime}{"\n"}{end}' 2>/dev/null | grep . | sort | tail -1)
  if [ -z "$newest" ]; then
    bad "no successful backup job on record"
    return
  fi
  age_h=$(python3 -c "
import datetime
t=datetime.datetime.strptime('$newest','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()//3600))")
  [ "$age_h" -le "$BACKUP_MAX_AGE_HOURS" ] \
    && ok "newest successful backup ${age_h}h old (<= ${BACKUP_MAX_AGE_HOURS}h)" \
    || bad "newest successful backup ${age_h}h old (> ${BACKUP_MAX_AGE_HOURS}h) — backups have stopped"

  local failed
  failed=$(oc get jobs -n "$ns" -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)
  [ "${failed:-0}" -gt 0 ] && warn "$failed failed backup job(s) retained — check: oc get jobs -n $ns" \
    || true

  # The job pins the release's cli image by digest; after an upgrade it must
  # be refreshed (missed after 4.22.16 — found by the restore rehearsal work).
  # The old image still runs, so WARN: drift, not breakage.
  local img cur
  img=$(jp cronjob etcd-backup "$ns" '{.spec.jobTemplate.spec.template.spec.containers[0].image}')
  cur=$(oc adm release info --image-for=cli 2>/dev/null)
  if [ -z "$cur" ]; then
    warn "could not resolve the current release's cli image to compare"
  elif [ "$img" = "$cur" ]; then
    ok "backup job image is the current release's cli image"
  else
    warn "backup job image is not the current release's cli — refresh the digest in manifests/15-etcd-backup.yaml, or the etcd-backup chart's values"
    info "job: ${img##*@}"; info "now: ${cur##*@}"
  fi

  local reclaim pv
  pv=$(jp pvc etcd-backup "$ns" '{.spec.volumeName}')
  reclaim=$(jp pv "$pv" "" '{.spec.persistentVolumeReclaimPolicy}')
  [ "$reclaim" = "Retain" ] && ok "backup PV reclaim policy Retain" \
    || bad "backup PV reclaim policy is '$reclaim' — one 'oc delete pvc' destroys every backup"
}

# --------------------------------------------------------------- T-15 ------
# What TLS the cluster actually offers, measured by handshake. The TLS
# profile is unset (Intermediate), which on paper allows ChaCha20 and CBC;
# FIPS mode strips them. The compliance TLS checks read configuration, so
# only a handshake shows the effective posture — and catches a regression
# (a non-FIPS node, a profile edit) that config checks would not.
# Probing logic: ../lib/tls-probe.py. Node addresses are used, not printed.
run_t15() {
  hdr "T-15  Effective TLS: 1.2+ with AEAD only (SP 800-52r2)"
  local targets=() api con oa n ip
  api=$(oc whoami --show-server | sed 's|^https://||')
  targets+=("api-server=$api")
  con=$(jp route console openshift-console '{.spec.host}');        [ -n "$con" ] && targets+=("ingress(console)=$con:443")
  oa=$(jp route oauth-openshift openshift-authentication '{.spec.host}'); [ -n "$oa" ] && targets+=("oauth=$oa:443")
  for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    ip=$(jp node "$n" "" '{.status.addresses[?(@.type=="InternalIP")].address}')
    [ -n "$ip" ] && targets+=("kubelet/$n=$ip:10250")
  done

  local out
  out=$(python3 ../lib/tls-probe.py "${targets[@]}")
  [ -n "$out" ] || { bad "TLS probe produced no output"; return; }

  local name probe result detail fails errs
  for name in $(printf '%s\n' "$out" | cut -f1 | sort -u); do
    fails=""; errs=""
    while IFS=$'\t' read -r _ probe result detail; do
      case "$probe:$result" in
        tls13:ACCEPTED|tls12-gcm:ACCEPTED) ;;
        tls13:*|tls12-gcm:*)   fails="$fails $probe($result)" ;;
        *:REFUSED) ;;
        *:ACCEPTED)            fails="$fails $probe(ACCEPTED: $detail)" ;;
        *)                     errs="$errs $probe" ;;
      esac
    done < <(printf '%s\n' "$out" | awk -F'\t' -v n="$name" '$1==n')
    if [ -n "$fails" ]; then bad "$name:$fails"
    elif [ -n "$errs" ]; then warn "$name: could not probe$errs"
    else ok "$name: TLS 1.3 + 1.2 AES-GCM only (1.0/1.1, CBC, ChaCha20, static RSA refused)"
    fi
  done
}

# --------------------------------------------------------------- T-16 ------
# File integrity monitoring (SI-7). The two compliance rules only check that
# a FileIntegrity object and its PrometheusRule EXIST; this checks AIDE is
# actually running and clean on every node. A Failed node means a watched
# file under /boot, /root, /usr or /etc changed since the baseline -- an
# intended change (GPU modality switch, manual fix) needs a re-init, anything
# else needs investigating. Manifest: ../manifests/20-file-integrity.yaml.
run_t16() {
  hdr "T-16  File integrity monitoring on every node (SI-7)"
  local ns=openshift-file-integrity phase nodes n res bad_nodes=""
  phase=$(jp fileintegrity all-nodes "$ns" '{.status.phase}')
  if [ -z "$phase" ]; then
    bad "no FileIntegrity 'all-nodes' in $ns — no file integrity monitoring"
    return
  fi
  [ "$phase" = Active ] && ok "FileIntegrity all-nodes Active" || bad "FileIntegrity all-nodes phase '$phase'"
  nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
  for n in $nodes; do
    res=$(oc get fileintegritynodestatuses -n "$ns" -o jsonpath="{.items[?(@.nodeName==\"$n\")].lastResult.condition}" 2>/dev/null)
    case "$res" in
      Succeeded) ;;
      "")        bad_nodes="$bad_nodes $n(no-result)" ;;
      *)         bad_nodes="$bad_nodes $n($res)" ;;
    esac
  done
  [ -z "$bad_nodes" ] && ok "AIDE clean on all $(echo $nodes | wc -w | tr -d ' ') nodes" \
    || bad "AIDE not clean:$bad_nodes — oc get fileintegritynodestatuses -n $ns"
  jp prometheusrule file-integrity "$ns" '{.metadata.name}' | grep -q . \
    && ok "alert rule file-integrity present (NB: Alertmanager has no receiver yet)" \
    || bad "PrometheusRule file-integrity missing"
}

# --------------------------------------------------------------- T-17 ------
# No GPU claimed (billing). GPUs on MOC are charged while claimed by user
# pods, so any claim -- or anything that could claim one later (a template
# scaled to zero, a CronJob, a VM with a GPU) -- FAILs unless its namespace
# is listed in GPU_CLAIM_ALLOW_NS (regex), which downgrades it to WARN.
# Also cross-checks each GPU node's own allocation count.
# Logic: ../lib/gpu-claims.py.
run_t17() {
  hdr "T-17  No GPU claimed or requested (billing)"
  local d pods wl vms out n alloc
  d=$(mktemp -d); pods="$d/pods.json"; wl="$d/wl.json"; vms="$d/vms.json"
  oc get pods -A -o json > "$pods" 2>/dev/null \
    && oc get deploy,sts,ds,rs,job,cronjob -A -o json > "$wl" 2>/dev/null \
    || { bad "could not list pods/workloads"; rm -rf "$d"; return; }
  oc get vm,vmi -A -o json > "$vms" 2>/dev/null || echo '{"items":[]}' > "$vms"

  out=$(python3 ../lib/gpu-claims.py "$pods" "$wl" "$vms" "${GPU_CLAIM_ALLOW_NS:-}")
  rm -rf "$d"
  if [ -z "$out" ]; then
    ok "no pod, workload template or VM requests a GPU"
  else
    while IFS=$'\t' read -r lvl what detail; do
      case "$lvl" in
        FAIL) bad "GPU requested: $what — $detail" ;;
        *)    warn "GPU requested (allowed/transient): $what — $detail" ;;
      esac
    done <<< "$out"
  fi

  # The nodes' own view: allocated nvidia.com/* per GPU node, from kubelet's
  # accounting (describe), independent of the pod scan above.
  for n in $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    alloc=$(oc describe node "$n" 2>/dev/null | sed -n '/Allocated resources/,/Events/p' \
      | awk '$1 ~ /^nvidia\.com\// && $2 != "0" {printf "%s=%s ", $1, $2}')
    [ -z "$alloc" ] && ok "$n: 0 GPUs allocated" || bad "$n: GPUs allocated: $alloc"
  done
}

# --------------------------------------------------------------- T-18 ------
# Operators' FIPS claims. The scans in T-03 check node and cluster settings,
# not which operators are installed. Every CSV must carry
# features.operators.openshift.io/fips-compliant=true, or be listed in
# operator-fips-accepted.txt (WARN, a recorded gap); anything else FAILs.
# OLM's own packageserver ships with OpenShift and is skipped.
# Record and decisions: operator-fips-inventory.md.
OPERATOR_FIPS_ACCEPTED="${OPERATOR_FIPS_ACCEPTED:-./operator-fips-accepted.txt}"
run_t18() {
  hdr "T-18  Installed operators claim FIPS support"
  local d out
  d=$(mktemp -d)
  oc get csv -A -o json > "$d/csv.json" 2>/dev/null || { bad "could not list CSVs"; rm -rf "$d"; return; }
  out=$(python3 - "$d/csv.json" "$OPERATOR_FIPS_ACCEPTED" <<'EOF'
import json, re, sys
items = json.load(open(sys.argv[1]))["items"]
accepted = {}
try:
    for line in open(sys.argv[2]):
        line = line.strip()
        if line and not line.startswith("#"):
            name, _, why = line.partition(" ")
            accepted[name] = why.strip()
except FileNotFoundError:
    pass
seen = {}
for c in items:
    md = c["metadata"]
    if md.get("labels", {}).get("olm.copiedFrom"):
        continue
    name = md["name"]
    if name == "packageserver":
        continue
    pkg = re.split(r"\.v?\d", name, maxsplit=1)[0]
    flag = md.get("annotations", {}).get("features.operators.openshift.io/fips-compliant", "none")
    seen[name] = (pkg, flag)
for name, (pkg, flag) in sorted(seen.items()):
    if flag == "true":
        print(f"OK\t{name}\t")
    elif pkg in accepted:
        print(f"WARN\t{name}\tflag {flag}; accepted: {accepted[pkg]}")
    else:
        print(f"FAIL\t{name}\tflag {flag}; not in the accepted list")
EOF
)
  rm -rf "$d"
  local nok=0
  while IFS=$'\t' read -r lvl name detail; do
    case "$lvl" in
      OK)   nok=$((nok+1)) ;;
      WARN) warn "$name: $detail" ;;
      FAIL) bad "$name: $detail" ;;
    esac
  done <<< "$out"
  ok "$nok operators flagged fips-compliant=true"
}

# ------------------------------------------------------------ node probe ---
# One debug pod per node gathers what T-19, T-21 and T-23 read, so each node
# is visited once. Cached for the run; retried, as in T-01.
NODE_CACHE=""
NODE_PROBE='
udevadm settle 2>/dev/null
for d in $(lsblk -rpno NAME,FSTYPE | awk "\$2==\"crypto_LUKS\"{print \$1}"); do
  v=$(cryptsetup luksDump "$d" 2>/dev/null | awk "/^Version:/{print \$2; exit}")
  t=$(clevis luks list -d "$d" 2>/dev/null | grep -c tang)
  echo "LUKS=$d v=$v tang=$t"
done
lsblk -rpno NAME,TYPE,FSTYPE,LABEL | awk "(\$2==\"disk\"||\$2==\"part\") && \$3!=\"\" && \$3!=\"crypto_LUKS\" && \$4!=\"boot\" && \$4!=\"EFI-SYSTEM\" {print \"PLAIN=\"\$1\" \"\$3}"
echo "CHRONYD=$(systemctl is-active chronyd 2>/dev/null)"
echo "NTPSYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
echo "NOUSB=$(tr " " "\n" </proc/cmdline | grep -cx nousb)"
echo "USBGUARD=$(systemctl is-active usbguard 2>/dev/null)"
echo END=1
'
node_probe() {
  [ -z "$NODE_CACHE" ] && NODE_CACHE=$(mktemp -d)
  local f="$NODE_CACHE/$1" attempt
  if ! grep -q '^END=1' "$f" 2>/dev/null; then
    for attempt in 1 2 3; do
      oc debug "node/$1" -n default --quiet -- chroot /host /bin/bash -c "$NODE_PROBE" 2>/dev/null | tr -d '\r' > "$f"
      grep -q '^END=1' "$f" && break
      [ "$attempt" -lt 3 ] && sleep 5
    done
  fi
  grep -q '^END=1' "$f" && cat "$f"
}
is_hosted() { [ "$(jp infrastructure cluster "" '{.status.controlPlaneTopology}')" = External ]; }

# A hosted cluster's control plane (API servers, etcd) and its ACS Central
# run on the hub: those checks read the hub, through HUB_KUBECONFIG, in the
# hosted control plane namespace clusters-<cluster>.
hub_oc() { [ -n "${HUB_KUBECONFIG:-}" ] || return 1; KUBECONFIG="$HUB_KUBECONFIG" oc "$@"; }

# --------------------------------------------------------------- T-19 ------
# Encryption at rest on local disks (3.13.16). Every filesystem a node holds
# is inside LUKS2 with a Tang binding, except /boot and the EFI partition,
# which RHCOS never encrypts. On compliant-dev-infra: root, etcd and the
# LVM Storage disks (MOC-issues #672, #811).
run_t19() {
  hdr "T-19  Local disks encrypted: LUKS2, unlocked by Tang (3.13.16)"
  # KubeVirt workers' disks are volumes on the hypervisor cluster, checked
  # there. Agent (bare-metal) workers have their own disks: test them.
  if is_hosted && [ "$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null)" = KubeVirt ]; then
    skip "KubeVirt hosted cluster: its workers' disks are the hypervisor's"; return
  fi
  local n out luks bad_n
  for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    out=$(node_probe "$n") || { bad "$n  could not run the node probe"; continue; }
    luks=$(echo "$out" | grep -c '^LUKS=')
    bad_n=$(echo "$out" | grep '^LUKS=' | grep -v -E 'v=2 tang=[1-9]' | sed 's/^LUKS=//' | tr '\n' ' ')
    local plain; plain=$(echo "$out" | sed -n 's/^PLAIN=//p' | tr '\n' ' ')
    if [ "$luks" = 0 ]; then bad "$n  no LUKS devices"
    elif [ -n "$bad_n" ]; then bad "$n  not LUKS2 with Tang: $bad_n"
    elif [ -n "$plain" ]; then bad "$n  unencrypted filesystem(s): $plain"
    else ok "$n  $luks LUKS2 device(s), all bound to Tang; no unencrypted filesystems"; fi
  done
}

# --------------------------------------------------------------- T-20 ------
# Session limits (3.1.11, 3.13.9): OAuth tokens expire and time out when
# idle. On a hosted cluster they are set on the HostedCluster, on the hub.
run_t20() {
  hdr "T-20  OAuth token lifetime and idle timeout (3.1.11)"
  is_hosted && { skip "hosted cluster: set on its HostedCluster (spec.configuration.oauth), check on the hub"; return; }
  local age idle
  age=$(jp oauth cluster "" '{.spec.tokenConfig.accessTokenMaxAgeSeconds}')
  idle=$(jp oauth cluster "" '{.spec.tokenConfig.accessTokenInactivityTimeout}')
  [ -n "$age" ] && [ "$age" -le 86400 ] && ok "access tokens expire after ${age}s" \
    || bad "accessTokenMaxAgeSeconds '${age:-unset}' (want <= 86400)"
  [ -n "$idle" ] && ok "idle timeout $idle" || bad "accessTokenInactivityTimeout unset"
}

# --------------------------------------------------------------- T-21 ------
# Time sync (3.3.7): audit records are only comparable if clocks agree.
# timedatectl, not chronyc: a debug pod cannot reach chronyd's socket
# ("506 Cannot talk to daemon").
run_t21() {
  hdr "T-21  Clocks synchronised (3.3.7)"
  is_hosted && { skip "hosted cluster: no debug pods"; return; }
  local n out d sync
  for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    out=$(node_probe "$n") || { bad "$n  could not run the node probe"; continue; }
    d=$(echo "$out" | sed -n 's/^CHRONYD=//p'); sync=$(echo "$out" | sed -n 's/^NTPSYNC=//p')
    [ "$d" = active ] && [ "$sync" = yes ] && ok "$n  chronyd active, NTP synchronised" \
      || bad "$n  chronyd ${d:-unknown}, NTPSynchronized=${sync:-unknown}"
  done
}

# --------------------------------------------------------------- T-22 ------
# Audit logging (3.3.1, 3.3.2): the API servers log request bodies, and the
# logs leave the cluster for Loki. No scanner checks that Loki accepts them;
# on 2026-11-19 it refused about 110 pushes a minute until its audit tenant
# limits were raised.
run_t22() {
  hdr "T-22  API audit profile and forwarding (3.3.1)"
  local prof; prof=$(jp apiserver cluster "" '{.spec.audit.profile}')
  case "$prof" in
    WriteRequestBodies|AllRequestBodies) ok "API audit profile $prof" ;;
    *) bad "API audit profile '${prof:-Default}' (want WriteRequestBodies)" ;;
  esac
  if ! oc get ns openshift-logging >/dev/null 2>&1; then bad "no openshift-logging: audit logs are not forwarded"; return; fi
  local clf ready
  clf=$(oc get clusterlogforwarder -n openshift-logging -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.pipelines[*].inputRefs}{"\n"}{end}' 2>/dev/null | grep '"audit"' | cut -d: -f1 | head -1)
  [ -z "$clf" ] && { bad "no ClusterLogForwarder with the audit input"; return; }
  ready=$(jp clusterlogforwarder "$clf" openshift-logging '{.status.conditions[?(@.type=="Ready")].status}')
  [ "$ready" = True ] && ok "ClusterLogForwarder $clf forwards audit, Ready" || bad "ClusterLogForwarder $clf Ready=$ready"
  # Over the rate limit: the collector buffers and retries (WARN). Over the
  # line size limit: the line is dropped, an audit record lost (FAIL).
  local p logs rate=0 size=0 c
  for p in $(oc get pods -n openshift-logging -o name 2>/dev/null | grep loki-distributor); do
    logs=$(oc logs -n openshift-logging "$p" --since=10m 2>/dev/null | grep 'write operation failed')
    c=$(printf '%s\n' "$logs" | grep -c 'rate limit exceeded'); rate=$((rate+c))
    c=$(printf '%s\n' "$logs" | grep -c 'max entry size'); size=$((size+c))
  done
  if oc get lokistack -n openshift-logging -o name 2>/dev/null | grep -q .; then
    [ "$size" = 0 ] && ok "no audit lines dropped for size in the last 10 minutes" \
      || bad "$size audit line(s) over Loki's line size limit in the last 10 minutes: dropped"
    [ "$rate" = 0 ] && ok "Loki under its rate limit in the last 10 minutes" \
      || warn "Loki over its rate limit $rate time(s) in the last 10 minutes; the collector retries (a scan's results can burst)"
  else
    info "no LokiStack here: forwarded to a remote Loki, not checked"
  fi
}

# --------------------------------------------------------------- T-23 ------
# Removable media (3.8.7): stage C boots every node with `nousb`; USBGuard
# runs on the masters (99-master-usbguard-enable). Either one blocks USB
# storage; a node with neither FAILs.
run_t23() {
  hdr "T-23  USB storage blocked (3.8.7)"
  is_hosted && { skip "hosted cluster: no debug pods"; return; }
  local n out nousb guard
  for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    out=$(node_probe "$n") || { bad "$n  could not run the node probe"; continue; }
    nousb=$(echo "$out" | sed -n 's/^NOUSB=//p'); guard=$(echo "$out" | sed -n 's/^USBGUARD=//p')
    if [ "$nousb" = 1 ] || [ "$guard" = active ]; then ok "$n  nousb=$nousb usbguard=${guard:-absent}"
    else bad "$n  USB not blocked: no nousb, usbguard ${guard:-absent}"; fi
  done
}

# --------------------------------------------------------------- T-24 ------
# A compliant hub refuses non-compliant hosted clusters and cleartext
# FlashBlade storage (MOC-issues #752). Warn-only policies do not count.
run_t24() {
  hdr "T-24  Hub admission policies enforce (Deny)"
  if ! oc get crd hostedclusters.hypershift.openshift.io >/dev/null 2>&1; then skip "not a hub (no HostedCluster API)"; return; fi
  local b act
  for b in compliant-hosted-clusters flashblade-nfs-tls; do
    act=$(jp validatingadmissionpolicybinding "$b" "" '{.spec.validationActions}')
    case "$act" in
      *Deny*) ok "$b: $act" ;;
      "")     bad "$b: binding missing" ;;
      *)      bad "$b: $act (not enforcing)" ;;
    esac
  done
}

# ---------------------------------------------------------------- main -----
command -v oc >/dev/null || { echo "oc not found" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }

# api.<cluster>.<domain>:6443 -> <cluster>; a hosted cluster's kubeconfig
# may name api-internal-<cluster>.<hcp domain> instead.
CLUSTER=$(oc whoami --show-server | sed -E 's#^https://api(\.|-internal-)([^.]+)\..*#\2#')
HCP_NS="clusters-$CLUSTER"
if [ -z "${BASELINE_FILE:-}" ]; then
  if [ "$CLUSTER" = jetty ]; then BASELINE_FILE=./baseline-fail-counts.txt
  else BASELINE_FILE="./baseline-$CLUSTER.txt"; fi
fi

printf '%sverification%s  —  %s  —  %s\n' "$B" "$N" "$(oc whoami --show-server)" "$(date -u '+%Y-%m-%d %H:%M UTC')"

ALL="t01 t02 t03 t04 t05 t06 t07 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20 t21 t22 t23 t24"
# No GPUs and no GPU Operator: the GPU tests have nothing to check.
HAS_GPU=0
{ oc get ns "$GPU_NS" >/dev/null 2>&1 || [ -n "$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null)" ]; } && HAS_GPU=1
RUN="${ONLY:-$ALL}"
for t in ${RUN//,/ }; do
  case "$t" in t06|t07|t12|t17)
    if [ "$HAS_GPU" = 0 ]; then
      [ -z "$ONLY" ] && { hdr "$(echo "$t" | tr t T)  (GPU)"; skip "no GPU nodes or GPU Operator on this cluster"; }
      continue
    fi ;;
  esac
  if declare -f "run_$t" >/dev/null; then "run_$t"; else echo "no such test: $t" >&2; fi
done
[ -n "${NODE_CACHE:-}" ] && rm -rf "$NODE_CACHE"

printf '\n%s--------------------------------------------------%s\n' "$B" "$N"
printf '%sPASS %d%s   %sFAIL %d%s   %sWARN %d%s   SKIP %d\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$WARN" "$N" "$SKIP"
printf 'Not covered here: GPU switch turnaround (./gpu-switch-timing.sh, mutating),\n'
printf 'VM function (../vms/test-vm*.sh), GPU-to-VM end-to-end (../vms/gpu/test-gpu-vm.sh)\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
