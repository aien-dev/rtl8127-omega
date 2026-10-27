# What is missing, and why this release only reads the chip

This is the plain list of what stops the Omega driver from carrying your network traffic today. Each item is a fact about the
Omega compiler we pin (`omega.pin`), or about the chip. None of it was guessed.

## The short version

The driver logic is written in Omega and passes its tests against a **software model** of the chip. To use it on a real card, a
program has to do three things Omega cannot do yet:

| # | What the driver needs | What Omega has today | Status |
|---|---|---|---|
| 1 | Read and write **1-byte and 2-byte** chip registers (the chip has them: ChipCmd at 0x37, Cfg9346 at 0x50, PHYstatus at 0x6C) | `mapget` / `mapset` handle **4-byte and 8-byte** words only (`seed/host/MAPPING.md`) | **Missing.** The read-only probe works around it for reads by reading the whole 4-byte word and picking out the part it needs. That is not safe for writes: a 4-byte write would also overwrite the neighbouring registers. |
| 2 | Hand a block of memory to the card so the card can read and write it (the TX and RX rings) | Needs the VFIO ioctls: set up an IOMMU container, map a memory block for the card (`VFIO_IOMMU_MAP_DMA`), get the device (`VFIO_GROUP_GET_DEVICE_FD`), read region info. `devctl` accepts only `FIONREAD` and NVIDIA requests. | **Missing.** There is no "arbitrary ioctl" word, on purpose (`seed/host/MAPPING.md`: "no arbitrary syscall"). A list of allowed VFIO requests would have to be added to the compiler, the same way the NVIDIA and UVM lists were. |
| 3 | The ring memory must be a page-aligned block that the compiler can give to the kernel | The driver keeps its rings in an Omega `global` array. A global cannot be given to the kernel. | **Needs a change here** once item 2 exists: use a `mapnew` block and `mapread` / `mapwrite` for the descriptors. |

Until 1 and 2 exist, taking the card away from the stock driver would leave it with nothing to talk to. So `takeover` is
**switched off** in this release, and the installer says so.

## Why we did not fake it

The Omega rule is: if the compiler cannot say something, do not write it in C or shell and call it Omega. So the driver core is Omega,
the tests are Omega, and the gaps above are written down instead of hidden. The installer is a shell script because installing is
copying and checking files; it contains no driver logic.

## What the proposal to Omega looks like (for whoever picks it up)

- `mapget` / `mapset` with `width` 1 and 2, one load or store each, bracketed like the 4 and 8 byte forms.
- `devctl` allow-list entries for the VFIO requests above, with their exact payload sizes, the same style as the UVM list.
- A way to learn the bus address of a mapped block (for VFIO this is the address the program chose in `VFIO_IOMMU_MAP_DMA`,
  so the program already knows it).
- A gate that runs them against a fake device file (as `seed/host/tests/mapping.om` does) and refuses everything else.

## Other things that are not done

- Interrupts. The core is polled; interrupts stay masked.
- Offloads, jumbo frames, more than one queue, power management, Wake-on-LAN, the vendor's firmware patches (PHY micro-code, PCIe tuning).
  The C driver this was ported from relies on the state the machine firmware leaves, and so does this.
- Everything about the **real chip** is UNKNOWN. See the README.
