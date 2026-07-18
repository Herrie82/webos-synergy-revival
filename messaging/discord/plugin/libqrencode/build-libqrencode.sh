#!/bin/bash
# Build libqrencode.a (static, webOS ARMv7) from the in-monorepo sources, so purple-discord's
# QR remote-auth path can link it without any dependency on the old ~/webos/discord-port tree.
# Uses the same cross toolchain env as build-discord.sh. config.h is the minimal hand-written one.
set -e
source ~/webos/wpe/env-glibc-gcc125.sh
cd "$(dirname "$0")"

# Core encoder objects only (exclude qrenc.c, the CLI main).
SRCS="qrencode.c qrinput.c qrspec.c rsecc.c bitstream.c mask.c mqrspec.c mmask.c split.c"
rm -f *.o libqrencode.a
for c in $SRCS; do
  echo "  CC $c"
  $CC -O2 -fPIC -DHAVE_CONFIG_H -I. -c "$c" -o "${c%.c}.o"
done
${AR:-arm-unknown-linux-gnueabi-ar} rcs libqrencode.a $(echo $SRCS | sed 's/\.c/.o/g')
${RANLIB:-arm-unknown-linux-gnueabi-ranlib} libqrencode.a
rm -f *.o
echo "=== built ==="
ls -la libqrencode.a
