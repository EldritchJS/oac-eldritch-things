#!/usr/bin/env bash
# Staged compliance remediation for jetty.
#
# Nothing here is clever — the value is the STAGING and the MCP pause, which
# are what stop this from being 377 consecutive node reboots.
#
#   stage1  6 platform remediations. No node reboots. Rolls kube-apiserver.
#   stage2  377 MachineConfigs. Pauses the pools, applies everything, then
#           unpauses -> ONE rolling reboot per pool instead of many.
#           ITERATIVE: run it, reboot, RESCAN, run it again until it reports
#           nothing outstanding. The operator gates some remediations behind
#           dependencies that only clear after a rescan sees the prerequisite
#           applied, so a single pass never finishes the job.
#   stage3  NOT AUTOMATED. The three GPU-dangerous manual checks. Deliberately
#           left to a human; see FEASIBILITY.md §3.
#
# Always: ./remediate.sh <stage> --dry-run   first.
#
# Usage:
#   ./remediate.sh stage1 --dry-run
#   ./remediate.sh stage1
#   ./remediate.sh stage2 --dry-run
#   ./remediate.sh stage2
#   ./remediate.sh status
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CO_NS=openshift-compliance
DRY=0
STAGE="${1:-status}"
[ "${2:-}" = "--dry-run" ] && DRY=1

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  %sWARN%s %s\n' "$Y" "$N" "$*"; }
run()  { if [ "$DRY" = "1" ]; then printf '  %s[dry-run]%s %s\n' "$Y" "$N" "$*";
         else printf '  + %s\n' "$*"; eval "$@"; fi; }

command -v oc >/dev/null || { echo "oc not found" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "not logged in (set KUBECONFIG)" >&2; exit 2; }

# Remediations that change cluster config objects rather than node config.
# Deduplicated: the ocp4-cis and ocp4-moderate variants of the same rule make
# the identical change, so applying both is idempotent but noisy.
#
# HISTORICAL on jetty: applied 2026-10-02. The platform scans were renamed to
# jetty-ocp4-cis / jetty-ocp4-moderate on 2026-10-08 (TailoredProfiles), so
# these objects no longer exist here and stage1 would report them missing.
# The names are kept as the record, and are correct for a fresh cluster bound
# to the stock profiles.
STAGE1_REMEDIATIONS="
ocp4-cis-api-server-encryption-provider-cipher-1
ocp4-cis-audit-profile-set
ocp4-moderate-api-server-encryption-provider-cipher-1
ocp4-moderate-audit-profile-set
ocp4-moderate-oauth-or-oauthclient-inactivity-timeout
ocp4-moderate-oauth-or-oauthclient-token-maxage
"

show_status() {
  hdr "Current posture"
  oc get apiserver cluster -o jsonpath='  etcd encryption : {.spec.encryption.type}{"\n"}  audit profile   : {.spec.audit.profile}{"\n"}' 2>/dev/null
  note "oauth tokenConfig: $(oc get oauth cluster -o jsonpath='{.spec.tokenConfig}' 2>/dev/null)"
  hdr "Remediations"
  local total applied notapplied mc
  total=$(oc get complianceremediation -n "$CO_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  applied=$(oc get complianceremediation -n "$CO_NS" -o jsonpath='{range .items[?(@.spec.apply==true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . )
  mc=$(oc get complianceremediation -n "$CO_NS" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for i in d['items'] if ((i.get('spec',{}).get('current',{}) or {}).get('object',{}) or {}).get('kind')=='MachineConfig'))")
  note "total        : $total"
  note "applied      : $applied"
  note "MachineConfig: $mc  (these are the ones that reboot nodes)"
  hdr "MachineConfigPools"
  oc get mcp --no-headers 2>/dev/null | awk '{printf "  %-8s updated=%-6s updating=%-6s degraded=%-6s paused=%s\n",$1,$3,$4,$5,$6}'
  oc get mcp -o jsonpath='{range .items[*]}  {.metadata.name} paused={.spec.paused}{"\n"}{end}' 2>/dev/null
}

stage1() {
  hdr "STAGE 1 — platform remediations (no node reboots)"
  note "Changes: etcd encryption -> aesgcm, audit profile -> WriteRequestBodies,"
  note "         OAuth inactivity timeout 10m, token max age 24h."
  note ""
  warn "kube-apiserver will roll across all 3 masters (brief API blips)."
  warn "etcd encryption triggers a full re-encrypt of secrets; takes minutes."
  warn "WriteRequestBodies sharply increases audit volume, and this cluster has"
  note "     no log forwarding — the extra data rotates away locally. Correct for"
  note "     800-171 regardless, but it makes the forwarding gap more urgent."
  note ""
  for r in $STAGE1_REMEDIATIONS; do
    if ! oc get complianceremediation "$r" -n "$CO_NS" >/dev/null 2>&1; then
      warn "missing (skipped): $r"; continue
    fi
    run "oc patch complianceremediation $r -n $CO_NS --type=merge -p '{\"spec\":{\"apply\":true}}'"
  done
  note ""
  note "Then watch, and do not start stage 2 until this settles:"
  note "  oc get co kube-apiserver -w"
  note "  oc get apiserver cluster -o jsonpath='{.spec.encryption.type}{\"\\n\"}'"
  note "  oc get kubeapiserver cluster -o jsonpath='{range .status.conditions[?(@.type==\"Encrypted\")]}{.reason}{\"\\n\"}{end}'"
  note "Re-run: tests/verify.sh"
}

stage2() {
  hdr "STAGE 2 — node hardening (377 MachineConfigs, ROLLING REBOOT)"
  warn "This reboots every node in the cluster, one at a time."
  warn "Confirm first that no VMs are running — a drain will evict them."
  note ""
  note "The pause/unpause is the whole point: applying 377 remediations to a"
  note "live pool makes the MCO re-render and reboot repeatedly. Paused, they"
  note "accumulate into ONE rendered config, so each node reboots once."
  note ""

  # Count non-empty lines. `oc get` writes "No resources found" to stderr and
  # nothing to stdout, so an empty result must read as 0 — an earlier version
  # using `grep -vc ... || echo 0` emitted "0\n0" and aborted on a clean cluster.
  local vmis
  vmis=$(oc get vmi -A --no-headers 2>/dev/null | grep -c . || true)
  vmis=${vmis:-0}
  if [ "$vmis" -ne 0 ] 2>/dev/null; then
    warn "ABORT: $vmis running VMI(s). Stop them, or accept that the drain evicts them."
    return 1
  fi
  note "no running VMIs — safe to drain"

  run "oc patch mcp master --type=merge -p '{\"spec\":{\"paused\":true}}'"
  run "oc patch mcp worker --type=merge -p '{\"spec\":{\"paused\":true}}'"

  note "Selecting MachineConfig-backed remediations..."

  # Selection is NOT simply "every MachineConfig remediation not yet applied".
  # Two measured problems make that wrong:
  #
  # 1. DEPENDENCIES. The operator refuses to apply a remediation labelled
  #    compliance.openshift.io/has-unmet-dependencies until its prerequisite is
  #    applied AND a rescan re-evaluates it. Patching apply=true on those does
  #    nothing except hide that another round is needed. Measured 2026-10-05:
  #    6 usbguard remediations sat blocked through an entire stage 2 run,
  #    and the post-hardening rescan then generated 2 more (383 -> 385).
  #    Remediation is ITERATIVE. Expect 2-3 rounds, each with a reboot.
  #
  # 2. ORDERING. Some remediations are unsafe unless a partner lands in the
  #    SAME rendered config. Enabling the usbguard service without the HID/hub
  #    allow rule can block console keyboards on baremetal. The MCP pause makes
  #    a batch atomic, so the guard is: only apply such a rule if its partner
  #    is already applied or is in this same batch. Otherwise hold it back and
  #    pick it up next round, once the partner is eligible.
  # Selector lives in lib/select-remediations.py so it is readable and
  # directly unit-testable (tests/test-remediation-ordering.sh).
  local plan; plan=$(mktemp)
  oc get complianceremediation -n "$CO_NS" -o json 2>/dev/null \
    | python3 "$HERE/lib/select-remediations.py" > "$plan"

  local names count nheld nblocked
  names=$(awk -F'\t' '$1=="APPLY"{print $2}' "$plan")
  count=$(printf '%s\n' "$names" | grep -c . )
  nheld=$(awk -F'\t' '$1=="HOLD"' "$plan" | grep -c . )
  nblocked=$(awk -F'\t' '$1=="BLOCKED"' "$plan" | grep -c . )

  note "  $count to apply"
  if [ "$nheld" -ne 0 ]; then
    warn "$nheld HELD BACK for safe ordering (not applied this round):"
    awk -F'\t' '$1=="HOLD"{printf "       %s\n         -> %s\n",$2,$3}' "$plan"
  fi
  if [ "$nblocked" -ne 0 ]; then
    warn "$nblocked BLOCKED by the operator's own dependency graph:"
    awk -F'\t' '$1=="BLOCKED"{printf "       %s\n",$2}' "$plan"
    note "     These become eligible only after a rescan that sees their"
    note "     prerequisite applied. Re-run stage2 after the reboot + rescan."
  fi

  if [ "$count" -eq 0 ]; then
    note ""
    note "Nothing to apply this round."
    [ $((nheld + nblocked)) -ne 0 ] \
      && note "Rescan, then re-run stage2 to pick up the $((nheld + nblocked)) outstanding." \
      || note "All MachineConfig remediations are applied."
    rm -f "$plan"; return 0
  fi

  if [ "$DRY" = "1" ]; then
    printf '  %s[dry-run]%s would patch %s remediations\n' "$Y" "$N" "$count"
  else
    local i=0
    for r in $names; do
      i=$((i+1))
      oc patch complianceremediation "$r" -n "$CO_NS" --type=merge -p '{"spec":{"apply":true}}' >/dev/null 2>&1 \
        || warn "failed: $r"
      [ $((i % 50)) -eq 0 ] && note "  ... $i/$count"
    done
    note "  applied $i"
  fi
  rm -f "$plan"

  note ""
  warn "NOW REVIEW before unpausing. Once unpaused the reboots begin."
  note "  oc get mc | grep -c 75-"
  note "Unpause with:"
  note "  oc patch mcp master --type=merge -p '{\"spec\":{\"paused\":false}}'"
  note "  oc patch mcp worker --type=merge -p '{\"spec\":{\"paused\":false}}'"
  note "Watch:  oc get mcp -w"
  note ""
  note "AFTER the reboot completes, in this order:"
  note "  1. rescan  — the nightly scan is NOT enough; verify.sh will compare"
  note "               against results that predate the hardening:"
  note "     for s in \$(oc get compliancescan -n $CO_NS -o name | sed 's|.*/||'); do"
  note "       oc annotate compliancescan \$s -n $CO_NS compliance.openshift.io/rescan= --overwrite; done"
  note "  2. tests/verify.sh   # T-06/T-07 prove both GPU modalities survived"
  note "  3. ./remediate.sh stage2   # AGAIN — picks up newly-eligible remediations"
  note "     Repeat until it reports nothing outstanding."
}

case "$STAGE" in
  status) show_status ;;
  stage1) stage1 ;;
  stage2) stage2 ;;
  stage3) hdr "STAGE 3 — not automated"
          note "ocp-allowed-registries, reject-unsigned-images, scc-limit-capabilities."
          note "All manual, all can break GPU support. See FEASIBILITY.md §3."
          note "Done on jetty 2026-10-08: scc-limit-capabilities (manifests/13-*);"
          note "allowed-registries + reject-unsigned-images, one change (manifests/14-*)." ;;
  *) echo "usage: $0 {status|stage1|stage2|stage3} [--dry-run]" >&2; exit 2 ;;
esac
