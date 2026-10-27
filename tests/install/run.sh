#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Installer tests, in a throw-away container with NO network, against a FAKE /sys and /proc (no real device, ever).
# Usage: sh tests/install/run.sh [IMAGE]     needs docker, and dist/rtl8127-probe-linux-aarch64 (built by tools/build.sh).
# Positive cases and negative controls: wrong checksum, wrong CPU, card on the default route, ssh with no other network, no card,
# takeover switched off, rollback fires without confirmation and does NOT fire with it, uninstall, dry run changes nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
img=${1:-aienos-onboard-base:alpha-20261026.3}
asset="$root/dist/rtl8127-probe-linux-aarch64"
[ -f "$asset" ] || { echo "install-test: build the probe first (sh tools/build.sh)"; exit 2; }
sum=$(sha256sum "$asset" | cut -d' ' -f1)
T=$(mktemp -d)
# the container runs as root, so it must also clean up what it made
cleanup() { docker run --rm -v "$T:/w" --entrypoint sh "$img" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT
fail=0

# a fake BAR 2 (RTL8127, IC 1, MAC 48:11:22:33:44:55, link up 10G), made the same way as the probe test
dd if=/dev/zero of="$T/good.bar" bs=4096 count=64 2>/dev/null
poke() { f=$1; o=$2; shift 2; for b in "$@"; do printf "\\$(printf %03o "0x$b")" | dd of="$f" bs=1 seek="$o" conv=notrunc 2>/dev/null; o=$((o + 1)); done; }
poke "$T/good.bar" 64 00 00 90 6c
poke "$T/good.bar" 0 a0 a1 a2 a3 a4 a5
poke "$T/good.bar" 6624 48 11 22 33 44 55
poke "$T/good.bar" 108 03 40
pass() { echo "install-test: $1 PASS"; }
bad() { echo "install-test: $1 FAIL ($2)"; fail=1; }

# mkroot DIR : a fake machine with one RTL8127 on enP7s7 (up, default route) and a second interface wlan0 (up unless OTHER_DOWN=1)
mkroot() {
	d=$1; rm -rf "$d"
	bd="$d/sys/bus/pci/devices/0007:01:00.0"
	mkdir -p "$bd/net/enP7s7" "$d/sys/bus/pci/drivers/r8127" "$d/sys/class/net/enP7s7" "$d/sys/class/net/wlan0" "$d/sys/class/net/lo" "$d/proc/net" "$d/home" "$d/dist"
	if [ -z "${NOCARD:-}" ]; then printf '0x10ec\n' > "$bd/vendor"; printf '0x8127\n' > "$bd/device"; else printf '0x8086\n' > "$bd/vendor"; printf '0x1234\n' > "$bd/device"; fi
	ln -s ../../drivers/r8127 "$bd/driver"
	: > "$d/sys/bus/pci/drivers/r8127/bind"; : > "$d/sys/bus/pci/drivers/r8127/unbind"; : > "$d/sys/bus/pci/drivers_probe"; : > "$bd/driver_override"
	cp "$T/good.bar" "$bd/resource2"
	echo up > "$d/sys/class/net/enP7s7/operstate"; echo down > "$d/sys/class/net/lo/operstate"
	if [ -n "${OTHER_DOWN:-}" ]; then echo down > "$d/sys/class/net/wlan0/operstate"; else echo up > "$d/sys/class/net/wlan0/operstate"; fi
	iface=${ROUTE_IF:-enP7s7}
	printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n%s\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' "$iface" > "$d/proc/net/route"
	cp "$asset" "$d/dist/rtl8127-probe-linux-aarch64"
	sed "s/^PIN_COMMIT=.*/PIN_COMMIT=testcommit/; s/^PIN_SHA256=.*/PIN_SHA256=${PINSUM:-$sum}/" "$root/install.sh" > "$d/i.sh"
}
# box DIR ENV... -- ARGS : run the installer in a container; output in DIR/out, exit code in DIR/rc. The asset is at file:///w/dist/<file>.
box() {
	d=$1; shift
	envs=""
	while [ "$1" != "--" ]; do envs="$envs -e $1"; shift; done; shift
	rc=0
	# shellcheck disable=SC2086
	docker run --rm --network none -v "$d:/w" -e HOME=/w/home -e RTL_SYSFS=/w/sys -e RTL_PROC=/w/proc -e RTL_PREFIX=/w/home/.local \
		-e RTL_STATE=/w/home/state -e RTL_BASE_URL=file:///w $envs --entrypoint sh "$img" /w/i.sh "$@" > "$d/out" 2>&1 || rc=$?
	echo "$rc" > "$d/rc"
}
rc_of() { cat "$1/rc"; }
has() { grep -qF "$2" "$1/out"; }

# 1. check, on a machine with the card
D=$T/a; mkroot "$D"; box "$D" -- check
[ "$(rc_of "$D")" = 0 ] && has "$D" "found: RTL8127 at 0007:01:00.0" && has "$D" "REFUSED" && pass "check finds the card and says takeover would be refused (default route)" || { bad check "$(cat "$D/out")"; }

# 2. one-line install: probe is downloaded, checked, installed, run read-only; network and driver untouched
D=$T/b; mkroot "$D"; box "$D" -- install
if [ "$(rc_of "$D")" = 0 ] && [ -x "$D/home/.local/bin/rtl8127-probe" ] && has "$D" "Downloaded and checked" && has "$D" "MAC (backup) 48:11:22:33:44:55" && has "$D" "Your network was not touched"; then pass "install downloads, checks, installs and runs read-only"; else bad install "$(cat "$D/out")"; fi
[ ! -s "$D/sys/bus/pci/drivers/r8127/unbind" ] && [ ! -s "$D/sys/bus/pci/drivers/r8127/bind" ] && [ ! -s "$D/sys/bus/pci/devices/0007:01:00.0/driver_override" ] && pass "install did not touch the network driver (no bind, unbind or override)" || bad untouched "driver files were written"

# 3. the same through a pipe, like curl | sh
D=$T/c; mkroot "$D"
rc=0; docker run --rm --network none -i -v "$D:/w" -e HOME=/w/home -e RTL_SYSFS=/w/sys -e RTL_PROC=/w/proc -e RTL_PREFIX=/w/home/.local -e RTL_STATE=/w/home/state -e RTL_BASE_URL=file:///w --entrypoint sh "$img" -s -- check < "$D/i.sh" > "$D/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && has "$D" "found: RTL8127" && pass "works when piped into sh (curl | sh form)" || bad pipe "$(cat "$D/out")"

# 4. NEGATIVE: a download that does not match its pinned checksum is refused and deleted, nothing installed
D=$T/d; PINSUM=0000000000000000000000000000000000000000000000000000000000000000 mkroot "$D"; box "$D" -- install
[ "$(rc_of "$D")" = 7 ] && has "$D" "does not match its pinned checksum" && [ ! -e "$D/home/.local/bin/rtl8127-probe" ] && [ ! -e "$D/home/.local/bin/rtl8127-probe.part" ] && pass "NEGATIVE wrong checksum: refused, deleted, nothing installed" || bad checksum "$(cat "$D/out")"

# 5. NEGATIVE: a tampered download (one byte changed) is refused
D=$T/e; mkroot "$D"; printf 'x' >> "$D/dist/rtl8127-probe-linux-aarch64"; box "$D" -- install
[ "$(rc_of "$D")" = 7 ] && [ ! -e "$D/home/.local/bin/rtl8127-probe" ] && pass "NEGATIVE tampered file: refused" || bad tamper "$(cat "$D/out")"

# 6. NEGATIVE: wrong CPU
D=$T/f; mkroot "$D"; box "$D" RTL_ARCH=x86_64 -- install
[ "$(rc_of "$D")" = 5 ] && has "$D" "aarch64" && [ ! -e "$D/home/.local/bin/rtl8127-probe" ] && pass "NEGATIVE x86_64: refused with a plain message, nothing installed" || bad arch "$(cat "$D/out")"

# 7. NEGATIVE: no RTL8127 on the machine
D=$T/g; NOCARD=1 mkroot "$D"; box "$D" -- install
[ "$(rc_of "$D")" = 3 ] && has "$D" "No RTL8127" && [ ! -e "$D/home/.local/bin/rtl8127-probe" ] && pass "NEGATIVE no card: says so, downloads nothing" || bad nocard "$(cat "$D/out")"

# 8. dry run changes nothing
D=$T/h; mkroot "$D"; box "$D" -- install --dry-run
[ "$(rc_of "$D")" = 0 ] && has "$D" "dry run" && [ ! -e "$D/home/.local/bin" ] && [ ! -e "$D/home/state" ] && pass "dry run changes nothing" || bad dry "$(cat "$D/out")"

# 9. NEGATIVE: takeover is switched off in this release (the driver cannot carry traffic)
D=$T/i; mkroot "$D"; box "$D" -- takeover
[ "$(rc_of "$D")" = 8 ] && has "$D" "not available in this release" && [ ! -s "$D/sys/bus/pci/drivers/r8127/unbind" ] && pass "NEGATIVE takeover: refused in this release, nothing written" || bad takeoff "$(cat "$D/out")"

# 10. NEGATIVE: even with the driver switch on (test only), a card on the default route is refused
D=$T/j; mkroot "$D"; box "$D" RTL_TEST_CAPS=1 -- takeover
[ "$(rc_of "$D")" = 9 ] && has "$D" "default route" && [ ! -s "$D/sys/bus/pci/drivers/r8127/unbind" ] && [ ! -e "$D/home/state/watchdog.pid" ] && pass "NEGATIVE default route: refused before anything is armed or written" || bad route "$(cat "$D/out")"

# 11. NEGATIVE: ssh session and no other network up
D=$T/k; ROUTE_IF=wlan0 OTHER_DOWN=1 mkroot "$D"; box "$D" RTL_TEST_CAPS=1 SSH_CONNECTION=1.2.3.4_5_6.7.8.9_22 -- takeover
[ "$(rc_of "$D")" = 9 ] && has "$D" "ssh" && [ ! -s "$D/sys/bus/pci/drivers/r8127/unbind" ] && pass "NEGATIVE ssh with no other network: refused" || bad ssh "$(cat "$D/out")"

# 12. takeover allowed (test switch, card NOT on the default route, other network up): rollback is armed FIRST, then the card is handed over,
#     and with no confirmation the stock driver comes back by itself
D=$T/l; ROUTE_IF=wlan0 mkroot "$D"
cat > "$D/run12.sh" <<'EOS'
sh /w/i.sh takeover
sleep 4
EOS
rc=0; docker run --rm --network none -v "$D:/w" -e HOME=/w/home -e RTL_SYSFS=/w/sys -e RTL_PROC=/w/proc -e RTL_PREFIX=/w/home/.local -e RTL_STATE=/w/home/state -e RTL_BASE_URL=file:///w -e RTL_TEST_CAPS=1 -e RTL_ROLLBACK_S=1 --entrypoint sh "$img" /w/run12.sh > "$D/out" 2>&1 || rc=$?
bdf=0007:01:00.0
if [ "$rc" = 0 ] && has "$D" "Rollback armed" && has "$D" "handed over" && [ "$(cat "$D/sys/bus/pci/drivers/r8127/unbind")" = "$bdf" ] && [ "$(cat "$D/sys/bus/pci/drivers_probe")" = "$bdf" ]; then pass "takeover: rollback armed first, then the card is handed over"; else bad takeover "$(cat "$D/out")"; fi
[ -e "$D/home/state/restored" ] && [ "$(cat "$D/sys/bus/pci/drivers/r8127/bind")" = "$bdf" ] && pass "rollback FIRES by itself when nobody confirms: stock driver bound again" || bad rollback "no restore happened"

# 13. NEGATIVE control for the rollback: with a confirmation in time, it does NOT fire
D=$T/m; ROUTE_IF=wlan0 mkroot "$D"
cat > "$D/run13.sh" <<'EOS'
sh /w/i.sh takeover
touch /w/home/state/confirm
sleep 4
EOS
rc=0; docker run --rm --network none -v "$D:/w" -e HOME=/w/home -e RTL_SYSFS=/w/sys -e RTL_PROC=/w/proc -e RTL_PREFIX=/w/home/.local -e RTL_STATE=/w/home/state -e RTL_BASE_URL=file:///w -e RTL_TEST_CAPS=1 -e RTL_ROLLBACK_S=1 --entrypoint sh "$img" /w/run13.sh > "$D/out" 2>&1 || rc=$?
[ ! -e "$D/home/state/restored" ] && [ ! -s "$D/sys/bus/pci/drivers/r8127/bind" ] && pass "NEGATIVE confirm in time: rollback does not fire" || bad confirm "restore ran anyway"

# 14. uninstall removes what install put there, leaves the network driver alone
D=$T/n; mkroot "$D"; box "$D" -- install >/dev/null 2>&1 || true
rc=0; docker run --rm --network none -v "$D:/w" -e HOME=/w/home -e RTL_SYSFS=/w/sys -e RTL_PROC=/w/proc -e RTL_PREFIX=/w/home/.local -e RTL_STATE=/w/home/state -e RTL_BASE_URL=file:///w --entrypoint sh "$img" /w/i.sh uninstall > "$D/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$D/home/.local/bin/rtl8127-probe" ] && [ ! -e "$D/home/state" ] && [ ! -s "$D/sys/bus/pci/drivers/r8127/bind" ] && pass "uninstall removes everything and leaves the driver alone" || bad uninstall "$(cat "$D/out")"

exit $fail
