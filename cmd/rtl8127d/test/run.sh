#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# rtl8127-probe against a FAKE BAR file (no device). Usage: sh cmd/rtl8127d/test/run.sh OMC
# Checks: a good RTL8127 image prints the right id, both MAC addresses and the link; the wrong chip, an all-ones image and a missing
# file are refused with their own exit codes; the file is not modified (read-only). Never touches a real device.
set -eu
omc=${1:?usage: run.sh OMC}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out="$root/build/test/probe"
rm -rf "$out"; mkdir -p "$out"
fail=0
cat "$root/om/rtl8127/rtl8127.om" "$root/om/rtl8127/hw.om" "$root/cmd/rtl8127d/probe.om" | "$omc" > "$out/probe" 2> "$out/err" || { echo "probe: omc failed: $(cat "$out/err")"; exit 1; }
chmod +x "$out/probe"

poke() { # poke FILE OFFSET HEXBYTES...   (little-endian bytes in file order)
	f=$1; o=$2; shift 2
	for b in "$@"; do printf "\\$(printf %03o "0x$b")" | dd of="$f" bs=1 seek="$o" conv=notrunc 2>/dev/null; o=$((o + 1)); done
}
newbar() { dd if=/dev/zero of="$1" bs=4096 count=64 2>/dev/null; }

check() { # check NAME WANT_EXIT WANT_TEXT FILE
	rc=0; "$out/probe" "$4" > "$out/$1.out" 2> "$out/$1.err" || rc=$?
	if [ "$rc" = "$2" ] && { [ -z "$3" ] || cat "$out/$1.out" "$out/$1.err" | grep -qF "$3"; }; then echo "probe: $1 PASS (exit $rc)"; else echo "probe: $1 FAIL (exit $rc, want $2 / '$3')"; cat "$out/$1.out" "$out/$1.err"; fail=1; fi
}

good="$out/bar-good"; newbar "$good"
poke "$good" 64 00 00 90 6c            # TxConfig 0x6c900000: RTL8127, IC version 1
poke "$good" 0 a0 a1 a2 a3 a4 a5       # MAC0
poke "$good" 6624 48 11 22 33 44 55    # backup address
poke "$good" 108 03 40                 # PHYstatus: link up, 10 Gb/s
sum1=$(sha256sum "$good" | cut -d' ' -f1)
check good 0 "TxConfig 0x6c900000" "$good"
grep -qF "MAC (backup) 48:11:22:33:44:55" "$out/good.out" && echo "probe: backup MAC PASS" || { echo "probe: backup MAC FAIL"; fail=1; }
grep -qF "MAC (current) a0:a1:a2:a3:a4:a5" "$out/good.out" && echo "probe: current MAC PASS" || { echo "probe: current MAC FAIL"; fail=1; }
grep -qF "link up, Mb/s 10000" "$out/good.out" && echo "probe: link PASS" || { echo "probe: link FAIL"; fail=1; }
grep -qF "read-only, nothing was written" "$out/good.out" && echo "probe: read-only notice PASS" || { echo "probe: notice FAIL"; fail=1; }
[ "$(sha256sum "$good" | cut -d' ' -f1)" = "$sum1" ] && echo "probe: file unchanged PASS" || { echo "probe: file CHANGED FAIL"; fail=1; }

down="$out/bar-down"; cp "$good" "$down"; poke "$down" 108 00 00
check down 0 "link down" "$down"

wrong="$out/bar-wrong"; cp "$good" "$wrong"; poke "$wrong" 64 00 00 00 54
check wrong-chip 14 "not an RTL8127" "$wrong"

ones="$out/bar-ones"; newbar "$ones"; tr '\000' '\377' < "$ones" > "$ones.x"; mv "$ones.x" "$ones"
check absent 13 "all ones" "$ones"

check missing 11 "" "$out/does-not-exist"
rc=0; "$out/probe" > /dev/null 2>&1 || rc=$?
[ "$rc" = 10 ] && echo "probe: usage exit 10 PASS" || { echo "probe: usage FAIL (exit $rc)"; fail=1; }
exit $fail
