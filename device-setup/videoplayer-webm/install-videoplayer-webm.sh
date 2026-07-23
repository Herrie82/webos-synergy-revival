#!/bin/bash
# install-videoplayer-webm.sh - make the stock TouchPad Video player (and Mojo-framework media apps)
# actually PLAY WebM/VP8/VP9, on top of the gst-video-codecs plugins.
#
# Two gates block WebM in the stock player; this installs the fix for both:
#   1. WebKit MediaPlayerPrivatePalm::supportsType() has no video/webm -> a bare .webm <video src>
#      never loads. Fix: patch the shared `mediastream` framework (StreamingPlayEngine) to mislabel
#      webm/mkv as a <source type="video/ogg"> (a type WebKit accepts); the media server then
#      typefinds the real bytes and plays the actual WebM. Other formats are untouched.
#   2. The media server's PlaybinPipeline autoplug prefers the H.264-only hardware `palmvideodecoder`,
#      which chokes on VP9 (chain error -2 -> endless buffering spinner). Fix: LD_PRELOAD
#      libmp-autoplug.so into media-pipeline, which overrides decodebin's autoplug-select/continue
#      with the plain defaults so `vp9dec`/`vp8dec` get chosen (hardware H.264 still wins by rank).
#
# Requires ../gst-video-codecs (vp8dec/vp9dec/matroskademux) + ../gst-opus-codec installed first.
# Messaging inline WebM/Opus uses the same media path; that app-side <source> mislabel lives in the
# core-apps repo (com.palm.app.messaging ConversationItem.js), not here.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; PRE="$HERE/prebuilt"
nr() { printf '%s\n' "$1" | novacom -d usb run file://bin/sh; }

FRAMEWORK_FILES="
/usr/palm/frameworks/mediastream/submission/24mediastream.js
/usr/palm/frameworks/mediastream/submission/24/concatenated.js
/usr/palm/frameworks/mediastream/submission/24/javascript/StreamingPlayEngine.js
"

echo "== remount rootfs rw =="
nr "mount -o remount,rw /dev/mapper/store-root / || mount -o remount,rw /"

echo "== 1) install the autoplug shim -> /usr/lib/libmp-autoplug.so =="
novacom -d usb put "file:///usr/lib/libmp-autoplug.so" < "$PRE/libmp-autoplug.so"

echo "== 2) wrap media-pipeline to preload the shim =="
nr '[ -f /usr/bin/media-pipeline.wrapper.orig ] || cp /usr/bin/media-pipeline /usr/bin/media-pipeline.wrapper.orig'
novacom -d usb put "file:///usr/bin/media-pipeline" < "$HERE/media-pipeline.wrapper"
nr 'chmod 755 /usr/bin/media-pipeline'

echo "== 3) mislabel webm/mkv in the mediastream framework (idempotent, backs up .orig) =="
for f in $FRAMEWORK_FILES; do
  tmp="$(mktemp)"
  novacom -d usb get "file://$f" > "$tmp"
  if [ ! -s "$tmp" ]; then echo "  SKIP (not on device): $f"; rm -f "$tmp"; continue; fi
  if grep -q 'video/ogg' "$tmp" && grep -q '_msrc' "$tmp"; then echo "  already patched: $f"; rm -f "$tmp"; continue; fi
  nr "[ -f $f.orig ] || cp $f $f.orig"
  python3 "$HERE/src/patch-mediastream.py" "$tmp"
  novacom -d usb put "file://$f" < "$tmp"
  rm -f "$tmp"
done

echo "== 4) restart mediaserver =="
nr "stop mediaserver 2>/dev/null; sleep 1; start mediaserver 2>/dev/null; true"

echo "== verify =="
nr 'grep -q libmp-autoplug /usr/bin/media-pipeline && echo "  media-pipeline wrapper: shim preloaded OK" || echo "  media-pipeline wrapper: MISSING shim"'
nr 'for f in /usr/palm/frameworks/mediastream/submission/24mediastream.js /usr/palm/frameworks/mediastream/submission/24/javascript/StreamingPlayEngine.js; do grep -q video/ogg "$f" && echo "  patched: $f" || echo "  NOT patched: $f"; done'

nr "mount -o remount,ro /dev/mapper/store-root / 2>/dev/null || true"
cat <<'MSG'
Done. Test on the device (screen ON), e.g.:
  luna-send -n 1 luna://com.palm.applicationManager/launch \
    '{"id":"com.palm.app.videoplayer","params":{"target":"file:///media/internal/<some>.webm"}}'
Watch /var/log/messages: you should see 'pipeline0 ... is now PLAYING' and NO 'palmvideodecoder ... ERROR'.

To revert:
  cp /usr/bin/media-pipeline.wrapper.orig /usr/bin/media-pipeline
  for f in <the three framework files>; do cp "$f.orig" "$f"; done
  rm -f /usr/lib/libmp-autoplug.so ; stop mediaserver; start mediaserver
MSG
