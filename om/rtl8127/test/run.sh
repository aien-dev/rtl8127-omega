#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# RTL8127 driver-core test: the Omega core against the software chip, then mutants that must be caught.
# Usage: sh om/rtl8127/test/run.sh OMC     (OMC from tools/omc.sh). Exit 0 only if the clean run passes and every mutant is detected.
set -eu
omc=${1:?usage: run.sh OMC}
here=$(cd "$(dirname "$0")" && pwd)
unit=$(dirname "$here")
root=$(cd "$unit/../.." && pwd)
out="$root/build/test/rtl8127"
mkdir -p "$out"
fail=0

build() { # build CORE OUTPUT
	cat "$1" "$unit/model.om" "$here/driver.om" | "$omc" > "$2" 2> "$2.err" || { echo "rtl8127: omc failed: $(cat "$2.err")"; return 1; }
	chmod +x "$2"
}

build "$unit/rtl8127.om" "$out/clean"
if "$out/clean" > "$out/clean.out"; then
	cat "$out/clean.out"
else
	cat "$out/clean.out"; echo "rtl8127: clean run FAIL"; fail=1
fi

# mutant NAME 'perl -0pi expression'
mutant() {
	cp "$unit/rtl8127.om" "$out/m.om"
	perl -0pi -e "$2" "$out/m.om"
	if cmp -s "$unit/rtl8127.om" "$out/m.om"; then echo "rtl8127: mutant $1 did not change the source: FAIL"; fail=1; return; fi
	if ! build "$out/m.om" "$out/m"; then echo "rtl8127: mutant $1 does not compile: FAIL"; fail=1; return; fi
	rc=0; "$out/m" > "$out/m.out" 2>&1 || rc=$?
	if [ "$rc" = 1 ] && grep -q "^RTL8127_OMEGA_MODEL: FAIL" "$out/m.out"; then
		echo "rtl8127: mutant $1 caught ($(grep -c '^FAIL ' "$out/m.out") checks failed)"
	elif [ "${3:-}" = trap-ok ] && [ "$rc" = 103 ]; then
		echo "rtl8127: mutant $1 stopped by Omega's bounds check (trap 3, exit 103), not by a test check"
	else
		echo "rtl8127: mutant $1 NOT CAUGHT (exit $rc)"; fail=1
	fi
}
mutant no-noclose     's/rtlw8 TXNOCLO or v 4/rtlw8 TXNOCLO or v 0/'
mutant tx-no-eor      's/dst32 mul i 32 f\n/dst32 mul i 32 0\n/'
mutant mac-locked     's/rtlw8 CFG9346 or v UNLOCK/rtlw8 CFG9346 or v 0/'
mutant link-inverted  's/if eq and s PHYSLNK 0/if ne and s PHYSLNK 0/'
mutant fcs-kept       's/rxcopy i sub n 4/rxcopy i sub n 0/'
mutant clo-unchecked  's/if gt done rtltxpend/if gt done 100000/'
mutant absent-missed  's/if eq tcr 4294967295/if eq tcr 4294967294/'
mutant chip-id-ignored 's/if ne and tcr TCRIDM TCRID/if ne and tcr TCRIDM TCRIDM/'
mutant rcr-no-myphys  's/or or RCRCHIP RCRBCST RCRMYPH/or RCRCHIP RCRBCST/'
mutant rx-no-eor      's/if eq i sub RXN 1\n/if eq i 99\n/'
mutant tail-not-written 's/rtlw32 SWTAIL0 and add get rs S_CLOB cur CLOMASK/rtlw32 SWTAIL0 0/'
mutant rx-len-unchecked 's/if gt n RXBUF/if gt n 5000/' trap-ok
exit $fail
