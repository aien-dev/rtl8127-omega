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
