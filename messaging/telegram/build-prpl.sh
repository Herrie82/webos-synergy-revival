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
	# Messaging-only build: no voice (VoIP), no webp/lottie sticker decoding, no translations -
	# matches the shipped prpl and avoids libtgvoip / rlottie / webp deps we don't provide.
	cmake -S "$SRC" -B "$BUILD" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_PREFIX_PATH="$TDLIB;$PURPLE" \
		-DTd_DIR="$TDLIB/lib/cmake/Td" \
		-DNoVoip=TRUE -DNoWebp=TRUE -DNoLottie=TRUE -DNoTranslations=TRUE
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
