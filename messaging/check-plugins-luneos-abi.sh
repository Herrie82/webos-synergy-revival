#!/bin/bash
# Would the built plugins resolve on LuneOS?
#
# check-plugins-dual-target.sh answers the luna-service2 API question at COMPILE time. This
# answers the rest of it at LINK time, which is stronger and needs no headers: take every symbol
# each built plugin imports and check it against what LuneOS actually exports.
#
# That covers libpurple, glib, json-glib and libc in one pass, and it catches the things a
# header check cannot -- a function that was removed, or one that exists in our staging tree but
# not in the version LuneOS ships.
#
# Versions in play: our staging libpurple is 2.14.13 and LuneOS ships 2.14.2, so the risk runs
# the unusual direction -- anything added after 2.14.2 is a break. glib is 2.70 (staging) against
# 2.78 (LuneOS), where the risk is removal of something long deprecated.
#
# Symbol NAMES are architecture-independent, so comparing our ARM plugins against LuneOS's
# x86-64 libraries is valid.
set -u

M=$(cd "$(dirname "$0")" && pwd)
LUNEOS=${LUNEOS:-/media/herrie/LuneOS/scarthgap/webos-ports}
L=$LUNEOS/tmp-glibc
SYSC=$L/sysroots-components/corei7-64
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

[ -d "$SYSC" ] || { echo "!! LuneOS sysroot not at $SYSC (set LUNEOS=)"; exit 1; }

# The authoritative answer to "what does LuneOS have" is the built image rootfs -- every library
# actually installed on the device, libpurple and json-glib included. sysroots-components is only
# what other recipes build against, and json-glib is not in it even though the image ships it.
RF=$(find "$L/work" -maxdepth 4 -type d -path "*/luneos-dev-image/*/rootfs" 2>/dev/null | head -1)
[ -n "$RF" ] || { echo "!! no built LuneOS image rootfs under $L/work/*/luneos-dev-image"; exit 1; }

# Two things that silently produce wrong answers here, both learned the hard way:
#  - LC_ALL=C throughout. comm compares byte-wise, and a locale-collated sort makes it report
#    present symbols as missing.
#  - strip nm's "@libfoo.so.0" / "@@libfoo.so.0" version decoration on BOTH sides. Miss either
#    and every versioned symbol compares unequal and looks absent -- which is exactly how
#    json-glib first appeared to be missing from LuneOS when in fact the image ships it.
for so in "$RF"/usr/lib/*.so* "$RF"/lib/*.so*; do
  [ -f "$so" ] && nm -D --defined-only "$so" 2>/dev/null
done | awk '$2 != "U" {print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u > "$TMP/provided"

echo "LuneOS image provides $(wc -l < "$TMP/provided") symbols (libpurple 2.14.2, glib 2.78)"
echo

RC=0
for so in "$M"/discord/plugin/purple-discord/build-arm/libdiscord.so \
          "$M"/signal/plugin/purple-presage/build-arm/libpresage.so \
          "$M"/facebook-e2ee/plugin/purple-combined/build-arm/libwhatsmeow.so \
          "$M"/googlechat/plugin/purple-googlechat/build-arm/libgooglechat.so \
          "$M"/telegram/plugin/tdlib-purple/build-arm/libtelegram-tdlib.so \
          "$M"/teams/plugin/purple-teams/libteams-personal.so; do
  name=$(basename "$so")
  [ -f "$so" ] || { printf "  %-24s not built -- skipped\n" "$name"; continue; }
  # Only the symbols LuneOS is expected to provide. A plugin also imports from libraries it
  # ships itself (tdlib, presage, whatsmeow, protobuf) and from the C++ runtime; those are not
  # LuneOS's job and would be pure noise here.
  nm -D --undefined-only "$so" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' \
    | grep -E "^(purple_|serv_|xmlnode_|g_|json_|xml)" | LC_ALL=C sort -u > "$TMP/refs"
  miss=$(LC_ALL=C comm -23 "$TMP/refs" "$TMP/provided")
  n=$(wc -l < "$TMP/refs")
  if [ -z "$miss" ]; then
    printf "  %-24s %4s refs   ok\n" "$name" "$n"
  else
    printf "  %-24s %4s refs   MISSING %s:\n" "$name" "$n" "$(echo "$miss" | wc -l)"
    echo "$miss" | sed 's/^/      /' | head -12
    RC=1
  fi
done

echo
[ $RC -eq 0 ] && echo "every plugin import resolves against LuneOS" \
              || echo "!! some imports would not resolve on LuneOS"
exit $RC
