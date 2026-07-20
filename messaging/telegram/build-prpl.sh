#!/bin/bash
# Cross-compile the Telegram prpl (tdlib-purple -> libtelegram-tdlib.so) for webOS 3.0.5 ARM.
# Authoritative build: everything lives in this monorepo (webos-synergy-revival). The old
# ~/webos/telegram-port and ~/webos/teams-port trees are ABANDONED - do not use them.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/telegram/plugin/tdlib-purple      # prpl source (this repo)
BUILD=$SRC/build-arm                                    # build dir (gitignored)
TOOLCHAIN=$SRC/cmake/arm-webos-toolchain.cmake         # ARM cross toolchain (this repo)
TDLIB=$REPO/build-output/tdlib/usr                     # prebuilt tdlib (this repo, gitignored)
PURPLE=$REPO/messaging/libpurple                       # prebuilt libpurple staging (this repo)
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252  # glib/openssl/zlib staging (external dep)
TGVOIP=$REPO/messaging/telegram/plugin/libtgvoip/install/usr  # libtgvoip (build-libtgvoip.sh; gitignored install)

OUT=$BUILD/libtelegram-tdlib.so
STRIPPED=$BUILD/libtelegram-tdlib.stripped.so
STRIP=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/bin/arm-unknown-linux-gnueabi-strip

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

# Configure once (CMakeCache persists); pass -r/--reconfigure to force a fresh configure.
if [ "$1" = "-r" ] || [ "$1" = "--reconfigure" ] || [ ! -f "$BUILD/build.ninja" ]; then
	echo "=== Configuring $BUILD ==="
	rm -rf "$BUILD"; mkdir -p "$BUILD"
	# Voice calls ON (libtgvoip, DSP-off first pass); no webp/lottie/translations.
	# libtgvoip.a resolves opus/asound/openssl from the same glibc staging as the prpl.
	cmake -S "$SRC" -B "$BUILD" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_PREFIX_PATH="$TDLIB;$PURPLE" \
		-DTd_DIR="$TDLIB/lib/cmake/Td" \
		-DNoVoip=FALSE -DNoWebp=TRUE -DNoLottie=TRUE -DNoTranslations=TRUE \
		-Dtgvoip_NO_DSP=TRUE \
		-Dtgvoip_INCLUDE_DIRS="$TGVOIP/include/tgvoip" \
		-Dtgvoip_LIBRARIES="$TGVOIP/lib/libtgvoip.a;$GLIB_STAGING/lib/libopus.so;$GLIB_STAGING/lib/libasound.so;$GLIB_STAGING/lib/libcrypto.so"
fi

echo "=== Building ==="
ninja -C "$BUILD" libtelegram-tdlib.so

echo "=== Stripping ==="
cp "$OUT" "$STRIPPED"
"$STRIP" --strip-unneeded "$STRIPPED"
ls -la "$OUT" "$STRIPPED"
echo "md5 (stripped): $(md5sum "$STRIPPED" | awk '{print $1}')"
echo ""
echo "Deploy the STRIPPED lib to device:"
echo "  /media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2/libtelegram-tdlib.so"
