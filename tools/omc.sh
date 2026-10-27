#!/bin/sh
# Print the path of a verified Omega compiler (omc).
# OMC=/path/to/omc picks one (it is checked against the pin). Otherwise: ./build/omc if it matches, else the omnet-style
# birth from the pinned omega-mv commit (needs git and network). Usage: tools/omc.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
pin_commit=$(awk '$1 == "omega-mv" { print $2 }' "$root/omega.pin")
pin_sha=$(awk '$1 == "omc-sha256" { print $2 }' "$root/omega.pin")
check() { [ -x "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$pin_sha" ]; }
if [ -n "${OMC:-}" ]; then
	check "$OMC" || { echo "omc.sh: $OMC does not match the pinned sha256 $pin_sha" >&2; exit 1; }
	echo "$OMC"; exit 0
fi
if check "$root/build/omc"; then echo "$root/build/omc"; exit 0; fi
src="$root/build/omega-mv"
if [ ! -d "$src/.git" ]; then
	mkdir -p "$root/build"
	git clone -q --filter=blob:none https://github.com/aien-dev/omega-mv.git "$src" >&2
fi
git -C "$src" fetch -q origin "$pin_commit" >&2 || true
git -C "$src" checkout -q --detach "$pin_commit" >&2
(cd "$src" && sh seed/omega-from-seed.sh) >&2
check "$src/seed/out/omc" || { echo "omc.sh: built omc does not match pin $pin_sha" >&2; exit 1; }
echo "$src/seed/out/omc"
