#!/bin/bash
# build-libtgvoip.sh — cross-compile grishka/libtgvoip (Telegram's 1:1 voice engine) for webOS 3.0.5
# ARM. Produces a static libtgvoip.a that the Telegram prpl links when built with -DNoVoip=FALSE
# (see build-prpl.sh). Uses the same toolchain + glibc staging as the prpl.
#
# First pass (M1 de-risk): ALSA audio backend, no PulseAudio (no pulse headers staged), and DSP
# (echo cancellation / noise suppression / AGC) DISABLED — that pulls in the bundled webrtc tree
# and isn't needed to prove the call pipeline. NEON DSP is a follow-up.
set -e
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/telegram/plugin/libtgvoip
ST=/home/herrie/webos/wpe/staging-glibc-252
PREFIX=$SRC/install/usr
HOST=arm-unknown-linux-gnueabi

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true

# -fPIC: the .a gets linked into libtelegram-tdlib.so (a shared object).
ARCH="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -O2 -fPIC"
export CPPFLAGS="-I$ST/include -I$ST/include/opus -DTGVOIP_NO_DSP"
export CFLAGS="$ARCH -D_DEFAULT_SOURCE"
export CXXFLAGS="$ARCH -std=c++14"
export LDFLAGS="-L$ST/lib -Wl,-rpath-link,$ST/lib"
export PKG_CONFIG_PATH=$ST/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$ST/lib/pkgconfig

cd "$SRC"
if [ "$1" = "-r" ] || [ ! -f Makefile ]; then
	echo "=== configure ==="
	./configure --host=$HOST --without-pulse --with-alsa --disable-dsp \
		--enable-static --disable-shared --prefix="$PREFIX"
fi
echo "=== build ==="
make -j"$(nproc)"
echo "=== install ==="
make install
echo "=== result ==="
find "$PREFIX" -name 'libtgvoip*.a' -o -name 'VoIPController.h' 2>/dev/null | head
