#!/usr/bin/env python3
"""Report anything that claims, or could claim, a GPU.

GPUs on MOC are billed while claimed by user pods, so an accidental claim
costs money. Used by verify.sh T-17.

Usage: gpu-claims.py <pods.json> <workloads.json> <vms.json> [allowed-ns-regex]

  pods.json       oc get pods -A -o json
  workloads.json  oc get deploy,sts,ds,rs,job,cronjob -A -o json
  vms.json        oc get vm,vmi -A -o json  (an empty list if CNV is absent)

Prints tab-separated lines:  LEVEL  WHAT  DETAIL
  FAIL   a live claim, a template that requests a GPU, or a VM with a GPU
  WARN   the same, but in an allowed namespace, or the GPU operator's own
         transient CUDA validation pod
Nothing printed means nothing claims or requests a GPU.

A "live claim" is a pod that is not Succeeded/Failed and requests an
nvidia.com/* resource (pending pods included: they claim as soon as they
schedule). Templates are checked too, because a Deployment scaled to zero or
a CronJob claims nothing today and a GPU tomorrow.
"""
import json
import re
import sys

PREFIX = "nvidia.com/"


def gpu_resources(podspec):
    out = {}
    for c in podspec.get("containers", []) + podspec.get("initContainers", []):
        r = c.get("resources", {})
        for d in (r.get("requests", {}), r.get("limits", {})):
            for k, v in d.items():
                if k.startswith(PREFIX):
                    out[k] = v
    return out


def template_spec(obj):
    kind = obj["kind"]
    if kind == "CronJob":
        return obj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return obj["spec"]["template"]["spec"]


def main(pods_f, wl_f, vm_f, allow):
    allow_re = re.compile(allow) if allow else None

    def level(ns):
        return "WARN" if allow_re and allow_re.search(ns) else "FAIL"

    for p in json.load(open(pods_f))["items"]:
        if p["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        g = gpu_resources(p["spec"])
        if not g:
            continue
        ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
        lvl = level(ns)
        if ns == "nvidia-gpu-operator" and "cuda-validator" in name:
            lvl = "WARN"   # operator's own seconds-long check after driver start
        print(f"{lvl}\tpod {ns}/{name}\tphase={p['status'].get('phase')} "
              f"node={p['spec'].get('nodeName') or '-'} {g}")

    for o in json.load(open(wl_f))["items"]:
        # Pods owned by a ReplicaSet/Job are reported via their template's owner;
        # skip ReplicaSets/Jobs that belong to a Deployment/CronJob to avoid
        # reporting the same template twice.
        if o["kind"] in ("ReplicaSet", "Job") and o["metadata"].get("ownerReferences"):
            continue
        g = gpu_resources(template_spec(o))
        if g:
            ns, name = o["metadata"]["namespace"], o["metadata"]["name"]
            rep = o["spec"].get("replicas")
            print(f"{level(ns)}\t{o['kind']} {ns}/{name}\t"
                  f"template requests {g}" + (f" replicas={rep}" if rep is not None else ""))

    for o in json.load(open(vm_f)).get("items", []):
        if o["kind"] == "VirtualMachine":
            dom = o["spec"].get("template", {}).get("spec", {}).get("domain", {})
        else:
            dom = o["spec"].get("domain", {})
        dev = dom.get("devices", {})
        names = [d.get("deviceName") for d in dev.get("gpus", []) + dev.get("hostDevices", [])]
        if names:
            ns, name = o["metadata"]["namespace"], o["metadata"]["name"]
            state = o["spec"].get("runStrategy", o["spec"].get("running")) \
                if o["kind"] == "VirtualMachine" else o.get("status", {}).get("phase")
            print(f"{level(ns)}\t{o['kind']} {ns}/{name}\tdevices={names} state={state}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
