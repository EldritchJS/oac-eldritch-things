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
TESTED_VBIOS=96.00.DA.00.17
```

## The result

On jetty's `moc-r4pcc02u16`, `test-gpu-memclear.sh` filled the memory of
all four GPUs with a pattern, handed the GPUs back with the pattern still
held, and read the memory through BAR0's PRAMIN window with no GPU driver
loaded. Every sampled word on every GPU read zero, both times:

- 2026-10-20, `HANDOFF=restart`: the same VM, stopped and started.
- 2026-10-26, `HANDOFF=new-vm`: the VM and its disk deleted, and a new VM
  in a second project took the same four GPUs. The control saw the
  pattern in 98.7% of sampled words; afterwards none.

README.md, "Is GPU memory cleared between tenants?", has the detail.

## Where each value comes from

- **Kernel and reset method.** vfio resets each GPU when a VM lets go of
  it, using the methods in `/sys/bus/pci/devices/<gpu>/reset_method` in
  order (function-level reset, then secondary bus reset). Whatever does
  the clearing, the host's reset or the GPU's firmware, sits on that path.
  Read from u16 on 2026-10-26. jetty has run OpenShift 4.22.16 since
  2026-10-08 and OpenShift Virtualization 4.22.12 since 2026-10-06, so
  these are the values the 2026-10-20 run used.
- **Device.** H100 SXM5 80GB (PCI 10de:2330), on all four GPUs.
- **VBIOS.** `96.00.DA.00.17`, read by `nvidia-smi` in the guests on
  2026-10-26 (all four GPUs, in the 2026-10-26 run and the pair test). The
  host has no NVIDIA driver in passthrough mode, so only a guest (or the
  BMC) can read it; `test-gpu-vm.sh` prints it as `vbios=`. Whether it was
  the same on 2026-10-20 is not recorded.

## What this does not show

One node, one firmware. Sampled 256 KiB per GiB, not every byte. Which
component clears the memory is not known, only that it is clear before
the next guest can read it.

No positive control after the handback: the pattern was seen through
PRAMIN while held, but nothing was written and read back through PRAMIN
in the new guest. Reads that cannot reach memory at all would also show
nothing. Every word read exactly zero; on these GPUs a register that is
not there reads 0xbadf5040, not zero (pramin.py), which suggests, but does
not show, that memory out of reach would not read as zero either. A write
and read-back through PRAMIN in the new guest would settle it.
