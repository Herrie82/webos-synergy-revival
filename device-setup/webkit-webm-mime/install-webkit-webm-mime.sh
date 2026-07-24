#!/bin/sh
# install-webkit-webm-mime.sh - RUN ON THE DEVICE (TouchPad).
#
# webOS routes every app/browser <video> through libWebKitLuna's MediaPlayerPrivate(Palm)
# -> the media server. WebKit gates playability with supportsType()/canPlayType(), whose MIME
# list is HARDCODED in the binary (GetTypeCache): video/mp4, the WMV/ASF family, etc. - but NO
# video/webm. So a <video>/<source type="video/webm"> is rejected before the media server (which
# CAN decode WebM/VP9 via the gst-0.10 backport + autoplug shim) ever sees it.
#
# There is no config for this list, so we patch the binary: the ".rodata" string "video/x-ms-wmv"
# (14 bytes) is dead weight on this device (no WMV decoder exists), so we overwrite it in place with
# "video/webm" + NUL padding. That single string is referenced by BOTH the supportsType set and the
# extension->mime map, so canPlayType("video/webm") flips to "maybe" and WebM loads natively.
# Pure string swap in .rodata - no code moves, fully reversible from the backup.
#
# After running, restart the UI (`killall LunaSysMgr`) to reload the patched library.
set -e

LIB=$(ls /usr/lib/libWebKitLuna.so /usr/palm/lib/libWebKitLuna.so 2>/dev/null | head -1)
[ -z "$LIB" ] && { echo "libWebKitLuna.so not found"; exit 1; }
OLD="video/x-ms-wmv"
NEW='video/webm'          # 10 bytes; padded to 14 with NULs below
BACKUP=/media/internal/libWebKitLuna.so.prewebm

if strings "$LIB" | grep -q "^video/webm$"; then
  echo "already patched ($LIB has video/webm) - nothing to do"; exit 0
fi

# Byte offset of the target string (unique in the binary).
OFF=$(grep -abo "$OLD" "$LIB" | head -1 | cut -d: -f1)
[ -z "$OFF" ] && { echo "target string '$OLD' not found - unexpected lib build, aborting"; exit 1; }
echo "patching $LIB at byte offset $OFF: '$OLD' -> '$NEW' (NUL-padded)"

[ -f "$BACKUP" ] || cp "$LIB" "$BACKUP"
echo "backup: $BACKUP"

mount -o remount,rw / 2>/dev/null || true
# 14 bytes: "video/webm" + 4 NULs, so the whole old string (incl. its "-wmv" tail) is overwritten.
printf 'video/webm\000\000\000\000' | dd of="$LIB" bs=1 seek="$OFF" count=14 conv=notrunc 2>/dev/null

if strings "$LIB" | grep -q "^video/webm$"; then
  echo "OK: video/webm now in libWebKitLuna. Restart the UI to load it:  killall LunaSysMgr"
else
  echo "verification FAILED - restoring backup"; cp "$BACKUP" "$LIB"; exit 1
fi
