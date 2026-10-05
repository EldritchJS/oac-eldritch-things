#!/usr/bin/env python3
"""Decide which ComplianceRemediations stage 2 may safely apply.

Reads `oc get complianceremediation -o json` on stdin, writes tab-separated
decisions on stdout:

    APPLY   <name>
    HOLD    <name>  <reason>
    BLOCKED <name>  <reason>

This lives in its own file rather than inside a `python3 -c "..."` string in
remediate.sh for two reasons: the shell quoting was unreadable, and a test
could not reliably extract it (an earlier attempt silently grabbed a different
embedded heredoc and "passed" against the wrong code).

Two invariants, both learned the hard way on jetty:

1. DEPENDENCIES. The operator refuses to apply a remediation labelled
   compliance.openshift.io/has-unmet-dependencies until its prerequisite is
   applied AND a rescan re-evaluates it. Patching apply=true on those achieves
   nothing and hides the fact that another round is needed. Measured
   2026-10-05: six usbguard remediations sat blocked through an entire stage 2
   run, and the post-hardening rescan then generated two more.

2. ORDERING. Some remediations are unsafe unless a partner lands in the SAME
   rendered MachineConfig. Enabling the usbguard service without the HID/hub
   allow rule can block console keyboards on baremetal. The MCP pause makes a
   batch atomic, so the rule is: only apply such a remediation if its partner
   is already applied or is in this same batch.
"""
import json
import sys

# rule -> rules that must be already-applied, or present in the same batch.
# Keyed on the rule suffix (the remediation name minus its scan-name prefix),
# and matched per-scan: a master-scoped partner does not satisfy a worker rule.
REQUIRES = {
    "service-usbguard-enabled": ["usbguard-allow-hid-and-hub"],
}


def load(stream):
    doc = json.load(stream)
    out = {}
    for item in doc.get("items", []):
        meta = item.get("metadata", {}) or {}
        name = meta.get("name", "")
        labels = meta.get("labels", {}) or {}
        scan = labels.get("compliance.openshift.io/scan-name", "")
        spec = item.get("spec", {}) or {}
        obj = ((spec.get("current", {}) or {}).get("object", {}) or {})
        rule = name[len(scan) + 1:] if scan and name.startswith(scan + "-") else name
        out[name] = {
            "name": name,
            "scan": scan,
            "rule": rule,
            "kind": obj.get("kind"),
            "applied": bool(spec.get("apply")),
            "unmet": any("has-unmet-dependencies" in k for k in labels),
        }
    return out


def decide(rems):
    mc = [r for r in rems.values() if r["kind"] == "MachineConfig" and not r["applied"]]
    candidates = [r for r in mc if not r["unmet"]]
    blocked = [r for r in mc if r["unmet"]]

    batch = {(r["scan"], r["rule"]) for r in candidates}
    done = {(r["scan"], r["rule"]) for r in rems.values() if r["applied"]}

    decisions = []
    for r in sorted(candidates, key=lambda x: x["name"]):
        missing = [
            p for p in REQUIRES.get(r["rule"], [])
            if (r["scan"], p) not in batch and (r["scan"], p) not in done
        ]
        if missing:
            decisions.append(("HOLD", r["name"], "unsafe alone; needs " + ",".join(missing)))
        else:
            decisions.append(("APPLY", r["name"], ""))
    for r in sorted(blocked, key=lambda x: x["name"]):
        decisions.append(("BLOCKED", r["name"], "operator: unmet dependency"))
    return decisions


def main():
    for verdict, name, reason in decide(load(sys.stdin)):
        if reason:
            print("%s\t%s\t%s" % (verdict, name, reason))
        else:
            print("%s\t%s" % (verdict, name))


if __name__ == "__main__":
    main()
