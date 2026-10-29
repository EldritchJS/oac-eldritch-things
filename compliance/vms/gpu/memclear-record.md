# GPU memory clearing: what was tested

Read by `../../tests/cluster-acceptance.sh`, which parses the `KEY=value`
lines below and compares them with every node in `vm-passthrough` mode. A
difference does not mean memory is no longer cleared. It means the result
below was not shown for what the node now runs: rerun
`test-gpu-memclear.sh` (billable) and update this record.

```
TESTED_KERNEL=5.14.0-687.46.1.el9_8.x86_64
TESTED_DEVICE=0x2330
TESTED_RESET_METHOD=flr bus
TESTED_VBIOS=96.00.DA.00.17
```

## The result

On jetty's `moc-r4pcc02u16`, `test-gpu-memclear.sh` filled the memory of
all four GPUs with a pattern, handed the GPUs back with the pattern still
held, and read the memory through BAR0's PRAMIN window with no GPU driver
loaded. Every sampled word on every GPU read zero, every time:

- 2026-10-20, `HANDOFF=restart`: the same VM, stopped and started.
- 2026-10-26, `HANDOFF=new-vm`: the VM and its disk deleted, and a new VM
  in a second project took the same four GPUs. The control saw the
  pattern in 98.7% of sampled words; afterwards none. Run again the same
  day with a positive control after the scan: a value written through the
  same window to 4 KiB of every GiB read back on all four GPUs (80,896 of
  80,896 words each), so the scan was reading memory, and its zeros are
  zeros.
- 2026-10-28, `HANDOFF=new-vm` with the positive control, after jetty was
  reinstalled (OpenShift 4.22.14, kernel `687.46.1`; the node is now named
  `a0-88-c2-27-c0-d4`). Same numbers: the pattern in 5,111,808 of 5,177,344
  sampled words per GPU while held, none in the new VM, and 80,896 of
  80,896 written words read back on each GPU.

README.md, "Is GPU memory cleared between tenants?", has the detail.

## Where each value comes from

- **Kernel and reset method.** vfio resets each GPU when a VM lets go of
  it, using the methods in `/sys/bus/pci/devices/<gpu>/reset_method` in
  order (function-level reset, then secondary bus reset). Whatever does
  the clearing, the host's reset or the GPU's firmware, sits on that path.
  The kernel is the reinstalled jetty's (2026-10-28); the earlier runs had
  `687.50.1` (OpenShift 4.22.16). The reset method was read from u16 on
  2026-10-26 and not re-read after the reinstall, which kept the same
  hardware and OpenShift Virtualization 4.22.12.
- **Device.** H100 SXM5 80GB (PCI 10de:2330), on all four GPUs.
- **VBIOS.** `96.00.DA.00.17`, read by `nvidia-smi` in the guests on
  2026-10-26 and again on 2026-10-28 (all four GPUs). The
  host has no NVIDIA driver in passthrough mode, so only a guest (or the
  BMC) can read it; `test-gpu-vm.sh` prints it as `vbios=`. Whether it was
  the same on 2026-10-20 is not recorded.

## What this does not show

One node, one firmware, two kernels. Sampled 256 KiB per GiB, not every byte. Which
component clears the memory is not known, only that it is clear before
the next guest can read it.

The 2026-10-20 restart run and the first 2026-10-26 run had no positive
control after the handback; the second 2026-10-26 run and the 2026-10-28
run did (step 6 of `test-gpu-memclear.sh`).
