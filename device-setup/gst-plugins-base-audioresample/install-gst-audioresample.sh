#!/bin/sh
# install-gst-audioresample.sh — install the gstreamer-0.10 `audioresample` element the stock
# TouchPad build SHIPPED WITHOUT (it has libgstaudioconvert.so but not libgstaudioresample.so).
#
# WHY THIS MATTERS: WebKit's in-app <audio> player (media-pipeline) builds its output chain via
# GstPlaySinkAudioConvert = `audioconvert ! audioresample`. Opus voice notes play because opusdec
# outputs 48 kHz (the sink's rate → no resample needed). But AAC/M4A (Teams voice notes are AAC at
# 8/44.1 kHz) MUST be resampled to the sink rate — and with `audioresample` missing, playsink can't
# build the chain ("Missing element 'audioresample'"), so Teams voice notes DON'T PLAY while every
# other connector's Opus does. Installing this element makes AAC (and any non-48kHz audio) play.
#
# The .so is gst-plugins-base-0.10.35 audioresample cross-built to match the device ABI bit-for-bit
# (same base as the stock libgstaudioconvert.so — gstreamer 0.10.35 / glib 2.16.6). See gst-opus-codec
# for the toolchain notes. Pure add-on: nothing stock is overwritten (unlike the opus ogg swap).
#
# After running, restart the UI (`killall LunaSysMgr`) — or reboot — so the media-pipeline re-scans
# the registry and picks up the new element.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PRE="$HERE/prebuilt"
DEV="${DEV:-topaz-linux}"
nr() { printf '%s\n' "$1" | novacom -d "$DEV" run file://bin/sh; }

echo "== remount rootfs rw =="
nr "mount -o remount,rw /dev/mapper/store-root / || mount -o remount,rw /"

echo "== push libgstaudioresample.so =="
novacom -d "$DEV" put "file:///usr/lib/gstreamer-0.10/libgstaudioresample.so" < "$PRE/libgstaudioresample.so"

echo "== drop the gstreamer registry so it re-scans =="
nr "rm -f /home/root/.gstreamer-0.10/registry.*.bin ~/.gstreamer-0.10/registry.*.bin 2>/dev/null || true"

echo "== verify =="
nr 'gst-inspect-0.10 audioresample >/dev/null 2>&1 && echo "  audioresample: OK" || echo "  audioresample: MISSING"'

echo "== remount ro =="
nr "mount -o remount,ro /dev/mapper/store-root / 2>/dev/null || true"
echo "Done. Restart the UI (killall LunaSysMgr) or reboot, then test in-app AAC playback."
echo "CLI test: gst-launch-0.10 playbin2 uri=file://<voice>.m4a audio-sink=alsasink  (-> PLAYING)"
