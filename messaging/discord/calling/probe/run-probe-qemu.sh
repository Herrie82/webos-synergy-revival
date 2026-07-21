#!/usr/bin/env bash
# run-probe-qemu.sh — run the cross-built ARM dave_probe on the dev host via
# qemu-arm-static (userspace emulation). Proves the ARM binary + libdave + mlspp +
# OpenSSL 1.1.1w execute. On the real TouchPad, just scp logs/dave_probe and run it
# (with LD_LIBRARY_PATH pointing at the device's OpenSSL 1.1.1w).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

TC="${ARM_TC:-/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125}"
OSSL="${ARM_OSSL:-/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update/openssl-1.1.1w}"
SYSROOT="$TC/arm-unknown-linux-gnueabi/sysroot"
BIN="$ROOT/logs/dave_probe"

[ -x "$BIN" ] || { echo "build first: probe/build-probe.sh"; exit 1; }
command -v qemu-arm-static >/dev/null || { echo "qemu-arm-static not installed"; exit 1; }

QEMU_LD_PREFIX="$SYSROOT" \
LD_LIBRARY_PATH="$OSSL:$SYSROOT/lib:$SYSROOT/usr/lib" \
  qemu-arm-static "$BIN"
