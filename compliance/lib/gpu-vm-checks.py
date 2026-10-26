#!/usr/bin/env python3
"""Check how GPU VMs are placed and configured. Used by cluster-acceptance.sh.

Each check turns a finding from ../vms/gpu/README.md into a rule:

  tenancy    No node runs GPU VMs from more than one namespace. NVLink links
             between GPUs held by different tenants are physically up, and
             whether a guest with its own driver can reach a peer is open
             (OPTIONS.md). Until it is answered, one tenant per node.
  eviction   No GPU VM has an effective evictionStrategy of LiveMigrate. A VM
             with a host device cannot migrate, so LiveMigrate blocks every
             drain on its node (upgrades, MachineConfig rollouts) forever.
             A VM without its own setting inherits the HyperConverged's,
             which defaults to LiveMigrate on a multi-node cluster.
  permitted  Every passthrough resource a node advertises is permitted on
             both the HyperConverged and the KubeVirt CR, with
             externalResourceProvider true. Otherwise the webhook rejects
             GPU VMs that ask for it.
  disk       No GPU VM boots from a containerDisk. That combination hung on
             CNV 4.22.9 (jetty, 2026-10-01; cause unknown), so it is a WARN
             that names the running CNV: retest it when CNV changes.
  sandbox    A node labelled for VMs needs sandboxWorkloads on in the GPU
             Operator's ClusterPolicy, or the label does nothing. A
             defaultWorkload other than container sends every unlabelled GPU
             node to VMs, which should be a choice: WARN.

Usage: gpu-vm-checks.py <nodes.json> <vms.json> <hco.json> <kubevirt.json>
                        <clusterpolicy.json>

  nodes.json     oc get nodes -o json
  vms.json       oc get vm,vmi -A -o json
  hco.json       oc get hyperconverged -A -o json
  kubevirt.json  oc get kubevirt -A -o json
  clusterpolicy.json  oc get clusterpolicy -o json  (an empty list without
                 the GPU Operator)

Prints tab-separated lines:  LEVEL  CHECK  DETAIL   (LEVEL is PASS, FAIL or
WARN). Fixtures and negative tests: ../tests/test-gpu-vm-checks.sh.
"""
import json
import sys

PREFIX = "nvidia.com/"
MODE_LABEL = "nvidia.com/gpu.workload.config"


def items(path):
    return json.load(open(path)).get("items", [])


def gpu_devices(spec):
    dev = spec.get("domain", {}).get("devices", {})
    return [d.get("deviceName") for d in dev.get("gpus", []) + dev.get("hostDevices", [])]


def permitted(cr_spec):
    """resourceName -> externalResourceProvider, from a permittedHostDevices."""
    phd = cr_spec.get("permittedHostDevices") or {}
    return {d.get("resourceName"): bool(d.get("externalResourceProvider"))
            for d in phd.get("pciHostDevices", []) + phd.get("mediatedDevices", [])}


def check_tenancy(vms):
    by_node = {}
    for o in vms:
        if o["kind"] != "VirtualMachineInstance" or not gpu_devices(o["spec"]):
            continue
        if o.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        node = o.get("status", {}).get("nodeName")
        if node:
            by_node.setdefault(node, set()).add(o["metadata"]["namespace"])
    if not by_node:
        return [("PASS", "tenancy", "no GPU VM running")]
    out = []
    for node, nss in sorted(by_node.items()):
        if len(nss) > 1:
            out.append(("FAIL", "tenancy", f"{node} runs GPU VMs from {len(nss)} namespaces: "
                        + ", ".join(sorted(nss))))
        else:
            out.append(("PASS", "tenancy", f"{node} runs GPU VMs from one namespace ({next(iter(nss))})"))
    return out


def check_eviction(vms, hco_spec):
    hco_default = hco_spec.get("evictionStrategy") or "LiveMigrate"
    out = []
    for o in vms:
        if o["kind"] != "VirtualMachine":
            continue
        spec = o["spec"].get("template", {}).get("spec", {})
        if not gpu_devices(spec):
            continue
        own = spec.get("evictionStrategy")
        eff = own or hco_default
        where = "own" if own else "from the HyperConverged"
        name = f"{o['metadata']['namespace']}/{o['metadata']['name']}"
        if eff == "LiveMigrate":
            out.append(("FAIL", "eviction", f"GPU VM {name}: evictionStrategy LiveMigrate ({where}) "
                        "blocks every drain of its node; set None or LiveMigrateIfPossible"))
        else:
            out.append(("PASS", "eviction", f"GPU VM {name}: evictionStrategy {eff} ({where})"))
    return out or [("PASS", "eviction", "no GPU VM defined")]


def check_permitted(nodes, hco_spec, kv_spec):
    advertised = {}
    for n in nodes:
        if n["metadata"].get("labels", {}).get(MODE_LABEL) != "vm-passthrough":
            continue
        for res, qty in n.get("status", {}).get("allocatable", {}).items():
            if res.startswith(PREFIX) and res != PREFIX + "gpu" and str(qty) != "0":
                advertised.setdefault(res, []).append(n["metadata"]["name"])
    if not advertised:
        return [("PASS", "permitted", "no node advertises a passthrough GPU")]
    hco, kv = permitted(hco_spec), permitted(kv_spec)
    out = []
    for res, nodes_ in sorted(advertised.items()):
        missing = [w for w, p in (("HyperConverged", hco), ("KubeVirt", kv)) if res not in p]
        internal = [w for w, p in (("HyperConverged", hco), ("KubeVirt", kv)) if res in p and not p[res]]
        if missing:
            out.append(("FAIL", "permitted", f"{res} (on {', '.join(nodes_)}) not in permittedHostDevices "
                        f"of {' and '.join(missing)}: GPU VMs asking for it are rejected"))
        elif internal:
            out.append(("FAIL", "permitted", f"{res} has externalResourceProvider false on "
                        f"{' and '.join(internal)}: KubeVirt would expect its own device plugin"))
        else:
            out.append(("PASS", "permitted", f"{res} permitted on the HyperConverged and KubeVirt"))
    return out


def check_disk(vms, cnv):
    out = []
    for o in vms:
        if o["kind"] != "VirtualMachine":
            continue
        spec = o["spec"].get("template", {}).get("spec", {})
        if not gpu_devices(spec):
            continue
        cd = [v["name"] for v in spec.get("volumes", []) if "containerDisk" in v]
        name = f"{o['metadata']['namespace']}/{o['metadata']['name']}"
        if cd:
            out.append(("WARN", "disk", f"GPU VM {name} boots from containerDisk {', '.join(cd)}: "
                        f"hung with a GPU on CNV 4.22.9; running CNV {cnv or 'unknown'}. "
                        "Use a DataVolume, or retest"))
        else:
            out.append(("PASS", "disk", f"GPU VM {name} uses no containerDisk"))
    return out or [("PASS", "disk", "no GPU VM defined")]


def check_sandbox(nodes, policies):
    vm_nodes = [n["metadata"]["name"] for n in nodes
                if n["metadata"].get("labels", {}).get(MODE_LABEL, "").startswith("vm-")]
    if not policies:
        return [("FAIL", "sandbox", f"no ClusterPolicy, but {', '.join(vm_nodes)} labelled for VMs")] \
            if vm_nodes else []
    sw = policies[0].get("spec", {}).get("sandboxWorkloads") or {}
    out = []
    if sw.get("enabled"):
        out.append(("PASS", "sandbox", "sandboxWorkloads enabled"))
    elif vm_nodes:
        out.append(("FAIL", "sandbox", f"sandboxWorkloads off, so the VM label on "
                    f"{', '.join(vm_nodes)} does nothing"))
    else:
        out.append(("PASS", "sandbox", "sandboxWorkloads off, and no node labelled for VMs"))
    if sw.get("enabled"):
        dw = sw.get("defaultWorkload") or "container"
        if dw == "container":
            out.append(("PASS", "sandbox", "defaultWorkload container: only labelled nodes serve VMs"))
        else:
            out.append(("WARN", "sandbox", f"defaultWorkload {dw}: every unlabelled GPU node serves VMs"))
    return out


def hco_settings(hco):
    """HyperConverged v1 (CNV 4.22) moved these under spec.virtualization;
    v1beta1 keeps them at spec. Read the new place first, as T-07 does."""
    spec = hco.get("spec", {})
    virt = spec.get("virtualization", {})
    return {k: virt.get(k, spec.get(k)) for k in ("evictionStrategy", "permittedHostDevices")}


def main(nodes_f, vms_f, hco_f, kv_f, cp_f):
    nodes, vms = items(nodes_f), items(vms_f)
    hcos, kvs, cps = items(hco_f), items(kv_f), items(cp_f)
    hco_spec = hco_settings(hcos[0]) if hcos else {}
    kv_spec = kvs[0].get("spec", {}).get("configuration", {}) if kvs else {}
    cnv = next((v.get("version") for v in (hcos[0].get("status", {}).get("versions") or [])
                if v.get("name") == "operator"), "") if hcos else ""
    for line in (check_tenancy(vms) + check_eviction(vms, hco_spec)
                 + check_permitted(nodes, hco_spec, kv_spec) + check_disk(vms, cnv)
                 + check_sandbox(nodes, cps)):
        print("\t".join(line))


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:])
