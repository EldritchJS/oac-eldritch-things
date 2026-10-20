#!/usr/bin/env python3
"""Read GPU memory through BAR0's PRAMIN window, bypassing the NVIDIA driver.

Used by test-gpu-memclear.sh inside a guest. BAR0 offset 0x700000 is a 1 MiB
window onto video memory; a register sets which 64 KiB-aligned address it
shows: NV_XAL_EP_BAR0_WINDOW (0x10fd40) on Hopper. The older
NV_PBUS_BAR0_WINDOW (0x1700) reads 0xbadf5040 on an H100: not there.

  pramin.py scan [GiB]    move the window across memory, sampling 256 KiB per GiB
Run as root. Moves the window and puts it back; with the driver loaded this
races the driver's own use of it, which is acceptable in a throwaway guest.
"""
import collections, ctypes, glob, mmap, os, sys

PATTERN = 0xC0DEFACE
WINDOW, WINDOW_SIZE, SAMPLE = 0x700000, 1 << 20, 256 << 10
WINDOW_REG = 0x10FD40


def gpus():
    for dev in sorted(glob.glob("/sys/bus/pci/devices/*")):
        if open(dev + "/vendor").read().strip() == "0x10de" and \
           open(dev + "/class").read().strip().startswith("0x0302"):
            yield dev


def reg(mm, off):
    return ctypes.c_uint32.from_buffer(mm, off)


def sample(mm, size):
    words = (ctypes.c_uint32 * (size // 4)).from_buffer(mm, WINDOW)
    return list(words)


def main():
    gib = int(sys.argv[2]) if len(sys.argv) > 2 else 79
    for dev in gpus():
        bdf = os.path.basename(dev)
        try:
            with open(dev + "/enable", "w") as f:
                f.write("1")
        except OSError:
            pass
        try:
            fd = os.open(dev + "/resource0", os.O_RDWR | os.O_SYNC)
            mm = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        except OSError as e:
            print(f"PRAMIN_FAIL {bdf} cannot map BAR0: {e}", flush=True)
            continue
        r = ctypes.c_uint32.from_buffer(mm, WINDOW_REG)
        saved, found, seen, values = r.value, 0, 0, collections.Counter()
        for g in range(gib):
            r.value = (saved & ~0xFFFFFF) | ((g << 30) >> 16)
            words = sample(mm, SAMPLE)
            found += words.count(PATTERN)
            seen += len(words)
            values.update(words)
        r.value = saved
        top = " ".join(f"{v:08x}x{n}" for v, n in values.most_common(4))
        print(f"PRAMIN_SCAN {bdf} boot0=0x{ctypes.c_uint32.from_buffer(mm, 0).value:08x} "
              f"window=0x{saved:08x} pattern_words={found} of {seen} top={top}", flush=True)
        del r
        mm.close()
        os.close(fd)


if __name__ == "__main__":
    main()
