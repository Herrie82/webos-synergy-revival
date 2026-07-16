#!/bin/bash
# Rebuild libdiscord.so for webOS ARMv7 (HP TouchPad) WITH the QR remote-auth path.
# The EionRobb Makefile's QR block pulls in NSS via pkg-config, which we don't have; we
# use the OpenSSL RSA backend in discord_rsa.c (USE_OPENSSL_CRYPTO) + a statically linked
# libqrencode.a instead. So bypass the Makefile QR auto-path (USE_QRCODE_AUTH=0) and inject
# the QR defines + include/link flags manually.
set -e
source ~/webos/wpe/env-glibc-gcc125.sh
export PKG_CONFIG_PATH=~/webos/teams-port/deploy/purple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

cd ~/webos/discord-port/src/purple-discord

QRINC=$HOME/webos/discord-port/src/libqrencode/inst/usr/include
QRA=$HOME/webos/discord-port/src/libqrencode/inst/usr/lib/libqrencode.a
SSLINC=$HOME/webos/wpe/staging-glibc-252/include
SSLLIB=$HOME/webos/wpe/staging-glibc-252/lib

rm -f libdiscord.so
make CC="$CC" USE_QRCODE_AUTH=0 \
  CPPFLAGS="-DUSE_QRCODE_AUTH -DUSE_OPENSSL_CRYPTO -I$QRINC -I$SSLINC" \
  LDFLAGS="-L$SSLLIB -Wl,-rpath-link,$SSLLIB $QRA -lssl -lcrypto" \
  libdiscord.so

echo "=== built ==="
ls -la libdiscord.so
arm-unknown-linux-gnueabi-readelf -d libdiscord.so | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D libdiscord.so | grep -c purple_init_plugin)"
