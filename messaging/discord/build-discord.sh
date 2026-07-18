#!/bin/bash
# Rebuild libdiscord.so for webOS ARMv7 (HP TouchPad) WITH the QR remote-auth path.
# The EionRobb Makefile's QR block pulls in NSS via pkg-config, which we don't have; we
# use the OpenSSL RSA backend in discord_rsa.c (USE_OPENSSL_CRYPTO) + a statically linked
# libqrencode.a instead. So bypass the Makefile QR auto-path (USE_QRCODE_AUTH=0) and inject
# the QR defines + include/link flags manually.
set -e
source ~/webos/wpe/env-glibc-gcc125.sh
# Authoritative source now lives in this monorepo (webos-synergy-revival); the old
# ~/webos/discord-port tree is GONE. purple staging + libqrencode are re-homed here too.
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
export PKG_CONFIG_PATH=$REPO/messaging/libpurple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

cd $REPO/messaging/discord/plugin/purple-discord

# libqrencode: in-monorepo headers + static lib (build once via libqrencode/build-libqrencode.sh).
QRINC=$REPO/messaging/discord/plugin/libqrencode
QRA=$REPO/messaging/discord/plugin/libqrencode/libqrencode.a
SSLINC=$HOME/webos/wpe/staging-glibc-252/include
SSLLIB=$HOME/webos/wpe/staging-glibc-252/lib
[ -f "$QRA" ] || { echo "libqrencode.a missing; run libqrencode/build-libqrencode.sh first"; exit 1; }

rm -f libdiscord.so
make CC="$CC" USE_QRCODE_AUTH=0 \
  CPPFLAGS="-DUSE_QRCODE_AUTH -DUSE_OPENSSL_CRYPTO -I$QRINC -I$SSLINC" \
  LDFLAGS="-L$SSLLIB -Wl,-rpath-link,$SSLLIB $QRA -lssl -lcrypto" \
  libdiscord.so

echo "=== built ==="
ls -la libdiscord.so
arm-unknown-linux-gnueabi-readelf -d libdiscord.so | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D libdiscord.so | grep -c purple_init_plugin)"
