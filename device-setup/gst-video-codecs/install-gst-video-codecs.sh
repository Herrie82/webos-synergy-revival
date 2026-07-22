#!/bin/bash
# install-gst-video-codecs.sh - deploy WebM (VP8/VP9) + Matroska + Speex codecs into the TouchPad's
# stock gstreamer-0.10 pipeline, so the stock Video player / Messaging attachments play WebM video
# (Telegram/Discord clips & video stickers) and Speex audio natively.
#
# Installs (all self-contained; libvpx is static-linked into libgstvpx.so):
#   libgstvpx.so       -> /usr/lib/gstreamer-0.10/   (vp8dec + vp9dec, libvpx 1.3.0 backport)
#   libgstmatroska.so  -> /usr/lib/gstreamer-0.10/   (matroskademux/mux; patched to know VP9)
#   libgstspeex.so     -> /usr/lib/gstreamer-0.10/   (speexdec)
#
# Pairs with ../gst-opus-codec (Opus). See README.md for how these were cross-built.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; PRE="$HERE/prebuilt"
nr() { printf '%s\n' "$1" | novacom -d usb run file://bin/sh; }
echo "== remount rootfs rw =="
nr "mount -o remount,rw /dev/mapper/store-root / || mount -o remount,rw /"
echo "== push plugins =="
for so in libgstvpx.so libgstmatroska.so libgstspeex.so; do
  novacom -d usb put "file:///usr/lib/gstreamer-0.10/$so" < "$PRE/$so"
done
echo "== drop registry to re-scan =="
nr "rm -f ~/.gstreamer-0.10/registry.*.bin /home/root/.gstreamer-0.10/registry.*.bin 2>/dev/null || true"
echo "== verify =="
nr 'for e in vp8dec vp9dec matroskademux speexdec; do gst-inspect-0.10 $e >/dev/null 2>&1 && echo "  $e: OK" || echo "  $e: MISSING"; done'
nr "mount -o remount,ro /dev/mapper/store-root / 2>/dev/null || true"
echo "Done. Test WebM: gst-launch-0.10 filesrc location=<x>.webm ! matroskademux ! vp9dec ! fakesink"
