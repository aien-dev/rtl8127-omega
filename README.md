# rtl8127-omega

A driver for the **Realtek RTL8127** 10 Gb network card (the one in the NVIDIA DGX Spark), written in
[Omega](https://github.com/aien-dev/omega-mv).

> **Please read this first.**
> - This is **experimental**.
> - It has **never been run on a real chip**. Everything it does was tested against a software model of the chip that we wrote.
> - Realtek has **no public datasheet** for this chip. Every register and every step comes from **Realtek's own Linux driver**
>   (`r8127` v11.014.00). We read that driver and wrote the same steps in Omega. If that driver is wrong or incomplete for your card, so is this.
> - **This release can only look at the chip. It cannot run your network yet.** The reason is in [docs/GAPS.md](docs/GAPS.md).

## Try it (it only looks, it changes nothing)

```sh
curl -fsSL https://raw.githubusercontent.com/aien-dev/rtl8127-omega/main/install.sh | sh
```

What that does, and only that:

1. Looks for an RTL8127 card. If you have none, it says so and stops.
2. Downloads **one** small file, `rtl8127-probe`, from this repository. The download is pinned to an exact commit and checked
   against a fingerprint (sha256). If the check fails, it deletes the file and stops.
3. Puts it in `~/.local/bin`.
4. Runs it once, with `sudo`, **read-only**. It prints the chip id, the MAC address the chip holds, and the link state.

It does **not** touch your network, your network driver, or your kernel. To remove it:

```sh
curl -fsSL https://raw.githubusercontent.com/aien-dev/rtl8127-omega/main/install.sh | sh -s -- uninstall
```

Want to see what it would do first? `... | sh -s -- check` only looks around. `... | sh -s -- install --dry-run` stops before the download.

It needs a 64-bit Arm Linux machine (like the DGX Spark). On anything else it tells you and stops.

## What is real, and what is not

| Thing | State |
|---|---|
| The driver core in Omega: reset, MAC address, link state, TX and RX rings, stop | Written. **184 checks pass** against the software chip, and **12 deliberately broken copies** of the code are all caught by those checks (11 by a failing check, 1 by Omega's own bounds check). |
| The read-only probe (`rtl8127-probe`) | Passes 11 checks against **fake** chip files. **Never read a real chip.** |
| The installer | 16 checks pass inside a throw-away container with no network and a fake `/sys`: it refuses a wrong checksum, a changed file, the wrong CPU, no card; it never touches your driver; the rollback works. |
| Running on a real RTL8127 | **UNKNOWN.** Not tried. |
| Carrying network traffic | **Not possible yet** ([docs/GAPS.md](docs/GAPS.md)). |
| `takeover` (hand the card to this driver) | **Switched off** in this release. The safety rules are built and tested so they are ready, see below. |

Every claim here is one of: **OBSERVED** (we ran it and saw it), **SOURCE** (read in Realtek's driver), or **UNKNOWN** (nobody has checked).
The driver's register table is SOURCE, with line numbers in the comments of [om/rtl8127/rtl8127.om](om/rtl8127/rtl8127.om). The tests are OBSERVED, on a
DGX Spark with the pinned Omega compiler.

## How a network driver works (the plain version)

A network card is a small computer on a board. The driver is the program that tells it what to do. In plain steps:

1. **Find the card and check it is the right one.** The driver reads one of the card's settings (a "register", think of it as a labelled mailbox on the card). If it reads all ones, nothing is there. If the model number is not the one we know, we stop. (`rtlinit`)
2. **Wake it up and reset it.** Cards start in an unknown state, so we tell it to reset and wait until it says it is done. (`rtlpwrup`, `rtlhwrst`)
3. **Ask it for its own address.** Every card has a unique MAC address (like a street address on the local network). We read it from the card. (`rtlinit`)
4. **Set up two waiting lines in memory.** One line is for packets we want to send, one for packets that arrive. Each line is a "ring" of 16 slots. Each slot has a small note (a "descriptor") that says "the packet is here, it is this long, you own it / I own it". The card reads and writes memory directly to do this, which is called DMA. We tell the card where the rings live. (`rtlinit`)
5. **Switch on sending and receiving.** We unlock the card's settings, say which packets to accept, and turn the send and receive parts on. We leave interrupts off, so the driver keeps checking ("polling") instead of waiting for the card to tap it on the shoulder. This is simpler, and slower.
6. **Send a packet.** Put the packet in a slot, hand the slot to the card, then ring the "doorbell" (write one register). The card sends it and hands the slot back. (`rtltx`, `rtltxrec`)
7. **Receive a packet.** Look at the next slot in the receive line. If the card has filled it, copy the packet out and give the slot back. (`rtlrx`)
8. **Report the link.** Ask the card's PHY (the part that talks to the actual cable) whether the cable is connected and how fast: 10, 100, 1000, 2500, 5000 or 10000 Mb/s. (`rtllink`)
9. **Stop.** Turn sending and receiving off. (`rtlstop`)

The function names are in [om/rtl8127/rtl8127.om](om/rtl8127/rtl8127.om) if you want to follow along.

## Why this could be wrong

Short version: **nobody has ever watched this code work on the real card.** Here is why that matters, and how we will find out.

**1. We copied from a driver, not from a manual.** Realtek publishes no datasheet for this chip. The only source is Realtek's own Linux driver. Every register number, every bit, every wait time came from reading it. If we misread one number, the card does something different from what we think.

**2. Our tests are marked by us.** We built a software pretend-card and ran the driver against it. But we built the pretend-card from the same reading of the same source. If we misunderstood something, we misunderstood it twice, and the tests still pass. Passing tests here mean "the code does what we think the card does", not "the code does what the card does".

**3. The "12 broken copies" test proves less than it sounds.** It shows the tests notice when the code is changed. It does not show the code matches real hardware.

Here are the specific things most likely to be wrong, and how each one would show up on the real card:

| What could be wrong | What we would see | How we find out |
|---|---|---|
| A register is at the wrong place | The probe reads nonsense or all ones | Step 1 of the hardware test below |
| The chip model number bits are different on this revision | Driver says "not my chip" | Step 1 |
| Reset takes longer than we wait (the vendor driver ignores a timeout, we report it) | Reset error | Step 2 |
| The PHY (cable side) registers have different addresses | Link never comes up, or wrong speed | Step 2 |
| A descriptor field is in the wrong order, or wrong byte order | Sent packets never leave, or received ones look scrambled | Step 3 (send one packet, watch from another machine) |
| We assume the firmware left the card in a usable state | Works on a clean boot, fails after a warm one | Repeat after reboot |
| A wait for the card to resume from low power is only noted as UNKNOWN in our source | Random failures after idle | Long run |
| We assume the simple interrupt mode and no MSI-X | Fine while polling, wrong if we ever turn interrupts on | Only matters later |
| Memory handed to the card must be aligned and inside what the memory-protection hardware (IOMMU) allows | Card writes somewhere else | Step 3 |

### How we will find out, in order

Each step tells us something before we risk the next one. The first two are read-only.

1. `sh install.sh check`. Looks around, changes nothing.
2. Run the probe on the real card. Expected on the Spark: link up, 10000 Mb/s, MAC `4c:bb:47:2b:b8:7b`. If it exits with code 14, the register map is wrong, and we stop and fix it.
3. Send one packet, then receive one, then loop them. Not possible in this release (see [docs/GAPS.md](docs/GAPS.md)).

### The big risk, said plainly

On the DGX Spark this card is the **only** working network connection. If a driver for it goes wrong while it owns the card, the machine drops off the network and someone has to walk over and fix it. That is why `takeover` is switched off, why the safety rules exist, and why this release only looks.

### If you try it

Please tell us what the probe printed, even if it is an error. A failed probe is useful: it tells us which part of our reading was wrong. Open an issue on this repo and paste the output. Do not paste anything private; the probe prints only the chip id, the MAC address and the link state.

## The safety rules (built and tested, for when takeover is switched on)

- It will **not** take a card that carries your default route, and will not take it if you are on ssh and nothing else is up.
- It arms a **rollback timer first**. Unless you confirm in time, the stock driver is put back by itself.
- Everything it downloads is pinned and checked before use. One download, nothing else on the network, nothing sent anywhere.
- A test-only switch is honoured only against a fake `/sys`, never against your real one.

## Where this came from

This is a port of the C driver in [aien-dev/aienux](https://github.com/aien-dev/aienux) pull request 450 (`native/net/aienos_rtl8127.c`), which is for the
Aienux kernel and was also never run on the chip. That C driver and this one share the same register table and the same ideas.
The Linux netdev patch that added the chip to `r8169` says the same thing we do: "there's no public datasheet for the chip so this is just
porting over the original vendor code" (Fabio Baltieri, 2025-11-17).

## Build and test it yourself

You need the pinned Omega compiler (`omega.pin`). `tools/omc.sh` builds it from the pinned commit, or use `OMC=/path/to/omc`.

```sh
sh om/rtl8127/test/run.sh "$(tools/omc.sh)"      # driver core against the software chip, plus the broken copies
sh cmd/rtl8127d/test/run.sh "$(tools/omc.sh)"    # the read-only probe against fake chip files
sh tools/build.sh                                 # builds dist/rtl8127-probe-linux-aarch64
sh tests/install/run.sh                           # installer tests (needs docker)
```

## Layout

- `om/rtl8127/rtl8127.om`: the driver core. `model.om`: the software chip. `hw.om`: read-only access to a real chip. `test/`: tests.
- `cmd/rtl8127d/probe.om`: the read-only probe.
- `install.sh`: the installer. `dist/`: the pinned probe binary. `tests/install/`: installer tests.
- `docs/GAPS.md`: what is missing.

## Licence

Apache-2.0. Register facts come from Realtek's `r8127` driver (see its own licence at github.com/openwrt/rtl8127); no Realtek code is copied here.

## Human-Directed Agentic Engineering

Development follows Human-Directed Agentic Engineering (HDAE): humans define goals,
architecture, constraints, acceptance criteria, and stopping points; agents implement,
execute checks, diagnose failures, and revise within those boundaries. Human review
retains responsibility for claims, acceptance, and release decisions. This describes
the development method, not a change to runtime autonomy or historical evidence.

For the documented method and a systems-software case study, see Gregory M. Kurtzer
(2026), *Ginux: Building an Independent Kernel That Runs Linux Userspace through
Human-Directed Agentic Engineering*, technical report, v1, Zenodo,
<https://doi.org/10.5281/zenodo.23682548>.
