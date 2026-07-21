#!/usr/bin/env bash
# build-probe.sh — cross-compile dave_probe.cpp for ARMv7 webOS against the
# vendored prebuilt libdave + mlspp static libs in ../prebuilt.
#
# Output: ../logs/dave_probe (ARM ELF). Run on-device, or under qemu via
# run-probe-qemu.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Toolchain + cross OpenSSL (override with env if your layout differs)
TC="${ARM_TC:-/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125}"
OSSL="${ARM_OSSL:-/home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update/openssl-1.1.1w}"
CXX="$TC/bin/arm-unknown-linux-gnueabi-g++"

PREFIX="$ROOT/prebuilt"
INC="$PREFIX/include"
LIB="$PREFIX/lib"
OUT="$ROOT/logs/dave_probe"

ARCH_FLAGS="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp"

echo "[probe] CXX     = $CXX"
echo "[probe] prefix  = $PREFIX"
echo "[probe] openssl = $OSSL"

"$CXX" $ARCH_FLAGS -std=c++17 -O2 -Wall \
  -I"$INC" \
  -I"$INC/dave-src" \
  -I"$INC/mlspp" \
  -I"$OSSL/include" \
  "$HERE/dave_probe.cpp" \
  -o "$OUT" \
  -Wl,--start-group \
    "$LIB/libdave.a" \
    "$LIB/libmlspp.a" \
    "$LIB/libhpke.a" \
    "$LIB/libtls_syntax.a" \
    "$LIB/libbytes.a" \
  -Wl,--end-group \
  -L"$OSSL" -lcrypto -lssl \
  -lpthread

echo "[probe] built: $OUT"
file "$OUT" || true
