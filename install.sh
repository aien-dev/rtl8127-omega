#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# rtl8127-omega installer.
#
#   curl -fsSL https://raw.githubusercontent.com/aien-dev/rtl8127-omega/main/install.sh | sh
#
# EXPERIMENTAL. It has never run against a real chip. Realtek publishes no register document for the RTL8127.
#
# What the one-liner does (and ONLY this):
#   1. looks for an RTL8127 network card (PCI 10ec:8127) and tells you what it found;
#   2. downloads ONE file (rtl8127-probe, an Omega program) from this repository at a pinned commit and checks its sha256;
#   3. installs it under your home folder (no root needed for this);
#   4. runs it once, read-only, with sudo, to show the chip id, MAC address and link state.
# It does NOT change your network, unbind your network driver, or load anything into the kernel. Your network keeps working.
#
# Other commands (sh -s -- COMMAND):   check | install | takeover | restore | uninstall | help
#   check      read-only report, changes nothing
#   takeover   hands the card to the Omega driver, with an automatic timed rollback. NOT AVAILABLE in this release:
#              the Omega driver cannot carry network traffic yet (see docs/GAPS.md). The safety rules below are built and tested.
#   restore    gives the card back to the stock driver
#   uninstall  removes what install put in your home folder (and restores the card if takeover was used)
#
# Safety rules (all on by default):
#   - never takes the card if it carries your default route, or if you are on ssh and have no other network;
#   - takeover arms a rollback timer first; unless you confirm in time, the stock driver is put back by itself;
#   - everything downloaded is pinned to a commit and checked against a sha256 before it is used;
#   - one download, no other network traffic, nothing is sent anywhere.
set -eu

VERSION=0.1.0
REPO=aien-dev/rtl8127-omega
PIN_COMMIT=45becc6a90086ce754a256245cff64d6e62a33a7
PIN_SHA256=81bd506adcb2ef85d2a42f6eb66b05e2f1c372a34ed9bc8b77ee0fe401493267
ASSET=dist/rtl8127-probe-linux-aarch64
BASE_URL=${RTL_BASE_URL:-https://raw.githubusercontent.com/$REPO/$PIN_COMMIT}
SYSFS=${RTL_SYSFS:-/sys}
PROCFS=${RTL_PROC:-/proc}
PREFIX=${RTL_PREFIX:-$HOME/.local}
STATE=${RTL_STATE:-$HOME/.local/share/rtl8127-omega}
ARCH=${RTL_ARCH:-$(uname -m)}
ROLLBACK_S=${RTL_ROLLBACK_S:-120}
# A fake /sys means a test. Test-only switches are honoured ONLY then, never against the real /sys.
TEST=0
[ "$SYSFS" = /sys ] || TEST=1

say() { printf '%s\n' "$*"; }
die() { printf 'rtl8127-omega: %s\n' "$*" >&2; exit "${2:-1}"; }
note() { printf 'rtl8127-omega: %s\n' "$*"; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else die "no sha256sum or shasum on this machine, so I cannot check the download. Stopping." 4; fi
}

# ---- looking around (read-only) ----
find_cards() { # prints the PCI address of each RTL8127
	for d in "$SYSFS"/bus/pci/devices/*; do
		[ -f "$d/vendor" ] && [ -f "$d/device" ] || continue
		[ "$(cat "$d/vendor")" = 0x10ec ] && [ "$(cat "$d/device")" = 0x8127 ] && basename "$d"
	done
	return 0
}
card_driver() { [ -L "$SYSFS/bus/pci/devices/$1/driver" ] && basename "$(readlink "$SYSFS/bus/pci/devices/$1/driver")" || true; }
card_netdev() { for n in "$SYSFS/bus/pci/devices/$1"/net/*; do [ -e "$n" ] && basename "$n" && return 0; done; return 0; }
default_route_ifaces() { awk 'NR>1 && $2=="00000000" {print $1}' "$PROCFS/net/route" 2>/dev/null | sort -u; }
other_links_up() { # count of other network interfaces (not lo, not $1) that are up
	n=0
	for i in "$SYSFS"/class/net/*; do
		[ -e "$i" ] || continue
		b=$(basename "$i")
		[ "$b" = lo ] && continue
		[ "$b" = "${1:-}" ] && continue
		[ "$(cat "$i/operstate" 2>/dev/null || echo down)" = up ] && n=$((n + 1))
	done
	echo "$n"
}
on_ssh() { [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; }

# Returns 0 and says why when taking this card would be risky.
risky() { # risky BDF
	nd=$(card_netdev "$1")
	if [ -n "$nd" ] && default_route_ifaces | grep -qx "$nd"; then
		say "it carries your default route ($nd): taking it would cut your internet"; return 0
	fi
	if on_ssh && [ "$(other_links_up "$nd")" = 0 ]; then
		say "you are connected over ssh and I see no other network that is up: you could lock yourself out"; return 0
	fi
	return 1
}

cmd_check() {
	say "rtl8127-omega $VERSION (experimental, never run on a real chip)"
	say "cpu: $ARCH"
	cards=$(find_cards)
	if [ -z "$cards" ]; then say "found: no RTL8127 network card (PCI 10ec:8127) on this machine"; return 3; fi
	for c in $cards; do
		nd=$(card_netdev "$c"); dr=$(card_driver "$c")
		say "found: RTL8127 at $c (interface ${nd:-none}, driver ${dr:-none})"
		if r=$(risky "$c"); then say "takeover: would be REFUSED, $r"; else say "takeover: the safety checks pass (but takeover is not available in this release)"; fi
	done
	return 0
}

# ---- the one download ----
fetch_probe() { # fetch_probe DEST
	[ "$ARCH" = aarch64 ] || [ "$ARCH" = arm64 ] || die "this release only has a 64-bit Arm (aarch64) build, and this machine is $ARCH. Nothing was changed." 5
	command -v curl >/dev/null 2>&1 || die "curl is not installed. Nothing was changed." 4
	case "$BASE_URL" in
		https://*) proto="--proto =https --tlsv1.2" ;;
		file://*) [ "$TEST" = 1 ] || die "a file:// source is only allowed in tests" 4; proto="" ;;
		*) die "the download address must be https" 4 ;;
	esac
	tmp="$1.part"
	# shellcheck disable=SC2086
	curl -fsSL $proto -o "$tmp" "$BASE_URL/$ASSET" || { rm -f "$tmp"; die "could not download $ASSET. Nothing was changed." 6; }
	got=$(sha256_of "$tmp")
	if [ "$got" != "$PIN_SHA256" ]; then
		rm -f "$tmp"
		die "the download does not match its pinned checksum (wanted $PIN_SHA256, got $got). I deleted it. Nothing was changed." 7
	fi
	chmod 755 "$tmp"; mv "$tmp" "$1"
}

run_probe() { # run_probe BDF   (read-only)
	res="$SYSFS/bus/pci/devices/$1/resource2"
	[ -e "$res" ] || { note "no $res to read; skipping the read-only look"; return 0; }
	if [ "$(id -u)" = 0 ]; then "$PREFIX/bin/rtl8127-probe" "$res"
	elif command -v sudo >/dev/null 2>&1; then say "Next: one sudo step to read the chip (read-only)."; sudo "$PREFIX/bin/rtl8127-probe" "$res"
	else note "no sudo here; run this as root to read the chip: $PREFIX/bin/rtl8127-probe $res"; fi
}

cmd_install() {
	dry=${1:-}
	cards=$(find_cards)
	if [ -z "$cards" ]; then say "No RTL8127 network card (PCI 10ec:8127) found on this machine. Nothing to do, nothing changed."; return 3; fi
	for c in $cards; do say "Found an RTL8127 at $c (interface $(card_netdev "$c"), driver $(card_driver "$c"))."; done
	say "This will: download rtl8127-probe (pinned to commit $PIN_COMMIT, sha256 checked), put it in $PREFIX/bin, and run it once, read-only."
	say "It will NOT change your network or your network driver."
	[ "$dry" = --dry-run ] && { say "(dry run: stopping here, nothing changed)"; return 0; }
	mkdir -p "$PREFIX/bin" "$STATE"
	fetch_probe "$PREFIX/bin/rtl8127-probe"
	say "Downloaded and checked: sha256 $PIN_SHA256"
	for c in $cards; do run_probe "$c"; done
	say ""
	say "Done. Your network was not touched."
	say "This release can READ the chip. It cannot run your network yet. Why, and what is missing: docs/GAPS.md in the repository."
	say "To remove everything:   curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- uninstall"
}

# ---- takeover: built, tested, and switched off in this release ----
write_restore() { # write_restore BDF DRIVER : a self-contained script that gives the card back
	cat > "$STATE/restore.sh" <<EOS
#!/bin/sh
# puts the stock driver ($2) back on $1
d="$SYSFS/bus/pci/devices/$1"
[ -e "\$d/driver/unbind" ] && echo "$1" > "\$d/driver/unbind" 2>/dev/null
echo > "\$d/driver_override" 2>/dev/null
echo "$1" > "$SYSFS/bus/pci/drivers/$2/bind" 2>/dev/null || echo "$1" > "$SYSFS/bus/pci/drivers_probe" 2>/dev/null
echo restored > "$STATE/restored"
EOS
	chmod 755 "$STATE/restore.sh"
}

caps_ok() { # the driver says it can carry traffic
	[ -f "$STATE/CAPS" ] && grep -qx 'dma=yes' "$STATE/CAPS" && return 0
	[ "$TEST" = 1 ] && [ -n "${RTL_TEST_CAPS:-}" ] && return 0
	return 1
}

cmd_takeover() {
	cards=$(find_cards); c=$(printf '%s\n' "$cards" | head -n 1)
	[ -n "$c" ] || die "no RTL8127 found. Nothing changed." 3
	if ! caps_ok; then
		die "takeover is not available in this release: the Omega driver cannot carry network traffic yet (see docs/GAPS.md). Nothing was changed." 8
	fi
	if r=$(risky "$c"); then die "REFUSED: $r. Nothing was changed." 9; fi
	dr=$(card_driver "$c"); [ -n "$dr" ] || die "the card has no stock driver bound; nothing to hand over. Nothing changed." 3
	mkdir -p "$STATE"; rm -f "$STATE/confirm" "$STATE/restored"
	write_restore "$c" "$dr"
	# 1. arm the rollback FIRST. It puts the stock driver back unless you confirm in time.
	( sleep "$ROLLBACK_S"; [ -e "$STATE/confirm" ] || sh "$STATE/restore.sh" ) >/dev/null 2>&1 &
	echo $! > "$STATE/watchdog.pid"
	say "Rollback armed: in $ROLLBACK_S seconds the stock driver comes back by itself unless you run:  touch $STATE/confirm"
	# 2. only now hand the card over.
	echo "$c" > "$SYSFS/bus/pci/devices/$c/driver/unbind"
	echo "vfio-pci" > "$SYSFS/bus/pci/devices/$c/driver_override"
	echo "$c" > "$SYSFS/bus/pci/drivers_probe"
	echo "$c $dr" > "$STATE/taken"
	say "Card $c handed over."
}

cmd_restore() {
	[ -f "$STATE/restore.sh" ] || { say "nothing to restore."; return 0; }
	sh "$STATE/restore.sh"; rm -f "$STATE/taken"
	say "The stock driver is back."
}

cmd_uninstall() {
	[ -f "$STATE/taken" ] && cmd_restore
	[ -f "$STATE/watchdog.pid" ] && kill "$(cat "$STATE/watchdog.pid")" 2>/dev/null || true
	rm -f "$PREFIX/bin/rtl8127-probe"
	rm -rf "$STATE"
	say "Removed rtl8127-probe and its state folder. Your network driver was not changed."
}

cmd=${1:-install}
case "$cmd" in
	check) cmd_check ;;
	install) cmd_install "${2:-}" ;;
	--dry-run|dry-run) cmd_install --dry-run ;;
	takeover) cmd_takeover ;;
	restore) cmd_restore ;;
	uninstall) cmd_uninstall ;;
	help|-h|--help) sed -n '2,32p' "$0" 2>/dev/null || say "see $REPO" ;;
	*) die "unknown command '$cmd' (try: check, install, uninstall)" 2 ;;
esac
