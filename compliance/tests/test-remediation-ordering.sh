#!/usr/bin/env bash
# Unit test for remediate.sh's stage 2 selector. No cluster required.
#
# WHY THIS EXISTS
# ---------------
# The selector enforces an ordering invariant: `service-usbguard-enabled` must
# never be applied unless `usbguard-allow-hid-and-hub` is already applied or in
# the SAME batch. Enabling the usbguard service without the HID/hub allow rule
# can block console keyboards on baremetal -- a failure you discover by walking
# to the machine.
#
# On jetty that path could not be exercised live: the operator happened to mark
# service-usbguard-enabled as dependency-blocked, so BLOCKED short-circuited
# before the ordering check ran. Untested lockout protection is not protection,
# hence synthetic fixtures.
#
# This calls lib/select-remediations.py directly -- the same file remediate.sh
# uses -- so the test cannot drift from the code it is testing. An earlier
# version tried to extract the selector out of remediate.sh with awk and
# silently grabbed a DIFFERENT embedded python heredoc instead; every case
# errored, which is the only reason it was caught.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else G=""; R=""; N=""; fi
pass=0; fail=0
ok()  { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; fail=$((fail+1)); }

SELECTOR=lib/select-remediations.py
[ -f "$SELECTOR" ] || { echo "missing $SELECTOR" >&2; exit 2; }
grep -q "select-remediations.py" remediate.sh \
  || { echo "remediate.sh no longer calls $SELECTOR -- test is testing nothing" >&2; exit 2; }

# Build a ComplianceRemediation list from compact specs:
#   name:applied:unmet
mkjson() {
  python3 -c "
import json,sys
items=[]
for spec in sys.argv[1:]:
    name,applied,unmet = spec.split(':')
    scan='-'.join(name.split('-')[:3])
    labels={'compliance.openshift.io/scan-name':scan}
    if unmet=='1': labels['compliance.openshift.io/has-unmet-dependencies']=''
    items.append({'metadata':{'name':name,'labels':labels},
                  'spec':{'apply':applied=='1',
                          'current':{'object':{'kind':'MachineConfig'}}}})
print(json.dumps({'items':items}))
" "$@"
}

run() { mkjson "$@" | python3 "$SELECTOR"; }

verdict() { # verdict <name> <expected APPLY|HOLD|BLOCKED|ABSENT> <output>
  local want="$2" got
  got=$(printf '%s\n' "$3" | awk -F'\t' -v n="$1" '$2==n{print $1}')
  got=${got:-ABSENT}
  [ "$got" = "$want" ] && ok "$1 -> $want" || bad "$1 -> got $got, want $want"
}

S=rhcos4-moderate-worker-service-usbguard-enabled
A=rhcos4-moderate-worker-usbguard-allow-hid-and-hub

echo "== case 1: service eligible, allow rule dependency-blocked =="
echo "   (the dangerous race -- service must NOT be applied alone)"
out=$(run "$S:0:0" "$A:0:1")
verdict "$S" HOLD    "$out"
verdict "$A" BLOCKED "$out"

echo "== case 2: both eligible -- safe, both land in one batch =="
out=$(run "$S:0:0" "$A:0:0")
verdict "$S" APPLY "$out"
verdict "$A" APPLY "$out"

echo "== case 3: allow rule already applied -- service is safe to add =="
out=$(run "$S:0:0" "$A:1:0")
verdict "$S" APPLY  "$out"
verdict "$A" ABSENT "$out"   # already applied, not a candidate

echo "== case 4: allow rule missing entirely -- still must not apply alone =="
out=$(run "$S:0:0")
verdict "$S" HOLD "$out"

echo "== case 5: per-scan scoping -- master's allow rule must not satisfy worker =="
out=$(run "$S:0:0" "rhcos4-moderate-master-usbguard-allow-hid-and-hub:1:0")
verdict "$S" HOLD "$out"

echo "== case 6: unrelated remediations are unaffected =="
out=$(run "rhcos4-moderate-worker-sysctl-something:0:0")
verdict "rhcos4-moderate-worker-sysctl-something" APPLY "$out"

echo "--------------------------------------------------"
printf 'PASS %d   FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
