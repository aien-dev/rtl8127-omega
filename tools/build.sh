#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build dist/rtl8127-probe-linux-aarch64 from the Omega sources with the pinned compiler. Usage: tools/build.sh [OMC]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
omc=${1:-$("$root/tools/omc.sh")}
mkdir -p "$root/dist" "$root/build"
cat "$root/om/rtl8127/rtl8127.om" "$root/om/rtl8127/hw.om" "$root/cmd/rtl8127d/probe.om" | "$omc" > "$root/dist/rtl8127-probe-linux-aarch64"
chmod 755 "$root/dist/rtl8127-probe-linux-aarch64"
sha256sum "$root/dist/rtl8127-probe-linux-aarch64"
