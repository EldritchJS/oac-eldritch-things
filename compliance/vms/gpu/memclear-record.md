# GPU memory clearing: what was tested

Read by `../../tests/cluster-acceptance.sh`, which parses the `KEY=value`
lines below and compares them with every node in `vm-passthrough` mode. A
difference does not mean memory is no longer cleared. It means the result
below was not shown for what the node now runs: rerun
`test-gpu-memclear.sh` (billable) and update this record.

```
TESTED_KERNEL=5.14.0-687.50.1.el9_8.x86_64
TESTED_DEVICE=0x2330
TESTED_RESET_METHOD=flr bus
TESTED_VBIOS=
```

## The result

On 2026-10-20, `test-gpu-memclear.sh` filled the memory of all four GPUs
on jetty's `moc-r4pcc02u16` with a pattern, stopped the VM holding them,
started it with the NVIDIA driver blocked, and read the memory through
BAR0's PRAMIN window. Every sampled word on every GPU read zero
(README.md, "Is GPU memory cleared between tenants?").

## Where each value comes from

- **Kernel and reset method.** vfio resets each GPU when a VM lets go of
  it, using the methods in `/sys/bus/pci/devices/<gpu>/reset_method` in
  order (function-level reset, then secondary bus reset). Whatever does
  the clearing, the host's reset or the GPU's firmware, sits on that path.
  Read from u16 on 2026-10-26. jetty has run OpenShift 4.22.16 since
  2026-10-08 and OpenShift Virtualization 4.22.12 since 2026-10-06, so
  these are the values the 2026-10-20 run used.
- **Device.** H100 SXM5 80GB (PCI 10de:2330), on all four GPUs.
- **VBIOS.** Not recorded. In passthrough mode the host has no NVIDIA
  driver, so only a guest (or the BMC) can read it. `test-gpu-vm.sh` now
  prints `vbios=` from the guest: copy it here after the next GPU run.
  Until then the acceptance suite warns.

## What this does not show

One node, one firmware. Sampled 256 KiB per GiB, not every byte. Which
component clears the memory is not known, only that it is clear before
the next guest can read it.
