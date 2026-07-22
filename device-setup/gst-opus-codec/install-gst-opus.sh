#!/bin/bash
# install-gst-opus.sh - deploy the Opus codec into the TouchPad's system gstreamer-0.10 pipeline
# so the stock Video/Music players (and Messaging voice-note playback) decode WhatsApp/Telegram/
# Signal voice notes (Opus-in-Ogg) natively - fast, no Atlas, no transcode.
#
# What it installs (see README.md for how these were built):
#   libgstopus.so   -> /usr/lib/gstreamer-0.10/   (opusdec + opusenc, gst-0.10 backport)
#   libgstogg.so    -> /usr/lib/gstreamer-0.10/   (Opus-aware oggdemux/oggmux; replaces the 2011
#                                                  stock one which tagged Opus streams x-unknown)
#   libopus.so.0    -> /usr/lib/                  (the codec the plugins link)
#
# The old libgstogg.so is backed up to libgstogg.so.orig on first run.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PRE="$HERE/prebuilt"
nr() { printf '%s\n' "$1" | novacom -d usb run file://bin/sh; }

echo "== remount rootfs rw =="
nr "mount -o remount,rw /dev/mapper/store-root / || mount -o remount,rw /"

echo "== back up stock libgstogg.so (once) + push libs =="
nr "cp -n /usr/lib/gstreamer-0.10/libgstogg.so /usr/lib/gstreamer-0.10/libgstogg.so.orig 2>/dev/null || true"
novacom -d usb put "file:///usr/lib/libopus.so.0"                    < "$PRE/libopus.so.0"
novacom -d usb put "file:///usr/lib/gstreamer-0.10/libgstopus.so"    < "$PRE/libgstopus.so"
novacom -d usb put "file:///usr/lib/gstreamer-0.10/libgstogg.so"     < "$PRE/libgstogg.so"
nr "cd /usr/lib && ln -sf libopus.so.0 libopus.so; ldconfig 2>/dev/null || true"

echo "== drop the gstreamer registry so it re-scans =="
nr "rm -f ~/.gstreamer-0.10/registry.*.bin /home/root/.gstreamer-0.10/registry.*.bin 2>/dev/null || true"

echo "== verify =="
nr 'gst-inspect-0.10 opusdec >/dev/null 2>&1 && echo "  opusdec: OK" || echo "  opusdec: MISSING"
gst-inspect-0.10 opusenc >/dev/null 2>&1 && echo "  opusenc: OK" || echo "  opusenc: MISSING"'

echo "== remount ro =="
nr "mount -o remount,ro /dev/mapper/store-root / 2>/dev/null || true"
echo "Done. Test: gst-launch-0.10 filesrc location=<voice>.ogg ! oggdemux ! opusdec ! audioconvert ! alsasink"
