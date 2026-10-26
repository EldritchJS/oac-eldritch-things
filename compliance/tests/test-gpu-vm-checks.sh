#!/usr/bin/env bash
# Unit test for lib/gpu-vm-checks.py. No cluster required.
#
# The checks guard situations a healthy cluster should never be in: GPU VMs
# from two tenants on one node, a GPU VM that blocks drains, a passthrough
# resource the webhook would reject. A live cluster that is set up properly
# can only show the PASS side, so each FAIL path is exercised here with
# synthetic objects. Calls the same file cluster-acceptance.sh uses.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else G=""; R=""; N=""; fi
pass=0; fail=0
ok()  { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; fail=$((fail+1)); }

CHECKS=lib/gpu-vm-checks.py
[ -f "$CHECKS" ] || { echo "missing $CHECKS" >&2; exit 2; }
grep -q "gpu-vm-checks.py" tests/cluster-acceptance.sh \
  || { echo "cluster-acceptance.sh no longer calls $CHECKS -- test is testing nothing" >&2; exit 2; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
RES=nvidia.com/GH100_H100_SXM5_80GB

# Fixture builders. Each writes one oc-style {"items": [...]} file.
nodes() { # nodes <name:mode:resource=qty>...
  python3 - "$@" > "$D/nodes.json" <<'EOF'
import json, sys
items = []
for a in sys.argv[1:]:
    name, mode, alloc = a.split(":", 2)
    r, q = alloc.split("=")
    items.append({"metadata": {"name": name, "labels": {"nvidia.com/gpu.workload.config": mode}},
                  "status": {"allocatable": {r: q}}})
print(json.dumps({"items": items}))
EOF
}
vms() { # vms <kind:ns/name:node-or-strategy:gpu|nogpu>...
  python3 - "$@" > "$D/vms.json" <<'EOF'
import json, sys
items = []
for a in sys.argv[1:]:
    kind, nsname, extra, gpu = a.split(":")
    ns, name = nsname.split("/")
    devices = {"gpus": [{"name": "g", "deviceName": "nvidia.com/GH100_H100_SXM5_80GB"}]} if gpu == "gpu" else {}
    spec = {"domain": {"devices": devices}}
    if kind == "VirtualMachineInstance":
        items.append({"kind": kind, "metadata": {"namespace": ns, "name": name},
                      "spec": spec, "status": {"phase": "Running", "nodeName": extra}})
    else:
        if extra != "-":
            spec["evictionStrategy"] = extra
        items.append({"kind": kind, "metadata": {"namespace": ns, "name": name},
                      "spec": {"template": {"spec": spec}}})
print(json.dumps({"items": items}))
EOF
}
crs() { # crs <hco-eviction|-> <hco-permitted> <kv-permitted>   permitted: res=ext,... or -
  # HCO_LAYOUT=v1beta1 puts the HCO settings at spec, as before CNV 4.22.
  python3 - "$@" "$D" "${HCO_LAYOUT:-v1}" <<'EOF'
import json, sys
ev, hp, kp, d, layout = sys.argv[1:]
def phd(s):
    if s == "-":
        return {}
    devs = []
    for e in s.split(","):
        r, ext = e.split("=")
        devs.append({"pciDeviceSelector": "10DE:2330", "resourceName": r,
                     "externalResourceProvider": ext == "true"})
    return {"pciHostDevices": devs}
hco = {"permittedHostDevices": phd(hp)}
if ev != "-":
    hco["evictionStrategy"] = ev
spec = hco if layout == "v1beta1" else {"virtualization": hco}
json.dump({"items": [{"spec": spec}]}, open(f"{d}/hco.json", "w"))
json.dump({"items": [{"spec": {"configuration": {"permittedHostDevices": phd(kp)}}}]},
          open(f"{d}/kv.json", "w"))
EOF
}
run() { python3 "$CHECKS" "$D/nodes.json" "$D/vms.json" "$D/hco.json" "$D/kv.json"; }

expect() { # expect <label> <LEVEL> <check> <substring>
  local out; out=$(run)
  if printf '%s\n' "$out" | awk -F'\t' -v l="$2" -v c="$3" -v s="$4" \
       '$1==l && $2==c && index($3,s) {f=1} END {exit !f}'; then
    ok "$1"
  else
    bad "$1"; printf '%s\n' "$out" | sed 's/^/        /'
  fi
}
expect_none() { # expect_none <label> <LEVEL>
  local out; out=$(run)
  if printf '%s\n' "$out" | awk -F'\t' -v l="$2" '$1==l {f=1} END {exit f}'; then
    ok "$1"
  else
    bad "$1"; printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

echo "gpu-vm-checks.py"

# A properly set up cluster: one tenant per node, VMs set to None, the
# resource permitted on both CRs.
nodes "n1:vm-passthrough:$RES=4" "n2:container:nvidia.com/gpu=4"
vms "VirtualMachine:alice/vm1:None:gpu" "VirtualMachineInstance:alice/vm1:n1:gpu" \
    "VirtualMachineInstance:bob/plain:n1:nogpu"
crs LiveMigrate "$RES=true" "$RES=true"
expect_none "healthy cluster: nothing fails" FAIL

# tenancy
vms "VirtualMachineInstance:alice/vm1:n1:gpu" "VirtualMachineInstance:bob/vm2:n1:gpu"
expect "two tenants' GPU VMs on one node fail" FAIL tenancy "n1 runs GPU VMs from 2 namespaces: alice, bob"
vms "VirtualMachineInstance:alice/vm1:n1:gpu" "VirtualMachineInstance:bob/vm2:n2:gpu"
expect "two tenants on separate nodes pass" PASS tenancy "n2 runs GPU VMs from one namespace (bob)"
vms "VirtualMachineInstance:alice/vm1:n1:gpu" "VirtualMachineInstance:bob/plain:n1:nogpu"
expect_none "a non-GPU VM from another tenant does not count" FAIL

# eviction
crs - "$RES=true" "$RES=true"
vms "VirtualMachine:alice/vm1:-:gpu"
expect "GPU VM inheriting the unset HCO default fails" FAIL eviction "LiveMigrate (from the HyperConverged)"
vms "VirtualMachine:alice/vm1:LiveMigrate:gpu"
expect "GPU VM with its own LiveMigrate fails" FAIL eviction "LiveMigrate (own)"
crs None "$RES=true" "$RES=true"
vms "VirtualMachine:alice/vm1:-:gpu"
expect "GPU VM inheriting HCO None passes" PASS eviction "None (from the HyperConverged)"
crs LiveMigrate "$RES=true" "$RES=true"
vms "VirtualMachine:alice/vm1:LiveMigrateIfPossible:gpu" "VirtualMachine:bob/plain:-:nogpu"
expect_none "LiveMigrateIfPossible passes; a non-GPU VM is not checked" FAIL

# permitted
vms
crs LiveMigrate "$RES=true" -
expect "resource missing from KubeVirt fails" FAIL permitted "of KubeVirt"
crs LiveMigrate - -
expect "resource missing from both fails" FAIL permitted "of HyperConverged and KubeVirt"
crs LiveMigrate "$RES=false" "$RES=true"
expect "externalResourceProvider false fails" FAIL permitted "externalResourceProvider false on HyperConverged"
HCO_LAYOUT=v1beta1 crs None "$RES=true" "$RES=true"
vms "VirtualMachine:alice/vm1:-:gpu"
expect "v1beta1 layout: HCO None at spec is read" PASS eviction "None (from the HyperConverged)"
expect_none "v1beta1 layout: permitted at spec is read" FAIL
nodes "n1:vm-passthrough:$RES=0" "n2:container:nvidia.com/gpu=4"
crs LiveMigrate - -
expect "nothing advertised: nothing to permit" PASS permitted "no node advertises a passthrough GPU"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
