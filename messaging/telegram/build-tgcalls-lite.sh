#!/bin/bash
# build-tgcalls-lite.sh — cross-compile the tgcalls-lite native engine (see
# plugin/tgcalls-lite/) for webOS 3.0.5 ARM. Same toolchain as build-libtgvoip.sh.
#
# Phase 0.2 spike: usrsctp only, to prove the SCTP signaling-channel dependency cross-compiles
# cleanly on this toolchain before Phase 1 builds the real engine on top of it (ICE via libnice,
# DTLS-SRTP via OpenSSL+libsrtp2 -- both already staged for Atlas's gstreamer-webrtc-1.0 and not
# re-verified here).
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/telegram/plugin/tgcalls-lite
USRSCTP_SRC=$SRC/third_party/usrsctp
USRSCTP_BUILD=$USRSCTP_SRC/build-arm
TOOLCHAIN=/home/herrie/webos/wpe/cmake-toolchain-glibc-gcc125.cmake

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true

echo "=== usrsctp: configure ==="
rm -rf "$USRSCTP_BUILD"; mkdir -p "$USRSCTP_BUILD"
cmake -S "$USRSCTP_SRC" -B "$USRSCTP_BUILD" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-Dsctp_build_shared_lib=OFF \
	-Dsctp_build_programs=OFF \
	-Dsctp_werror=OFF \
	-Dsctp_debug=OFF

echo "=== usrsctp: build ==="
ninja -C "$USRSCTP_BUILD"

echo "=== usrsctp: result ==="
find "$USRSCTP_BUILD" -name 'libusrsctp.a' -exec ls -la {} \; -exec file {} \;
